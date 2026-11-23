# Onion service

Plan §11.3: clearnet + onion together. This file describes how the onion side is
set up, what it solves and **what it does not solve**. Claim/module mapping:
`docs/spec.md` §Claim texts. Configuration audit: `scripts/verify_onion.sh`.

## Why it exists

Onion is the only complete way for the server never to see the client IP. The
Tor circuit ends at the last hop; the connection that reaches nginx comes from
127.0.0.1. To a network observer (A2) the connection is an encrypted stream
between the exit node and the server: which user opened which page cannot be
matched. Under passive surveillance (A3) this is the only extra defense we have
(§14 #8).

## Why an IP limit is meaningless (§4.4)

- On clearnet nginx sees the client but **there is nowhere to enforce a limit**:
  `X-Forwarded-For` is the underlying claim, and the client can forge it; the
  real address is the TCP source, and behind NAT/CGNAT that lumps hundreds of
  people into one address.
- On onion the client is already a single address: 127.0.0.1.
- With both together: the same user can arrive over clearnet and over onion;
  a "N requests per address" counter throws every onion user into one bucket,
  and when the bucket fills it closes the service for everyone.

That is why `nginx.conf` **has no** `limit_req` / `limit_conn`, and must not:
load protection goes through PoW (§4.4) and Tor's own intro-DoS defense.
Verification: `docker compose exec nginx nginx -T | grep -cE '^\s*limit_(req|conn)'` → `0`
(the anchor is required because the comment lines mention `limit_req` too).

## Setup

1. Directories (host, inside the repo):

   ```bash
   mkdir -p infra/tor/data/hidden_service
   chmod 700 infra/tor/data infra/tor/data/hidden_service
   ```

2. Ownership. Tor must write to the data directory **as its own user**, and Tor
   rejects a `HiddenServiceDir` it does not own. Do not guess the UID of the
   user in the image, ask it:

   ```bash
   docker run --rm --entrypoint sh dockurr/tor -c 'id'
   # e.g.: uid=100 gid=101(tor)
   sudo chown -R 100:101 infra/tor/data
   ```

3. The `tor` service in `docker-compose.yml` shares nginx's network namespace
   (`network_mode: "service:nginx"`). This is the container form of "loopback on
   the same machine": `HiddenServicePort 80 127.0.0.1:8081` really goes to
   loopback, not to a container IP over the docker bridge. Using the bridge IP
   would work too, but then the "single address" claim would depend on the
   docker network; loopback states the intent plainly.

4. Start:

   ```bash
   docker compose up -d tor
   cat infra/tor/data/hidden_service/hostname      # → xxxxxxxxxxxxxxxx.onion
   ```

   This address is derived from the onion v3 key. If `infra/tor/data` is
   deleted the address **changes** and the old address never works again. There
   is no backup policy (§11.5), but this directory is not user data; losing it
   is not losing content, it is losing the address.

## HiddenServicePort forwarding

The whole chain on one line:

```text
client → tor circuit (3 nodes) → the tor daemon on this machine
       → HiddenServicePort 80 127.0.0.1:8081   (infra/tor/config/torrc)
       → nginx  server { listen 127.0.0.1:8081; server_name $ONION_HOST; }
       → unix socket → BEAM
```

| Step | File | Line | If it is wrong |
|---|---|---|---|
| tor → nginx target | `infra/tor/config/torrc` | `HiddenServicePort 80 127.0.0.1:8081` | onion comes up, returns 502 |
| nginx listener | `infra/nginx.conf` | `listen 127.0.0.1:8081;` | tor cannot connect, the service is dead |
| nginx Host match | `infra/nginx.conf` | `server_name $ONION_HOST;` | the request falls to the default block (clearnet), clearnet content is served at the onion address |
| `$ONION_HOST` render | `infra/deploy.md` (two-pass render) | the address in the `hostname` file | `server_name` stays empty, `nginx -t` fails |

The first number of `HiddenServicePort` is the **virtual** port (the 80 Tor
listens on), the second is the real target. 8081 is not exposed: it is not
published in `docker-compose.yml` and `listen` is loopback-only — so the only way
to reach 8081 is through Tor. This is the configuration form of the "no IP"
claim (`docs/spec.md` §Claim texts).

Verification:

```bash
# is tor really connecting to loopback? (an outside connection should not appear)
ss -tnp | grep 8081                      # 127.0.0.1 only

# are the lines the claim rests on loaded?
scripts/verify_onion.sh --docker         # 0 = pass, 1 = missing, 3 = no nginx
```

## Two onion addresses: real + decoy

A single onion address **is a persistent identifier**. The address is derived
from the onion v3 key and does not change as long as the key is not deleted; so
every session that arrives at the same address is tied to one name, even if it
is not the same visitor. Onion removes the IP, but this time the address itself
becomes the correlation surface: an observer can say "the flows into this
address around these hours might be the same person"; if the address was shared
publicly, that share is a trace too.

Suggestion: **two separate HiddenServiceDirs** — one the real service, one a
decoy. Both go to the same nginx listener and both serve the same content; from
outside they cannot be told apart (same body, same headers, same timing — the
address-level form of the bucket logic, §6.2).

```conf
# infra/tor/config/torrc — the second (decoy) address
HiddenServiceDir /var/lib/tor/hidden_service_decoy
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:8081
HiddenServiceEnableIntroDoSDefense 1
HiddenServicePoWDefensesEnabled 1
```

Why:

1. **It splits correlation.** The traffic of the two addresses is collected
   separately; reading a single address as "a single user" becomes harder.
2. **It splits link rot.** If one of the addresses is exposed (shared in a chat
   group, in a screenshot) the other stays clean — the real address cannot be
   changed without deleting its key, the decoy can.
3. **It costs nothing.** The second service runs in the same Tor process, in
   the same nginx block; no extra process, port or log.

Its limit: the decoy **makes correlation harder, not impossible**, and does not
mean "no identity". `server_name` matches only the real address; the decoy
address has a different Host, so it must be added to `server_name` or a second
listener opened — if it is not, decoy requests fall to the default block. Adding
the address is one line in `nginx.conf` — but it must also go into the render
step, otherwise `$ONION_HOST_DECOY` stays a literal variable and `nginx -t`
fails:

```nginx
server_name $ONION_HOST $ONION_HOST_DECOY;
```

```bash
# an extra line in the render command from deploy.md — ORDER MATTERS:
# `$ONION_HOST_DECOY` begins with `$ONION_HOST`. If the longer variable is not
# replaced first, the `$ONION_HOST` rule turns it into `address.onion_DECOY`.
sed -e "s|\$ONION_HOST_DECOY|$DECOY|g" -e "s|\$ONION_HOST|$ONION|g" nginx.conf > nginx.conf.rendered
```

## Onion-Location

Clearnet responses carry the `Onion-Location: http://$ONION_HOST<path>` header
(`nginx.conf`, the 443 server). When Tor Browser sees this header it shows an
"open in onion site" button in the address bar; the user switches from clearnet
to onion in one click. This does not force the user — it is an announcement, not
a redirect.

`$ONION_HOST` is written into `nginx.conf` during deploy (deploy.md, two-pass
render). Onion responses do not have this header, and no HSTS either: onion is
served over http and the browser treats `.onion` as a secure origin.

The onion block's `server_name` is `$ONION_HOST`, not `_`: Tor preserves the
original Host header, so an onion request arrives under its own name. This
states the block's intent in the configuration; it is also how
`verify_onion.sh` runs the "Onion-Location only on clearnet" check.

Which claim holds in which mode (and which one is **invalid**): `docs/spec.md`
§Claim texts. Summary: on clearnet say "the IP does not reach the application",
not "no IP"; "no IP" can only be said in onion mode.

## What it does not hide

The honesty list. These are not bugs, they are limits:

1. **It does not hide where the server is.** An onion service does not hide the
   server's IP; Tor circuits connect to the server. Location hiding is a
   separate job and out of scope (§1).
2. **It does not hide that the same content is on clearnet.** As long as
   clearnet stays open an observer can compare the two surfaces; onion does not
   take back clearnet's weakness (§14 #1).
3. **It does not hide the live stream on the server (A3).** If the server is
   compromised the onion user's request is visible in nginx as 127.0.0.1 — no
   identity, but a request and a time. Onion's gain is not "who", it is the loss
   of "from where".
4. **It does not hide the timing leak.** Chat is real time, and Tor latency
   makes message-connection matching harder, not impossible (§7.4, §14 #4).
5. **It does not hide the text itself.** Style is identity (§14 #12). Onion
   closes the network layer, not the text.
6. **It does not hide denial of service.** The onion address gets scanned and
   hammered too; intro-DoS defense and PoW slow that down, they do not stop it.

## Maintenance

- The `tor` image is `dockurr/tor:latest` — pin it to a digest in production
  (the §10.3 reasoning applies to images too).
- The Tor version must support onion PoW defense
  (`HiddenServicePoWDefensesEnabled`, tor ≥ 0.4.8). If it does not, Tor ignores
  the line; startup does not fail.
- While debugging, `logging.driver: none` means nothing is visible. Temporarily
  switch that service to `json-file`, and switch it back when you are done —
  leaving it is a §5.1 violation.
