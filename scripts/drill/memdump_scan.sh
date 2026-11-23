#!/usr/bin/env bash
# shellcheck shell=bash
#
# memdump_scan.sh — zifiri seizure drill, leg 2 (memory dump)
#
# After the traffic stops it waits, refreshes the nginx workers, dumps the
# memory of the BEAM and nginx processes with gcore and searches the dumps for
# the canary.
#
# Why refresh the workers: old nginx workers may still hold the client address
# in their buffers from the request. Refreshing kills them; the new workers saw
# no traffic at all, so they must be clean. On the BEAM side the canary IP must
# never appear (unix socket + header stripping, §5.1).
#
# Requirement: gdb (gcore), coreutils. If gcore is missing the script does not
# pass silently: it fails loudly and exits 2.
#
set -euo pipefail

PROG=${0##*/}
CANARY_IP=${CANARY_IP:-172.31.77.7}
QUIET_SECONDS=${DRILL_QUIET_SECONDS:-60}
OUT=${DRILL_OUT:-/run/zifiri-drill}
TOKEN=${CANARY_TOKEN:-}
KEEP=auto
DO_RELOAD=1
INCLUDE_OLD=0
DRY_RUN=0
NGINX_RELOAD_CMD=${NGINX_RELOAD_CMD:-}
EXEC_PREFIX=${DRILL_EXEC_PREFIX:-}
EXEC=()
VERBOSE=0

usage() {
  cat <<EOF
$PROG — seizure drill, leg 2: memory dump scan

Usage:
  $PROG [options]

Options:
  --quiet-seconds N   Seconds to wait after the traffic stops (default: $QUIET_SECONDS)
  --out DIR           Directory the dumps are written to (default: $OUT)
  --keep              Do not delete the dumps even when green
  --no-reload         Do not refresh the nginx workers (old workers are scanned)
  --include-old       Also dump old workers that could not be refreshed (turns red)
  --dry-run           Only print what would be done
  --ip ADDRESS        Test-network IP
  -v, --verbose       Verbose: processes, dump sizes, every scan step
  -h, --help          This text

Environment:
  CANARY_IP, CANARY_TOKEN, DRILL_QUIET_SECONDS, DRILL_OUT,
  NGINX_RELOAD_CMD, DRILL_EXEC_PREFIX

  DRILL_EXEC_PREFIX: to run the commands inside the container,
  e.g. DRILL_EXEC_PREFIX="docker exec -u root zifiri-app"
  NGINX_RELOAD_CMD: command to use instead of the default 'nginx -s reload'.

Exit codes:
  0  green: no canary IP in the dumps
  1  red: canary IP found in a dump
  2  unproven: no gcore, reload failed, dump could not be taken
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
vlog() { if ((VERBOSE)); then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

while (($#)); do
  case $1 in
    --quiet-seconds) QUIET_SECONDS=${2:-}; shift 2 || die "missing value" ;;
    --out) OUT=${2:-}; shift 2 || die "missing value" ;;
    --keep) KEEP=yes; shift ;;
    --no-reload) DO_RELOAD=0; shift ;;
    --include-old) INCLUDE_OLD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --ip) CANARY_IP=${2:-}; shift 2 || die "missing value" ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $QUIET_SECONDS =~ ^[0-9]+$ ]] || die "invalid seconds: $QUIET_SECONDS"
[[ $CANARY_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "invalid IPv4: $CANARY_IP"

if [[ -n $EXEC_PREFIX ]]; then
  # shellcheck disable=SC2206
  EXEC=($EXEC_PREFIX)
fi
run() { "${EXEC[@]}" "$@"; }

# ---------------------------------------------------------------- preconditions

if ((DRY_RUN == 0)) && ! command -v gcore >/dev/null 2>&1 && [[ -z $EXEC_PREFIX ]]; then
  die "gcore not found. Install gdb (Debian/Ubuntu: apt install gdb) or run
     inside the container with DRILL_EXEC_PREFIX. No silent pass:
     without memory evidence the drill is not green."
fi
if [[ -n $EXEC_PREFIX ]] && ((DRY_RUN == 0)); then
  run sh -c 'command -v gcore >/dev/null' ||
    die "gcore is not available inside $EXEC_PREFIX. Install gdb in the container or take the dump from the host."
fi

if [[ $EUID -ne 0 ]]; then
  SCOPE=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || printf '0')
  if [[ $SCOPE != 0 ]]; then
    warn "yama/ptrace_scope=$SCOPE; gcore may fail (root or the same user is required)"
  fi
fi

IFS=. read -r O1 O2 O3 O4 <<<"$CANARY_IP"
TUPLE="{$O1,$O2,$O3,$O4}"
PLAIN_RE="(^|[^0-9.])${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"
MAPPED_RE="::ffff:${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"

if [[ -z $TOKEN ]]; then
  TOKEN=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ -n $TOKEN ]] || TOKEN=$(python3 -c 'import os;print(os.urandom(16).hex())' 2>/dev/null)
  TOKEN="zifiri-canary-${TOKEN:-00000000000000000000000000000000}"
  warn "CANARY_TOKEN not given; the body canary is meaningless (only the IP is searched)"
  SCAN_TOKEN=0
else
  SCAN_TOKEN=1
fi

# ---------------------------------------------------------------- wait

printf '\n== memory dump scan ==\n'
printf 'IP            : %s\n' "$CANARY_IP"
printf 'wait          : %s s (traffic must have stopped)\n' "$QUIET_SECONDS"
if ((DRY_RUN)); then
  printf 'mode          : dry-run, nothing was done\n'
fi
if ((DRY_RUN == 0 && QUIET_SECONDS > 0)); then
  sleep "$QUIET_SECONDS"
fi

# ---------------------------------------------------------------- nginx reload

mapfile -t OLD_WORKERS < <(run pgrep -f 'nginx: worker process' 2>/dev/null || true)
RELOAD_STATUS="skipped"
if ((DO_RELOAD)); then
  if ((DRY_RUN)); then
    RELOAD_STATUS="dry-run"
  elif [[ -n $NGINX_RELOAD_CMD ]]; then
    if $NGINX_RELOAD_CMD >/dev/null 2>&1; then RELOAD_STATUS="ok (custom command)"; else RELOAD_STATUS="FAILED"; fi
  elif run nginx -s reload >/dev/null 2>&1; then
    RELOAD_STATUS="ok"
  elif command -v systemctl >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
    RELOAD_STATUS="ok (systemctl)"
  else
    RELOAD_STATUS="FAILED"
  fi

  if [[ $RELOAD_STATUS == FAILED ]]; then
    printf 'nginx reload  : FAILED\n'
    die "the nginx workers could not be refreshed. Pass NGINX_RELOAD_CMD (e.g.
     NGINX_RELOAD_CMD='docker exec zifiri-app nginx -s reload') or scan the old
     workers on purpose with --no-reload."
  fi

  # Wait for the old workers to exit; if they do not, the dumps would mislead.
  if ((DRY_RUN == 0 && ${#OLD_WORKERS[@]} > 0)); then
    waited=0
    while ((waited < 30)); do
      alive=0
      for pid in "${OLD_WORKERS[@]}"; do
        run kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
      done
      ((alive == 0)) && break
      sleep 1
      waited=$((waited + 1))
    done
    if ((alive > 0)); then
      warn "old nginx workers are still alive: $alive of them (30 s drain)"
      RELOAD_STATUS="$RELOAD_STATUS, drain incomplete"
    fi
  fi
fi
printf 'nginx reload  : %s (old workers: %d)\n' "$RELOAD_STATUS" "${#OLD_WORKERS[@]}"

# ---------------------------------------------------------------- processes

mapfile -t BEAM_PIDS < <(run pgrep -x beam.smp 2>/dev/null || true)
if ((${#BEAM_PIDS[@]} == 0)); then
  mapfile -t BEAM_PIDS < <(run pgrep -f 'beam.smp' 2>/dev/null || true)
fi

if ((DO_RELOAD)); then
  mapfile -t NGINX_PIDS < <(run pgrep -f 'nginx: worker process' 2>/dev/null || true)
  if ((${#NGINX_PIDS[@]} == 0)); then
    mapfile -t NGINX_PIDS < <(run pgrep -x nginx 2>/dev/null || true)
  fi
else
  NGINX_PIDS=("${OLD_WORKERS[@]}")
fi

if ((INCLUDE_OLD)) && ((${#OLD_WORKERS[@]})); then
  for pid in "${OLD_WORKERS[@]}"; do
    run kill -0 "$pid" 2>/dev/null && NGINX_PIDS+=("$pid")
  done
fi

if ((${#BEAM_PIDS[@]} == 0 && ${#NGINX_PIDS[@]} == 0)); then
  die "neither a BEAM nor an nginx process found. If you are inside a container, pass DRILL_EXEC_PREFIX."
fi

printf 'BEAM          : %s\n' "${BEAM_PIDS[*]:-(none)}"
printf 'nginx         : %s\n' "${NGINX_PIDS[*]:-(none)}"
vlog "reload status: $RELOAD_STATUS"
vlog "to dump: ${#BEAM_PIDS[@]} BEAM + ${#NGINX_PIDS[@]} nginx processes"

# ---------------------------------------------------------------- space check

mkdir -p -- "$OUT" 2>/dev/null || die "could not create output dir: $OUT"
if [[ -z $EXEC_PREFIX ]]; then
  FREE_KB=$(df -Pk "$OUT" 2>/dev/null | awk 'NR==2{print $4}' || true)
  vlog "disk: ${FREE_KB:-?} KB free on $OUT"
  RSS_KB=0
  for pid in "${BEAM_PIDS[@]}" "${NGINX_PIDS[@]}"; do
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
    [[ -n $rss ]] && RSS_KB=$((RSS_KB + rss))
  done
  if [[ -n ${FREE_KB:-} && $FREE_KB -lt $((RSS_KB * 3 / 2)) ]]; then
    warn "${FREE_KB}KB free on $OUT, total RSS of the processes is ${RSS_KB}KB. The dumps may not fit."
  fi
fi

if ((DRY_RUN)); then
  printf 'dumps         : (dry-run) %s\n\nRESULT: UNPROVEN — dry-run.\n' "$OUT"
  exit 2
fi

# ---------------------------------------------------------------- dump

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMPDIR=$OUT/memdump-$STAMP
mkdir -p -- "$DUMPDIR" || die "could not create dump dir: $DUMPDIR"

CORES=()
FAILED=0
dump_one() {
  local label=$1 pid=$2 out
  out=$DUMPDIR/$label
  if run gcore -o "$out" "$pid" >"$DUMPDIR/$label.gcore.log" 2>&1; then
    if [[ ! -f $out.$pid ]]; then
      # With DRILL_EXEC_PREFIX gcore may have written inside the container; in
      # that case the dump cannot be read from the host and cannot be "clean".
      if [[ -n $EXEC_PREFIX ]] && run test -f "$out.$pid"; then
        die "the dump was created inside the container but is not visible from the host: $out.$pid
     bind-mount $OUT into the container (docker run -v $OUT:$OUT)
     or take the dump from the host. We do not call an invisible dump 'clean'."
      fi
      printf '  %-14s pid=%-7s FAILED (no dump file)\n' "$label" "$pid"
      FAILED=$((FAILED + 1))
      return 1
    fi
    CORES+=("$out.$pid")
    vlog "dump written: $out.$pid"
    printf '  %-14s pid=%-7s %s\n' "$label" "$pid" "$(du -h "$out.$pid" 2>/dev/null | cut -f1)"
    return 0
  fi
  printf '  %-14s pid=%-7s FAILED (%s)\n' "$label" "$pid" "$(tail -n 1 "$DUMPDIR/$label.gcore.log" 2>/dev/null)"
  FAILED=$((FAILED + 1))
  return 1
}

printf 'dump dir      : %s\n' "$DUMPDIR"
for pid in "${BEAM_PIDS[@]}"; do dump_one beam "$pid" || true; done
for pid in "${NGINX_PIDS[@]}"; do dump_one nginx "$pid" || true; done

((${#CORES[@]})) || die "no dump could be taken ($FAILED failed). Check the gdb/ptrace permissions."

# ---------------------------------------------------------------- scan

RED=0
printf '\ndump scan:\n'
for core in "${CORES[@]}"; do
  name=${core##*/}
  flags=()
  hit=0
  vlog "scanning: $core"

  if grep -aqE -e "$PLAIN_RE" "$core"; then flags+=("ip-plain"); hit=1; fi
  if grep -aqF -e "$TUPLE" "$core"; then flags+=("ip-tuple"); hit=1; fi
  if grep -aqE -e "$MAPPED_RE" "$core"; then flags+=("ip-mapped"); hit=1; fi

  if python3 - "$CANARY_IP" "$core" <<'PY'
import sys

ip, path = sys.argv[1], sys.argv[2]
needle = bytes(int(p) for p in ip.split("."))
chunk = 8 << 20
prev = b""
with open(path, "rb") as fh:
    while True:
        data = fh.read(chunk)
        if not data:
            break
        buf = prev + data
        if needle in buf:
            sys.exit(0)
        prev = buf[-(len(needle) - 1):]
sys.exit(1)
PY
  then
    flags+=("ip-raw")
    hit=1
  fi

  token_hit="none"
  if ((SCAN_TOKEN)) && grep -aqF -e "$TOKEN" "$core"; then
    token_hit="PRESENT (informational: published content)"
  fi

  if ((hit)); then
    RED=$((RED + 1))
    printf '  %-28s RED: %s | token: %s\n' "$name" "${flags[*]}" "$token_hit"
  else
    printf '  %-28s clean | token: %s\n' "$name" "$token_hit"
  fi
done

# ---------------------------------------------------------------- cleanup

if ((RED == 0)) && [[ $KEEP != yes ]]; then
  rm -rf -- "$DUMPDIR"
  printf '\ndumps deleted (green). Use --keep to retain them.\n'
else
  printf '\ndumps: %s\n' "$DUMPDIR"
fi

if ((RED > 0)); then
  printf '\nRESULT: RED — canary IP found in %d dumps. Drill failed.\n' "$RED"
  exit 1
fi
if ((FAILED > 0)); then
  printf '\nRESULT: UNPROVEN — %d processes could not be dumped, the scan is incomplete.\n' "$FAILED"
  exit 2
fi
printf '\nRESULT: GREEN — no canary IP in %d dumps.\n' "${#CORES[@]}"
exit 0
