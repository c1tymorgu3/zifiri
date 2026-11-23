# zifiri — verification (verify.md)

Every **"preserved"** claim in the plan is tied here to a command you can run. If the
command is not green, the claim does not exist; the document does not change the claim,
the command does.

The anonymity claim is the first-class claim. What an instance publishes is its
operator's decision and has no command here; who can be identified does, and every
heading below carries the same `C-nn` ID as `docs/claims.md`.

- Source: `docs/spec.md` (the current contract); the plan sections cited per row are
  not published.
- This file is the output of §13 **P0**. P0's exit criterion: every row below has a
  command that really runs, and the drill skeleton is green on an empty install.
- Runtime environment: **Linux host + Docker**, bash. It is not run on Windows; on
  Windows only the files are edited.

---

## 0. How to run it

### 0.1 Shared variables

Once at the start of each session:

```bash
export C=/opt/zifiri                 # compose root (docker-compose.yml lives here)
export V=/var/lib/zifiri             # the one writable volume (host path, §5.2/2)
export DB=$V/zifiri.db
export Z=https://zifiri.example      # clearnet root
export ZO=http://zifiriXXXXXXXX.onion
export APP=zifiri-app                # container name of the app service
export NGX=zifiri-nginx
export CANARY="zifiri-canary-$(openssl rand -hex 6)"
export BODY="govde-$CANARY"
dc() { docker compose -f "$C/docker-compose.yml" "$@"; }
```

`CANARY` must stay **the same** for the whole drill (write → scan → delete → scan). A new
canary is a new drill.
`$ID` = the id of the post deleted during the test (assigned by hand,
`sqlite3 $DB "select max(id) from posts;"`).

### 0.2 Required tools (host)

```bash
apt-get install -y sqlite3 jq curl openssl binutils tcpdump tshark gdb cryptsetup util-linux minisign
go install github.com/rakyll/hey@latest   # for the adaptive difficulty measurement (§4.4)
npx playwright install chromium          # for the CSP inline test (§10.1)
```

`gcore` (the memory leg) needs `SYS_PTRACE` inside the container: `cap_add: [SYS_PTRACE]`
and `security_opt: [seccomp=unconfined]` on the `app` service — enabled only in the drill
profile, off in production.

### 0.3 Drill CLI contract (§1)

The drill script is `bin/drill`. Skeleton in P0, working version in P1. The contract:

| command | what it does | output |
|---|---|---|
| `bin/drill canary --ip 172.31.77.7 --body "$BODY"` | pads, solves PoW and builds the envelope with the real client crypto, sends it, waits until it is published | `status=202 bytes=0` |
| `bin/drill delete --canary "$CANARY"` | "yok ol" over the `own_i` tokens of the posts carrying the canary | `status=204` |
| `bin/drill chat --room genel --body "chat-$CANARY"` | joins the chat and sends a message | `status=202` |
| `bin/drill scan --canary "$CANARY"` | four-leg scan (FS, DB, WAL, journald) | `RED 0` (green) / `RED n` + the matching lines |
| `bin/drill pow-bench --n 20` | solves the client PoW 20 times, measures the durations | `median=<ms>` |

Exit code: `0` green, `1` red, `2` precondition missing. CI reads this code.

Fixed test network (so the canary IP is a real source address):

```bash
docker network create --subnet 172.31.77.0/24 zifiri-canary 2>/dev/null
docker network connect zifiri-canary $NGX 2>/dev/null
# client side: docker run --rm --network zifiri-canary --ip 172.31.77.7 ...
```

### 0.4 Markers

- **✅** runs on the host today, without the application code.
- **⏳Pn** the command depends on a file that Pn will write; while the file is missing the
  command is red and **that is expected**. At P0 exit these rows count as "skeleton green".
- **🔴** a deviation from the expected output = red = the phase is not finished (§13).

### 0.5 Markdown note

Inside tables, the pipes in a command are escaped as `\|` (markdown table syntax). When
copying, read `\|` as `|`; inside fenced blocks there is no escaping.

---

## Claim index — one heading per claim (C-01 … C-49)

The IDs are the ones in `docs/claims.md`; this index is the join between a claim and the
command that can refute it. Counts marked *today* were measured on **2026-11-23** with
`mix test <file>` on this checkout; where a row has no test the plan is the only source
and the claim is unproven.

### C-01 — A bucket is ten minutes, target 120, aligned to the wall clock
`mix test test/bucket_test.exs` → `14 passed` (today).

### C-02 — The bucket drains on the clock, not on a count; the drain is shuffled
`mix test test/bucket_test.exs` → `14 passed` (today).

### C-03 — An empty bucket is filled with decoys; `fill(n)` = `n − real`
`mix test test/decoy_test.exs` → `15 passed` (today).

### C-04 — A decoy envelope is indistinguishable from a real one
`mix test test/decoy_shape_test.exs` → `6 passed` (today).

### C-05 — The moment of writing is hidden; the position inside the bucket is uniform
`mix test test/timing_test.exs` → `3 passed` (today).

### C-06 — The decoy key is per bucket, in RAM, never on disk
`mix test test/decoy_test.exs` → `15 passed` (today).

### C-07 — Fast mode: under one second, a 1-in-5 neighbourhood
No test yet (`fast_mode_test`); the claim is unproven.

### C-08 — The 1:1 table has five columns and no sender column
`mix test test/mailbox_test.exs` → `30 passed` (today).

### C-09 — 1:1 addressing is a 16-byte HMAC tag; the key is not stored
`mix test test/mailbox_test.exs` → `30 passed` (today).

### C-10 — A 1:1 envelope is exactly 4096 bytes, enforced by the table too
`mix test test/mailbox_test.exs` → `30 passed` (today).

### C-11 — 1:1 TTL is 72 hours and the sweeper deletes what expired
`mix test test/mailbox_test.exs` → `30 passed` (today); the sweeper row is timing sensitive.

### C-12 — 1:1 paging: 200 upper bound, a cursor that neither skips nor repeats
`mix test test/mailbox_test.exs` → `30 passed` (today).

### C-13 — The recipient cannot open a decoy envelope
No test; AEAD is not exercised against a decoy.

### C-14 — 1:1 envelopes join the bucket and are completed to 120
No test; envelopes are written directly today.

### C-15 — Listings: plaintext metadata, non-unique `owner_hash`, day precision
`mix test test/listings_test.exs` → `33 passed` (today).

### C-16 — Presence: no trace when off, `:unknown`, mutual for five minutes, ETS only
`mix test test/presence_test.exs` → `31 passed` (today).

### C-17 — Deletion level 1: the row goes, no tombstone, the file is untouched
`mix test test/vanish_test.exs` → `33 passed` (today).

### C-18 — Deletion level 2: the body is in neither the file nor the `-wal`
`mix test test/vanish_test.exs` → `33 passed` (today); see §6 for the manual scan.

### C-19 — Schema allowlist: no table outside the list
`mix test test/schema_test.exs` → `8 passed` (today).

### C-20 — No logs at code level: no `Logger.info`, `IO.inspect`, `dbg`
`mix test test/no_log_test.exs test/architecture_test.exs` → `9 + 6 passed` (today).

### C-21 — No logs at deployment level: proxy, container, crash dump, swap
`bin/drill scan` on a live container; no automated test.

### C-22 — The envelope is padded to 4 KB and its size does not vary
`mix test test/envelope_test.exs` → `22 passed` (today).

### C-23 — `owner_hash` is a peppered HMAC, not an identity
`mix test test/owner_test.exs` → `18 passed` (today).

### C-24 — IP and peer never reach the application
`mix test test/transport_test.exs` → `2 passed` (today).

### C-25 — PoW: the challenge is single-use and bound to the envelope
`mix test test/pow_test.exs` → `22 passed` (today).

### C-26 — Chat writes nothing to disk
`mix test test/chat_test.exs` → `31 passed` (today).

### C-27 — Fixed-size error responses, the path is never echoed
`mix test test/leak_test.exs` → `9 passed` (today); the 2026-11-22 snapshot had this red.

### C-28 — No published claim against A1
`grep -nE 'A1.*%[0-9]' docs/scope-v5.md | wc -l` → `0`.

### C-29 — When cover ships, the set against A1 is at most k
`cover_test`, not written; the text may only say "at most k".

### C-30 — Fast mode is the default
`fast_mode_test`, not written; the client default is already `fast` (`client/src/ui/mode.ts`).

### C-31 — "Send hidden" label with a live neighbourhood counter
Client test, not written.

### C-32 — The application does not read IP / XFF / user-agent
`mix test test/transport_test.exs` → `2 passed` (today).

### C-33 — No code outside `transport.ex` reads those headers
`grep -rnE 'remote_ip|x-forwarded-for' --include='*.ex' lib | grep -v transport.ex | wc -l` → `0`.

### C-34 — The nginx access log is off
`grep -E '^[[:space:]]*access_log' infra/nginx.conf | grep -vcE 'access_log[[:space:]]+off;'` → `0`.

### C-35 — A live request leaves the client address in no log
§12.1 row 4, run against a live stack.

### C-36 — On onion the server cannot see the client IP
§12.1 plus `infra/tor/torrc`.

### C-37 — No claim against A1 in the clearnet copy
Text audit of `docs/scope-v5.md` §Claim texts.

### C-38 — "Yok ol" zeroes the `.db` and `-wal` within five seconds
`mix test test/vanish_test.exs` → `33 passed` (today); §12.3 is the manual drill.

### C-39 — VACUUM is not on the delete path
`grep -rn 'VACUUM' --include='*.ex' lib | grep -vc maintenance` → `1` today
(`lib/zifiri/vanish.ex`); the decision has not reached the code.

### C-40 — `auto_vacuum = INCREMENTAL`
`grep -rn auto_vacuum --include='*.ex' lib config priv` → `0` today.

### C-41 — No backup, no tombstone
`mix test test/schema_test.exs` → `8 passed` (today).

### C-42 — Block-level disk rests on LUKS
`lsblk -o NAME,FSTYPE -n | grep -c crypto_LUKS` → `>=1`; no block-level guarantee beyond it.

### C-43 — The operator is the moderator; the decision record has `threshold = 1`
`mix test test/mod_test.exs` → `18 passed` (today).

### C-44 — The audit chain catches later edits
`mix test test/mod_test.exs` → `18 passed` (today).

### C-45 — The audit chain does not prove who decided
Text audit; this claim must not be made anywhere.

### C-46 — The identity line is 40 bytes / 64 base32 characters
`mix test test/identity_test.exs` → `27 passed` (today).

### C-47 — `mailbox_id` is derived from the seed by HKDF
`mix test test/identity_test.exs` → `27 passed` (today).

### C-48 — "Write it on paper" is not claimed in v1
Text audit of the v1 copy.

### C-49 — The v2 word list is 27 words
`identity_test` v2 group, not written.

---

## 1. The seizure drill — three legs (§1, §13)

Runs at the exit of every phase. If all three are not green the phase does not close.

### Leg 1 — disk image

```bash
# 1) write and publish the post carrying the canary
bin/drill canary --ip 172.31.77.7 --body "$BODY"          # status=202 bytes=0
sleep 5
# 2) confirm it is published (the body canary must be found ONLY here)
curl -sS "$Z/api/feed" | jq -r '.posts[].body' | grep -cF "$CANARY"   # >=1
# 3) scan: the IP in four forms, the UA and the body canary
bin/drill scan --canary "$CANARY"                          # RED 0
# 4) delete, scan again (level 2, §6.1)
bin/drill delete --canary "$CANARY"                        # status=204
sleep 5
bin/drill scan --canary "$CANARY"                          # RED 0
```

Manual equivalent (the reference if the script breaks):

```bash
# IP: plain text, Erlang tuple, IPv4-mapped IPv6, raw four bytes (172=0xAC 31=0x1F 77=0x4D 7=0x07)
for pat in '172\.31\.77\.7' '172,31,77,7' '::ffff:172\.31\.77\.7'; do
  echo "== $pat"; grep -rlaF -- "$pat" "$V" /var/lib/docker /var/log /tmp 2>/dev/null
done
grep -rlaP -- '\xac\x1f\x4d\x07' "$V" /var/lib/docker 2>/dev/null
journalctl --since '-30 min' 2>/dev/null | grep -cF "$CANARY"
```

Expected: no file name at all, the `journalctl` count is `0`. A single hit = red.

A powered-off disk image (§2 A1, §11.4): without LUKS opened, not even the SQLite
signature shows in the image.

```bash
cryptsetup luksDump /dev/nvme0n1p3 | head -3                 # the LUKS header is there
grep -ac 'SQLite format 3' /mnt/image/var/lib/zifiri/zifiri.db  # 0
```

### Leg 2 — memory dump (60 s after the traffic stops)

```bash
sleep 60
dc exec -T nginx nginx -s reload                       # workers are recycled
dc exec -T app sh -c 'gdb -p 1 -batch -ex "gcore /tmp/beam.core" >/dev/null 2>&1'
dc cp app:/tmp/beam.core /tmp/beam.core
strings -a /tmp/beam.core | grep -cF "$CANARY"        # 0
strings -a /tmp/beam.core | grep -c '172\.31\.77\.7'  # 0
```

Expected: `0` and `0`. Free-page residue and a physical RAM image are out of scope
(§5.2/4, A3).

### Leg 3 — network capture + published data

```bash
tcpdump -i any -s0 -w /tmp/a3.pcap 'tcp port 443' &
TCPDUMP=$!
for i in 1 2 3 4 5; do bin/drill canary --ip 172.31.77.$((10+i)) --body "a3-$CANARY-$i"; done
sleep 3; kill $TCPDUMP
# (a) were the arrivals spread over an interval longer than 60 s?
tshark -r /tmp/a3.pcap -Y 'http.request.method=="POST"' -T fields -e frame.time_epoch \
  | sort -n | awk 'NR==1{f=$1} END{print $1-f}'        # >= 60
# (b) did the publication arrive in a single burst?
for i in $(seq 1 30); do curl -sS "$Z/api/feed" | jq -r '.posts|length'; sleep 1; done | uniq -c
# (c) is there any matching field on the row?
sqlite3 "$DB" "select group_concat(name,' ') from pragma_table_info('posts');"
```

Expected: (a) ≥ `60`; (b) the count steps once (every post in the same second); (c) the
column set is `id parent_id kova body day owner_hash mod_state` — no IP, no clock, no
round id. Matching success ≈ 1/n, n = k = 5 → **≤ 20%**.

---

## 2. §5.1 — every row of the log table

| Claim | Command | Expected output | Source |
|---|---|---|---|
| The nginx access log is off: `access_log off;` is written explicitly (a missing directive means logging) | `dc exec -T nginx nginx -T 2>/dev/null \| grep -cE 'access_log[[:space:]]+off;'` | `>=1` (one per server block; `0` = 🔴) | §5.1 |
| The nginx access log really writes nothing: not one line after a canary request | `curl -sS -o /dev/null -A "$CANARY" "$Z/"; sleep 2; docker logs --since 3m $NGX 2>/dev/null \| wc -l` | `0` (the driver is `none`, so `docker logs` cannot read it either) | §5.1 |
| The nginx error log: `error_log /dev/null crit;` | `dc exec -T nginx nginx -T 2>/dev/null \| grep -cE 'error_log[[:space:]]+/dev/null[[:space:]]+crit;'` | `>=1` | §5.1 |
| The nginx error log carries no client address | `curl -sS -o /dev/null -A "$CANARY" "$Z/api/yok"; grep -rlaF "$CANARY" $V /var/log/nginx 2>/dev/null \| wc -l` | `0` | §5.1 |
| nginx → Phoenix: `X-Forwarded-For`, `X-Real-IP`, `Forwarded`, `User-Agent` are emptied | `dc exec -T nginx nginx -T 2>/dev/null \| grep -cE 'proxy_set_header[[:space:]]+(X-Forwarded-For\|X-Real-IP\|Forwarded\|User-Agent)[[:space:]]+"";'` | `4` | §5.1 |
| The IP never enters the BEAM: unix socket only, no TCP listener | `dc exec -T app sh -c 'ss -lx \| grep -c zifiri.sock; ss -ltn \| grep -c ":4000"'` | `1` and `0` | §5.1 |
| Headers and the peer address do not reach Phoenix (test) | `mix test test/zifiri/headers_test.exs` ⏳P1 | `0 failures` (no `x-forwarded-for`/`user-agent` in the request, `get_peer_data` port is `0`) | §5.1 |
| Docker: `logging.driver: none` on every service | `docker inspect -f '{{.Name}} {{.HostConfig.LogConfig.Type}}' $(dc ps -q) \| grep -vc ' none$'` | `0` | §5.1 |
| No `*-json.log` on the host (stdout is not written to disk) | `find /var/lib/docker/containers -name '*-json.log' -size +0 2>/dev/null \| wc -l` | `0` | §5.1 |
| No application output in the system journal (or it carries no identity) | `journalctl --since '-2 hours' 2>/dev/null \| grep -acF "$CANARY"` | `0` | §5.1 |
| Phoenix prod logger `warning`, `Plug.Logger` not in the pipeline | `grep -rn 'Plug.Logger' $C/app/lib \| wc -l; grep -c 'level: :warning' $C/app/config/prod.exs` | `0` and `>=1` | §5.1 |
| An error record is reduced to `{exception class, module, line}`; `conn`/peer/body are dropped | `mix test test/zifiri/log_redaction_test.exs` ⏳P1 | `0 failures` (a 500 is produced, no canary in `err.log`, the record has 3 fields) | §5.1 |
| The error record carries no canary (end to end) | `curl -sS -o /dev/null -A "$CANARY" -H "X-Canary: $CANARY" "$Z/api/boom"; sleep 1; grep -acF "$CANARY" $V/err.log` | `0` | §5.1 |
| `err.log` is a 1 MB ring: it does not overflow | `for i in $(seq 1 300); do curl -sS -o /dev/null "$Z/api/boom"; done; stat -c %s $V/err.log` | `<= 1048576` | §5.1 |
| Ecto `log: false`; only counters in telemetry | `grep -c 'log: false' $C/app/config/*.exs; mix test test/zifiri/telemetry_test.exs` ⏳P1 | `>=1` and `0 failures` (no `:query` event carrying SQL text) | §5.1 |
| Application code does not read `remote_ip`/`x-forwarded-for`/`user_agent` (compile-time grep; a violation breaks the build) | `grep -rnE 'remote_ip\|x_forwarded_for\|x-forwarded-for\|user_agent\|user-agent' $C/app/lib \| grep -v '/modules/' \| wc -l` | `0` | §5.1 |
| No BEAM crash dump is attempted | `dc exec -T app sh -c 'echo "SEC=$ERL_CRASH_DUMP_SECONDS DUMP=$ERL_CRASH_DUMP"'` | `SEC=0 DUMP=/dev/null` | §5.1 |
| Killing the VM produces no `erl_crash.dump` | `dc kill -s KILL app; sleep 10; docker diff $APP \| grep -c 'erl_crash.dump'; find / -xdev -name 'erl_crash.dump*' 2>/dev/null \| wc -l` | `0` and `0` | §5.1 |
| Swap is off | `swapon --show; grep -c '^/dev' /proc/swaps` | empty output and `0` | §5.1 |
| Hibernate is off | `grep -cw disk /sys/power/state` | `0` (`freeze mem` is visible, no `disk`) | §5.1 |
| Core dumps are off: `ulimit -c 0`, empty `core_pattern`, Docker `ulimits.core: 0` | `dc exec -T app sh -c 'ulimit -c'; sysctl -n kernel.core_pattern; docker inspect -f '{{json .HostConfig.Ulimits}}' $APP` | `0`; `\|/bin/false` or empty; `[{"Name":"core","Soft":0,"Hard":0}]` | §5.1 |
| Audit: an aggregate counter, not an access record; it carries no identity | `sqlite3 "$DB" ".schema" \| grep -icE 'remote_ip\|user_agent\|peer\|cookie\|session'` | `0` | §5.1 |
| Write allowlist: exactly four files on the volume | `comm -13 <(printf '%s\n' err.log zifiri.db zifiri.db-shm zifiri.db-wal \| sort) <(ls -A $V \| sort)` | empty output | §5.2/2 |
| The container root is read-only; writes go only to tmpfs + volume | `docker diff $APP \| grep -vE '^[AC] /(tmp\|run\|var/lib/zifiri)(/\|$)' \| wc -l` | `0` | §5.2/3 |

---

## 3. §4.1 — fixed-size buckets and padding

Buckets: 256 B, 1 KB, 4 KB, 16 KB. The rest of the envelope is a fixed length; one request
size per bucket.

| Claim | Command | Expected output | Source |
|---|---|---|---|
| Padding is validated: the length prefix does not exceed the bucket, the filler bytes are zero | `mix test test/zifiri/pad_test.exs` ⏳P3 | `0 failures` (256/1024/4096/16384 → `202`; 255/1023/4097/16385 and non-zero filler → `400`) | §4.1 |
| An unpadded / off-bucket body is refused (on the wire) | `head -c 255 /dev/urandom > /tmp/bad.bin; curl -sS -o /dev/null -w '%{http_code}\n' --data-binary @/tmp/bad.bin "$Z/api/post"` | `400` (the size check runs before PoW; a `422` means the order is wrong = 🔴) | §4.1 |
| The response is a bodyless `202`: its size says nothing about the content | `bin/drill canary --body "$BODY"` | `status=202 bytes=0` | §4.1 |
| One request size per bucket: different lengths in the same bucket are the same size on the wire | `tcpdump -i any -s0 -w /tmp/b1.pcap 'tcp port 443' & sleep 1; for n in 10 40 90 150 200; do bin/drill canary --body "$(head -c $n /dev/zero \| tr '\0' a)"; done; sleep 2; pkill tcpdump; tshark -r /tmp/b1.pcap -Y 'tcp.len>0' -T fields -e tcp.len \| sort -n \| uniq -c \| wc -l` | `<= 2` (one dominant size plus a possible TLS split) | §4.1 |
| The anonymity set is per bucket: `/pool` reports bucket by bucket | `curl -sS "$Z/pool" \| jq -e '(.buckets \| keys) == ["1024","16384","256","4096"]'` | `true` | §4.1, §4.2 |

---

## 4. §4.2 — batch publication

| Claim | Command | Expected output | Source |
|---|---|---|---|
| Minimum pool k = 5, per bucket | `curl -sS "$Z/pool" \| jq -r '.buckets["256"].k'` | `5` | §4.2/2 |
| No publication before k is full (the post waits) | `bin/drill canary --body "k1-$CANARY" >/dev/null; sleep 1; curl -sS "$Z/pool" \| jq -r '.buckets["256"].queued'` | `< 5`, the feed length is unchanged | §4.2/2 |
| The close is random between T_min..T_max; about 20% of the pool is left for the next round | `mix test test/zifiri/batch_test.exs` ⏳P3 | `0 failures` (close delay 2–20 min, carry-over 10–30%) | §4.2/2 |
| The round id is **not on the row** (it lives in RAM and dies on publication) | `sqlite3 "$DB" "select group_concat(name,' ') from pragma_table_info('posts');"` | `id parent_id kova body day owner_hash mod_state` | §4.2/1, §4.3 |
| No clock, a day (day precision) | `sqlite3 "$DB" "select count(*) from posts where day not glob '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]';"` | `0` | §4.3 |
| `UNIQUE(owner_hash)`: a resend is idempotent, no second row | `sqlite3 "$DB" "select count(*) from (select owner_hash from posts group by owner_hash having count(*)>1);"` | `0` | §3.3, §4.2/3 |
| The same envelope sent twice gives two `202`s and one row | `bin/drill canary --body "dup-$CANARY"; bin/drill canary --body "dup-$CANARY"; sqlite3 "$DB" "select count(*) from posts where body like '%dup-$CANARY%';"` | `status=202 bytes=0` ×2 and `1` | §4.2/3 |
| `boot_id` changes on restart (the client learns it lost the queue) | `B1=$(curl -sSI "$Z/api/feed" \| tr -d '\r' \| awk -F': ' 'tolower($1)=="x-zifiri-boot"{print $2}'); dc restart app; sleep 20; B2=$(curl -sSI "$Z/api/feed" \| tr -d '\r' \| awk -F': ' 'tolower($1)=="x-zifiri-boot"{print $2}'); test -n "$B1" && test "$B1" != "$B2"` | exit code `0` | §4.2/3 |
| The queue is RAM only: no queue table is written to disk | `sqlite3 "$DB" "select count(*) from sqlite_master where name like '%queue%' or name like '%pending%';"` | `0` | §4.2/1 |
| Anonymity-set measure: `/anon` gives the last 24 h distribution of n per bucket | `curl -sS "$Z/anon" \| jq -r '.buckets["256"] \| "min=\(.min) medyan=\(.median)"'` | `median >= 5` | §4.2/4 |
| `/pool` shows "queued / target k" at this instant | `curl -sS "$Z/pool" \| jq -c '.buckets["256"] \| {queued,k}'` | `{"queued":n,"k":5}` | §4.2/4 |

---

## 5. §4.4 — PoW, adaptive difficulty, identity-free layers

| Claim | Command | Expected output | Source |
|---|---|---|---|
| `challenge` lives in RAM, 5 min, the same for everyone | `A=$(curl -sS "$Z/api/challenge" \| jq -r .challenge); B=$(curl -sS "$Z/api/challenge" \| jq -r .challenge); test "$A" = "$B" && echo same` | `same` | §4.4/1 |
| PoW is bound to the body and cannot move to another request; the same `(challenge,nonce)` is not accepted twice | `mix test test/zifiri/pow_test.exs` ⏳P3 | `0 failures` (A's nonce in B's body → `422`; a replay → `422`) | §4.4/1 |
| The PoW target is ~250 ms (client side) | `bin/drill pow-bench --n 20` | median `200–400 ms` | §4.4/1 |
| Adaptive difficulty: the target rises under load and falls when it eases | `D1=$(curl -sS "$Z/api/challenge" \| jq -r .target_bits); hey -z 60s -c 64 "$Z/api/challenge" >/dev/null 2>&1 & sleep 30; D2=$(curl -sS "$Z/api/challenge" \| jq -r .target_bits); wait; echo "$D1 -> $D2"` | `D2 > D1`; back to `D1` after 2 idle minutes | §4.4/2 |
| The global circuit breaker lives in memory only | `sqlite3 "$DB" ".schema" \| grep -icE 'breaker\|throttle\|ratelimit'` | `0` | §4.4/3 |
| The same body hash is dropped inside a short window | `bin/drill canary --body "rep-$CANARY"; bin/drill canary --body "rep-$CANARY"; sqlite3 "$DB" "select count(*) from posts where body like '%rep-$CANARY%';"` | `1` | §4.4/4 |
| No IP-based limit at the edge (no `limit_req` zone) | `dc exec -T nginx nginx -T 2>/dev/null \| grep -c 'limit_req'` | `0` | §4.4 |
| No layer looks at identity: no key/quota table on the write path | `grep -rnE 'quota\|rate_limit\|api_key' $C/app/lib \| grep -v '/modules/' \| wc -l` | `0` | §4.4 |

---

## 6. §6.1 — deletion, level 1/2

| Claim | Command | Expected output | Source |
|---|---|---|---|
| Level 1 (logical): the row leaves the query and the API | `curl -sS -o /dev/null -w '%{http_code}\n' "$Z/api/post/$ID"` | `404` | §6.1 |
| Level 2: the canary is not in the DB file | `grep -acF "$CANARY" "$DB"` | `0` | §6.1 |
| Level 2: the canary is not in the WAL | `grep -acF "$CANARY" "$DB-wal"` | `0` | §6.1 |
| Level 2: the canary is not in the shm | `grep -acF "$CANARY" "$DB-shm"` | `0` | §6.1 |
| `PRAGMA secure_delete=ON` is applied (code + behaviour) | `grep -rn 'secure_delete' $C/app/lib $C/app/config \| wc -l; mix test test/zifiri/delete_test.exs` ⏳P4 | `>=1` and `0 failures` (a deleted page is zeroed) | §6.1 |
| The WAL empties after `wal_checkpoint(TRUNCATE)` | `sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);"; stat -c %s "$DB-wal"` | `0\|N\|N` (first field `0` = not busy) and `0` | §6.1 |
| The daily `VACUUM` runs | `sqlite3 "$DB" "VACUUM;"; stat -c %s "$DB"` | the size shrinks or stays; afterwards `grep -acF "$CANARY" "$DB"` → `0` | §6.1 |
| The delete response is only `204` | `bin/drill delete --canary "$CANARY"` | `status=204` | §6 |
| No tombstone: no "deleted" row is written | `sqlite3 "$DB" "select count(*) from sqlite_master where name like '%tombstone%' or name like '%deleted%';"` | `0` | §6/1 |
| Queued (pending) posts fall too | `bin/drill canary --body "pend-$CANARY" >/dev/null; Q1=$(curl -sS "$Z/pool" \| jq -r '.buckets["256"].queued'); bin/drill delete --canary "$CANARY" >/dev/null; Q2=$(curl -sS "$Z/pool" \| jq -r '.buckets["256"].queued'); echo "$Q1 -> $Q2"` | `Q2 < Q1` | §6/1 |
| The seed is deleted only **after** `204`; it is kept on a network error | `mix test test/zifiri/wipe_order_test.exs` ⏳P4 | `0 failures` (error → the seed stays, the request is resent) | §6/3 |
| Inside the pepper rotation window the old and new pepper are both tried | `mix test test/zifiri/pepper_rotation_test.exs` ⏳P4 | `0 failures` | §6/1, §3.3 |

---

## 7. §10.1 — CSP and inline script

| Claim | Command | Expected output | Source |
|---|---|---|---|
| The CSP header exists and does not contain `'unsafe-inline'` | `curl -sSI "$Z/" \| tr -d '\r' \| grep -i '^content-security-policy:' \| grep -c "unsafe-inline"` | `0` | §10.1 |
| All eleven CSP directives are in place | `H=$(curl -sSI "$Z/" \| tr -d '\r' \| grep -i '^content-security-policy:'); for d in "default-src 'none'" "script-src 'self'" "style-src 'self'" "img-src 'self'" "font-src 'self'" "connect-src 'self'" "base-uri 'none'" "form-action 'none'" "frame-ancestors 'none'" "require-trusted-types-for 'script'"; do grep -qF "$d" <<<"$H" && echo "ok $d" \|\| echo "EKSIK $d"; done \| grep -c EKSIK` | `0` | §10.1 |
| Inline script does not run (headless browser) | `npx playwright test e2e/csp.spec.ts --reporter=line` ⏳P7 | `2 passed` | §10.1 |
| The other headers: no-referrer, nosniff, COOP, no-store, HSTS | `curl -sSI "$Z/api/feed" \| tr -d '\r' \| grep -icE '^(referrer-policy: no-referrer\|x-content-type-options: nosniff\|cross-origin-opener-policy: same-origin\|cache-control: no-store\|strict-transport-security:)'` | `5` | §10.1 |
| The body is plain text: HTML cannot be injected (no XSS) | `bin/drill canary --body '<img src=x onerror=alert(1)>' >/dev/null; sleep 30; P=$(curl -sS "$Z/api/feed" \| jq -r '.posts[] \| select(.body\|contains("onerror")) \| .id' \| head -1); curl -sS "$Z/p/$P" \| grep -c 'onerror='` | `0` (and the `&lt;img` count is `1`) | §10.1 |
| External links are not clickable: user text never produces `<a href>` | `curl -sS "$Z/p/$P" \| grep -c 'href="https://example.com"'` | `0` | §10.2 |
| Unicode control characters are stripped (bidi, zero width) | `bin/drill canary --body "$(printf 'bidi\xe2\x80\xae$CANARY')" >/dev/null; curl -sS "$Z/api/feed" \| jq -r '.posts[] \| select(.body\|contains("bidi")) \| .body' \| grep -c $'\u202e'` | `0` | §10.1 |

---

## 8. §3.3 — no public key column in the schema

| Claim | Command | Expected output | Source |
|---|---|---|---|
| No public key / identity column in the schema | `sqlite3 "$DB" ".schema" \| grep -icE 'pub(lic)?_?key\|ed25519\|author_id\|user_id\|identity\|nickname'` | `0` | §3.3, §3.1 |
| `schema_test.exs` enforces it | `mix test test/zifiri/schema_test.exs` ⏳P2 | `0 failures` | §3.1, §13 P2 |
| Ownership is HMAC only: `owner_hash` is 64 hex, there is no token | `sqlite3 "$DB" "select count(*) from posts where length(owner_hash) != 64;"` | `0` | §3.3 |
| No shared field between two posts (each post has its own `own_i`) | `sqlite3 "$DB" "select count(*) from (select owner_hash from posts group by owner_hash having count(*)>1);"` | `0` | §3.3 |
| `server_pepper` is not on disk, it is in tmpfs | `findmnt -T /run/zifiri/pepper -n -o FSTYPE; grep -rlaF "$(cat /run/zifiri/pepper)" $V 2>/dev/null \| wc -l` | `tmpfs` and `0` | §4.3, §11.4 |

---

## 9. §2 — the threat model's other "preserved" claims

| Claim | Command | Expected output | Source |
|---|---|---|---|
| A1 the disk image cannot be read: LUKS | `lsblk -o NAME,FSTYPE -n \| grep -c crypto_LUKS` | `>=1` | §11.4 |
| A2 onion hardens it: `Onion-Location` is published | `curl -sSI "$Z/" \| tr -d '\r' \| grep -ic '^onion-location:'` | `1` | §11.3 |
| A2 onion traffic comes from loopback, no real IP | `ss -tn state established '( sport = :80 )' \| awk 'NR>1{print $5}' \| grep -vc '^127\.0\.0\.1:'` | `0` (the matching connection count must also be `>=1`) | §11.3 |
| A5 reproducible build: two runners give the same hash | `sha256sum dist/assets/*.js \| sort` (on two independent runners) | the two outputs are byte-identical | §10.3 |
| A5 a hash publication exists | `test -s $C/docs/hashes.txt && minisign -Vm $C/docs/hashes.txt -p $C/docs/hashes.pub` | `Signature and comment signature verified` | §10.3 |
| Bundle < 100 KB | `find $C/app/assets/dist \( -name '*.js' -o -name '*.css' \) -type f -exec du -cb {} + \| tail -1` | `<= 102400` | §11.1 |
| Image < 200 MB | `docker image inspect -f '{{.Size}}' zifiri:latest` | `<= 209715200` | §13 P1 |
| Chat messages are not written to disk | `bin/drill chat --room genel --body "chat-$CANARY"; sleep 2; grep -acF "chat-$CANARY" "$DB"; grep -acF "chat-$CANARY" "$DB-wal"` | `0` and `0` | §7.1 |
| Chat history is gone on restart | `dc restart app; sleep 20; curl -sS "$Z/api/chat/genel/history" \| jq 'length'` | `0` | §7.1 |
| Epoch/ctr replay is refused | `mix test test/zifiri/chat_replay_test.exs` ⏳P5 | `0 failures` (an old epoch signature → `422`) | §7.3 |
| The mod store is separate from the content store; it never sees `owner_hash` | `sqlite3 "$DB" "select count(*) from sqlite_master where type='table' and name like '%mod%';"` | `0` | §8.1 |
| The audit chain verifies and its head is published daily | `mix zifiri.verify --only audit; curl -sS "$Z/audit" \| jq -r '.head'` | exit code `0` and a 64-hex head | §8.2 |
| A mod session cannot be linked to content | `mix test test/zifiri/mod_separation_test.exs` ⏳P6 | `0 failures` | §8.3 |
| The core tests pass with the module absent | `mv $C/app/lib/zifiri/modules /tmp/mod.bak && mix test 2>&1 \| tail -3; mv /tmp/mod.bak $C/app/lib/zifiri/modules` | `0 failures` | §12/1 |
| No privacy module is on by default | `mix zifiri.verify --only modules` | no `MODÜL AÇIK` line, exit code `0` | §12/4 |

---

## 10. Outside the model — no command, because there is no claim

These sit outside the model: inventing a measurement for them would violate §14. Each
one is named in plan §14 as a boundary, and none of them is softened into a promise.

| class | status | why there is no command |
|---|---|---|
| A3 forward-looking surveillance | not preserved | the live request stream and live memory are visible by design; there is no protection to measure |
| A6 device access | not preserved | the seed is on the device; optional passphrase wrapping is a reduction, not a guarantee |
| Read privacy | not preserved | who reads what is visible from the network (except over onion) |
| Level 3 (block device) | no guarantee | only the LUKS reduction; residue is reachable on a running system |
| Self-betrayal through style/content | not preserved | there is no technical fix |

---

## 11. CI binding

`mix zifiri.verify` runs every row in order and exits `1` if it returns `RED n`. Phase
mapping (§13):

| phase | sections that must be green |
|---|---|
| P1 | all of §2 (nginx, Docker, BEAM, swap/core/hibernate, Ecto), the bundle/image rows in §10 |
| P2 | all of §8, the LUKS/pepper rows in §9 |
| P3 | all of §3, §4, §5 |
| P4 | all of §6 |
| P5 | the chat rows in §9 |
| P6 | the mod rows in §9 |
| P7 | all of §7, the A5 rows in §9 |

Rule: a red row is not carried into the next phase; if it is carried, the phase does not
close and the row is **not deleted** from this file — it is marked "known red" with a date
and a reason.

---

## Pepper

In production the key for `owner_hash` is read from `/run/zifiri/pepper`
(`ZIFIRI_PEPPER` changes the path). If the file is missing, unreadable, or shorter than
32 bytes, `Zifiri.Owner.validate!/0` crashes at boot; it does not fall back to the
development constant (plan §4.3, §11.4).

| check | command | expected | § |
|---|---|---|---|
| The pepper is in tmpfs and ≥ 32 bytes | `stat -c '%s' /run/zifiri/pepper; test "$(stat -c '%s' /run/zifiri/pepper)" -ge 32` | the size is printed and the exit code is `0` | §4.3 |
| Prod does not boot without the pepper | `sudo mv /run/zifiri/pepper{,.bak} && dc up -d --force-recreate app; sleep 15; docker inspect -f '{{.State.Restarting}}' "$(dc ps -q app)"; sudo mv /run/zifiri/pepper{.bak,} && dc restart app` | `true` — the container keeps restarting, it does not stay up (the log line is only `class: RuntimeError`; the message text is deliberately not written) | §4.3, §11.4 |

---

## 12. Post-decision rows — network layer and deletion

The runnable counterpart of the decisions in `docs/scope-v5.md` (no claim against A1 on
clearnet, deletion N = 5, VACUUM out of the delete path). Three blocks; each gives
green/red on its own.

### 12.1 nginx: access_log off, no client address in the error log

```bash
# 1) is the access log fully off in the configuration (comment lines do not count)
dc exec -T nginx nginx -T 2>/dev/null \
  | grep -E '^[[:space:]]*access_log' \
  | grep -vcE 'access_log[[:space:]]+off;'          # expected: 0

# 2) the access log file was never opened
dc exec -T nginx sh -c 'ls /var/log/nginx/access.log 2>/dev/null | wc -l'   # expected: 0

# 3) the error log carries no client address: /dev/null
dc exec -T nginx nginx -T 2>/dev/null \
  | grep -E '^[[:space:]]*error_log'                # expected: error_log  /dev/null crit;

# 4) live request: the canary IP appears in no log
bin/drill canary --ip 172.31.77.7 --body "log-$CANARY" >/dev/null
dc logs --since 2m nginx 2>&1 | grep -cF '172.31.77.7'   # expected: 0
```

Green criterion: all four rows give the expected value. If row 3 writes anything other
than `error_log /dev/null crit;` (especially `stderr`), row 4 alone is not enough: the
error log file is scanned as well.

Today (2026-11-22): `infra/nginx.conf` has 5 `access_log` lines, all `off`; the
configuration side of rows 1 and 2 is **green**. Row 4 (the live drill) was **not run →
none**.

### 12.2 the application does not read `remote_ip` / `x-forwarded-for`

```bash
# 1) no code outside the single permitted module reads these headers
grep -rnE 'remote_ip|x-forwarded-for|x_forwarded_for|x-real-ip|x_real_ip' \
  --include='*.ex' --include='*.exs' "$C/app/lib" \
  | grep -v 'lib/zifiri/transport.ex' | wc -l       # expected: 0

# 2) the boundary module returns a constant
cd "$C/app" && mix test test/transport_test.exs     # expected: 2 tests, 0 failures

# 3) even if the header is sent, it does not come back in the response
curl -sS -H 'X-Forwarded-For: 203.0.113.9' -H 'X-Real-IP: 203.0.113.9' \
  "$Z/health" | grep -c '203.0.113.9'                # expected: 0
```

`lib/zifiri/transport.ex` is the single exception and the exception is recorded as an
exemption in CI; the file returns `:unknown` for `peer/1`. Row 1 measures that the
exemption has not turned into a hole.

Today (2026-11-22): row 1 is `0` (measured with `grep` on Windows; the only match is the
`transport.ex` moduledoc). Row 2 is **green: 2 tests, 0 failures**. Row 3 was **not run →
none**.

### 12.3 after "yok ol" the marker text is absent from the `.db` and the `-wal`

```bash
export N=5
MARK="vanish-$CANARY"
bin/drill canary --body "$MARK" >/dev/null
bin/drill delete --canary "$CANARY" >/dev/null
sleep "$N"

grep -acF "$MARK" "$DB"        # expected: 0
grep -acF "$MARK" "$DB-wal"    # expected: 0

sqlite3 "$DB" 'PRAGMA auto_vacuum;'    # expected: 2 (INCREMENTAL)
sqlite3 "$DB" 'PRAGMA secure_delete;'  # expected: 1

# VACUUM is not on the delete path: it appears only in the nightly maintenance module
grep -rn 'VACUUM' --include='*.ex' "$C/app/lib" \
  | grep -v 'maintenance' | wc -l      # expected: 0
```

`grep -a` is mandatory: the file is binary, and without `-a` `grep` says "Binary file
matches" and gives no count. If `$DB-wal` does not exist after the delete, `grep` exits
`2` — that is green too (no file = no content); write the command as
`[ ! -e "$DB-wal" ] || grep -acF "$MARK" "$DB-wal"`.

Today (2026-11-22 20:30): `mix test test/vanish_test.exs` is **33 tests, 0 failures** — the
first two rows are green. The last two are **red**: the delete path is still
`DELETE → checkpoint → VACUUM → checkpoint` (`lib/zifiri/vanish.ex:450`) and `auto_vacuum`
was never configured (`grep -rn auto_vacuum lib config priv` → 0). This section is the
decision text, not today's code; the decision does not count as applied until rows 12–13
turn green (see `docs/claims.md` §5, rows C-39–C-40).
