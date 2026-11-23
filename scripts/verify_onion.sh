#!/usr/bin/env bash
# shellcheck shell=bash
#
# verify_onion.sh — onion/clearnet claim audit
#
# What it does: splits the `nginx -T` output (the fully resolved configuration)
# into server blocks and verifies, per mode, that the lines the claim rests on
# are really there:
#
#   1. `access_log off`        — in every proxy block; no file log anywhere
#   2. `proxy_set_header X-Forwarded-For ""` — in every proxy block (no IP leak)
#   3. `Onion-Location`        — ONLY in the clearnet block, not in the onion one
#   4. `real_ip` / `set_real_ip_from` / `proxy_protocol` — nowhere
#
# Why `nginx -T`: it audits the tree nginx actually loaded, not the template;
# includes, http level and server blocks appear in a single stream.
#
# Exit codes:
#   0  every check passed
#   1  at least one check failed (the missing line is printed by name)
#   2  usage error
#   3  nginx not found (NO silent pass — an unverified claim is not green)
#
# bash + awk + grep only. With `--docker` the nginx in the container is checked.

set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=

NGINX_BIN=${NGINX_BIN:-nginx}
CONFIG=
USE_DOCKER=0
COMPOSE_FILE=${COMPOSE_FILE:-$SELF_DIR/../infra/docker-compose.yml}
VERBOSE=0

FAILS=0
CHECKS=0
TMPDIR_V=

usage() {
  cat <<EOF
$PROG — onion/clearnet claim audit (through nginx -T)

Usage:
  $PROG [options]

Options:
  --config FILE     Audit this file instead of the template: \`nginx -T -c FILE\`
                    (for the rendered nginx.conf.rendered)
  --nginx PATH      nginx binary (default: \$NGINX_BIN or nginx from PATH)
  --docker          Audit the nginx in the container:
                    docker compose -f <compose> exec -T nginx nginx -T
  --compose FILE    compose file for --docker
                    (default: $COMPOSE_FILE)
  -v, --verbose     Print every audited line too
  -h, --help        This text

Checks:
  * \`access_log off;\` in every proxy block
  * \`proxy_set_header X-Forwarded-For "";\` in every proxy block
  * \`Onion-Location\` only in the clearnet (443) block
  * no \`real_ip\`, \`set_real_ip_from\`, \`proxy_protocol\` anywhere

Exit codes: 0 passed · 1 a check failed · 2 usage error · 3 no nginx

Example:
  $PROG --config infra/nginx.conf.rendered
  $PROG --docker
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'Help: %s --help\n' "$PROG" >&2
  exit 2
}

cleanup() {
  # The last command of an EXIT trap overrides the exit code; always return 0.
  if [ -n "$TMPDIR_V" ]; then rm -rf -- "$TMPDIR_V"; fi
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case $1 in
    --config)   [ $# -ge 2 ] || die_usage "--config wants a value"; CONFIG=$2; shift 2 ;;
    --config=*) CONFIG=${1#*=}; shift ;;
    --nginx)    [ $# -ge 2 ] || die_usage "--nginx wants a value"; NGINX_BIN=$2; shift 2 ;;
    --nginx=*)  NGINX_BIN=${1#*=}; shift ;;
    --docker)   USE_DOCKER=1; shift ;;
    --compose)  [ $# -ge 2 ] || die_usage "--compose wants a value"; COMPOSE_FILE=$2; shift 2 ;;
    --compose=*) COMPOSE_FILE=${1#*=}; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

ok()   { CHECKS=$((CHECKS + 1)); printf '  ok      %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  MISSING %s\n' "$1" >&2; }
note() { [ "$VERBOSE" -eq 1 ] && printf '        %s\n' "$1" || true; }

# --- find nginx -------------------------------------------------------------
DUMP=
if [ "$USE_DOCKER" -eq 1 ]; then
  command -v docker >/dev/null 2>&1 || {
    printf '%s: nginx not found — no docker either, the container cannot be audited\n' "$PROG" >&2
    exit 3
  }
  [ -f "$COMPOSE_FILE" ] || {
    printf '%s: compose file missing: %s\n' "$PROG" "$COMPOSE_FILE" >&2
    exit 3
  }
  printf '%s: auditing the nginx in the container (%s)\n' "$PROG" "$COMPOSE_FILE"
  if ! DUMP=$(docker compose -f "$COMPOSE_FILE" exec -T nginx nginx -T 2>&1); then
    printf '%s: nginx not found — the container is not running or the image has no nginx\n' "$PROG" >&2
    printf '%s\n' "$DUMP" | tail -n 5 >&2
    exit 3
  fi
else
  if ! command -v "$NGINX_BIN" >/dev/null 2>&1; then
    printf '%s: nginx not found (%s) — no audit possible on this machine.\n' "$PROG" "$NGINX_BIN" >&2
    printf '%s: claim NOT VERIFIED; try --docker for the container or --config for the rendered file.\n' "$PROG" >&2
    exit 3
  fi
  printf '%s: running %s -T\n' "$PROG" "$NGINX_BIN"
  if [ -n "$CONFIG" ]; then
    [ -f "$CONFIG" ] || { printf '%s: file missing: %s\n' "$PROG" "$CONFIG" >&2; exit 2; }
    if ! DUMP=$("$NGINX_BIN" -T -c "$CONFIG" 2>&1); then
      printf '%s: nginx -T failed (invalid configuration):\n' "$PROG" >&2
      printf '%s\n' "$DUMP" | tail -n 10 >&2
      exit 1
    fi
  else
    if ! DUMP=$("$NGINX_BIN" -T 2>&1); then
      printf '%s: nginx -T failed (invalid configuration):\n' "$PROG" >&2
      printf '%s\n' "$DUMP" | tail -n 10 >&2
      exit 1
    fi
  fi
fi

[ -n "$DUMP" ] || { printf '%s: nginx -T returned nothing\n' "$PROG" >&2; exit 3; }

TMPDIR_V=$(mktemp -d "${TMPDIR:-/tmp}/verify_onion.XXXXXX")
ALL=$TMPDIR_V/all.conf
# Comment lines are dropped: the checks look only at ACTIVE directives. Otherwise
# a comment such as "no Onion-Location" would trip the check the wrong way.
printf '%s\n' "$DUMP" | sed -E '/^[[:space:]]*#/d' > "$ALL"

# --- split the server blocks ------------------------------------------------
# `nginx -T` prints every file under a "# configuration file ..." header; block
# boundaries are found by counting braces. nginx never opens a block on one line
# (in the generated tree `server {` sits on its own line), so counting suffices.
awk -v out="$TMPDIR_V" '
  function brace_count(s,   t, o, c) { t = s; o = gsub(/\{/, "", t); c = gsub(/\}/, "", t); return o - c }
  /^[[:space:]]*server[[:space:]]*\{[[:space:]]*$/ && !inb {
    inb = 1; n++; f = sprintf("%s/srv.%03d.conf", out, n); depth = 0
  }
  inb {
    print >> f
    depth += brace_count($0)
    if (depth <= 0) { inb = 0; close(f) }
  }
' "$ALL"

SRV_FILES=("$TMPDIR_V"/srv.*.conf)
if [ ! -e "${SRV_FILES[0]}" ]; then
  printf '%s: no server block found — the configuration is not in the expected form\n' "$PROG" >&2
  exit 1
fi

PROXY_BLOCKS=0
ONION_BLOCKS=0
CLEARNET_BLOCKS=0

for f in "${SRV_FILES[@]}"; do
  name=$(basename -- "$f" .conf)
  listens=$(grep -Eo '^[[:space:]]*listen[[:space:]]+[^;]+' "$f" | awk '{print $2}' | paste -sd, - || true)
  sname=$(grep -Eo '^[[:space:]]*server_name[[:space:]]+[^;]+' "$f" | sed -E 's/^[[:space:]]*server_name[[:space:]]+//' | paste -sd, - || true)
  label="$name (listen=$listens server_name=$sname)"

  is_proxy=0
  grep -qE '^[[:space:]]*proxy_pass[[:space:]]' "$f" && is_proxy=1
  is_onion=0
  printf '%s' "$listens" | grep -q '8081' && is_onion=1
  is_clearnet=0
  printf '%s' "$listens" | grep -qE '(^|,)443($|,)' && is_clearnet=1

  if [ "$is_proxy" -eq 1 ]; then
    PROXY_BLOCKS=$((PROXY_BLOCKS + 1))
    printf '%s:\n' "$label"

    if grep -qE '^[[:space:]]*access_log[[:space:]]+off;' "$f"; then
      ok "access_log off"
    else
      fail "$label — no 'access_log off;' (the access log may stay on)"
    fi

    if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]+"";' "$f"; then
      ok 'proxy_set_header X-Forwarded-For ""'
    else
      fail "$label — no 'proxy_set_header X-Forwarded-For \"\";' (the client IP reaches BEAM)"
    fi

    if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+X-Real-IP[[:space:]]+"";' "$f"; then
      ok 'proxy_set_header X-Real-IP ""'
    else
      fail "$label — no 'proxy_set_header X-Real-IP \"\";'"
    fi

    if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+Accept-Encoding[[:space:]]+"";' "$f"; then
      ok 'proxy_set_header Accept-Encoding ""'
    else
      fail "$label — no 'proxy_set_header Accept-Encoding \"\";' (the bucket size is distorted)"
    fi
  fi

  if [ "$is_onion" -eq 1 ]; then
    ONION_BLOCKS=$((ONION_BLOCKS + 1))
    if grep -qE '^[[:space:]]*add_header[[:space:]]+Onion-Location' "$f"; then
      fail "$label — 'Onion-Location' in the onion block (it belongs in clearnet only)"
    else
      ok "no Onion-Location in the onion block"
    fi
    if grep -qE '^[[:space:]]*access_log[[:space:]]+off;' "$f"; then
      : # counted above if this is a proxy block; otherwise verified here
      [ "$is_proxy" -eq 1 ] || ok "access_log off"
    else
      [ "$is_proxy" -eq 1 ] || fail "$label — no 'access_log off;'"
    fi
  fi

  if [ "$is_clearnet" -eq 1 ]; then
    CLEARNET_BLOCKS=$((CLEARNET_BLOCKS + 1))
    # After the render the value is the .onion address; the FORM is checked, not
    # the template variable: add_header Onion-Location "http://<address><path>" always;
    if grep -qE '^[[:space:]]*add_header[[:space:]]+Onion-Location[[:space:]]+"http://[^"]+"[[:space:]]+always;' "$f"; then
      ok "Onion-Location in the clearnet block"
    else
      fail "$label — no 'add_header Onion-Location \"http://<onion-address>\" always;' (the §11.3 announcement disappears)"
    fi
  fi
done

printf 'http level:\n'
if grep -qE '^[[:space:]]*access_log[[:space:]]+off;' "$ALL"; then
  ok "access_log off (active in at least one place)"
else
  fail "http level — no 'access_log off;' at all"
fi

BAD_LOG=$(awk '/^[[:space:]]*access_log[[:space:]]/ && $0 !~ /^[[:space:]]*access_log[[:space:]]+off[[:space:]]*;/ {print NR": "$0}' "$ALL" | head -n 3 | paste -sd';' - || true)
if [ -n "$BAD_LOG" ]; then
  fail "a file/target log is defined somewhere: $BAD_LOG"
else
  ok "no file log defined anywhere"
fi

if grep -qE '^[[:space:]]*(real_ip_header|set_real_ip_from)\b|proxy_protocol' "$ALL"; then
  fail "real_ip / set_real_ip_from / proxy_protocol in use — XFF is trusted, the IP can leak"
else
  ok "no real_ip / proxy_protocol"
fi

if grep -q 'proxy_set_header[[:space:]]*X-Forwarded-For' "$ALL"; then
  xff=$(grep -cE '^[[:space:]]*proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]+"";' "$ALL" || true)
  if [ "$xff" -ge "$PROXY_BLOCKS" ] && [ "$PROXY_BLOCKS" -gt 0 ]; then
    ok "X-Forwarded-For cleared in $xff/$PROXY_BLOCKS proxy blocks"
  else
    fail "X-Forwarded-For cleared on $xff lines, there are $PROXY_BLOCKS proxy blocks"
  fi
else
  fail "no 'proxy_set_header X-Forwarded-For \"\";' anywhere"
fi

if [ "$ONION_BLOCKS" -eq 0 ]; then
  fail "no onion block (listen 127.0.0.1:8081) — the onion claim has no basis in the configuration"
fi
if [ "$CLEARNET_BLOCKS" -eq 0 ]; then
  fail "no clearnet 443 block"
fi

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%s: FAILED — %d/%d checks failed. The onion/clearnet claim cannot be defended with this configuration.\n' \
    "$PROG" "$FAILS" "$CHECKS" >&2
  exit 1
fi

printf '%s: passed — %d checks (proxy blocks: %d, onion: %d, clearnet: %d)\n' \
  "$PROG" "$CHECKS" "$PROXY_BLOCKS" "$ONION_BLOCKS" "$CLEARNET_BLOCKS"

