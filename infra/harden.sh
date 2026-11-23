#!/usr/bin/env bash
# zifiri — host hardening. plan §5.1 (no logs), §11.4 (disk and memory).
#
# WHAT IT DOES
#   turns swap off · cuts core dumps at three layers · makes journald stop
#   writing to disk · deletes old records under /var/log.
#   Every step is IDEMPOTENT: a second run produces the same state, no error.
#
# WHAT IT DOES NOT DO
#   It does not set up LUKS (that has to happen at install time — harden.md
#   §"LUKS"), and it does not block provider logs, network observation or data
#   in RAM. Those limits are written out one by one in harden.md; a green script
#   does not mean "anonymous".
#
# USAGE
#   sudo ./harden.sh                    # apply (root)
#   ./harden.sh --dry-run               # print the plan, change nothing
#   sudo ./harden.sh --log-age-days 3   # /var/log threshold (default 7 days)
#
# EXIT CODES
#   0 success · 1 error (not root, invalid argument) · 2 not Linux.
#
# Rollback: each step prints its one-line rollback underneath; batch rollback
# is in harden.md.

set -euo pipefail

PROG=${0##*/}

DRY_RUN=0
LOG_AGE_DAYS=7

SYSCTL_FILE=/etc/sysctl.d/90-zifiri-hardening.conf
LIMITS_FILE=/etc/security/limits.conf
LIMITS_BEGIN='# BEGIN zifiri-harden (core dumps off)'
LIMITS_END='# END zifiri-harden (core dumps off)'
LIMITS_DROPIN=/etc/systemd/system.conf.d/90-zifiri-core.conf
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/90-zifiri.conf
FSTAB_BACKUP=/etc/fstab.zifiri.bak
# Kept in one place: both the command that is applied and the dry-run output
# show the same text.
FSTAB_SED='s|^([^#].*[[:space:]]swap[[:space:]].*)$|# zifiri: swap off — \1|'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }
rollback() { printf '  rollback: %s\n' "$*"; }
would() { printf '  [dry-run] %s\n' "$*"; }

is_linux() {
  [ "$(uname -s 2>/dev/null || echo unknown)" = Linux ] && [ -d /proc/sys/kernel ]
}

# Run the command; under dry-run only print it. Work that needs a redirection
# does not go through here — those carry their own dry-run branch, like
# install_content/find.
do_cmd() {
  if (( DRY_RUN )); then
    would "$*"
  else
    "$@"
  fi
}

# Write the content only if it changed (idempotency lives here). install -D
# creates the directory.
install_content() {
  local path=$1 content=$2 mode=${3:-0644} tmp

  if (( DRY_RUN )); then
    would "would write: $path (mode $mode)"
    printf '%s\n' "$content" | sed 's/^/      | /'
    return 0
  fi

  tmp=$(mktemp)
  printf '%s\n' "$content" >"$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    say "  no change: $path"
    rm -f "$tmp"
    return 0
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  say "  written: $path"
}

usage() {
  cat <<EOF
$PROG — zifiri host hardening (plan §5.1, §11.4)

  sudo $PROG [--dry-run] [--log-age-days N]

  --dry-run            Change nothing; print the command and the rollback
                       line of every step.
  --log-age-days N     Delete *.log files under /var/log older than N days
                       (default: 7).
  -h, --help           This text.

Steps: swap off · core dump off (sysctl + limits + coredump.socket) ·
journald Storage=none · /var/log cleanup · verification.

LUKS is NOT this script's job: encryption happens at install time (harden.md).
EOF
}

# ---------------------------------------------------------------------------
# 1. swap
# ---------------------------------------------------------------------------

step_swap() {
  step "2/7 swap off"
  say "  What it does: turns off the active swap areas, comments out the swap"
  say "               lines in /etc/fstab, masks the swap/hibernate targets."
  say "  Why: swap is RAM written to disk. If a message body, a session key or"
  say "       the pepper lands there, the \"not written to disk\" (§7.1) claim"
  say "       collapses. Hibernate does the same for all of RAM."
  rollback "sudo cp -a $FSTAB_BACKUP /etc/fstab && sudo swapon -a && sudo systemctl unmask swap.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

  if is_linux; then
    local n
    n=$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')
    say "  current: $n active swap areas"
  else
    say "  current: unreadable (not Linux)"
  fi

  do_cmd swapoff -a

  if ! is_linux; then
    would "sed -i -E '$FSTAB_SED' /etc/fstab"
  elif [ -f /etc/fstab ]; then
    # The backup is taken once, in every case: the rollback command points at
    # the file, and without it the command would be lying.
    if [ ! -e "$FSTAB_BACKUP" ]; then
      do_cmd cp -a /etc/fstab "$FSTAB_BACKUP"
    fi
    if grep -Eq '^[[:space:]]*[^#[:space:]].*[[:space:]]swap[[:space:]]' /etc/fstab; then
      # Keep the commented line reversible: the original text stays at the end.
      do_cmd sed -i -E "$FSTAB_SED" /etc/fstab
    else
      say "  /etc/fstab: no swap line to comment out (idempotent)"
    fi
  fi

  # Masking stops someone from later saying 'swapon -a' or 'systemctl
  # hibernate'. The error (no such unit) is swallowed: being absent is fine.
  do_cmd systemctl mask swap.target 2>/dev/null || true
  do_cmd systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. core dump (sysctl)
# ---------------------------------------------------------------------------

step_sysctl() {
  step "3/7 core dump — sysctl"
  say "  What it does: pipes core_pattern into the void, turns off the setuid"
  say "                dump and dmesg reads, zeroes swappiness."
  say "  Why: an EMPTY core_pattern does not help — leaving it empty writes a"
  say "       file named 'core' into the working directory. The way to close it"
  say "       is |/bin/false. dmesg_restrict: the kernel ring carries process"
  say "       names and addresses."
  rollback "sudo rm -f $SYSCTL_FILE && sudo sysctl --system"

  local content
  content=$(cat <<'EOF'
# zifiri — plan §5.1. MANAGED FILE: written by infra/harden.sh.
# A manual edit is overwritten on the next run; the change goes into the script.

# No core dump is written for any process (pipe → /bin/false).
kernel.core_pattern = |/bin/false
kernel.core_uses_pid = 0
# setuid processes cannot dump either (a crash under sudo moves RAM to disk).
fs.suid_dumpable = 0
# The kernel ring and symbol addresses are closed to non-root.
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
# Ineffective while swap is off; if it is ever turned on, no aggressive paging.
vm.swappiness = 0
# "Martian" packets are logged with their source address — client IP leak (§5.1).
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
EOF
)
  install_content "$SYSCTL_FILE" "$content" 0644
  do_cmd sysctl --system

  say "  systemd-coredump is a separate path; sysctl does not cover it, so it is"
  say "  turned off separately."
  do_cmd systemctl disable --now systemd-coredump.socket 2>/dev/null || true
  do_cmd systemctl mask systemd-coredump.socket systemd-coredump@.service 2>/dev/null || true
  rollback "sudo systemctl unmask systemd-coredump.socket systemd-coredump@.service && sudo systemctl enable --now systemd-coredump.socket"
}

# ---------------------------------------------------------------------------
# 3. ulimit core 0
# ---------------------------------------------------------------------------

step_limits() {
  step "4/7 ulimit core 0"
  say "  What it does: sets the core limit to 0 for PAM sessions; writes the"
  say "                DefaultLimitCORE=0 drop-in for systemd services."
  say "  Why: besides core_pattern, RLIMIT_CORE=0 makes the kernel never try the"
  say "       dump path at all. limits.conf alone does not cover systemd"
  say "       services — two layers are needed."
  rollback "sudo sed -i '/BEGIN zifiri-harden/,/END zifiri-harden/d' $LIMITS_FILE && sudo rm -f $LIMITS_DROPIN"

  if [ -f "$LIMITS_FILE" ] && grep -qF "$LIMITS_BEGIN" "$LIMITS_FILE"; then
    say "  $LIMITS_FILE: zifiri block already present (idempotent)"
  else
    local block
    block=$(cat <<EOF
$LIMITS_BEGIN
# core 0: a crashing process cannot dump its RAM to disk. For PAM sessions;
# systemd services are covered by $LIMITS_DROPIN and LimitCORE=0 in the unit.
*       hard    core    0
*       soft    core    0
root    hard    core    0
root    soft    core    0
$LIMITS_END
EOF
)
    if (( DRY_RUN )); then
      would "block to append: $LIMITS_FILE"
      printf '%s\n' "$block" | sed 's/^/      | /'
    else
      [ -d "$(dirname "$LIMITS_FILE")" ] || install -d -m 0755 "$(dirname "$LIMITS_FILE")"
      if ! printf '\n%s\n' "$block" >>"$LIMITS_FILE"; then
        warn "$LIMITS_FILE could not be written — this step was SKIPPED"
        return 1
      fi
      say "  appended: $LIMITS_FILE (zifiri block)"
    fi
  fi

  local dropin
  dropin=$(cat <<'EOF'
# zifiri — plan §5.1. MANAGED FILE: written by infra/harden.sh.
# Core limit 0 for every service that starts. Running services pick this value
# up only when restarted; the zifiri units also carry their own LimitCORE=0
# (infra/systemd/*.service).
[Manager]
DefaultLimitCORE=0
EOF
)
  install_content "$LIMITS_DROPIN" "$dropin" 0644
}

# ---------------------------------------------------------------------------
# 4. journald
# ---------------------------------------------------------------------------

step_journald() {
  step "5/7 journald — Storage=none"
  say "  What it does: configures journald so it never writes to disk, and"
  say "                empties the existing journal files."
  say "  Why: journald writes unit output, kernel messages and (if enabled)"
  say "       audit records to disk. Tor's and nginx's stdout lands here; with"
  say "       Storage=none none of it persists."
  rollback "sudo rm -f $JOURNALD_DROPIN && sudo systemctl restart systemd-journald"

  local dropin
  dropin=$(cat <<'EOF'
# zifiri — plan §5.1. MANAGED FILE: written by infra/harden.sh.
# Storage=none: the journal FILE is never created. Records are kept in memory
# at runtime only and are lost on restart. `journalctl` shows no history on
# this machine — deliberate; turn it on temporarily while debugging.
[Journal]
Storage=none
# Bridging to syslog: if rsyslog exists it writes to disk there, so cut the bridge.
ForwardToSyslog=no
EOF
)
  install_content "$JOURNALD_DROPIN" "$dropin" 0644
  do_cmd systemctl restart systemd-journald

  say "  emptying the existing journal files (the drop-in only cuts new records)."
  do_cmd journalctl --rotate 2>/dev/null || true
  do_cmd journalctl --vacuum-time=1s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5. /var/log
# ---------------------------------------------------------------------------

step_logs() {
  step "6/7 /var/log — delete old records"
  say "  What it does: deletes rotated/compressed logs and *.log files older"
  say "                than $LOG_AGE_DAYS days."
  say "  Why: log rotation keeps records for months; if the canary scan (§5.2)"
  say "       hits in an old file the phase is red. Deleting shortens the"
  say "       lifetime — the content should not have been written at all; this"
  say "       is the second line of defense."
  say "  Preserved: wtmp, btmp, lastlog (the OPERATOR's session records, not the"
  say "             client's — §5 last paragraph) and /var/log/journal (emptied"
  say "             in step 5)."
  rollback "none — a deleted file does not come back. Look at the list with --dry-run first."

  local common=(-xdev -type f ! -path '/var/log/journal/*'
                ! -name wtmp ! -name btmp ! -name lastlog)

  if (( DRY_RUN )) || ! is_linux; then
    would "find /var/log ${common[*]} \\( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' -o -name '*.old' -o -name '*.log.[0-9]*' \\) -delete"
    would "find /var/log ${common[*]} -name '*.log' -mtime +$LOG_AGE_DAYS -delete"
    if is_linux; then
      say "  (dry-run list:)"
      find /var/log "${common[@]}" \
        \( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' \
           -o -name '*.old' -o -name '*.log.[0-9]*' \) \
        -printf '      would delete: %p (%s bytes)\n' 2>/dev/null || true
      find /var/log "${common[@]}" -name '*.log' -mtime +"$LOG_AGE_DAYS" \
        -printf '      would delete: %p (%s bytes)\n' 2>/dev/null || true
    fi
    return 0
  fi

  local before after
  before=$(du -sk /var/log 2>/dev/null | awk '{print $1}' || echo 0)
  find /var/log "${common[@]}" \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' \
       -o -name '*.old' -o -name '*.log.[0-9]*' \) -delete 2>/dev/null || true
  find /var/log "${common[@]}" -name '*.log' -mtime +"$LOG_AGE_DAYS" \
    -delete 2>/dev/null || true
  after=$(du -sk /var/log 2>/dev/null | awk '{print $1}' || echo 0)
  say "  /var/log: ${before:-?} KB → ${after:-?} KB"
}

# ---------------------------------------------------------------------------
# 6. preflight (LUKS warning) — information, not an error
# ---------------------------------------------------------------------------

step_preflight() {
  step "1/7 scope and preflight"
  say "  This script does not encrypt the disk. LUKS must be set up at install time (harden.md)."
  if is_linux; then
    if dmsetup ls --target crypt 2>/dev/null | grep -q .; then
      say "  dm-crypt device present: $(dmsetup ls --target crypt 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    else
      warn "no dm-crypt device visible: disk encryption (§11.4) may not be met."
    fi
  else
    say "  dm-crypt status unreadable (not Linux)."
  fi
  say "  Out of scope: provider logs, network observation, RAM image, DNS, backup."
}

# ---------------------------------------------------------------------------
# 7. verification
# ---------------------------------------------------------------------------

step_verify() {
  step "7/7 verification"
  say "  Expected:"
  say "    swapon --show                 → empty"
  say "    sysctl -n kernel.core_pattern → |/bin/false"
  say "    sysctl -n fs.suid_dumpable    → 0"
  say "    sysctl -n kernel.dmesg_restrict → 1"
  say "    sysctl -n vm.swappiness       → 0"
  say "    journalctl --disk-usage       → 'No journal files were found'"
  say "    grep core /etc/security/limits.conf → soft/hard 0"

  if (( DRY_RUN )) || ! is_linux; then
    say ""
    say "  (dry-run: no measurement taken)"
    return 0
  fi

  local swaps pattern suid dmesg swappiness usage cores
  swaps=$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')
  pattern=$(sysctl -n kernel.core_pattern 2>/dev/null || echo '?')
  suid=$(sysctl -n fs.suid_dumpable 2>/dev/null || echo '?')
  dmesg=$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo '?')
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo '?')
  usage=$(journalctl --disk-usage 2>&1 | tr '\n' ' ' || true)
  cores=$(awk '/^[^#]/ && $3=="core" {printf "%s=%s ", $2, $4}' "$LIMITS_FILE" 2>/dev/null || true)

  say ""
  say "  --- current state ---"
  say "    swap area count:        $swaps (0 expected)"
  say "    kernel.core_pattern:    $pattern"
  say "    fs.suid_dumpable:       $suid"
  say "    kernel.dmesg_restrict:  $dmesg"
  say "    vm.swappiness:          $swappiness"
  say "    journal:                ${usage:-?}"
  say "    limits.conf core:       ${cores:-<none>}"
}

# ---------------------------------------------------------------------------
# main flow
# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) DRY_RUN=1 ;;
      --log-age-days)
        LOG_AGE_DAYS=${2:?"--log-age-days wants a number"}
        shift
        ;;
      --log-age-days=*) LOG_AGE_DAYS=${1#*=} ;;
      -h|--help) usage; exit 0 ;;
      *) printf '%s: unknown argument: %s\n\n' "$PROG" "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done

  case "$LOG_AGE_DAYS" in
    ''|*[!0-9]*) printf '%s: --log-age-days must be a positive integer: %s\n' "$PROG" "$LOG_AGE_DAYS" >&2; exit 1 ;;
  esac

  say "zifiri hardening — plan §5.1, §11.4"
  say "environment: $(uname -srm 2>/dev/null || echo unknown)"
  if (( DRY_RUN )); then
    say "mode: DRY-RUN (nothing is changed)"
  else
    say "mode: APPLY"
  fi

  # --- platform gate --------------------------------------------------------
  # The script is Linux-specific: /proc/sys, sysctl, systemctl, find -printf.
  # On a non-Linux environment (macOS, Windows/MSYS, a container host) it stops
  # instead of silently doing half the work. The dry-run plan is still printed —
  # the commands are not run, only shown — and it exits 2.
  if ! is_linux; then
    say ""
    say "ERROR: this script is for a Linux server; it cannot be applied here."
    say "  detected: $(uname -s 2>/dev/null || echo unknown)"
    say "  required: a Linux kernel + /proc/sys + systemd (Debian/Ubuntu VPS,"
    say "            infra/deploy.md). Windows/macOS have no swapoff, sysctl or"
    say "            systemctl; the commands do not run here."
    if (( DRY_RUN )); then
      say ""
      say "Dry-run plan follows; NO command was run and no file was changed."
      DRY_RUN=1
      step_preflight
      step_swap
      step_sysctl
      step_limits
      step_journald
      step_logs
      step_verify
      say ""
      say "RESULT: plan printed; not applied (not Linux)."
    fi
    exit 2
  fi

  if (( ! DRY_RUN )) && [ "$(id -u)" -ne 0 ]; then
    printf '%s: root is required to apply (sudo %s)\n' "$PROG" "$PROG" >&2
    exit 1
  fi

  step_preflight
  step_swap
  step_sysctl
  step_limits
  step_journald
  step_logs
  step_verify

  say ""
  if (( DRY_RUN )); then
    say "RESULT: dry-run complete; nothing was changed."
  else
    say "RESULT: hardening applied. What stays out of scope is in harden.md."
  fi
}

main "$@"

