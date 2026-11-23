#!/usr/bin/env bash
# shellcheck shell=bash
#
# write_allowlist.sh — zifiri seizure drill, leg 1 (disk image)
#
# What it does: compares the `docker diff` output against the allowed set. The
# allowed set is NOT embedded in this script: it is read from `allowlist.txt` in
# the same directory (overridable with --allowlist). To review the set you edit
# data, not code.
#
# allowlist.txt format (line: <kind> <value>, # comment):
#
#   file            /var/lib/zifiri/zifiri.db      file allowed in diff
#   dir             /var/lib                     allowed parent dir (except D)
#   managed         /etc/hosts                   managed by docker, informational
#   tmpfs           /tmp                         red if it shows up in diff
#   volume-required zifiri.db                    must exist in the volume
#   volume-allowed  zifiri.db-wal                allowed name in the volume
#
# ${ZIFIRI_DB_DIR} is expanded in values.
#
# Anything extra = red (exit 1).
#
# IMPORTANT: `docker diff` does not show volume contents; if /var/lib/zifiri is
# a volume, the zifiri.db lines never appear in the diff. That is why the
# volume's real file set is checked separately with --volume-dir (§5.2 item 2).
#
# --json: writes a single JSON object to stdout (for CI); the human report goes
# to stderr. The exit code matches the "exit" field in the JSON.
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=.

CONTAINER=${ZIFIRI_CONTAINER:-zifiri-app}
DB_DIR=${ZIFIRI_DB_DIR:-/var/lib/zifiri}
VOLUME_DIR=
SOURCE=container
DIFF_FILE=
ALLOWLIST=${DRILL_ALLOWLIST:-$SELF_DIR/allowlist.txt}
STRICT_EMPTY=1
JSON=0
VERBOSE=0

usage() {
  cat <<EOF
$PROG — docker diff / volume write allowlist check

Usage:
  $PROG [CONTAINER] [options]
  docker diff CONTAINER | $PROG --stdin [options]

Options:
  --stdin               read the diff from stdin
  --diff-file FILE      read the diff from a file
  --allowlist FILE      allowed set file (default: $ALLOWLIST)
  --volume-dir DIR      also check the volume directory (full file set)
  --allow-empty-diff    count an empty diff as green (default: unproven)
  --json                write JSON to stdout (for CI; report to stderr)
  -v, --verbose         Verbose: allowlist path, line count, every decision
  -h, --help            This text

Environment: ZIFIRI_CONTAINER (default: $CONTAINER), ZIFIRI_DB_DIR,
       DRILL_ALLOWLIST

Exit codes:
  0  green: nothing outside the allowed set
  1  red: there is a write outside the allowlist
  2  unproven: diff empty, no allowlist, no docker, or an error
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
    --stdin) SOURCE=stdin; shift ;;
    --diff-file) need_value "$@"; DIFF_FILE=$2; SOURCE=diff_file; shift 2 ;;
    --allowlist) need_value "$@"; ALLOWLIST=$2; shift 2 ;;
    --volume-dir) need_value "$@"; VOLUME_DIR=$2; shift 2 ;;
    --allow-empty-diff) STRICT_EMPTY=0; shift ;;
    --json) JSON=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -*) printf '%s: unknown option: %s\n' "$PROG" "$1" >&2; exit 2 ;;
    *) CONTAINER=$1; shift ;;
  esac
done

# ---------------------------------------------------------------- allowed set

ALLOWED_FILES=()
ALLOWED_DIRS=()
DOCKER_MANAGED=()
TMPFS_REQUIRED=()
VOLUME_REQUIRED=()
VOLUME_ALLOWED=()

expand_vars() {
  local v=$1
  # Single quotes on purpose: what is looked for is the text "${ZIFIRI_DB_DIR}" itself.
  # shellcheck disable=SC2016
  v=${v//'${ZIFIRI_DB_DIR}'/$DB_DIR}
  # shellcheck disable=SC2016
  v=${v//'${DB_DIR}'/$DB_DIR}
  printf '%s' "$v"
}

ALLOWLIST_LINES=0
load_allowlist() {
  local file=$1 line kind value lineno=0
  [[ -r $file ]] || die "allowlist unreadable: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    if [[ -z $line || $line == '#'* ]]; then continue; fi
    kind=${line%%[[:space:]]*}
    value=${line#"$kind"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [[ -n $value ]] || die "$file:$lineno: no value: $line"
    value=$(expand_vars "$value")
    case $kind in
      file) ALLOWED_FILES+=("$value") ;;
      dir) ALLOWED_DIRS+=("$value") ;;
      managed) DOCKER_MANAGED+=("$value") ;;
      tmpfs) TMPFS_REQUIRED+=("$value") ;;
      volume-required) VOLUME_REQUIRED+=("$value") ;;
      volume-allowed) VOLUME_ALLOWED+=("$value") ;;
      *) die "$file:$lineno: unknown kind: $kind" ;;
    esac
    ALLOWLIST_LINES=$((ALLOWLIST_LINES + 1))
  done <"$file"
  if ((ALLOWLIST_LINES == 0)); then
    die "$file: empty allowlist — allowing every line or everything is wrong either way"
  fi
}

load_allowlist "$ALLOWLIST"
vlog "allowlist: $ALLOWLIST ($ALLOWLIST_LINES rules, ${#ALLOWED_FILES[@]} files, ${#ALLOWED_DIRS[@]} dirs)"

normalize() {
  local p=$1
  while [[ $p == *//* ]]; do p=${p//\//\/}; done
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  printf '%s' "$p"
}

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    if [[ $needle == "$item" ]]; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------- diff source

WORK=$(mktemp -d "${DRILL_STATE_DIR:-${TMPDIR:-/var/tmp}}/zifiri-diff.XXXXXX" 2>/dev/null) ||
  WORK=$(mktemp -d) || die "could not create temp dir"
# shellcheck disable=SC2064
trap "rm -rf -- '$WORK'" EXIT

RAW=$WORK/diff.txt
case $SOURCE in
  stdin)
    cat >"$RAW"
    ;;
  diff_file)
    [[ -r $DIFF_FILE ]] || die "unreadable: $DIFF_FILE"
    cp -- "$DIFF_FILE" "$RAW"
    ;;
  container)
    if ! command -v docker >/dev/null 2>&1; then
      die "no docker; use --stdin or --diff-file"
    fi
    docker diff "$CONTAINER" >"$RAW" 2>"$WORK/docker.err" ||
      die "docker diff $CONTAINER failed: $(head -n 1 "$WORK/docker.err")"
    ;;
esac

LINES=$(wc -l <"$RAW" | tr -d ' ')
vlog "diff: $LINES lines"

# ---------------------------------------------------------------- comparison

VIOLATIONS=()
MANAGED=()
SEEN_ALLOWED=()

while IFS= read -r line || [[ -n $line ]]; do
  line=${line%$'\r'}
  if [[ -z ${line//[[:space:]]/} ]]; then continue; fi
  case $line in
    [ACD]" "*) : ;;
    *)
      warn "unrecognised diff line: $line"
      VIOLATIONS+=("?|$line")
      continue
      ;;
  esac
  status=${line%% *}
  path=$(normalize "${line#* }")

  if in_list "$path" ${ALLOWED_FILES[@]+"${ALLOWED_FILES[@]}"}; then
    SEEN_ALLOWED+=("$status $path")
    vlog "allowed file: $status $path"
    continue
  fi
  if in_list "$path" ${ALLOWED_DIRS[@]+"${ALLOWED_DIRS[@]}"}; then
    # Directory parent records: A (Docker created the volume mountpoint) or
    # C (content changed) are possible. D (deleted) is never expected.
    if [[ $status == D ]]; then
      VIOLATIONS+=("$status|$path (allowed directory deleted)")
    else
      SEEN_ALLOWED+=("$status $path")
    fi
    continue
  fi
  hit_tmpfs=0
  for t in ${TMPFS_REQUIRED[@]+"${TMPFS_REQUIRED[@]}"}; do
    case $path in
      "$t" | "$t"/*) hit_tmpfs=1 ;;
    esac
  done
  if ((hit_tmpfs)); then
    # It should be tmpfs; seeing it in the diff means tmpfs was not mounted and
    # that leaves the door open for the canary to be written to disk (§5.1).
    VIOLATIONS+=("$status|$path (not tmpfs — §5.1 violation)")
    continue
  fi
  if in_list "$path" ${DOCKER_MANAGED[@]+"${DOCKER_MANAGED[@]}"}; then
    MANAGED+=("$status $path")
    continue
  fi
  VIOLATIONS+=("$status|$path")
  vlog "violation: $status $path"
done <"$RAW"

# ---------------------------------------------------------------- volume set

VOLUME_EXTRA=()
VOLUME_MISSING=()
VOLUME_CHECKED=0
if [[ -n $VOLUME_DIR ]]; then
  [[ -d $VOLUME_DIR ]] || die "volume directory missing: $VOLUME_DIR"
  VOLUME_CHECKED=1
  declare -A PRESENT=()
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    PRESENT[$name]=1
    if [[ -d $entry ]]; then
      VOLUME_EXTRA+=("$name/ (directory)")
      continue
    fi
    in_list "$name" ${VOLUME_ALLOWED[@]+"${VOLUME_ALLOWED[@]}"} || VOLUME_EXTRA+=("$name")
  done < <(find "$VOLUME_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)
  for name in ${VOLUME_REQUIRED[@]+"${VOLUME_REQUIRED[@]}"}; do
    if [[ -z ${PRESENT[$name]:-} ]]; then VOLUME_MISSING+=("$name"); fi
  done
fi

# ---------------------------------------------------------------- decision

STATUS=green
EXIT_CODE=0
if ((${#VIOLATIONS[@]})); then
  STATUS=red
  EXIT_CODE=1
elif ((${#VOLUME_EXTRA[@]})); then
  STATUS=red
  EXIT_CODE=1
elif ((${#VOLUME_MISSING[@]})); then
  STATUS=unproven
  EXIT_CODE=2
elif ((LINES == 0)); then
  if ((STRICT_EMPTY)) && ((VOLUME_CHECKED == 0)); then
    STATUS=unproven
    EXIT_CODE=2
  fi
fi

# ---------------------------------------------------------------- report

REPORT_FD=1
if ((JSON)); then REPORT_FD=2; fi

# shellcheck disable=SC2059  # the format string deliberately comes from the caller
say() { printf "$@" >&"$REPORT_FD"; }

say '\n== write allowlist check ==\n'
case $SOURCE in
  container) say 'source       : docker diff %s\n' "$CONTAINER" ;;
  stdin) say 'source       : stdin\n' ;;
  diff_file) say 'source       : %s\n' "$DIFF_FILE" ;;
esac
say 'allowlist    : %s (%d rules)\n' "$ALLOWLIST" "$ALLOWLIST_LINES"
say 'diff lines   : %s\n' "$LINES"
say 'volume       : %s\n\n' "${VOLUME_DIR:-(not checked)}"

if ((${#SEEN_ALLOWED[@]})); then
  say 'Allowed:\n'
  for entry in "${SEEN_ALLOWED[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#MANAGED[@]})); then
  say 'Managed by Docker (informational):\n'
  for entry in "${MANAGED[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#VOLUME_MISSING[@]})); then
  say 'Expected file missing from the volume:\n'
  for entry in "${VOLUME_MISSING[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#VOLUME_EXTRA[@]})); then
  say 'Unlisted file in the volume:\n'
  for entry in "${VOLUME_EXTRA[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#VIOLATIONS[@]})); then
  say 'OUTSIDE THE ALLOWLIST:\n'
  for entry in "${VIOLATIONS[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

case $STATUS in
  red)
    if ((${#VIOLATIONS[@]})); then
      say 'RESULT: RED — %d path outside the allowlist. Drill failed.\n' "${#VIOLATIONS[@]}"
    else
      say 'RESULT: RED — %d unlisted file in the volume.\n' "${#VOLUME_EXTRA[@]}"
    fi
    ;;
  unproven)
    if ((${#VOLUME_MISSING[@]})); then
      say 'RESULT: UNPROVEN — volume incomplete: %s\n' "${VOLUME_MISSING[*]}"
    else
      say 'RESULT: UNPROVEN — diff empty and volume not checked.\n'
      say '       The app may never have written; pass --volume-dir or\n'
      say '       run this after a load test.\n'
    fi
    ;;
  green)
    if ((${#MANAGED[@]})); then
      say 'RESULT: GREEN — no writes outside the allowlist (Docker-managed lines: %d, informational).\n' "${#MANAGED[@]}"
    elif ((LINES == 0)); then
      say 'RESULT: GREEN — diff empty (no writes).\n'
    else
      say 'RESULT: GREEN — %s lines, all inside the allowed set.\n' "$LINES"
    fi
    ;;
esac

# ---------------------------------------------------------------- JSON

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_array() {
  local first=1 item
  local -n _ref=$1
  printf '['
  for item in "${_ref[@]}"; do
    if ((first)); then first=0; else printf ','; fi
    printf '"%s"' "$(json_escape "$item")"
  done
  printf ']'
}

json_nullable() {
  if [[ -z $1 ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

emit_json() {
  printf '{"tool":"write_allowlist","schema":1'
  printf ',"source":"%s"' "$SOURCE"
  printf ',"container":%s' "$(json_nullable "$([[ $SOURCE == container ]] && printf '%s' "$CONTAINER")")"
  printf ',"allowlist":"%s"' "$(json_escape "$ALLOWLIST")"
  printf ',"allowlist_rules":%d' "$ALLOWLIST_LINES"
  printf ',"diff_lines":%d' "$LINES"
  printf ',"volume_dir":%s' "$(json_nullable "$VOLUME_DIR")"
  printf ',"volume_checked":%s' "$([[ $VOLUME_CHECKED == 1 ]] && printf 'true' || printf 'false')"
  printf ',"status":"%s"' "$STATUS"
  printf ',"exit":%d' "$EXIT_CODE"
  printf ',"allowed":'
  json_array SEEN_ALLOWED
  printf ',"managed":'
  json_array MANAGED
  printf ',"violations":'
  json_array VIOLATIONS
  printf ',"volume_extra":'
  json_array VOLUME_EXTRA
  printf ',"volume_missing":'
  json_array VOLUME_MISSING
  printf '}\n'
}

if ((JSON)); then emit_json; fi

exit "$EXIT_CODE"

