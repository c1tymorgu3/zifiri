#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-all.sh — run the drill in order, report in a single table
#
# The order is not arbitrary:
#
#   0. negative control  does the scanner really find things? (plant.sh)
#   1. canary_scan.sh    disk + /proc environment + journald
#   2. write_allowlist   docker diff / volume set
#   3. memdump_scan.sh   BEAM/nginx memory dump
#
# If the negative control fails, the remaining steps' "clean" result is VOID:
# the green of a blind scanner proves nothing (scripts/SHARE.md).
#
# Table statuses:
#   PASS   step green (exit 0)
#   FAIL   step red (exit 1)
#   SKIP   step did not run or was incomplete (exit 2: unproven,
#          exit 3: environment missing — no docker)
#
# SKIP is not green. On a machine without Docker this script never returns a
# PASS total; doing so would be wrong.
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=.

VERBOSE=0
JSON=0
ONLY=
STATE=${DRILL_STATE_DIR:-${TMPDIR:-/tmp}}

usage() {
  cat <<EOF
$PROG — run the whole seizure drill and summarise it

Usage:
  $PROG [options]

Options:
  --only NAMES      Only the selected steps (comma-separated): control,canary,allowlist,memdump
  --json            JSON summary on stdout (for CI); detailed output on stderr
  -v, --verbose     Run every step with --verbose and print its output too
  -h, --help        This text

Environment:
  DRILL_STATE_DIR        Temporary state directory (default: $STATE)
  ZIFIRI_DB_DIR          Published DB directory (default: /var/lib/zifiri)
  DRILL_DOCKER_ROOT      Docker data directory (default: /var/lib/docker)
  DRILL_TMP_ROOT         Temporary file root (default: /tmp)
  CANARY_TOKEN           Fixed canary; if absent canary_scan generates one

Exit codes:
  0  every step PASS
  1  at least one FAIL (or the negative control failed → all void)
  3  no FAIL, but at least one step did not run for lack of environment (no docker)
  2  no FAIL, but at least one step is unproven

Example:
  ./run-all.sh -v
  ./run-all.sh --only control,canary
  ./run-all.sh --json | jq -r '.steps[] | "\\(.status)\\t\\(.step)"'
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
need_value() {
  if (($# >= 2)) && [[ -n $2 ]]; then return 0; fi
  die "$1 wants a value"
}

while (($#)); do
  case $1 in
    --only) need_value "$@"; ONLY=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for s in canary_scan.sh write_allowlist.sh memdump_scan.sh negative/plant.sh; do
  [[ -x $SELF_DIR/$s ]] || die "script missing or not executable: $SELF_DIR/$s"
done

mkdir -p -- "$STATE" 2>/dev/null || true
WORK=$(mktemp -d "$STATE/zifiri-runall.XXXXXX") || die "could not create temp dir"
# shellcheck disable=SC2064
trap "rm -rf -- '$WORK'" EXIT

wanted() {
  if [[ -z $ONLY ]]; then return 0; fi
  case ",$ONLY," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

STEPS=()
STATUSES=()
CODES=()
NOTES=()

run_step() {
  local name=$1 label=$2
  shift 2
  local out=$WORK/$name.log rc=0 status note
  local -a extra=()
  if ((VERBOSE)); then extra+=(--verbose); fi
  "$SELF_DIR/$label" "${extra[@]}" "$@" >"$out" 2>&1 || rc=$?
  case $rc in
    0) status=PASS ;;
    1) status=FAIL ;;
    2) status=SKIP ;;
    3) status=SKIP ;;
    *) status=FAIL ;;
  esac
  note=$(grep -m1 '^RESULT:' "$out" 2>/dev/null | sed 's/^RESULT: //' || true)
  if [[ -z $note ]]; then
    note=$(grep -m1 -E '^[^ ]+: ' "$out" 2>/dev/null | sed 's/^[^ ]*: //' || true)
  fi
  STEPS+=("$name")
  STATUSES+=("$status")
  CODES+=("$rc")
  NOTES+=("${note:-(no output)}")
  printf '  %-16s %-4s (exit %s) %s\n' "$name" "$status" "$rc" "${note:0:80}" >&2
  if ((VERBOSE)); then
    sed 's/^/      | /' "$out" >&2 || true
  fi
  return 0
}

printf '\n== drill: run-all ==\n\n' >&2

if wanted control; then run_step 'negative control' negative/plant.sh; fi
if wanted canary; then run_step 'canary_scan' canary_scan.sh; fi
if wanted allowlist; then run_step 'write_allowlist' write_allowlist.sh; fi
if wanted memdump; then run_step 'memdump_scan' memdump_scan.sh; fi

if ((${#STEPS[@]} == 0)); then
  die "--only matched no step: $ONLY"
fi

# ---------------------------------------------------------------- decision

CONTROL_FAILED=0
FAIL_COUNT=0
SKIP_COUNT=0
ENV_SKIP=0
for i in "${!STEPS[@]}"; do
  case ${STATUSES[$i]} in
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      if [[ ${STEPS[$i]} == 'negative control' ]]; then CONTROL_FAILED=1; fi
      ;;
    SKIP)
      SKIP_COUNT=$((SKIP_COUNT + 1))
      if [[ ${CODES[$i]} == 3 ]]; then ENV_SKIP=1; fi
      ;;
  esac
done

OVERALL=0
if ((FAIL_COUNT > 0)); then
  OVERALL=1
elif ((ENV_SKIP)); then
  OVERALL=3
elif ((SKIP_COUNT > 0)); then
  OVERALL=2
fi

# ---------------------------------------------------------------- table

table() {
  local i
  printf '\n%-18s %-6s %-4s %s\n' 'STEP' 'STATUS' 'CODE' 'NOTE'
  printf '%-18s %-6s %-4s %s\n' '------------------' '------' '----' '---'
  for i in "${!STEPS[@]}"; do
    printf '%-18s %-6s %-4s %s\n' "${STEPS[$i]}" "${STATUSES[$i]}" "${CODES[$i]}" "${NOTES[$i]}"
  done
  printf '\n'
  case $OVERALL in
    0) printf 'TOTAL: PASS — %d steps green.\n' "${#STEPS[@]}" ;;
    1)
      if ((CONTROL_FAILED)); then
        printf 'TOTAL: FAIL — the negative control failed.\n'
        printf '       The scanner is blind: every other step is VOID.\n'
      else
        printf 'TOTAL: FAIL — %d steps red.\n' "$FAIL_COUNT"
      fi
      ;;
    3) printf 'TOTAL: SKIP — %d steps did not run for lack of environment (no docker?).\n' "$SKIP_COUNT" ;;
    2) printf 'TOTAL: SKIP — %d steps unproven.\n' "$SKIP_COUNT" ;;
  esac
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

if ((JSON)); then
  table >&2
  printf '{'
  printf '"tool":"run-all","schema":1,"overall":"%s","exit":%d,"steps":[' \
    "$(case $OVERALL in 0) printf PASS ;; 1) printf FAIL ;; *) printf SKIP ;; esac)" "$OVERALL"
  for i in "${!STEPS[@]}"; do
    if ((i > 0)); then printf ','; fi
    printf '{"step":"%s","status":"%s","exit":%s,"note":"%s"}' \
      "$(json_escape "${STEPS[$i]}")" "${STATUSES[$i]}" "${CODES[$i]}" "$(json_escape "${NOTES[$i]}")" 
  done
  printf ']}\n'
else
  table
fi

exit "$OVERALL"
