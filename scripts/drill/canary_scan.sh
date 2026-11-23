#!/usr/bin/env bash
# shellcheck shell=bash
#
# canary_scan.sh — zifiri seizure drill, leg 1 (disk image)
#
# What it does: searches for a fixed test-network IP and a random canary string
# on disk and in process environments. The IP is searched in four forms:
#
#   1. plain text          172.31.77.7
#   2. Erlang tuple        {172,31,77,7}
#   3. raw four bytes      (grep -a, byte pattern; binary files)
#   4. IPv4-mapped IPv6    ::ffff:172.31.77.7
#
# Places scanned (default): /var/lib/docker (including container json logs),
# $ZIFIRI_DB_DIR/*.db + *.db-wal + *.db-shm, /tmp, /proc/*/environ,
# journald (journalctl --since).
#
# Every grep call uses `-a`: WAL/SHM, container json logs and core files are
# binary; without `-a` grep says "binary file matches" and the line context is
# lost. File size is not a scan limit (DRILL_MAX_SCAN_BYTES only bounds the raw
# byte stage).
#
# A single hit = red (exit 1).
#
# Uses only coreutils + grep. Bash 4.4+ (mapfile -d).
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=

CANARY_IP=${CANARY_IP:-172.31.77.7}
SINCE=${DRILL_SINCE:-"2 hours ago"}
DB_DIR=${ZIFIRI_DB_DIR:-/var/lib/zifiri}
DOCKER_ROOT=${DRILL_DOCKER_ROOT:-/var/lib/docker}
TMP_ROOT=${DRILL_TMP_ROOT:-/tmp}
MAX_BYTES=${DRILL_MAX_SCAN_BYTES:-0}
TOKEN=${CANARY_TOKEN:-}
MODE=full
VERBOSE=0
ROOTS=()
ROOTS_EXPLICIT=0
FORCE_JOURNALD=0
SCAN_PROC_ENV=1
HITS_FILE=

usage() {
  cat <<EOF
$PROG — seizure drill, leg 1: canary scan

Usage:
  $PROG [options]
  $PROG --root DIR [--root DIR...]      (targeted scan)

Options:
  --ip ADDRESS      Test-network IP (default: $CANARY_IP)
  --token STRING    Canary string to use (default: generated)
  --since TIME      journalctl --since value (default: "$SINCE")
  --root DIR        Extra directory to scan (repeatable)
  --docker-root D   Docker data directory (default: $DOCKER_ROOT)
  --db-dir D        Published DB directory (default: $DB_DIR)
  --tmp-root D      Temporary file root (default: $TMP_ROOT)
  --max-bytes N     Per-file cap in the raw byte stage (0 = unlimited)
  --hits-file F     Write hits to file F in machine-readable form
                    (line: form<TAB>path<TAB>red|info)
  --emit            Only generate the canary, print a send example, exit
  --ip-only         Search only for the IP forms
  --token-only      Search only for the body canary
  --no-proc-env     Do not scan /proc/*/environ
  --journald        Scan journald even if --root was given
  -v, --verbose     What is being scanned, how many files, which stage
  -h, --help        This text

Environment variables:
  CANARY_IP, CANARY_TOKEN, DRILL_SINCE, DRILL_STATE_DIR,
  DRILL_MAX_SCAN_BYTES, ZIFIRI_DB_DIR, DRILL_DOCKER_ROOT, DRILL_TMP_ROOT

Scope rule:
  Without --root, docker + DB + $TMP_ROOT + journald are scanned.
  With --root, ONLY the given roots are scanned; the automatic docker/DB/
  journald checks are off (use --journald for journald). This is for a targeted
  (negative control) scan; the drill report requires a full scan.

Exit codes:
  0  green: no canary anywhere
  1  red: at least one hit
  2  unproven: the scan was incomplete (no journald, no permission, empty test)
  3  environment missing: no docker — part of the disk leg could not be scanned

  3 is not green. A drill that passes silently is worse than a red one.

Example:
  # 1) generate a canary, send the traffic
  $PROG --emit
  # 2) scan with the same canary
  CANARY_TOKEN=zifiri-canary-... $PROG
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
vlog() { if ((VERBOSE)); then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

need_value() {
  if (($# >= 2)) && [[ -n $2 ]]; then return 0; fi
  die "$1 wants a value"
}

while (($#)); do
  case $1 in
    --ip) need_value "$@"; CANARY_IP=$2; shift 2 ;;
    --token) need_value "$@"; TOKEN=$2; shift 2 ;;
    --since) need_value "$@"; SINCE=$2; shift 2 ;;
    --root) need_value "$@"; ROOTS+=("$2"); ROOTS_EXPLICIT=1; shift 2 ;;
    --docker-root) need_value "$@"; DOCKER_ROOT=$2; shift 2 ;;
    --db-dir) need_value "$@"; DB_DIR=$2; shift 2 ;;
    --tmp-root) need_value "$@"; TMP_ROOT=$2; shift 2 ;;
    --max-bytes) need_value "$@"; MAX_BYTES=$2; shift 2 ;;
    --hits-file) need_value "$@"; HITS_FILE=$2; shift 2 ;;
    --emit) MODE=emit; shift ;;
    --ip-only) MODE=ip; shift ;;
    --token-only) MODE=token; shift ;;
    --no-proc-env) SCAN_PROC_ENV=0; shift ;;
    --journald) FORCE_JOURNALD=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    *) printf '%s: unknown argument: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done
while (($#)); do ROOTS+=("$1"); ROOTS_EXPLICIT=1; shift; done

# ---------------------------------------------------------------- validation

valid_ipv4() {
  local ip=$1 octet
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    ((10#$octet <= 255)) || return 1
  done
  return 0
}

valid_ipv4 "$CANARY_IP" || die "invalid IPv4: $CANARY_IP"
[[ $MAX_BYTES =~ ^[0-9]+$ ]] || die "DRILL_MAX_SCAN_BYTES must be a number: $MAX_BYTES"

IFS=. read -r O1 O2 O3 O4 <<<"$CANARY_IP"
TUPLE="{$O1,$O2,$O3,$O4}"
MAPPED="::ffff:$CANARY_IP"
# Plain IP: a match not followed by another digit (so 172.31.77.70 is not a false positive).
PLAIN_RE="(^|[^0-9.])${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"
MAPPED_RE="::ffff:${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"
# Raw byte pattern: 172.31.77.7 -> \xac\x1f\x4d\x07. A grep pattern cannot
# hold a NUL or a newline byte; if such an IP is given the stage is skipped
# (not silently).
RAW_OK=1
for octet in "$O1" "$O2" "$O3" "$O4"; do
  if ((10#$octet == 0 || 10#$octet == 10)); then RAW_OK=0; fi
done
if ((RAW_OK)); then
  # '\\%03o' -> text escape sequence, then converted to bytes with %b (no nested quotes).
  ESC=$(printf '\\%03o\\%03o\\%03o\\%03o' "$O1" "$O2" "$O3" "$O4")
  printf -v RAW_PAT '%b' "$ESC"
fi


# ---------------------------------------------------------------- canary

gen_token() {
  local hex=
  if [[ -r /dev/urandom ]]; then
    hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') || hex=
  fi
  if [[ -z $hex ]]; then
    hex=$(python3 -c 'import os;print(os.urandom(16).hex())' 2>/dev/null) ||
      die "could not generate a random canary"
  fi
  printf 'zifiri-canary-%s' "$hex"
}

if [[ -z $TOKEN ]]; then
  TOKEN=$(gen_token)
  FRESH_TOKEN=1
else
  FRESH_TOKEN=0
fi

if [[ $MODE == emit ]]; then
  cat <<EOF
CANARY_TOKEN=$TOKEN
CANARY_IP=$CANARY_IP

# Request to send from the test network (put HOST in yourself):
curl -sS -o /dev/null -w '%{http_code}\n' \\
  --interface $CANARY_IP \\
  -H 'User-Agent: $TOKEN' \\
  -H 'X-Forwarded-For: $CANARY_IP' \\
  -H 'X-Real-IP: $CANARY_IP' \\
  --data-binary '$TOKEN' \\
  'https://HOST/api/posts'

# Then scan with the same canary:
CANARY_TOKEN=$TOKEN $PROG
EOF
  exit 0
fi

# ---------------------------------------------------------------- roots

DO_DOCKER=0
DO_DB=0
DO_JOURNAL=0
if ((ROOTS_EXPLICIT)); then
  if ((FORCE_JOURNALD)); then DO_JOURNAL=1; fi
  vlog "targeted scan: only ${ROOTS[*]}"
else
  ROOTS=("$DOCKER_ROOT" "$DB_DIR" "$TMP_ROOT")
  DO_DOCKER=1
  DO_DB=1
  DO_JOURNAL=1
fi

# ---------------------------------------------------------------- state

declare -A SEEN=()
RED_HITS=()
INFO_HITS=()
SKIPPED=()
DOCKER_MISSING=0

# If the raw byte stage cannot be expressed as a grep pattern that must not be
# a silent gap: no proof means the result is 2.
if ((RAW_OK == 0)) && [[ $MODE != token ]]; then
  warn "raw byte search not possible: the IP contains a 0 or 10 byte (grep pattern cannot express it)"
  SKIPPED+=("ip-raw (IP bytes cannot be written as a grep pattern)")
fi

is_published_db() {
  case $1 in
    "$DB_DIR"/*.db | "$DB_DIR"/*.db-wal) return 0 ;;
  esac
  return 1
}

record() {
  local form=$1 file=$2 key
  key="$form|$file"
  if [[ -n ${SEEN[$key]:-} ]]; then return 0; fi
  SEEN[$key]=1
  if [[ $form == token ]] && is_published_db "$file"; then
    INFO_HITS+=("$key")
  else
    RED_HITS+=("$key")
  fi
  vlog "hit: $form $file"
  return 0
}

# ---------------------------------------------------------------- temporary dir

STATE_ROOT=${DRILL_STATE_DIR:-${TMPDIR:-/var/tmp}}
mkdir -p -- "$STATE_ROOT" 2>/dev/null || true
TMPD=$(mktemp -d "$STATE_ROOT/zifiri-canary.XXXXXX") || die "could not create temp dir: $STATE_ROOT"
# shellcheck disable=SC2064
trap "rm -rf -- '$TMPD'" EXIT

# ---------------------------------------------------------------- file list

FILELIST=$TMPD/files.nul
: >"$FILELIST"

for root in "${ROOTS[@]}"; do
  if [[ ! -d $root ]]; then
    if ((DO_DOCKER)) && [[ $root == "$DOCKER_ROOT" ]]; then
      # No docker: no silent pass, reported with its own exit code.
      DOCKER_MISSING=1
      printf '%s: no docker, skipped: %s\n' "$PROG" "$root" >&2
      SKIPPED+=("docker ($root missing)")
    else
      warn "directory missing, skipped: $root"
      SKIPPED+=("$root")
    fi
    continue
  fi
  n0=$(tr -cd '\000' <"$FILELIST" | wc -c | tr -d ' ')
  # The script's own directory is excluded: the default IP is written inside
  # these files, so otherwise the scan would find itself on every run.
  if [[ -n $SELF_DIR ]]; then
    find "$root" -xdev -type f -readable \
      ! -path "$TMPD/*" ! -path "$SELF_DIR/*" -print0 >>"$FILELIST" 2>/dev/null || true
  else
    find "$root" -xdev -type f -readable \
      ! -path "$TMPD/*" -print0 >>"$FILELIST" 2>/dev/null || true
  fi
  n1=$(tr -cd '\000' <"$FILELIST" | wc -c | tr -d ' ')
  vlog "root $root: $((n1 - n0)) files"
done

FILE_COUNT=$(tr -cd '\000' <"$FILELIST" | wc -c | tr -d ' ')
vlog "total files: $FILE_COUNT"
((FILE_COUNT > 0)) || die "no files to scan (roots: ${ROOTS[*]})"

# The SQLite trio is reported separately: WAL and SHM are the primary evidence
# sites (§6.1).
DB_FILES=0
if ((DO_DB)); then
  for ext in db db-wal db-shm; do
    c=0
    if [[ -d $DB_DIR ]]; then
      c=$(find "$DB_DIR" -maxdepth 1 -type f -name "*.$ext" 2>/dev/null | wc -l | tr -d ' ')
    fi
    vlog "db: *.$ext -> $c files"
    DB_FILES=$((DB_FILES + c))
  done
  if ((DB_FILES == 0)); then
    warn "no *.db / *.db-wal / *.db-shm under $DB_DIR — the published-row claim could not be measured"
    SKIPPED+=("db ($DB_DIR empty or missing)")
  fi
fi

# ---------------------------------------------------------------- candidates

# The four forms cannot be searched in one grep call: -E and -F do not mix.
# So the candidate list is produced in two passes (E: plain + mapped, F: tuple
# + raw bytes, also F: token), then only the candidates are classified one by
# one. In a /tmp with 40 thousand files this is far cheaper than a full pass
# per form.
CANDS=$TMPD/cands.nul
: >"$CANDS"

xargs_grep() { LC_ALL=C xargs -0 -r -a "$FILELIST" grep -a -l -Z "$@" 2>/dev/null || true; }

if [[ $MODE != token ]]; then
  xargs_grep -E -e "$PLAIN_RE" -e "$MAPPED_RE" >>"$CANDS"
  if ((RAW_OK)); then
    xargs_grep -F -e "$TUPLE" -e "$RAW_PAT" >>"$CANDS"
  else
    xargs_grep -F -e "$TUPLE" >>"$CANDS"
  fi
fi
if [[ $MODE != ip ]]; then
  xargs_grep -F -e "$TOKEN" >>"$CANDS"
fi

CANDIDATES=()
if [[ -s $CANDS ]]; then
  if printf '' | sort -z -u >/dev/null 2>&1; then
    mapfile -d '' -t CANDIDATES < <(sort -z -u "$CANDS")
  else
    mapfile -d '' -t CANDIDATES < <(sort -u "$CANDS")
  fi
fi
vlog "candidate files: ${#CANDIDATES[@]} / $FILE_COUNT"

# ---------------------------------------------------------------- classification

if ((${#CANDIDATES[@]})); then
  for f in "${CANDIDATES[@]}"; do
    if [[ ! -f $f ]]; then continue; fi
    if [[ $MODE != token ]]; then
      if LC_ALL=C grep -aqE -e "$PLAIN_RE" -- "$f" 2>/dev/null; then record ip-plain "$f"; fi
      if LC_ALL=C grep -aqF -e "$TUPLE" -- "$f" 2>/dev/null; then record ip-tuple "$f"; fi
      if LC_ALL=C grep -aqE -e "$MAPPED_RE" -- "$f" 2>/dev/null; then record ip-mapped "$f"; fi
      if ((RAW_OK)); then
        if LC_ALL=C grep -aqF -e "$RAW_PAT" -- "$f" 2>/dev/null; then record ip-raw "$f"; fi
      fi
    fi
    if [[ $MODE != ip ]]; then
      if LC_ALL=C grep -aqF -e "$TOKEN" -- "$f" 2>/dev/null; then record token "$f"; fi
    fi
  done
fi

# ---------------------------------------------------------------- process env

# If the IP lands in an environment variable it is never written to disk but it
# sits in /proc/<pid>/environ. So the environment is a scan site too.
PROC_UNREADABLE=0
if ((SCAN_PROC_ENV)) && [[ $MODE != token ]]; then
  seen_proc=0
  for envf in /proc/[0-9]*/environ; do
    [[ -e $envf ]] || continue
    seen_proc=$((seen_proc + 1))
    if [[ ! -r $envf ]]; then
      PROC_UNREADABLE=$((PROC_UNREADABLE + 1))
      vlog "environment unreadable: $envf"
      continue
    fi
    if grep -aqE -e "$PLAIN_RE" -- "$envf" 2>/dev/null; then record ip-plain "$envf"; fi
    if grep -aqF -e "$TUPLE" -- "$envf" 2>/dev/null; then record ip-tuple "$envf"; fi
  done
  vlog "/proc: $seen_proc environments, $PROC_UNREADABLE unreadable"
  if ((PROC_UNREADABLE > 0)); then
    warn "/proc: $PROC_UNREADABLE process environments unreadable (another user/root required)"
    SKIPPED+=("proc-environ ($PROC_UNREADABLE unreadable)")
  fi
fi

# ---------------------------------------------------------------- journald

JOURNAL_OK=0
JOURNAL_FILE=$TMPD/journal.txt
if ((DO_JOURNAL)); then
  if command -v journalctl >/dev/null 2>&1; then
    if journalctl --since "$SINCE" --no-pager -o short-iso >"$JOURNAL_FILE" 2>"$TMPD/journal.err"; then
      JOURNAL_OK=1
      vlog "journald: $(wc -l <"$JOURNAL_FILE" | tr -d ' ') lines"
    else
      warn "journalctl unreadable: $(head -n 1 "$TMPD/journal.err" 2>/dev/null)"
      SKIPPED+=("journald")
    fi
  else
    warn "no journalctl; journald not scanned"
    SKIPPED+=("journald")
  fi
fi

if ((JOURNAL_OK)); then
  if [[ $MODE != token ]]; then
    grep -aqE -e "$PLAIN_RE" "$JOURNAL_FILE" && record ip-plain '<journald>'
    grep -aqF -e "$TUPLE" "$JOURNAL_FILE" && record ip-tuple '<journald>'
    grep -aqE -e "$MAPPED_RE" "$JOURNAL_FILE" && record ip-mapped '<journald>'
    # binary journald fields could also hold the raw bytes
    if ((RAW_OK)) && LC_ALL=C grep -aqF -e "$RAW_PAT" "$JOURNAL_FILE"; then
      record ip-raw '<journald>'
    fi
  fi
  if [[ $MODE != ip ]] && grep -aqF -e "$TOKEN" "$JOURNAL_FILE"; then
    record token '<journald>'
  fi
fi

# ---------------------------------------------------------------- body canary (files)

if [[ $MODE != ip ]]; then
  while IFS= read -r -d '' f; do
    record token "$f"
  done < <(xargs -0 -r -a "$FILELIST" grep -a -l -Z -F -e "$TOKEN" 2>/dev/null || true)
fi

# ---------------------------------------------------------------- machine-readable hits

if [[ -n $HITS_FILE ]]; then
  : >"$HITS_FILE"
  for key in ${INFO_HITS[@]+"${INFO_HITS[@]}"}; do
    printf '%s\t%s\t%s\n' "${key%%|*}" "${key#*|}" info >>"$HITS_FILE"
  done
  for key in ${RED_HITS[@]+"${RED_HITS[@]}"}; do
    printf '%s\t%s\t%s\n' "${key%%|*}" "${key#*|}" red >>"$HITS_FILE"
  done
  vlog "hits file: $HITS_FILE"
fi

# ---------------------------------------------------------------- report

print_group() {
  local title=$1 key form file count=0
  local -a lines=()
  for key in "${@:2}"; do
    form=${key%%|*}
    file=${key#*|}
    lines+=("$form|$file")
  done
  if ((${#lines[@]} == 0)); then return 0; fi
  printf '%s\n' "$title"
  local -A forms=()
  for key in "${lines[@]}"; do
    form=${key%%|*}
    file=${key#*|}
    forms[$form]=$((${forms[$form]:-0} + 1))
    if ((count < 40)); then
      printf '  %-12s %s\n' "$form" "$file"
    fi
    count=$((count + 1))
  done
  if ((count > 40)); then
    printf '  ... %d more records (total %d)\n' "$((count - 40))" "$count"
  fi
  printf '  summary:'
  for form in "${!forms[@]}"; do printf ' %s=%d' "$form" "${forms[$form]}"; done
  printf '\n\n'
  return 0
}

printf '\n== canary scan ==\n'
printf 'IP           : %s\n' "$CANARY_IP"
printf 'tuple        : %s\n' "$TUPLE"
printf 'mapped       : %s\n' "$MAPPED"
printf 'canary       : %s%s\n' "$TOKEN" "$([[ ${FRESH_TOKEN:-0} == 1 ]] && printf ' (generated in this run — not counted as body evidence)')"
if ((JOURNAL_OK)); then JOURNAL_NOTE=; else JOURNAL_NOTE=' (SKIPPED)'; fi
printf 'journald     : --since "%s"%s\n' "$SINCE" "$JOURNAL_NOTE"
printf 'proc environ : %s\n' "$([[ $SCAN_PROC_ENV == 1 && $MODE != token ]] && printf 'scanned' || printf 'skipped')"
printf 'roots        : %s\n' "${ROOTS[*]}"
printf 'file count   : %s\n\n' "$FILE_COUNT"

if ((${#RED_HITS[@]})); then print_group 'RED hits:' "${RED_HITS[@]}"; fi
if ((${#INFO_HITS[@]})); then print_group 'Expected (published DB row):' "${INFO_HITS[@]}"; fi

if ((${#RED_HITS[@]})); then
  printf 'RESULT: RED — %d hits. Drill failed.\n' "${#RED_HITS[@]}"
  exit 1
fi

if ((DOCKER_MISSING)); then
  printf 'RESULT: ENVIRONMENT MISSING — no docker, %s could not be scanned (other roots clean).\n' "$DOCKER_ROOT"
  printf '        This run is not green. Install Docker or narrow the scope with --root.\n'
  exit 3
fi

if ((${#SKIPPED[@]})); then
  printf 'RESULT: UNPROVEN — no hits, but these places could not be scanned: %s\n' "${SKIPPED[*]}"
  exit 2
fi

# The green message states what was scanned without inflating it: a targeted
# scan has no journald.
if ((JOURNAL_OK)); then JN='journald scanned'; else JN='journald not scanned'; fi
if ((SCAN_PROC_ENV)) && [[ $MODE != token ]]; then PN='proc environ scanned'; else PN='proc environ not scanned'; fi
printf 'RESULT: GREEN — %d files, %s, %s, no canary.\n' "$FILE_COUNT" "$JN" "$PN"
exit 0

