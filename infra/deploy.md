# Dağıtım

Plan §11.3 (tek VPS + nginx, CDN yok), §11.4 (disk/bellek), §5 (log yok).
Sıra önemlidir: 1–4 yapılmadan `docker compose up` çalıştırmak, "şifreli disk"
ve "pepper yalnız RAM'de" iddialarını geçersiz kılar.

Varsayım: Debian/Ubuntu VPS, root/sudo, Docker + compose v2 kurulu, $HOST
alan adı bu makineye yönlendirilmiş.

---

## 1. Disk şifreleme (LUKS) — §11.4

Kurulum sırasında "guided - use entire disk and set up encrypted LVM" seçilirse
bu adım zaten yapılmıştır; doğrula ve geç.

```bash
lsblk -f                       # crypt altında ext4 mü?
sudo cryptsetup status "$(lsblk -no NAME /dev/disk/by-uuid/$(findmnt -no UUID /) | head -1)" 2>/dev/null
sudo dmsetup ls --target crypt
```

Sonradan şifreleme (veri varsa önce yedek — §11.5 yedeği kaldırdığı için bu
tek seferlik bir iştir):

```bash
sudo cryptsetup luksFormat /dev/sdX          # onay ister, parola sorar
sudo cryptsetup luksOpen  /dev/sdX zifiri
sudo mkfs.ext4 /dev/mapper/zifiri
```

`/etc/crypttab`:

```
zifiri  UUID=<luks-uuid>  none  luks,discard
```

Anahtar **diskte durmaz** — `none` yazan üçüncü alan bunun içindir; açılışta
operatör parolayı verir. Uzaktan açma (dropbear-initramfs vb.) operatör
kararıdır (§11.4); yöntem seçilirse initramfs'e gömülen anahtar, disk
şifrelemesinin "kapalı disk okunamaz" kazancını olduğu gibi korur ama
"anahtar diskte yok" iddiasını zayıflatır — bilerek seç.

## 2. Swap ve hibernate kapat — §5.1

```bash
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
sudo systemctl mask swap.target dev-zram0.swap 2>/dev/null
sudo systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

Swap kapalıysa hibernate zaten çalışmaz; maskeleme, birinin sonradan
`systemctl hibernate` demesini engeller. Hibernate, RAM'i diske yazar: "mesajlar
diske yazılmaz" (§7.1) iddiasını tek başına çürütür.

Doğrulama:

```bash
swapon --show            # çıktı boş olmalı
findmnt -t swap          # çıktı boş olmalı
```

## 3. Çekirdek dökümü ve sysctl — §5.1

`/etc/sysctl.d/90-zifiri.conf`:

```
# Çekirdek dökümü kapalı. BOŞ BIRAKMAK İŞE YARAMAZ: boş core_pattern
# "core" adında dosyayı çalışma dizinine yazar. Kapatmanın yolu çöpe boru.
kernel.core_pattern = |/bin/false
kernel.core_uses_pid = 0
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
# Çekirdek "martian" paketleri kaynak adresiyle loglar — IP sızıntısı.
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
```

```bash
sudo sysctl --system
sudo systemctl disable --now systemd-coredump.socket
sudo systemctl mask systemd-coredump@.service
```

Üç katman birlikte gerekir, hiçbiri tek başına yetmez:

| katman | nerede | ne yapar |
|---|---|---|
| `ulimit core 0` | docker-compose.yml (`ulimits.core`) | BEAM çökerse dosya yazılmaz |
| `ERL_CRASH_DUMP=/dev/null` + `SECONDS=0` | Dockerfile | Erlang kendi dökümünü yazmaz |
| `kernel.core_pattern=\|/bin/false` | host sysctl | Çekirdek dökümü hiçbir süreç için yazılmaz |

## 4. Pepper'ı tmpfs'e koy — §4.3, §11.4

Pepper diske **hiç** yazılmaz; repo'da da yoktur.

```bash
# Host'ta tmpfs bir dizin. /run açılışta temizlenir: pepper her açılışta
# yeniden sağlanır, bu bilinçli.
sudo install -d -m 0700 -o root -g root /run/zifiri-pepper
sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /run/zifiri-pepper/pepper'
sudo chmod 0400 /run/zifiri-pepper/pepper
```

Compose'a yolu ver (repoya yazma, kabukta tut):

```bash
export ZIFIRI_PEPPER_FILE=/run/zifiri-pepper/pepper
```

Kurallar:

- Pepper'ı `docker-compose.yml`'a gömme, imaja `COPY` etme, ortam değişkeniyle
  konteynere verme: env, `docker inspect` ve `/proc/<pid>/environ` üzerinden
  okunur. Dosya olarak, read-only bağlanır.
- Dosya yoksa compose **açılmaz** (`${ZIFIRI_PEPPER_FILE:?...}`). Sessizce boş
  bir dizinle açılıp "pepper yok" durumuna düşmek, pepper'ı olmayan bir
  kurulumla aynı şeydir ve fark edilmez — bu yüzden fail-fast.
- Pepper değişirse türetilen tüm `owner_hash` değerleri geçersiz olur: mevcut
  gönderilerin sahipliği kaybolur, "Yok ol" çalışmaz. Pepper'ı yalnız kurulumda
  bir kez üret ve kaybetme; kaybı geri dönüşsüzdür.

## 5. Dizinler ve sertifika

```bash
cd /opt/zifiri/infra
mkdir -p certs acme tor/data/hidden_service
chmod 700 tor/data tor/data/hidden_service
```

TLS. Sıralama önemli: nginx 443 bloğu sertifika dosyaları yoksa **hiç
başlamaz**, yani "önce nginx'i aç, sonra sertifika al" çalışmaz. İlk sertifika
bu yüzden `--standalone` ile, nginx kapalıyken alınır; yenilemeler nginx açıkken
webroot üzerinden yapılır (80 portundaki ACME konumu nginx.conf'ta hazır).

```bash
# 1) İlk sertifika — port 80 boşken, nginx henüz ayakta değil
sudo certbot certonly --standalone -d "$HOST"

# 2) Yenilemenin webroot'a geçtiğini doğrula (nginx açıldıktan SONRA çalıştır).
#    --webroot bayrağı bir kez verilince renewal conf'a yazılır.
sudo certbot renew --cert-name "$HOST" --dry-run -a webroot \
     --webroot-path /opt/zifiri/infra/acme

# 3) Kopyala + nginx'i yeniden yükle (yenileme kancası).
#    $HOST kancaya GÖMÜLMEZ: certbot kancaya RENEWED_LINEAGE verir, kanca onu
#    kullanır. Sabit alan adı yazmak, sertifikayı yenilerken sessizce yanlış
#    dizini kopyalamaya yol açar.
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/zifiri.sh >/dev/null <<'SH'
#!/bin/sh
set -eu
LINEAGE=${RENEWED_LINEAGE:?RENEWED_LINEAGE yok - kancayi certbot calistirmali}
install -m 0644 "$LINEAGE/fullchain.pem" /opt/zifiri/infra/certs/fullchain.pem
install -m 0640 -g 10001 "$LINEAGE/privkey.pem" /opt/zifiri/infra/certs/privkey.pem
docker compose -f /opt/zifiri/infra/docker-compose.yml exec -T nginx nginx -s reload
SH
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/zifiri.sh

# 4) Kancayı bir kez elle çalıştır ki ilk kopya oluşsun
sudo RENEWED_LINEAGE="/etc/letsencrypt/live/$HOST" \
     /etc/letsencrypt/renewal-hooks/deploy/zifiri.sh
ls -l /opt/zifiri/infra/certs/
```

`privkey.pem` grup `10001` ve mod `0640`: nginx root olmayan kullanıcıyla
çalışır ve bu dosyayı okuyabilmelidir. `certbot renew` kancası, `docker compose
exec` başarısız olursa (nginx kapalıysa) `set -e` yüzünden düşer — yenileme
yine tamamlanmış olur, yalnız kopyalama bir sonraki turda yapılır.

## 6. nginx.conf render — iki geçiş

`infra/nginx.conf` şablondur; `$HOST` ve `$ONION_HOST` doldurulur. nginx bu
değişkenleri kendisi genişletmez. Önce kabukta tanımla:

```bash
export HOST='<alan-adı>'      # $HOST yer tutucusu
```

Tüm komutlar `/opt/zifiri/infra` dizininden çalışır (compose dosyası orada).

```bash
cd /opt/zifiri/infra
export ZIFIRI_PEPPER_FILE=/run/zifiri-pepper/pepper

# 1. geçiş: onion adresi henüz yok
sed -e "s|\$HOST|$HOST|g" \
    -e "s|\$ONION_HOST|ilk-acilis.onion|g" \
    nginx.conf > nginx.conf.rendered

docker compose up -d

# 2. geçiş: onion adresi belli oldu
ONION=$(cat tor/data/hidden_service/hostname)
sed -e "s|\$HOST|$HOST|g" \
    -e "s|\$ONION_HOST|$ONION|g" \
    nginx.conf > nginx.conf.rendered
docker compose restart nginx
```

`nginx.conf.rendered` git'e girmez (`.gitignore`).

## 7. Doğrulama — iddia başına komut

Bu bölümdeki komutlar bu makinede **çalıştırılmadı** (Docker yok). Hepsi
sunucuda, `/opt/zifiri/infra` dizininden çalıştırılacak.

```bash
cd /opt/zifiri/infra
```

**Yapılandırma ayrıştırılıyor mu**

```bash
docker compose config --quiet && echo OK
docker compose exec nginx nginx -t
```

**§5.1 — erişim kaydı kapalı mı**

```bash
docker compose exec nginx nginx -T | grep -nE '^\s*access_log'
# Beklenen: yalnız `access_log off;` satırları. `logs/access.log` YOK.
docker compose exec nginx nginx -T | grep -nE '^\s*error_log'
# Beklenen: `error_log /dev/null crit;`
```

**§4.4 — IP limiti yok mu**

```bash
docker compose exec nginx nginx -T | grep -cE '^\s*(limit_req|limit_req_zone|limit_conn|limit_conn_zone)'
# Beklenen: 0
```

**§5.1 — XFF BEAM'e girmiyor mu**

```bash
# app tarafında ham soket testi: nginx'in eklediği başlıklara bak
docker compose exec nginx nginx -T | grep -cE '^\s*(real_ip_header|set_real_ip_from|proxy_protocol)'
# Beklenen: 0
# Uçtan uca: istek at, app'in gördüğü başlıkları geçici olarak yaz
curl -sS -H 'X-Forwarded-For: 203.0.113.9' -H 'User-Agent: canary-ua' https://$HOST/ -o /dev/null
# app'te geçici teşhis logu açıkken: 203.0.113.9 ve canary-ua GÖRÜNMEMELİ
```

**Log hiçbir yere yazılmıyor mu**

```bash
for c in app nginx tor; do
  docker inspect -f "{{.Name}} {{.HostConfig.LogConfig.Type}}" $(docker compose ps -q $c)
done
# Beklenen: üçünde de `none`

sudo find /var/lib/docker/containers -name '*-json.log' -size +0c
# Beklenen: boş

sudo journalctl -u docker --since '1 hour ago' | grep -c "$HOST"
# Beklenen: 0 (docker daemon'ın kendi olayları hariç)
```

**Diskte ne var (§6.1 allowlist)**

```bash
sudo ls -la /var/lib/docker/volumes/zifiri_zifiri-data/_data
# Beklenen: yalnız zifiri.db, zifiri.db-wal, zifiri.db-shm, err.log
```

**§11.4 — disk, swap, döküm**

```bash
findmnt -no SOURCE,FSTYPE /            # crypt / ext4
sudo cryptsetup status zifiri | head -5
swapon --show                          # boş
cat /proc/sys/kernel/core_pattern       # |/bin/false
mount | grep ' /run '                   # tmpfs
ls -l /run/zifiri-pepper/pepper         # -r-------- root root
docker inspect -f '{{.HostConfig.Ulimits}}' $(docker compose ps -q app)
# core = 0
sudo find / -xdev -name 'erl_crash.dump*' 2>/dev/null   # boş
```

**§10.1 — CSP ve başlıklar**

```bash
curl -sSI https://$HOST/ \
  | grep -iE 'content-security-policy|strict-transport|referrer-policy|onion-location|cache-control'
# Beklenen: Cache-Control: no-store

ASSET=$(curl -sS https://$HOST/ | grep -oE '/assets/[A-Za-z0-9._-]+\.(js|css)' | head -1)
curl -sSI "https://$HOST$ASSET" | grep -i cache-control
# Beklenen: public, max-age=31536000, immutable
```

**Ağ yüzeyi**

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'   # yalnız nginx
sudo ss -ltnp | grep -E ':(9050|8081)\b' # boş: loopback'te, host'ta değil
sudo ss -lx | grep app.sock              # soket var
```

## 8. Yeniden başlatma

Sıra: LUKS açılır → pepper tmpfs'e **geri konur** → `docker compose up -d`.

`/run` tmpfs olduğu için pepper her açılışta kaybolur ve **aynısı** geri
konmalıdır. Yeniden üretmek = tüm `owner_hash`'lerin geçersizleşmesi = her
gönderinin sahipliğinin kaybı.

```bash
sudo cryptsetup luksOpen /dev/sdX zifiri

sudo install -d -m 0700 -o root -g root /run/zifiri-pepper
# pepper'ı güvenli kaynaktan geri yükle (parola yöneticisi, kağıt, HSM)
sudo sh -c 'umask 077; cat > /run/zifiri-pepper/pepper'
sudo chmod 0400 /run/zifiri-pepper/pepper

cd /opt/zifiri/infra
export ZIFIRI_PEPPER_FILE=/run/zifiri-pepper/pepper
docker compose up -d
```

İlk kurulumdaki pepper'ı kaybettiysen geri dönüş yoktur: yeni pepper ile sistem
çalışır, ama eski gönderilerin hiçbiri sahiplenilemez.

## 9. Güncelleme

```bash
cd /opt/zifiri && git pull
docker compose -f infra/docker-compose.yml build --pull
docker compose -f infra/docker-compose.yml up -d
```

`docker compose down -v` **kullanma**: `-v` veri volume'ünü siler, yani tüm
içerik gider ve yedek yoktur (§11.5).

Volume sahipliği bozulursa (ör. `zifiri-run` root sahipli doğduysa, app soketi
oluşturamaz):

```bash
cd /opt/zifiri/infra
docker compose down
docker volume rm zifiri_zifiri-run    # yalnız soket; veri değil
docker compose up -d
```

`zifiri-data`'yı asla bu şekilde silme.

## 10. Bilinen sınırlar

- Sertifika şeffaflığı (CT) alan adını yayınlar: $HOST gizli değildir ve
  olması hedeflenmedi (§14 #5).
- `sshd` ve `docker` servisinin kendi kayıtları operatörün IP'sini tutar —
  kullanıcı IP'si değil. Operatör modülü eklenirse `MANIFEST.md`'de yazılmalı
  (§12).
- Bu makinede `docker compose config` ve `nginx -t` **çalıştırılmadı** (Docker
  kurulu değil). YAML `python3 -c 'import yaml; yaml.safe_load(...)'` ile
  doğrulandı; nginx yapılandırması hiçbir nginx ikilisi tarafından
  ayrıştırılmadı. İlk `up` öncesi `docker compose config --quiet` ve
  `docker compose exec nginx nginx -t` zorunlu adımdır.
