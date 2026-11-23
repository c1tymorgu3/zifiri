# Deployment

Plan §11.3 (single VPS + nginx, no CDN), §11.4 (disk/memory), §5 (no logs).
Order matters: running `docker compose up` before steps 1–4 are done invalidates
the "encrypted disk" and "pepper lives only in RAM" claims.

Assumption: Debian/Ubuntu VPS, root/sudo, Docker + compose v2 installed, the
$HOST domain name pointed at this machine.

---

## 1. Disk encryption (LUKS) — §11.4

If "guided - use entire disk and set up encrypted LVM" was selected during
install, this step is already done; verify and move on.

```bash
lsblk -f                       # is ext4 sitting under crypt?
sudo cryptsetup status "$(lsblk -no NAME /dev/disk/by-uuid/$(findmnt -no UUID /) | head -1)" 2>/dev/null
sudo dmsetup ls --target crypt
```

Encrypting after the fact (back up first if there is data — since §11.5 removed
backups, this is a one-time job):

```bash
sudo cryptsetup luksFormat /dev/sdX          # asks for confirmation, then a passphrase
sudo cryptsetup luksOpen  /dev/sdX zifiri
sudo mkfs.ext4 /dev/mapper/zifiri
```

`/etc/crypttab`:

```
zifiri  UUID=<luks-uuid>  none  luks,discard
```

The key **does not live on disk** — that is what the third field, `none`, is
for; the operator supplies the passphrase at boot. Remote unlock
(dropbear-initramfs etc.) is the operator's decision (§11.4); if that route is
chosen, a key baked into initramfs preserves the "a powered-off disk cannot be
read" benefit of disk encryption as-is, but weakens the "the key is not on disk"
claim — choose it deliberately.

## 2. Turn off swap and hibernate — §5.1

```bash
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
sudo systemctl mask swap.target dev-zram0.swap 2>/dev/null
sudo systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

With swap off hibernate does not work anyway; masking keeps someone from running
`systemctl hibernate` later. Hibernate writes RAM to disk: on its own it
disproves the "messages are not written to disk" (§7.1) claim.

Verification:

```bash
swapon --show            # output should be empty
findmnt -t swap          # output should be empty
```

## 3. Core dumps and sysctl — §5.1

`/etc/sysctl.d/90-zifiri.conf`:

```
# Core dumps off. LEAVING IT EMPTY DOES NOT WORK: an empty core_pattern
# writes a file named "core" into the working directory. The only closed form
# is a pipe to nothing.
kernel.core_pattern = |/bin/false
kernel.core_uses_pid = 0
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
# The kernel logs "martian" packets with their source address — an IP leak.
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
```

```bash
sudo sysctl --system
sudo systemctl disable --now systemd-coredump.socket
sudo systemctl mask systemd-coredump@.service
```

All three layers are needed; none is sufficient alone:

| layer | where | what it does |
|---|---|---|
| `ulimit core 0` | docker-compose.yml (`ulimits.core`) | if BEAM crashes, no file is written |
| `ERL_CRASH_DUMP=/dev/null` + `SECONDS=0` | Dockerfile | Erlang does not write its own dump |
| `kernel.core_pattern=\|/bin/false` | host sysctl | the kernel writes no dump for any process |

## 4. Put the pepper on tmpfs — §4.3, §11.4

The pepper is **never** written to disk; it is not in the repo either.

```bash
# A tmpfs directory on the host. /run is cleared at boot: the pepper is
# re-provisioned on every boot, and that is deliberate.
sudo install -d -m 0700 -o root -g root /run/zifiri-pepper
sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /run/zifiri-pepper/pepper'
sudo chmod 0400 /run/zifiri-pepper/pepper
```

Give compose the path (do not write it to the repo, keep it in the shell):

```bash
export ZIFIRI_PEPPER_FILE=/run/zifiri-pepper/pepper
```

Rules:

- Do not embed the pepper in `docker-compose.yml`, do not `COPY` it into the
  image, do not hand it to the container as an environment variable: env is
  readable via `docker inspect` and `/proc/<pid>/environ`. Pass it as a file,
  mounted read-only.
- If the file is missing compose **does not start** (`${ZIFIRI_PEPPER_FILE:?...}`).
  Coming up silently with an empty directory and landing in a "no pepper" state
  is the same thing as an install without a pepper, and goes unnoticed — hence
  fail-fast.
- If the pepper changes, every derived `owner_hash` becomes invalid: ownership
  of existing posts is lost and "Vanish" stops working. Generate the pepper once
  at install time and do not lose it; its loss is irreversible.

## 5. Directories and certificate

```bash
cd /opt/zifiri/infra
mkdir -p certs acme tor/data/hidden_service
chmod 700 tor/data tor/data/hidden_service
```

TLS. Order matters: the nginx 443 block **will not start at all** without the
certificate files, so "start nginx first, get the certificate later" does not
work. The first certificate is therefore obtained with `--standalone` while
nginx is down; renewals go through the webroot while nginx is up (the ACME
location on port 80 is ready in nginx.conf).

```bash
# 1) First certificate — while port 80 is free, nginx not yet up
sudo certbot certonly --standalone -d "$HOST"

# 2) Verify that renewal has switched to the webroot (run AFTER nginx is up).
#    Once the --webroot flag is given, it is written to the renewal conf.
sudo certbot renew --cert-name "$HOST" --dry-run -a webroot \
     --webroot-path /opt/zifiri/infra/acme

# 3) Copy + reload nginx (renewal hook).
#    $HOST is NOT baked into the hook: certbot gives the hook RENEWED_LINEAGE,
#    and the hook uses it. Hardcoding a domain name leads to silently copying
#    the wrong directory when the certificate is renewed.
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/zifiri.sh >/dev/null <<'SH'
#!/bin/sh
set -eu
LINEAGE=${RENEWED_LINEAGE:?RENEWED_LINEAGE missing - certbot must run the hook}
install -m 0644 "$LINEAGE/fullchain.pem" /opt/zifiri/infra/certs/fullchain.pem
install -m 0640 -g 10001 "$LINEAGE/privkey.pem" /opt/zifiri/infra/certs/privkey.pem
docker compose -f /opt/zifiri/infra/docker-compose.yml exec -T nginx nginx -s reload
SH
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/zifiri.sh

# 4) Run the hook once by hand so the first copy exists
sudo RENEWED_LINEAGE="/etc/letsencrypt/live/$HOST" \
     /etc/letsencrypt/renewal-hooks/deploy/zifiri.sh
ls -l /opt/zifiri/infra/certs/
```

`privkey.pem` is group `10001`, mode `0640`: nginx runs as a non-root user and
must be able to read this file. If the `certbot renew` hook's `docker compose
exec` fails (nginx down), `set -e` makes it fail — the renewal still completes,
only the copy happens on the next round.

## 6. nginx.conf render — two passes

`infra/nginx.conf` is a template; `$HOST` and `$ONION_HOST` are filled in.
nginx does not expand these variables itself. Define them in the shell first:

```bash
export HOST='<domain-name>'      # $HOST placeholder
```

All commands run from the `/opt/zifiri/infra` directory (the compose file is
there).

```bash
cd /opt/zifiri/infra
export ZIFIRI_PEPPER_FILE=/run/zifiri-pepper/pepper

# pass 1: the onion address does not exist yet
sed -e "s|\$HOST|$HOST|g" \
    -e "s|\$ONION_HOST|first-boot.onion|g" \
    nginx.conf > nginx.conf.rendered

docker compose up -d

# pass 2: the onion address is known
ONION=$(cat tor/data/hidden_service/hostname)
sed -e "s|\$HOST|$HOST|g" \
    -e "s|\$ONION_HOST|$ONION|g" \
    nginx.conf > nginx.conf.rendered
docker compose restart nginx
```

`nginx.conf.rendered` is not committed (`.gitignore`).

## 7. Verification — one command per claim

The commands in this section were **not run** on this machine (no Docker). All
of them are to be run on the server, from the `/opt/zifiri/infra` directory.

```bash
cd /opt/zifiri/infra
```

**Does the configuration parse**

```bash
docker compose config --quiet && echo OK
docker compose exec nginx nginx -t
```

**§5.1 — is the access log off**

```bash
docker compose exec nginx nginx -T | grep -nE '^\s*access_log'
# Expected: only `access_log off;` lines. There is NO `logs/access.log`.
docker compose exec nginx nginx -T | grep -nE '^\s*error_log'
# Expected: `error_log /dev/null crit;`
```

**§4.4 — is there no IP limit**

```bash
docker compose exec nginx nginx -T | grep -cE '^\s*(limit_req|limit_req_zone|limit_conn|limit_conn_zone)'
# Expected: 0
```

**§5.1 — does XFF not reach BEAM**

```bash
# raw socket test on the app side: look at the headers nginx adds
docker compose exec nginx nginx -T | grep -cE '^\s*(real_ip_header|set_real_ip_from|proxy_protocol)'
# Expected: 0
# End to end: send a request, temporarily log the headers the app sees
curl -sS -H 'X-Forwarded-For: 203.0.113.9' -H 'User-Agent: canary-ua' https://$HOST/ -o /dev/null
# with temporary diagnostic logging on in the app: 203.0.113.9 and canary-ua MUST NOT APPEAR
```

**Is anything being logged anywhere**

```bash
for c in app nginx tor; do
  docker inspect -f "{{.Name}} {{.HostConfig.LogConfig.Type}}" $(docker compose ps -q $c)
done
# Expected: `none` on all three

sudo find /var/lib/docker/containers -name '*-json.log' -size +0c
# Expected: empty

sudo journalctl -u docker --since '1 hour ago' | grep -c "$HOST"
# Expected: 0 (excluding the docker daemon's own events)
```

**What is on disk (§6.1 allowlist)**

```bash
sudo ls -la /var/lib/docker/volumes/zifiri_zifiri-data/_data
# Expected: only zifiri.db, zifiri.db-wal, zifiri.db-shm, err.log
```

**§11.4 — disk, swap, dump**

```bash
findmnt -no SOURCE,FSTYPE /            # crypt / ext4
sudo cryptsetup status zifiri | head -5
swapon --show                          # empty
cat /proc/sys/kernel/core_pattern       # |/bin/false
mount | grep ' /run '                   # tmpfs
ls -l /run/zifiri-pepper/pepper         # -r-------- root root
docker inspect -f '{{.HostConfig.Ulimits}}' $(docker compose ps -q app)
# core = 0
sudo find / -xdev -name 'erl_crash.dump*' 2>/dev/null   # empty
```

**§10.1 — CSP and headers**

```bash
curl -sSI https://$HOST/ \
  | grep -iE 'content-security-policy|strict-transport|referrer-policy|onion-location|cache-control'
# Expected: Cache-Control: no-store

ASSET=$(curl -sS https://$HOST/ | grep -oE '/assets/[A-Za-z0-9._-]+\.(js|css)' | head -1)
curl -sSI "https://$HOST$ASSET" | grep -i cache-control
# Expected: public, max-age=31536000, immutable
```

**Network surface**

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'   # nginx only
sudo ss -ltnp | grep -E ':(9050|8081)\b' # empty: on loopback, not on the host
sudo ss -lx | grep app.sock              # socket present
```

## 8. Reboot

Order: LUKS opens → the pepper is **put back** on tmpfs → `docker compose up -d`.

Because `/run` is tmpfs the pepper is lost on every boot and the **same one**
must be restored. Regenerating it = every `owner_hash` becoming invalid = the
loss of ownership for every post.

```bash
sudo cryptsetup luksOpen /dev/sdX zifiri

sudo install -d -m 0700 -o root -g root /run/zifiri-pepper
# restore the pepper from a secure source (password manager, paper, HSM)
sudo sh -c 'umask 077; cat > /run/zifiri-pepper/pepper'
sudo chmod 0400 /run/zifiri-pepper/pepper

cd /opt/zifiri/infra
export ZIFIRI_PEPPER_FILE=/run/zifiri-pepper/pepper
docker compose up -d
```

If you lost the pepper from the initial install there is no way back: the system
works with a new pepper, but none of the old posts can be claimed.

## 9. Update

```bash
cd /opt/zifiri && git pull
docker compose -f infra/docker-compose.yml build --pull
docker compose -f infra/docker-compose.yml up -d
```

Do **not** use `docker compose down -v`: `-v` deletes the data volume, i.e. all
content is gone and there is no backup (§11.5).

If volume ownership breaks (e.g. `zifiri-run` was created owned by root and the
app cannot create the socket):

```bash
cd /opt/zifiri/infra
docker compose down
docker volume rm zifiri_zifiri-run    # socket only; not data
docker compose up -d
```

Never delete `zifiri-data` this way.

## 10. Known limits

- Certificate transparency (CT) publishes the domain name: $HOST is not secret
  and was never meant to be (§14 #5).
- The `sshd` and `docker` services keep their own records, which hold the
  operator's IP — not the user's IP. If an operator module is added it must be
  declared in `MANIFEST.md` (§12).
- `docker compose config` and `nginx -t` were **not run** on this machine
  (Docker is not installed). The YAML was validated with
  `python3 -c 'import yaml; yaml.safe_load(...)'`; the nginx configuration was
  not parsed by any nginx binary. Before the first `up`,
  `docker compose config --quiet` and `docker compose exec nginx nginx -t` are
  mandatory steps.
