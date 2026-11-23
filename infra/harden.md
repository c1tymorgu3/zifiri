# Host hardening — what it closes, what it does not

`harden.sh` reduces the traces the server **itself** produces: core dumps, swap,
journal, old log files. It does **not** encrypt the disk (that has to happen at
install time, see below), and it does **not** cover the provider or the network.

Three layers must not be confused:

| layer | who closes it | this script |
|---|---|---|
| process/kernel traces (core, swap, journald, /var/log) | the operating system | **yes** |
| disk (block device, snapshot, discarded VM image) | LUKS — at install time | no |
| environment (provider logs, network observation, hypervisor RAM) | provider contract / threat model | no |

The script going green does not mean "anonymous"; the plan's §5.1 "no logs"
claim covers only the first layer, §11.4's disk claim the second.

Usage:

```sh
sudo ./harden.sh --dry-run     # show the plan, change nothing
sudo ./harden.sh               # apply (idempotent, re-runnable)
sudo ./harden.sh --log-age-days 3
```

On a non-Linux environment the script stops (exit 2): `swapoff`, `sysctl`,
`systemctl` are not there; `--dry-run` only prints the plan and runs no command.

Files it manages — manual edits are overwritten on the next run:

```
/etc/sysctl.d/90-zifiri-hardening.conf
/etc/systemd/journald.conf.d/90-zifiri.conf
/etc/systemd/system.conf.d/90-zifiri-core.conf
/etc/security/limits.conf        (only the "BEGIN/END zifiri-harden" block)
/etc/fstab                       (only the swap lines are commented out)
```

---

## Step by step

| # | step | what it stops | undo |
|---|---|---|---|
| 1 | pre-check | — (warns if there is no LUKS) | — |
| 2 | swap off | RAM being written to disk, the hibernate image | `cp /etc/fstab.zifiri.bak /etc/fstab && swapon -a && systemctl unmask swap.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target` |
| 3 | core dump off | a crashing process's memory being dumped to disk | `rm /etc/sysctl.d/90-zifiri-hardening.conf && sysctl --system` |
| 4 | ulimit core 0 | a dump attempt with RLIMIT_CORE>0 | delete the block + delete the drop-in |
| 5 | journald `Storage=none` | unit output, kernel messages, tor/nginx logs | delete the drop-in + `systemctl restart systemd-journald` |
| 6 | `/var/log` cleanup | old rotated files | **none** — `--dry-run` first |
| 7 | verification | — (measurement) | — |

### 2. swap — RAM's copy on disk

Swap is the area where the kernel writes pages it has decided not to keep in
memory. If a message body, an open session token or a copy of the pepper lands
there, the "messages are not written to disk" (§7.1) claim collapses: anyone
holding a disk image reads plaintext in the swap file. Hibernate does the same
thing for **all of RAM** and leaves the whole of memory in a single file — which
is why its targets are masked.

- **Stops:** the kernel moving cold pages to swap; RAM being written to a single
  file via `systemctl hibernate`; someone later running `swapon -a`
  (`swap.target` is masked).
- **Does not stop:** runtime RAM (§A3); files under `/tmp` if it sits on disk;
  the provider's access to VM memory.
- **Cost:** on a machine without swap the OOM killer kicks in earlier. That is
  why §11.4 keeps memory small (SQLite + a single BEAM node). `zram` is shut
  down by `swapoff -a` too — zram stayed in RAM so it was not a privacy risk,
  but it is closed so that no two different swap paths are left behind.

### 3. core dump — three separate doors, all three closed

A single setting is not enough, because three separate mechanisms decide whether
a dump gets written:

1. `kernel.core_pattern` — where the kernel writes. **Leaving it empty does not
   mean off**: an empty pattern means "write a file named `core` into the
   working directory". The only closed form is a pipe: `|/bin/false` → the
   kernel pipes the data to `/bin/false`, which exits without reading it;
   nothing is written to disk.
2. `RLIMIT_CORE` — a per-process limit. `limits.conf` covers PAM sessions but
   **not systemd services**; that is why there is also a `DefaultLimitCORE=0`
   drop-in and `LimitCORE=0` in every unit.
3. `systemd-coredump` — captures the dump through its own pipeline and writes it
   to the journal/system; it can work even if `core_pattern` changes, so it is
   masked.

Additionally `fs.suid_dumpable=0`: `2` means "root only writes", i.e. the dump
still lands on disk — a file root can read is also readable by whoever takes the
disk image. On the BEAM side `ERL_CRASH_DUMP=/dev/null` +
`ERL_CRASH_DUMP_SECONDS=0` do the same job for Erlang's own dump (the default
`erl_crash.dump` leaves a 6 MB file in the repo root — there is one sitting in
this repo, see `.gitignore`).

- **Stops:** a crashing process's memory (messages, tokens, SQLite pages, the
  pepper) being written to a single file on disk; root-owned memory being dumped
  when a process running under `sudo` crashes.
- **Does not stop:** live process memory — the same user (or root) reads it via
  `ptrace`, `/proc/<pid>/mem`, `process_vm_readv`; the hypervisor's memory dump
  is entirely outside this.

### 4. ulimit core 0 — the third layer

`core_pattern` decides "where it is written", `RLIMIT_CORE` decides "whether it
is written at all"; the two are separate doors. With the limit at zero the
kernel never even tries the dump path, so no file appears even if
`core_pattern` is changed by mistake.

- The `/etc/security/limits.conf` block — PAM sessions (ssh, su, sudo).
- `/etc/systemd/system.conf.d/90-zifiri-core.conf` → `DefaultLimitCORE=0` —
  **systemd services do not read limits.conf**; this drop-in covers them.
  It only affects services that are starting; a running service picks the value
  up when it restarts (which is why you run `harden.sh` before installing the
  services).
- `LimitCORE=0` in every unit — the unit is closed on its own, without waiting
  for the drop-in.

`ulimit -c 0` also works by hand in a shell but is not persistent and does not
cover services; that is why the script writes all three persistent paths.

- **Stops:** a dump file appearing while the limit is `0`; sessions started via
  `su`/`sudo` opening with the default unlimited setting.
- **Does not stop:** a process that says `ulimit -c unlimited` (it cannot raise
  it if the hard limit is 0 — except root); root turning it back on with
  `sysctl kernel.core_pattern` (root already reads everything, §A3).

### Appendix — the rest of sysctl

- `kernel.dmesg_restrict=1` — the kernel ring buffer carries process names,
  addresses, module paths and device information; it is closed to non-root.
- `kernel.kptr_restrict=2` — no kernel pointer leaks through `/proc`
  (addresses useful for breaking KASLR).
- `net.ipv4.conf.*.log_martians=0` — "martian" packets are logged with their
  source address; this line stops a misconfigured network from writing client
  IPs into the kernel log.
- `vm.swappiness=0` — no effect while swap is off; if someone turns swap back on
  the kernel still does not swap eagerly (defense in depth).

### 5. journald — `Storage=none`

journald writes the units' stdout/stderr, kernel messages and (if enabled)
audit records to disk. Even if Tor runs with `Log notice stdout` and nginx with
`error_log /dev/null`, **systemd itself** collects unit output. `Storage=none`
never creates the journal file: records live in memory only at runtime and are
lost on restart. `ForwardToSyslog=no` cuts the rsyslog bridge — otherwise
`Storage=none` is useless, because rsyslog writes the same lines to
`/var/log/syslog`.

- **Stops:** unit output, kernel messages and tor/nginx errors from becoming
  persistent; looking back through history with `journalctl`.
- **Does not stop:** `journalctl` at runtime (root reads the in-memory ring);
  a separately running `auditd` (not turned off — if it is on it is a §5.1
  violation, and `systemctl disable --now auditd` is a separate decision);
  another file rsyslog writes under its own configuration (step 6 is the second
  line of defense).

### 6. `/var/log` cleanup

Rotated records are kept for months; files like `access.log.1`, `syslog.2.gz`
carry the past even after you say "we no longer write them". The script deletes
rotated/compressed files and `*.log` files older than `--log-age-days`
(default 7).

- **Preserved:** `wtmp`, `btmp`, `lastlog` — these are the **operator's** session
  records, not the client's (§5 last paragraph); deleting them blinds the
  `last`/`lastb` diagnostics with no privacy gain. `/var/log/journal` is handled
  separately (step 5).
- **Does not stop:** a deleted file remaining on the block device. The file
  system says "deleted", the blocks stay; on SSD TRIM/GC clears them over time,
  in snapshots and backups never. **That is why deletion is not a privacy
  guarantee** — without disk encryption an old log is not "deleted".

### 7. Verification

```sh
swapon --show                                   # empty
sysctl -n kernel.core_pattern                   # |/bin/false
sysctl -n fs.suid_dumpable                      # 0
sysctl -n kernel.dmesg_restrict                 # 1
sysctl -n vm.swappiness                         # 0
journalctl --disk-usage                         # "No journal files were found"
grep -E '^[^#].*core' /etc/security/limits.conf  # soft/hard 0
systemd-analyze verify /etc/systemd/system/zifiri*.service
```

`harden.sh` prints most of these measurements itself in its last step. If the
measurement is green the first layer is closed; for the second and third layers
see below.

---

## systemd units (`infra/systemd/`)

The three units are the path for running the release directly on the host; the
default distribution is docker compose (`infra/deploy.md`). Do not use both —
you end up with two writers on the same SQLite file.

| unit | what it narrows |
|---|---|
| `zifiri.service` | empty capability set, read-only root, two write paths, `LimitCORE=0`, `ERL_CRASH_DUMP=/dev/null`, pepper via `LoadCredential` |
| `zifiri-tor.service` | empty capability set, only `/var/lib/tor` writable, `MemoryDenyWriteExecute=yes` (C, no JIT) |
| `zifiri-nginx.service` | only 4 capabilities (bind/setuid/setgid/dac_override), only `/run` writable, `LimitCORE=0` |

Shared principles and their reasoning:

- `ProtectSystem=strict` + `ReadWritePaths=/var/lib/zifiri /run/zifiri` — the
  root file system is read-only; the application writes only the database, the
  error log and the unix socket. `/opt/zifiri` is code and is not written.
- `ProtectHome=yes` — `/home`, `/root`, `/run/user` do not exist for the
  process. The release is under `/opt`, `HOME=/var/lib/zifiri`; nobody needs a
  home directory.
- `NoNewPrivileges=yes` + `CapabilityBoundingSet=` — the process cannot escalate
  via a setuid binary, a file capability or polkit. BEAM binds a unix socket and
  does not open a port below 1024; it needs no capability.
- `MemoryDenyWriteExecute=no` **only in zifiri.service**: BEAM JIT writes code
  into a writable page and then makes it executable with `mprotect`. systemd's
  W^X seccomp filter rejects exactly this pattern; writing `yes` kills the
  emulator with EPERM at startup. So here `no` is not a shortcoming, it is
  required for the JIT to work. An ERTS compiled without JIT could use `yes`.
  tor and nginx are C; `yes` in tor, `no` in nginx because it depends on the
  PCRE JIT compilation (the reason is in the comment).
- `LoadCredential=pepper:/run/zifiri-pepper/pepper` — the pepper is not written
  to disk; systemd takes the file into a unit-private tmpfs copy and the
  application reads `%d/pepper`. The unit does not start if the file is missing
  (fail-fast): an install that comes up without a pepper is the same silent
  mistake as an install that has lost its pepper.
- No syscall filter, deliberately: the set BEAM uses varies from distribution to
  distribution (io_uring, `sched_setaffinity`, `prctl`, `madvise`); a wrong
  filter produces silent EPERM at runtime. The surface is narrowed instead with
  the capability set + read-only root + `NoNewPrivileges`.
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` — the application uses only
  a unix socket; INET/INET6 are open so that it does not crash if a library
  silently opens DNS. If you want it narrower, write only `AF_UNIX` and verify
  it runs without errors for a week.

**Does not stop:** someone who is root on the same machine from reading these
units' files (§A3); unit hardening does not stop root, it only narrows lateral
movement from a compromised application process. The provider's console and
hypervisor access are entirely outside it.

> Note: the units could not be verified with `systemd-analyze verify` on this
> machine (Windows) — there is no systemd. Before installing on Linux, run:
> `systemd-analyze verify infra/systemd/zifiri.service` (give the file path as
> an absolute path; the `Documentation=` and `LoadCredential=` paths must
> exist).

---

## Why LUKS has to happen at install time

This script does not set up LUKS and must not. The reason is not "it is a
chore", it is **that it cannot encrypt the past**:

1. **Every block written before encryption is plaintext.** A file deleted from
   the file system stays on the block device; setting up LUKS afterwards
   encrypts only the writes that follow. The old log, the old SQLite page, the
   old `erl_crash.dump` remnant stay readable. `cryptsetup reencrypt` solves
   this by overwriting, but: it needs free space, takes hours/days and loses
   data if interrupted — not a job for a live server.
2. **Provider snapshots freeze the past.** Every snapshot taken before
   encryption stays plaintext, even if you encrypt later. Whether the provider
   deletes historical snapshots and how long it keeps them is a contract
   matter; technically it is not in your hands.
3. **Key delivery.** At install time the passphrase/key that opens the disk is
   with the operator. A later "let's encrypt it" step in most practice leaves
   the key either on the disk or in a field in the provider's panel — at which
   point there is no encryption, only delay.
4. **Install time is the only clean moment.** On a fresh VM the disk is empty:
   no plaintext remnants, no snapshots, no downtime cost. That window closes
   once.

Correct order: the provider's "encrypted disk" option, or full-disk LUKS +
remote unlock in rescue mode (`dropbear-initramfs`). Then the operating system
is installed, then `harden.sh`. The reverse order (install first, encrypt later)
leaves the three remnants above.

**What LUKS stops:** pulling the disk and taking it away, reading a discarded
VM image, inspecting a snapshot the provider took, recovering the leftovers of a
VM deleted by mistake.

**What LUKS does not stop:** a running VM (the disk is transparent while the key
is open), the hypervisor's memory access, the provider console, legal
compulsion, application-level mistakes. Disk encryption does not mean "nobody
can read it while the server is running"; it means "the disk cannot be read
while the server is off/idle".

---

## Out of scope — deliberately not done

- **Provider logs:** network flow logs, console access, snapshot history, the
  support team's access. These are a matter of contract and provider choice;
  the script cannot see them.
- **Network layer:** TLS termination, DNS, time sync, IP headers. The Tor side
  is `infra/onion.md`, the clearnet side is `infra/nginx.conf`.
- **RAM:** runtime memory, `/proc/<pid>/mem`, the hypervisor dump.
- **Backups:** §11.5 treats the backup itself separately; if the place the
  backup is taken to is not encrypted, disk encryption will not save it.
- **auditd / rsyslog:** not turned off. If installed they produce a §5.1
  violation; turning them off is a separate decision (zifiri is not run on a
  machine that needs auditing).
- **Docker path:** if compose is used, the container log driver (`json-file`
  limit / `none`) and `--log-driver` must be set separately instead of journald;
  this script turns off the host's journald, it does not delete the containers'
  own log files.
