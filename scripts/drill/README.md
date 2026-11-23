# Seizure drill — scripts

The runnable form of the plan §1 criterion. Three legs, three scripts:

| leg | question | script |
|---|---|---|
| 1 — disk image | can "who wrote this listing, when, from which IP" not be answered? | `canary_scan.sh`, `write_allowlist.sh` |
| 2 — memory | can it not be answered in a dump taken after the traffic stops either? | `memdump_scan.sh` |
| 3 — network + published data | is matching at chance level (≈ 1/n)? | outside these scripts; measured separately with the `n` measurement in §4.2 |
| — | does the scanner really find things? | `negative/plant.sh` — **mandatory**, see `negative/README.md` |
| — | run everything in order and summarise | `run-all.sh` |

The scripts are for Linux and run on the VPS. On a development machine
(Windows/macOS) the full drill does not run (no docker, gdb, journald); but
`negative/plant.sh` runs there too and should — after every change that touches
the scanner. `bash -n` + `shellcheck` hold for every script.

## Common

- Dependencies: bash 4.4+, coreutils, `grep`, `find`; the memory leg also needs
  `gdb` (`gcore`). Nothing else. (`canary_scan.sh` does not use python3.)
- Every script has `set -euo pipefail`, `--help` and `-v/--verbose`.
  `shellcheck` is clean.
- Exit codes mean the same in every script:

  | code | meaning |
  |---|---|
  | `0` | green — the claim was proven in this run |
  | `1` | red — there is a hit, the phase is not finished (§13) |
  | `2` | **unproven** — the scan was incomplete (no tool, no permission, empty test) |
  | `3` | **environment missing** — no docker, part of the disk leg could not be scanned |

  `2` and `3` are not green. A drill that passes silently is worse than a red
  one. `3` exists as its own code precisely so it cannot pass silently: saying
  "clean" on a machine without docker is not looking at all.
- The allowed set lives in data, not code: `write_allowlist.sh` reads the
  allowlist from `allowlist.txt`. A new legitimate write path means a line in
  that file, not a change to the script.
- `write_allowlist.sh --json` and `run-all.sh --json` write a single JSON object
  to stdout (for CI); the human report goes to stderr.
- No script writes its own evidence file into the scanned places; temporary
  files open under `$DRILL_STATE_DIR` (default `/var/tmp`) and are deleted on
  exit.

---

## 1. `canary_scan.sh` — canary scan (§5.2 item 1)

### What it does

Searches the disk for a fixed test-network IP (default `172.31.77.7`) and a
random canary string. The IP is searched in **four forms**, because the same
address is represented differently at different layers:

| form | where it occurs | how it is searched |
|---|---|---|
| `172.31.77.7` | nginx/Apache log, `X-Forwarded-For`, plain text | `grep -E`, with a digit boundary |
| `{172,31,77,7}` | Erlang/Elixir `:inet` tuple, `IO.inspect` output, ETS dump | `grep -F` |
| raw 4 bytes `AC 1F 4D 07` | sockaddr structures, binary logs, kernel buffers | `grep -a`, byte pattern (WAL/SHM included) |
| `::ffff:172.31.77.7` | IPv4-mapped IPv6 (dual-stack listener) | `grep -E` |

The raw byte search runs over every file, but the pattern is the four bytes
themselves (`LC_ALL=C grep -a -F`), so a text file containing the ASCII
`172.31.77.7` does not match at this stage — only a file that really carries the
`AC 1F 4D 07` bytes matches. That way WAL/SHM, cores and compressed bodies are
caught in one pass without noise. If the IP contains a `0` or `10` byte (e.g.
`10.0.0.1`) the pattern cannot be expressed as a grep pattern; in that case the
stage is switched off not silently but by saying "skipped", and the result is
`2`.

Places scanned:

- `/var/lib/docker` — container json logs (`containers/<id>/<id>-json.log`),
  overlay2 layers (`diff/`), `volumes/`, image layers. Because `-xdev` is used,
  running containers' `merged/` mount points are skipped: that is the view of
  the layers, and the data is already under `diff/`.
- `/var/lib/zifiri` — `*.db`, `*.db-wal` (the SQLite WAL trap, §6.1).
- `/tmp`
- journald — `journalctl --since` (default "2 hours ago"), read once, then
  searched separately for the three forms.

### How to run

```bash
# 1) generate a canary and get a send example
./canary_scan.sh --emit
#    → CANARY_TOKEN=zifiri-canary-<32 hex>

# 2) send the request from the test network (put HOST in yourself)
curl -sS -o /dev/null -w '%{http_code}\n' \
  --interface 172.31.77.7 \
  -H 'User-Agent: zifiri-canary-...' \
  -H 'X-Forwarded-For: 172.31.77.7' \
  -H 'X-Real-IP: 172.31.77.7' \
  --data-binary 'zifiri-canary-...' \
  'https://HOST/api/posts'

# 3) scan with the same canary
CANARY_TOKEN=zifiri-canary-... ./canary_scan.sh
```

If you run it without `--emit` a fresh canary is generated and the script marks
it "not counted as body evidence": that string was never sent anywhere, so its
absence proves nothing. The IP scan is still valid on that run.

Options: `--ip`, `--token`, `--since`, `--root` (repeatable), `--ip-only`,
`--token-only`.

### What it proves

- At scan time the canary IP is not in the **readable files** under the roots
  above and not in journald. That is, that request's client address was not
  written to disk.
- The body canary is found only in the published DB row (`$ZIFIRI_DB_DIR/*.db`,
  `*.db-wal`). Finding it anywhere else is red: a log, tmp, a file outside the
  volume, `-shm`, journald.

### What it does not prove (the honest limit)

- **Deleted files and free blocks.** `grep` sees only the live file tree. A
  deleted log file's blocks, the file-system journal and SSD wear-levelling
  copies are not scanned. Those are §6.1 **Level 3** and are not guaranteed;
  the mitigation is full-disk encryption (§11.4).
- **Mount points that are not scanned.** Any path not added with `--root`, a
  separate disk, a network share, NFS, a host outside the container is out of
  scope. `-xdev` draws that boundary deliberately.
- **Memory.** This leg looks at the disk. For RAM, `memdump_scan.sh`.
- **A3 (forward-looking surveillance).** If the server has been taken over, the
  attacker may already have a copy taken at scan time. This script says "not on
  disk now", not "never was".
- **journald itself.** If `journalctl` is unreachable (not root, no journal, no
  systemd) the script returns `2`; it does not say "journald is clean".

### Interpretation

- An `ip-*` hit = red, no argument.
- A `token` hit inside `*.db`/`*.db-wal` = expected (published content), it shows
  up in the report's "Expected" section and does not break the green.
- A `token` hit inside `*.db-shm` = red. `-shm` is only the WAL index and carries
  no page content; a body there means something is wrong.

---

## 2. `write_allowlist.sh` — write allowlist (§5.2 items 2 and 3)

### What it does

Compares the `docker diff` output against the allowed set. Allowed:

```
/var/lib/zifiri/zifiri.db
/var/lib/zifiri/zifiri.db-wal
/var/lib/zifiri/zifiri.db-shm
/var/lib/zifiri/err.log
+ their parent dirs: /var, /var/lib, /var/lib/zifiri
+ /tmp and /run must be tmpfs: if they show up in the diff, tmpfs is assumed
  absent and it is red (§5.1)
```

Anything extra is red. The `A` (added), `C` (changed), `D` (deleted)
distinction is kept: an allowed directory being `D` is red too.

If `--volume-dir` is given the volume's **whole file set** is checked as well:
anything other than `zifiri.db`, `-wal`, `-shm`, `err.log` (including a
subdirectory) is red.

### Important technical point: `docker diff` does not see the volume

Docker does **not** include the contents of volume and tmpfs mount points in the
`docker diff` output. If `/var/lib/zifiri` is a named volume, the `zifiri.db`
lines never appear in the diff. So:

- the diff side proves that no path outside the allowlist appeared in the
  container's **writable layer** (with the root fs `read_only: true` that set
  really should be small);
- the volume's file set is a separate claim, measured with `--volume-dir`.

Those are two separate pieces of evidence; one does not stand in for the other.

### How to run

```bash
# after a load test
./write_allowlist.sh zifiri-app --volume-dir /var/lib/docker/volumes/zifiri-data/_data

# or pipe the diff in
docker diff zifiri-app | ./write_allowlist.sh --stdin
```

### What it proves

- In the container's writable layer there is no creation/change/deletion other
  than the four allowed files and their parent dirs.
- (if the volume check is given) the volume holds exactly the expected file set;
  no `zifiri.db-journal`, no `*.log.1`, no temporary file, no subdirectory.

### What it does not prove

- **The contents of the files.** It does not say what was written inside an
  allowed file; that is `canary_scan.sh`'s job.
- **Files written and then deleted.** A file that was `A` and then `D` shows up
  in the diff only as `D`. Its content may have gone to disk (Level 3).
- **The host side.** Nothing written by a process on the host outside Docker is
  in this output. `journalctl`, `/var/log`, processes outside the application
  are out of scope.
- **tmpfs contents.** `/tmp` and `/run` do not appear in the diff; a canary
  written there is not caught by this script (`canary_scan.sh` scans `/tmp` but
  not `/run` — deliberately: `/run` is for the pepper and pid files, and dumps
  are written there too).
- An empty diff is not green on its own: if the application never wrote, the
  test is empty. Without `--volume-dir` the script returns `2`.

---

## 3. `memdump_scan.sh` — memory dump (§5.2 item 4)

### What it does

1. Waits `DRILL_QUIET_SECONDS` (default **60**) after the traffic stops.
2. Refreshes the nginx workers (`nginx -s reload`, or `NGINX_RELOAD_CMD`, or
   `systemctl reload nginx` if needed). Waits 30 seconds for the old workers to
   exit; if they do not, it warns (the dumps would mislead).
3. Dumps the memory of BEAM (`beam.smp`) and the nginx workers with `gcore`.
4. Searches the dumps for the canary IP in four forms; reports the body canary
   as information.

Order matters: **refresh first, then dump.** An old worker's memory holds the
request buffer; dumping it measures the drill's failure, not the drill.

### How to run

```bash
# stop the traffic, then:
./memdump_scan.sh                       # nginx + BEAM running on the host
CANARY_TOKEN=zifiri-canary-... ./memdump_scan.sh

# if everything is inside the container:
DRILL_EXEC_PREFIX="docker exec -u root zifiri-app" \
NGINX_RELOAD_CMD="docker exec zifiri-app nginx -s reload" \
CANARY_TOKEN=zifiri-canary-... ./memdump_scan.sh
```

In container mode `gcore` writes the dump inside the container. The script
verifies that the dump is readable from the host; if it is not, it does not say
green, it stops with `2`. That is why you bind-mount the `$DRILL_OUT` directory
into the container:

```bash
docker run -v /run/zifiri-drill:/run/zifiri-drill ...
```

By default the dumps are written under `/run/zifiri-drill/memdump-<time>/`
(tmpfs — not `/tmp`, because `/tmp` is a scanned place, and to avoid leaking a
dump into the disk image as well). On a green run the dumps are deleted, on a red
one they are kept; `--keep` keeps them in every case.

`--dry-run` only prints what would be done, `--no-reload` deliberately scans the
old workers (when testing the refresh behaviour).

### What it proves

- 60 seconds after the traffic stops, there is no canary IP in the **refreshed**
  nginx workers or in BEAM. That is, the request address is not held in these
  processes' live memory.
- The IP never appearing on the BEAM side is direct proof of the §5.1 claim: the
  unix socket + the `X-Forwarded-For`/`X-Real-IP`/`Forwarded` stripping works.

### What it does not prove — the A3 limit

This script's limit is the same as the plan's A3 line and **is not negotiable**:

- **A dump taken during live traffic is out of scope.** The script runs after
  the traffic stops; a dump taken before that is expected to contain the IP, and
  that is not a bug, it is the definition of A3.
- **Freed pages.** `gcore` takes the process's mapping at that moment. Pages the
  allocator has handed back to the operating system, regions dropped with
  `madvise(MADV_DONTNEED)` and pages the process never touched are not in the
  dump. "Not in the dump" ≠ "never in RAM".
- **A physical RAM image.** Cold-boot attacks, DMA, hypervisor-level dumps are
  outside this script.
- **Kernel buffers.** Socket buffers, `sk_buff`, conntrack, page cache are not
  visible in a user process's dump. A kernel dump is separate work and is not
  here.
- **Processes we cannot dump.** If `gcore` fails (ptrace permission, setuid, a
  different user) the script returns `2`. A process that could not be dumped is
  not counted as "clean".
- **Swap and core files.** Swap must be off (§5.1); this script does not check
  swap. `swapon --show` is a separate check.
- **The dump is itself a leak.** The core files kept on a red run contain the
  canary IP. They must be deleted once the inspection is done; that is why
  `/run` (tmpfs) is the default.

---

## 4. `negative/plant.sh` — negative control (mandatory)

### What it does

Deliberately writes the canary into three places and requires `canary_scan.sh`
to find all three: a plain-text access record, a docker json-file log, and
`/proc/<pid>/environ`. It also runs a false-positive check with a neighbouring
address (`172.31.77.70`).

### Why it is mandatory

A green scan proves nothing: a wrong root, a wrong pattern, a permission error
and a working scanner all produce the same output. A scanner that cannot show red
saying "clean" is an untested claim. Details: `negative/README.md`.

### How to run

```bash
./negative/plant.sh        # the control; if it fails, do not trust the scanner
./negative/plant.sh -v     # run the scanner verbosely
```

No Docker needed; it runs on a development machine too.

---

## 5. `run-all.sh` — run everything in order

```bash
./run-all.sh              # full drill, summary table
./run-all.sh -v           # with each step's output
./run-all.sh --only control,canary
./run-all.sh --json       # a single JSON object for CI
```

Order: negative control → canary → allowlist → memdump. If the negative control
fails, the result of the remaining steps is treated as **void** and the total
becomes `1`.

The table shows `PASS` / `FAIL` / `SKIP`; `SKIP` means either `2` (unproven) or
`3` (environment missing), and neither is green.

---

## Drill order

At the exit of every phase (§13):

```bash
# 0) stop the traffic
# 1) is the scanner blind? — always first
./negative/plant.sh
# 2) disk leg
CANARY_TOKEN=... ./canary_scan.sh
./write_allowlist.sh zifiri-app --volume-dir "$VOLUME"
# 3) memory leg
CANARY_TOKEN=... ./memdump_scan.sh
# 4) network leg — a separate measurement, the §4.2 anonymity set (n)
```

Or a single command: `./run-all.sh`.

If all of them return `0` the phase's drill is green. If any returns `1` the
phase is not finished. If any returns `2` there is **no evidence**: finish the
missing tool or write into `docs/verify.md` why it could not be proven. If any
returns `3` the environment is missing (no docker) — that is not evidence either,
and it is written down the same way.

## P0 note

At P0 these scripts must come back green as a skeleton (§13). On an empty
install `canary_scan.sh` may return `2` with "directory missing, skipped"
warnings; that is expected behaviour — there is nothing to prove yet. From P1 on,
`0` is expected.

On a development machine without Docker `canary_scan.sh` returns **`3`**
(`no docker, skipped`). That is not an error, it is the report that the scope is
incomplete: a targeted scan can be done with `--root`, but drill evidence wants a
full scan. `negative/plant.sh` comes back green on this machine too.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `canary_scan.sh` is very slow | `/var/lib/docker` is large; the raw byte pass reads every binary file | normal; cap it with `DRILL_MAX_SCAN_BYTES` (the evidence weakens) |
| `journalctl unreadable` | not root, or no journal | run with `sudo`; otherwise accept `2` |
| `docker diff` is empty | the volume contents do not show up in the diff | pass `--volume-dir` |
| `gcore not found` | gdb is not installed | `apt install gdb` or `DRILL_EXEC_PREFIX` |
| `gcore` `ptrace: Operation not permitted` | `yama/ptrace_scope` or a different user | run as root, give the container `SYS_PTRACE` |
| reload `FAILED` | nginx is inside the container | `NGINX_RELOAD_CMD="docker exec ... nginx -s reload"` |
| `neither a BEAM nor an nginx process found` | the processes are inside the container | pass `DRILL_EXEC_PREFIX` |
| `the dump was created inside the container but is not visible from the host` | `$DRILL_OUT` is not bind-mounted | `-v /run/zifiri-drill:/run/zifiri-drill` |
| `C /tmp` shows up in the diff | `/tmp` is not tmpfs | add a tmpfs mount (§5.1); this is a real finding |
| `no docker, skipped` + `exit 3` | `/var/lib/docker` missing (docker not installed) | normal; use a host with docker for the drill, or narrow the scope with `--root` |
| the `negative control` failed | the scanner does not see the plants | `negative/plant.sh -v`; look at `scan.log`. Report no green until it is fixed |
| `allowlist unreadable` | `allowlist.txt` missing/moved | pass the path with `--allowlist` |
| `journald: SKIPPED` | no `journalctl` or not root | `sudo`; otherwise accept `2` |
