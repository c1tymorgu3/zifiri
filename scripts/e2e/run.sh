#!/usr/bin/env bash
#
# scripts/e2e/run.sh — the browser-level E2E: a real Chrome loads the real
# server over HTTP and the DOM it produced is inspected.
#
# Three scenarios:
#
#   a) `/`          — the shell is drawn: `#app` is populated and the rail has
#                     exactly three tabs (Rooms / Messages / Listings).
#   b) `/?demo=1`   — the demo badge says "sample data", the room list is not
#                     empty, and the listing list is not empty.
#   c) console      — no `CONSOLE`/`Uncaught` line reaches Chrome's log for any
#                     of those pages.
#
# Two things this script refuses to do:
#
#   * Report PASS for a check that cannot fail. The console check runs a
#     self-test page that logs and throws first; if Chrome's log does not carry
#     those two lines, the detector is reported UNPROVEN and the run fails.
#   * Touch a server it did not start. If the port already answers zifiri's
#     `/health`, it is left running. If the port answers something else, the
#     script stops with an error instead of testing the wrong process.
#
# Usage:
#   scripts/e2e/run.sh                          # port 4000, start the server if needed
#   ZIFIRI_E2E_PORT=4010 scripts/e2e/run.sh     # a different port (see docs/e2e.md)
#   ZIFIRI_E2E_KEEP=1 scripts/e2e/run.sh        # keep the DOM dumps on success
#
# The CI job exports ZIFIRI_BASE_URL and CHROME_BIN and starts the server
# itself; both are honoured here, so this file is the local command and the CI
# step at once.
#
# Exit: 0 all checks passed, 1 a check failed, 2 the environment is wrong
# (no Chrome, port held by a foreign process, server never became ready).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# CI (`.github/workflows/ci.yml`, job `e2e`) exports `ZIFIRI_BASE_URL` and
# `CHROME_BIN`; a workstation usually exports neither. Both spellings are
# accepted so the same script is the local command and the CI step.
BASE="${ZIFIRI_BASE_URL:-http://127.0.0.1:${ZIFIRI_E2E_PORT:-4000}}"
BASE="${BASE%/}"
PORT="${ZIFIRI_E2E_PORT:-$(printf '%s' "$BASE" | sed -E 's#.*:([0-9]+)$#\1#')}"

CHROME="${CHROME:-${CHROME_BIN:-${CHROME_PATH:-/c/Program Files/Google/Chrome/Application/chrome.exe}}}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zifiri-e2e.XXXXXX")" || exit 2
# Chrome is a native binary: MSYS paths are not translated for it, so every
# path handed to Chrome itself goes through cygpath when it exists.
if command -v cygpath >/dev/null 2>&1; then
  WORK_NATIVE="$(cygpath -m "$WORK")"
else
  WORK_NATIVE="$WORK"
fi

PASSED=0
FAILED=0
STARTED=0
SERVER_PID=""

say() { printf '%s\n' "$*"; }
ok() { PASSED=$((PASSED + 1)); printf '  [PASS] %s\n' "$*"; }
no() { FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# Where the DOM dumps, console logs and the screenshot go. CI uploads
# `e2e/artifacts`; a local run keeps them in $WORK only when asked.
artifacts_dir() {
  if [ -n "${ZIFIRI_E2E_ARTIFACTS:-}" ]; then
    printf '%s' "$ZIFIRI_E2E_ARTIFACTS"
  elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '%s' "$ROOT/e2e/artifacts"
  fi
}

cleanup() {
  local status=$? dir
  if [ "$STARTED" = "1" ]; then
    stop_server
  fi
  dir="$(artifacts_dir)"
  if [ -n "$dir" ]; then
    mkdir -p "$dir"
    # The DOM dumps, the console logs and the screenshot — not the Chrome
    # profile, which is thousands of files and none of them evidence.
    cp "$WORK"/*.html "$WORK"/*.log "$WORK"/*.png "$dir/" 2>/dev/null
    say "artifacts: $dir"
    rm -rf "$WORK"
  elif [ "$FAILED" = "0" ] && [ "${ZIFIRI_E2E_KEEP:-0}" != "1" ]; then
    rm -rf "$WORK"
  else
    say "artifacts: $WORK"
  fi
  return $status
}
trap cleanup EXIT

# -- server ------------------------------------------------------------------

health_body() {
  curl -s --max-time 3 "$BASE/health" 2>/dev/null
}

is_zifiri() {
  [ "$(health_body)" = '{"status":"ok"}' ]
}

port_listener() {
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano 2>/dev/null |
      awk -v want=":${PORT}" '$1 == "TCP" && $2 ~ want"$" && $4 == "LISTENING" { print $5; exit }'
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :${PORT}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n 1
  fi
}

stop_server() {
  # `mix phx.server` is a shim over the Erlang VM; killing the shim can leave
  # the listener behind, so the port holder is what gets stopped.
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  local i pid
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pid="$(port_listener)"
    [ -z "$pid" ] && return 0
    sleep 0.5
  done
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Stop-Process -Id $pid -Force" >/dev/null 2>&1
  else
    kill -9 "$pid" 2>/dev/null
  fi
}

start_server() {
  say "server: not running — starting zifiri on port ${PORT}"
  ( cd "$ROOT" && ZIFIRI_E2E_PORT="$PORT" exec mix run --no-start scripts/e2e/serve.exs ) \
    >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  STARTED=1

  local i
  for i in $(seq 1 90); do
    if is_zifiri; then
      say "server: ready (pid ${SERVER_PID}, log $WORK/server.log)"
      return 0
    fi
    sleep 1
  done

  say "--- server.log (tail) ---"
  tail -n 40 "$WORK/server.log" 2>/dev/null
  die "the server did not answer ${BASE}/health within 90s"
}

if is_zifiri; then
  say "server: already running at ${BASE} — left untouched"
elif [ -n "$(port_listener)" ]; then
  die "port ${PORT} is held by pid $(port_listener), which does not answer ${BASE}/health with zifiri's {\"status\":\"ok\"}. Free the port or pick another one: ZIFIRI_E2E_PORT=4010 scripts/e2e/run.sh"
else
  start_server
fi

[ -x "$CHROME" ] || [ -f "$CHROME" ] || die "Chrome not found at $CHROME (set CHROME=...)"

# -- chrome ------------------------------------------------------------------

# chrome_dom <url> <outfile> [extra args...] — dump the post-load DOM.
chrome_dom() {
  local url="$1" out="$2"
  shift 2
  "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-first-run \
    --no-default-browser-check \
    --disable-extensions \
    --hide-scrollbars \
    --window-size=1280,900 \
    --user-data-dir="$WORK_NATIVE/profile" \
    --virtual-time-budget=8000 \
    "$@" \
    --dump-dom "$url" >"$out" 2>"$out.err"
}

count_of() { grep -o "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }

say ""
say "a) GET / — the shell is drawn"
chrome_dom "$BASE/" "$WORK/root.html"
rc=$?
if [ "$rc" != "0" ]; then
  no "/ did not load (chrome exit ${rc})"
else
  if grep -q 'id="app"' "$WORK/root.html" && grep -q 'class="zf-rail"' "$WORK/root.html"; then
    ok "#app is populated (the rail exists inside it)"
  else
    no "#app is empty or still the boot skeleton"
  fi

  tabs="$(count_of 'class="zf-tab"' "$WORK/root.html")"
  if [ "$tabs" = "3" ]; then
    ok "rail has 3 tabs (Rooms / Messages / Listings)"
  else
    no "rail has ${tabs} tabs, expected 3"
  fi

  if grep -q 'zf-boot-note' "$WORK/root.html"; then
    no "the boot placeholder (\"yükleniyor…\") is still in the DOM — main.ts never replaced it"
  else
    ok "boot placeholder was replaced by the app"
  fi
fi

say ""
say "b) GET /?demo=1 — sample data is on screen"
chrome_dom "$BASE/?demo=1" "$WORK/demo.html"
rc=$?
if [ "$rc" != "0" ]; then
  no "/?demo=1 did not load (chrome exit ${rc})"
else
  if grep -q 'data-demo="true"' "$WORK/demo.html" && grep -qF 'sample data' "$WORK/demo.html"; then
    ok 'demo badge is present and reads "sample data"'
  else
    no 'demo badge is missing (data-demo="true" and the "sample data" label must both be there)'
  fi

  # `> 0` alone would not discriminate: the live path renders its one room
  # (lobby) even with an empty store. "neighbourhood" only exists in the fixtures, so
  # seeing it is what proves the demo data — not the live path — reached the DOM.
  rooms="$(count_of 'class="zf-room"' "$WORK/demo.html")"
  if [ "$rooms" -gt 0 ] && grep -q '>neighbourhood<' "$WORK/demo.html"; then
    ok "room list has ${rooms} rooms, including the fixture-only \"neighbourhood\""
  elif [ "$rooms" -gt 0 ]; then
    no "room list has ${rooms} rooms but not the fixture-only \"neighbourhood\" — this is the live path, not demo"
  else
    no "room list is empty"
  fi
fi

# One surface is mounted at a time (shell.setContent swaps the host), so the
# listing list only exists in the DOM when that surface is the initial one.
chrome_dom "$BASE/?demo=1&surface=listings" "$WORK/demo-listings.html"
rc=$?
if [ "$rc" != "0" ]; then
  no "/?demo=1&surface=listings did not load (chrome exit ${rc})"
else
  listings="$(count_of 'class="listing"' "$WORK/demo-listings.html")"
  if [ "$listings" -gt 0 ]; then
    ok "listing list has ${listings} listings (surface=listings)"
  else
    no "listing list is empty"
  fi
fi

# A screenshot is cheap and it is what a human asks for when a check fails.
"$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
  --disable-extensions --hide-scrollbars --window-size=1280,900 \
  --user-data-dir="$WORK_NATIVE/profile" --virtual-time-budget=8000 \
  --screenshot="$WORK_NATIVE/demo.png" "$BASE/?demo=1" >/dev/null 2>&1
[ -f "$WORK/demo.png" ] && say "  screenshot: $WORK/demo.png"

# -- console -----------------------------------------------------------------

say ""
say "c) console — nothing reaches Chrome's log"

# Chrome's stderr log is the only console sink that survives `--headless=new`.
# Prove the sink works before trusting a clean result from it.
cat >"$WORK/console-probe.html" <<'HTML'
<!doctype html><title>console-probe</title>
<script>
  console.error("e2e-detector-probe-log");
  setTimeout(function () { throw new Error("e2e-detector-probe-throw"); }, 10);
</script>
<p>probe</p>
HTML

PROBE_URL="file:///$WORK_NATIVE/console-probe.html"
"$CHROME" --headless=new --disable-gpu --no-first-run \
  --user-data-dir="$WORK_NATIVE/profile-probe" \
  --enable-logging=stderr --v=0 --virtual-time-budget=3000 \
  --dump-dom "$PROBE_URL" >/dev/null 2>"$WORK/probe.log"

probe_hits="$(grep -cE 'CONSOLE|Uncaught' "$WORK/probe.log" 2>/dev/null | tr -d ' ')"
if [ "${probe_hits:-0}" -ge 2 ]; then
  ok "the console detector works (it caught the probe's log + throw)"
else
  no "the console detector caught nothing on a page that logs and throws — a clean result below would be meaningless (probe hits: ${probe_hits:-0})"
fi

check_console() {
  local label="$1" url="$2"
  local log="$WORK/console-$(echo "$label" | tr -c 'a-z0-9' '_').log"
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --disable-extensions --hide-scrollbars --window-size=1280,900 \
    --user-data-dir="$WORK_NATIVE/profile" \
    --enable-logging=stderr --v=0 --virtual-time-budget=8000 \
    --dump-dom "$url" >/dev/null 2>"$log"

  local hits
  hits="$(grep -E 'CONSOLE|Uncaught|SEVERE' "$log" 2>/dev/null)"
  if [ -z "$hits" ]; then
    ok "no console error on ${label}"
  else
    no "console error on ${label}:"
    printf '%s\n' "$hits" | sed 's/^/         /'
  fi
}

check_console "/" "$BASE/"
check_console "/?demo=1" "$BASE/?demo=1"
check_console "/?demo=1&surface=listings" "$BASE/?demo=1&surface=listings"

# -- result ------------------------------------------------------------------

say ""
say "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" = "0" ] || exit 1
exit 0
