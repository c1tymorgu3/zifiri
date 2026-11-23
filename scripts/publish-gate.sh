#!/usr/bin/env bash
#
# zifiri — publish gate
#
# Runs the mechanical half of the "publish gate" checklist before the repo is
# flipped to public. Every check prints PASS / FAIL / WARN / SKIP / INFO in one
# table; any FAIL exits 1. WARN never fails the gate — it is something a human
# must look at and tick off by hand.
#
#   scripts/publish-gate.sh            run the gate
#   scripts/publish-gate.sh --help     this text
#
# See docs/publish-gate.md for which of the ten checklist items are automated.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/publish-gate.sh [--help]

Runs the pre-publish checks from docs/publish-gate.md and prints a PASS/FAIL
table. Exit status: 0 = no FAIL, 1 = at least one FAIL, 2 = usage/not a repo.

Checks
  a  no tracked secret artefacts (pepper, .env*, hostname, hs_ed25519_*,
     *.db / *.db-wal / *.db-shm, *.onion)
  b  no tracked build output (node_modules, _build/, deps/, *.beam)
  c  secret scan: gitleaks -> trufflehog -> grep fallback (method is printed)
  d  every commit author is a noreply.github.com address          [WARN]
  e  no zero-byte tracked files                                   [WARN]
  f  no TODO/FIXME/XXX in lib/ or client/src/                     [WARN]
  g  LICENSE present and it is AGPL (SPDX line reported)          [WARN on
                                                                  missing SPDX]
Extra checks that map to the same checklist
  h  claims.md and verify.md cite the same claim IDs
  i  docs/arsiv/* carries the SUPERSEDED banner
  j  main tree hash equals the snapshot tree hash
  k  SECURITY.md exists
  l  untracked files are listed (each one must be reviewed by hand)
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    echo "unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "publish-gate: not inside a git repository" >&2
  exit 2
fi
cd "$ROOT"

# ---------------------------------------------------------------- plumbing ---
# Results are collected first and printed as a table, so the output stays
# readable no matter how noisy an individual check is.
R_ID=()
R_ST=()
R_NAME=()
R_NOTE=()

add() { # add <id> <status> <name> [note]
  R_ID+=("$1")
  R_ST+=("$2")
  R_NAME+=("$3")
  R_NOTE+=("${4:-}")
}

OUT=""
RC=0
capture() { # capture <cmd...>  -> sets OUT and RC
  RC=0
  OUT=$("$@" 2>&1) || RC=$?
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ checks ---
# a) Secret / runtime artefacts must never be tracked.
capture git ls-files
tracked=$OUT
artefacts=$(printf '%s\n' "$tracked" |
  grep -E '(^|/)(pepper|\.env|hostname|hs_ed25519_).*|\.db(-wal|-shm)?$|\.onion$' || true)
if [ -z "$artefacts" ]; then
  add a PASS "no tracked secret artefacts (pepper/.env/hostname/hs_ed25519_*/db/onion)"
else
  add a FAIL "tracked secret artefacts found" "$artefacts"
fi

# b) Build output must never be tracked.
build=$(printf '%s\n' "$tracked" | grep -E 'node_modules|_build/|deps/|\.beam$' || true)
if [ -z "$build" ]; then
  add b PASS "no tracked build output (node_modules/_build/deps/*.beam)"
else
  add b FAIL "tracked build output found" "$build"
fi

# c) Secret scan. Prefer a real scanner; fall back to a grep of the index.
scan_pattern='(gho_|ghp_|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|xox[baprs]-)'
if have gitleaks; then
  method="gitleaks detect"
  capture gitleaks detect --no-banner --redact
  if [ "$RC" -eq 0 ]; then
    add c PASS "secret scan clean (gitleaks detect)" "method: gitleaks $(gitleaks version 2>/dev/null || echo '?')"
  else
    add c FAIL "gitleaks reported findings" "method: gitleaks detect
$OUT"
  fi
elif have trufflehog; then
  method="trufflehog filesystem"
  capture trufflehog filesystem "$ROOT" --no-update --fail
  if [ "$RC" -eq 0 ]; then
    add c PASS "secret scan clean (trufflehog)" "method: trufflehog $(trufflehog --version 2>/dev/null || echo '?')"
  else
    add c FAIL "trufflehog reported findings" "method: trufflehog
$OUT"
  fi
else
  method="grep fallback (gitleaks and trufflehog not installed)"
  capture git grep -nIE "$scan_pattern"
  if [ -z "$OUT" ]; then
    add c PASS "secret scan clean (grep fallback)" "method: $method"
  else
    add c FAIL "grep fallback matched secret-shaped strings" "method: $method
$OUT"
  fi
fi

# d) Commit identity must not leak a real address.
authors=$(git log --format='%an <%ae>' | sort -u || true)
bad_authors=$(printf '%s\n' "$authors" | grep -v 'noreply\.github\.com' | grep -v '^$' || true)
if [ -z "$bad_authors" ]; then
  add d PASS "all commit authors are noreply.github.com" "authors:
$authors"
else
  add d WARN "commit authors outside noreply.github.com" "authors:
$authors"
fi

# e) Zero-byte tracked files (usually an accident; .gitkeep is intentional).
empties=$(git ls-files -z | xargs -0 -n1 sh -c 'test -s "$0" || echo "EMPTY: $0"' || true)
if [ -z "$empties" ]; then
  add e PASS "no zero-byte tracked files"
else
  add e WARN "zero-byte tracked files" "$empties"
fi

# f) Unfinished-work markers in the code that ships.
todo_dirs=""
for d in lib client/src; do [ -d "$d" ] && todo_dirs="$todo_dirs $d"; done
if [ -n "$todo_dirs" ]; then
  # shellcheck disable=SC2086
  todos=$(grep -rn 'TODO\|FIXME\|XXX' $todo_dirs --include='*.ex' --include='*.ts' 2>/dev/null || true)
else
  todos=""
fi
if [ -z "$todos" ]; then
  add f PASS "no TODO/FIXME/XXX in lib/ or client/src/"
else
  add f WARN "TODO/FIXME/XXX markers in shipping code" "$todos"
fi

# g) Licence: present, and AGPL.
if [ ! -f LICENSE ]; then
  add g FAIL "LICENSE missing"
else
  if grep -qE 'GNU AFFERO GENERAL PUBLIC LICENSE|SPDX-License-Identifier: AGPL' LICENSE; then
    if grep -q 'SPDX-License-Identifier' LICENSE; then
      add g PASS "LICENSE is AGPL with an SPDX identifier" "$(grep -m1 'SPDX-License-Identifier' LICENSE)"
    else
      add g WARN "LICENSE is AGPL but carries no SPDX-License-Identifier line" \
        "LICENSE text is AGPL-3.0; add a machine-readable header, e.g.:
SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (c) 2026 c1tymorgu3"
    fi
  else
    add g FAIL "LICENSE is not AGPL" "$(head -3 LICENSE)"
  fi
fi

# h) claims.md and verify.md must cite the same claim IDs.
if [ -f docs/claims.md ] && [ -f docs/verify.md ]; then
  claims_ids=$(grep -o 'C-[0-9]\+' docs/claims.md | sort -u || true)
  verify_ids=$(grep -o 'C-[0-9]\+' docs/verify.md | sort -u || true)
  if [ -z "$claims_ids" ] && [ -z "$verify_ids" ]; then
    add h WARN "claims.md / verify.md carry no C-xx claim IDs" \
      "neither file cites a C-01-style ID, so the diff cannot prove they agree.
Either apply the ID scheme from DECISIONS.md or cross-check the two files by hand."
  elif [ "$claims_ids" = "$verify_ids" ]; then
    add h PASS "claims.md and verify.md cite the same claim IDs ($(printf '%s\n' "$claims_ids" | grep -c . || true) IDs)"
  else
    add h FAIL "claims.md / verify.md claim ID sets differ" \
      "$(diff <(printf '%s\n' "$claims_ids") <(printf '%s\n' "$verify_ids") || true)"
  fi
else
  add h SKIP "claims.md / verify.md not both present"
fi

# i) Archived documents must be marked superseded.
if [ -d docs/arsiv ]; then
  arsiv_md=$(find docs/arsiv -name '*.md' -type f 2>/dev/null || true)
  if [ -z "$arsiv_md" ]; then
    add i WARN "docs/arsiv/ exists but holds no .md files"
  else
    missing=$(printf '%s\n' "$arsiv_md" | while IFS= read -r f; do
      grep -q 'SUPERSEDED' "$f" || echo "$f"
    done)
    if [ -z "$missing" ]; then
      add i PASS "every docs/arsiv/*.md carries a SUPERSEDED banner"
    else
      add i FAIL "docs/arsiv files without a SUPERSEDED banner" "$missing"
    fi
  fi
else
  add i SKIP "docs/arsiv/ does not exist (move historical docs there before publishing)"
fi

# j) Tree hash: the rebuilt history must not have changed a single byte.
if git rev-parse --verify --quiet refs/heads/snapshot >/dev/null; then
  main_tree=$(git rev-parse 'main^{tree}' 2>/dev/null || git rev-parse 'HEAD^{tree}')
  snap_tree=$(git rev-parse 'snapshot^{tree}')
  if [ "$main_tree" = "$snap_tree" ]; then
    add j PASS "main tree hash equals snapshot tree hash" "tree: $main_tree"
  else
    add j FAIL "main tree hash differs from snapshot" "main:   $main_tree
snapshot: $snap_tree"
  fi
else
  add j SKIP "no local snapshot branch to compare against"
fi

# k) Security policy must exist (GitHub private vulnerability reporting).
if [ -f SECURITY.md ]; then
  add k PASS "SECURITY.md present"
else
  add k FAIL "SECURITY.md missing"
fi

# l) Untracked files: informational, but each one must be reviewed by hand.
untracked=$(git ls-files --others --exclude-standard || true)
if [ -z "$untracked" ]; then
  add l INFO "no untracked files"
else
  add l INFO "$(printf '%s\n' "$untracked" | grep -c . ) untracked file(s) — review each before committing" "$untracked"
fi

# ------------------------------------------------------------------ report ---
fails=0
warns=0
for i in "${!R_ST[@]}"; do
  case ${R_ST[$i]} in
    FAIL) fails=$((fails + 1)) ;;
    WARN) warns=$((warns + 1)) ;;
  esac
done

printf 'zifiri publish gate — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
printf 'repo: %s\n' "$ROOT"
printf 'secret scan method: %s\n\n' "$method"
printf '%-3s %-5s %s\n' "ID" "SONUC" "KONTROL"
printf '%-3s %-5s %s\n' "---" "-----" "-------"
for i in "${!R_ID[@]}"; do
  printf '%-3s %-5s %s\n' "${R_ID[$i]}" "${R_ST[$i]}" "${R_NAME[$i]}"
done

if [ "$warns" -gt 0 ] || [ "$fails" -gt 0 ]; then
  printf '\nAyrıntı\n'
  for i in "${!R_ID[@]}"; do
    case ${R_ST[$i]} in
      PASS | INFO | SKIP) continue ;;
    esac
    printf '\n[%s] %s — %s\n' "${R_ID[$i]}" "${R_ST[$i]}" "${R_NAME[$i]}"
    printf '%s\n' "${R_NOTE[$i]}" | sed 's/^/    /'
  done
fi

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf 'SONUÇ: FAIL (%d fail, %d uyarı) — depoyu public yapma.\n' "$fails" "$warns"
  exit 1
fi
printf 'SONUÇ: PASS (%d uyarı) — uyarıları elle işaretle: docs/publish-gate.md\n' "$warns"
exit 0
