#!/usr/bin/env bash
# shellcheck shell=bash
#
# plant.sh — negative control: prove the scanner actually finds things
#
# Why it exists: a green scan proves nothing. The scanner may be broken, the
# root may be wrong, or the pattern may not match at all; in all three cases the
# output is "clean". This script deliberately writes the canary into three
# places and requires the scanner to find all three. If it does not, the control
# FAILS (exit 1) — i.e. the scanner cannot be trusted and the drill's result is
# void as well.
#
# Three plants:
#   A  plain text file      var/log/nginx/access.log      (IP inside the line)
#   B  JSON log             var/lib/docker/containers/…-json.log (docker json-file)
#   C  environment variable /proc/<pid>/environ           (never written to disk)
#
# Fourth check (false positive): an innocent file containing a neighbouring IP
# such as 172.31.77.70 must NOT produce a hit. If the pattern is too broad it
# is caught here.
#
# No Docker needed. No gdb needed. Only bash + grep + python3.
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=.
SCANNER=${DRILL_SCANNER:-$SELF_DIR/../canary_scan.sh}

IP=${CANARY_IP:-172.31.77.7}
TOKEN=${CANARY_TOKEN:-zifiri-canary-negative-control-0000000000000000}
KEEP=0
VERBOSE=0
STATE=${DRILL_STATE_DIR:-${TMPDIR:-/tmp}}
SLEEP_SECONDS=${DRILL_PLANT_SLEEP:-900}

usage() {
  cat <<EOF
$PROG — negative control for the canary scanner

Usage:
  $PROG [options]

What it does:
  1. writes a neighbouring IP (${IP%.*}.70) into an innocent file, scans it:
     there must be NO hit
  2. plants the canary in three places, scans: ALL THREE must be found
  3. removes the plants (--keep leaves them)

Options:
  --ip ADDRESS      IP to plant (default: $IP)
  --token STRING    Body canary (default: fixed test string)
  --state DIR       Parent directory for the plants (default: $STATE)
  --scanner FILE    Scanner to run (default: $SCANNER)
  --keep            Leave the plants and the process (for manual inspection)
  -v, --verbose     Run the scanner with --verbose, print every step
  -h, --help        This text

Exit codes:
  0  control PASSED: the scanner found all three plants and missed the innocent file
  1  control FAILED: the scanner is blind — no green scan on this machine counts
     as evidence
  2  control could not run (no scanner, no permission, environment missing)

Example:
  ./negative/plant.sh -v
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
vlog() { if ((VERBOSE)); then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

need_value() {
  if (($# >= 2)) && [[ -n $2 ]]; then return 0; fi
  die "$1 wants a value"
}

while (($#)); do
  case $1 in
    --ip) need_value "$@"; IP=$2; shift 2 ;;
    --token) need_value "$@"; TOKEN=$2; shift 2 ;;
    --state) need_value "$@"; STATE=$2; shift 2 ;;
    --scanner) need_value "$@"; SCANNER=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "invalid IPv4: $IP"
[[ -x $SCANNER ]] || die "scanner is not executable: $SCANNER"

mkdir -p -- "$STATE" 2>/dev/null || die "could not create state dir: $STATE"
ROOT=$(mktemp -d "$STATE/zifiri-negative.XXXXXX") || die "could not create temp dir: $STATE"

PLANT_PIDS=()
# shellcheck disable=SC2329  # called via trap
cleanup() {
  local pid
  if ((${#PLANT_PIDS[@]})); then
    for pid in "${PLANT_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  fi
  if ((KEEP)); then
    printf '%s: plants left in place: %s\n' "$PROG" "$ROOT" >&2
    if ((${#PLANT_PIDS[@]})); then
      printf '%s: live process: %s (clean up with kill)\n' "$PROG" "${PLANT_PIDS[*]}" >&2
    fi
  else
    rm -rf -- "$ROOT"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- scanner call

# run_scan <root> <hits file> <extra flags...>
# The exit code is written to the global SCAN_RC; the script itself does not die.
SCAN_RC=0
run_scan() {
  local root=$1 hits=$2
  shift 2
  local -a flags=()
  if ((VERBOSE)); then flags+=(--verbose); fi
  : >"$hits"
  SCAN_RC=0
  "$SCANNER" --root "$root" --hits-file "$hits" \
    --ip "$IP" --token "$TOKEN" "${flags[@]}" "$@" >"$ROOT/scan.log" 2>&1 || SCAN_RC=$?
  vlog "scan $root -> exit $SCAN_RC"
  return 0
}

hits_count() {
  if [[ -s $1 ]]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi
}

# no awk: the contract says bash + coreutils + grep + python3 only.
has_hit() {
  local hits=$1 want_form=$2 want_path=$3 form path
  if [[ ! -s $hits ]]; then return 1; fi
  while IFS=$'\t' read -r form path _; do
    if [[ $form == "$want_form" && $path == "$want_path" ]]; then return 0; fi
  done <"$hits"
  return 1
}

printf '\n== negative control: is the canary scanner blind? ==\n'
printf 'IP        : %s\n' "$IP"
printf 'scanner   : %s\n' "$SCANNER"
printf 'plant root: %s\n\n' "$ROOT"

FAILURES=0

# ---------------------------------------------------------------- 1) false positive

BASE=$ROOT/baseline
mkdir -p -- "$BASE"
# Neighbouring IP: if the pattern is "172.31.77.7" it must NOT catch this.
printf 'innocent line, the neighbouring address %s.70 and %s0 appear here\n' "${IP%.*}" "$IP" >"$BASE/decoy.log"
printf 'another line mentioning %s.70 and 10.0.0.1\n' "${IP%.*}" >>"$BASE/decoy.log"

run_scan "$BASE" "$ROOT/hits-baseline.tsv" --no-proc-env
base_hits=$(hits_count "$ROOT/hits-baseline.tsv")
vlog "baseline hits: $base_hits"

if ((base_hits == 0)) && ((SCAN_RC == 0)); then
  printf '  [PASS] no false positive: the innocent file (%s.70) produced no hit\n' "${IP%.*}"
else
  printf '  [FAIL] false positive: %s hits, exit %s (the innocent file must not be flagged)\n' "$base_hits" "$SCAN_RC"
  if [[ -s $ROOT/hits-baseline.tsv ]]; then
    while IFS= read -r line; do printf '         %s\n' "$line"; done <"$ROOT/hits-baseline.tsv"
  fi
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------- 2) plants

PLANT=$ROOT/plant
mkdir -p -- "$PLANT/var/log/nginx" "$PLANT/var/lib/docker/containers"

# A) plain text: nginx access record
ACCESS=$PLANT/var/log/nginx/access.log
printf '%s - - [22/Nov/2026:16:41:02 +0000] "POST /api/posts HTTP/1.1" 201 812 "-" "%s"\n' \
  "$IP" "$TOKEN" >"$ACCESS"
printf '%s - - [22/Nov/2026:16:41:03 +0000] "GET /feed HTTP/1.1" 200 900 "-" "curl/8.5"\n' \
  "$IP" >>"$ACCESS"

# B) JSON log: the format the docker json-file driver writes
CID=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
JSONLOG=$PLANT/var/lib/docker/containers/$CID/$CID-json.log
mkdir -p -- "$PLANT/var/lib/docker/containers/$CID"
printf '{"log":"2026-11-22T16:41:02.113000000Z POST /api/posts from %s ua=%s\\n","stream":"stdout","time":"2026-11-22T16:41:02.113000000Z"}\n' \
  "$IP" "$TOKEN" >"$JSONLOG"
printf '{"log":"2026-11-22T16:41:03.004000000Z GET /feed 200\\n","stream":"stdout","time":"2026-11-22T16:41:03.004000000Z"}\n' \
  >>"$JSONLOG"

# C) environment variable: never written to disk, only present in /proc/<pid>/environ
CANARY_IP="$IP" ZIFIRI_CANARY="$TOKEN" HTTP_X_FORWARDED_FOR="$IP" \
  sleep "$SLEEP_SECONDS" >/dev/null 2>&1 &
ENV_PID=$!
PLANT_PIDS+=("$ENV_PID")
vlog "environment plant pid=$ENV_PID"

# Wait until the process environment is readable (5 s at most).
waited=0
while ((waited < 50)); do
  if [[ -r /proc/$ENV_PID/environ ]] && grep -aqF -e "$IP" "/proc/$ENV_PID/environ" 2>/dev/null; then
    break
  fi
  sleep 0.1
  waited=$((waited + 1))
done
if [[ ! -r /proc/$ENV_PID/environ ]]; then
  printf '  [FAIL] environment plant could not be set up: /proc/%s/environ unreadable\n' "$ENV_PID"
  printf '         (this kernel does not expose /proc/<pid>/environ; the environment leg cannot be measured)\n'
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------- 3) scan

run_scan "$PLANT" "$ROOT/hits-plant.tsv"
plant_hits=$(hits_count "$ROOT/hits-plant.tsv")
vlog "plant hits: $plant_hits, exit $SCAN_RC"

if ((SCAN_RC == 1)); then
  printf '  [PASS] the scanner came back red (exit 1)\n'
else
  printf '  [FAIL] the scanner should have returned exit 1 on the plants, got: %s\n' "$SCAN_RC"
  FAILURES=$((FAILURES + 1))
fi

check_plant() {
  local label=$1 form=$2 path=$3
  if has_hit "$ROOT/hits-plant.tsv" "$form" "$path"; then
    printf '  [PASS] %-28s found (%s)\n' "$label" "$form"
    return 0
  fi
  printf '  [FAIL] %-28s NOT FOUND (%s, %s)\n' "$label" "$form" "$path"
  FAILURES=$((FAILURES + 1))
  return 0
}

check_plant 'A plain text (access.log)' ip-plain "$ACCESS"
check_plant 'B JSON log (docker)' ip-plain "$JSONLOG"
check_plant 'C environment (/proc/PID/environ)' ip-plain "/proc/$ENV_PID/environ"

# ---------------------------------------------------------------- 4) decision

printf '\n'
if ((FAILURES == 0)); then
  printf 'RESULT: CONTROL PASSED — the scanner found all three plants and missed the innocent file.\n'
  printf '        On this machine the canary_scan.sh result can be counted as evidence.\n'
  printf '        (hits: %s lines; details: %s)\n' "$plant_hits" "$ROOT/hits-plant.tsv"
  if ((KEEP)); then
    printf '        --keep: the plants are still there, you can look by hand.\n'
  fi
  exit 0
fi

printf 'RESULT: CONTROL FAILED — %d checks failed.\n' "$FAILURES"
printf '        The scanner is blind. A "clean" result from this machine is not evidence.\n'
printf '        Scanner log: %s\n' "$ROOT/scan.log"
if [[ -s $ROOT/scan.log ]]; then
  printf '\n--- scanner output (last 20 lines) ---\n'
  tail -n 20 "$ROOT/scan.log"
fi
exit 1

