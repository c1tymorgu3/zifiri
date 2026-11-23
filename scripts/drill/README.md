# El koyma tatbikatı — betikler

Plan §1'deki ölçütün çalıştırılabilir hali. Üç ayak, üç betik:

| ayak | soru | betik |
|---|---|---|
| 1 — disk imajı | "bu gönderiyi kim yazdı, ne zaman, hangi IP'den" sorusu cevaplanamıyor mu? | `canary_scan.sh`, `write_allowlist.sh` |
| 2 — bellek | trafik kesildikten sonra alınan dökümde de cevaplanamıyor mu? | `memdump_scan.sh` |
| 3 — ağ + yayınlanmış veri | eşleştirme şans düzeyinde mi (≈ 1/n)? | bu betiklerin kapsamı dışında; §4.2'deki `n` ölçüsüyle ayrı ölçülür |
| — | tarayıcı gerçekten buluyor mu? | `negative/plant.sh` — **zorunlu**, bkz. `negative/README.md` |
| — | hepsini sırayla koştur ve özetle | `run-all.sh` |

Betikler Linux içindir ve VPS üzerinde çalışır. Geliştirme makinesinde
(Windows/macOS) tam tatbikat koşmaz (docker, gdb, journald yok); ama
`negative/plant.sh` orada da koşar ve koşmalıdır — tarayıcıya dokunan her
değişiklikten sonra. `bash -n` + `shellcheck` her betik için geçerlidir.

## Ortak

- Bağımlılık: bash 4.4+, coreutils, `grep`, `find`; bellek ayağı ayrıca
  `gdb` (`gcore`). Başka hiçbir şey yok. (`canary_scan.sh` python3 kullanmaz.)
- Her betikte `set -euo pipefail`, `--help` ve `-v/--verbose` vardır.
  `shellcheck` temizdir.
- Çıkış kodları her betikte aynı anlamda:

  | kod | anlam |
  |---|---|
  | `0` | yeşil — iddia bu koşuda kanıtlandı |
  | `1` | kırmızı — isabet var, faz bitmemiştir (§13) |
  | `2` | **kanıtlanmadı** — tarama eksik kaldı (araç yok, izin yok, boş test) |
  | `3` | **ortam eksik** — docker yok, disk ayağının bir kısmı taranamadı |

  `2` ve `3` yeşil değildir. Sessizce geçen bir tatbikat, kırmızıdan daha
  kötüdür. `3` özellikle sessiz geçmemesi için ayrı koddur: docker'ı olmayan
  bir makinede "temiz" demek, hiç bakmamaktır.
- İzinli küme kodda değil veride: `write_allowlist.sh` allowlist'i
  `allowlist.txt`'den okur. Yeni bir meşru yazma yolu için o dosyaya satır
  eklenir, betiğe dokunulmaz.
- `write_allowlist.sh --json` ve `run-all.sh --json` stdout'a tek JSON nesnesi
  yazar (CI için); insan raporu stderr'e gider.
- Hiçbir betik kendi kanıt dosyasını taranan yerlere yazmaz; geçici dosyalar
  `$DRILL_STATE_DIR` (varsayılan `/var/tmp`) altında açılır ve çıkışta silinir.

---

## 1. `canary_scan.sh` — canary taraması (§5.2 madde 1)

### Ne yapar

Sabit bir test ağı IP'sini (varsayılan `172.31.77.7`) ve rastgele bir canary
dizgesini diskte arar. IP **dört biçimde** aranır, çünkü aynı adres farklı
katmanlarda farklı temsil edilir:

| biçim | nerede oluşur | nasıl aranır |
|---|---|---|
| `172.31.77.7` | nginx/Apache log, `X-Forwarded-For`, düz metin | `grep -E`, rakam sınırı ile |
| `{172,31,77,7}` | Erlang/Elixir `:inet` tuple'ı, `IO.inspect` çıktısı, ETS dump | `grep -F` |
| ham 4 bayt `AC 1F 4D 07` | sockaddr yapıları, ikili log, çekirdek tamponu | `grep -a`, bayt deseni (WAL/SHM dahil) |
| `::ffff:172.31.77.7` | IPv4-mapped IPv6 (dual-stack dinleyici) | `grep -E` |

Ham bayt araması tüm dosyalarda yapılır ama desen dört baytın kendisidir
(`LC_ALL=C grep -a -F`), yani ASCII `172.31.77.7` yazan bir metin dosyası bu
aşamada eşleşmez — yalnız gerçekten `AC 1F 4D 07` baytlarını taşıyan dosya
eşleşir. Böylece WAL/SHM, core ve sıkıştırılmış gövdeler tek geçişte yakalanır
ve gürültü oluşmaz. IP'de `0` ya da `10` baytı varsa (ör. `10.0.0.1`) desen
grep ile ifade edilemez; o durumda aşama sessizce değil, "atlandı" diyerek
devre dışı kalır ve sonuç `2` olur.

Taranan yerler:

- `/var/lib/docker` — container json log (`containers/<id>/<id>-json.log`),
  overlay2 katmanları (`diff/`), `volumes/`, image katmanları. `-xdev`
  kullanıldığı için çalışan container'ların `merged/` bağlama noktaları
  atlanır: orası katmanların görünümüdür, veri `diff/` altında zaten var.
- `/var/lib/zifiri` — `*.db`, `*.db-wal` (SQLite WAL tuzağı, §6.1).
- `/tmp`
- journald — `journalctl --since` (varsayılan "2 hours ago"), tek okuma,
  sonra üç biçim için ayrı ayrı aranır.

### Nasıl çalıştırılır

```bash
# 1) canary üret ve gönderim örneğini al
./canary_scan.sh --emit
#    → CANARY_TOKEN=zifiri-canary-<32 hex>

# 2) test ağından isteği gönder (HOST'u kendin koy)
curl -sS -o /dev/null -w '%{http_code}\n' \
  --interface 172.31.77.7 \
  -H 'User-Agent: zifiri-canary-...' \
  -H 'X-Forwarded-For: 172.31.77.7' \
  -H 'X-Real-IP: 172.31.77.7' \
  --data-binary 'zifiri-canary-...' \
  'https://HOST/api/posts'

# 3) aynı canary ile tara
CANARY_TOKEN=zifiri-canary-... ./canary_scan.sh
```

`--emit` olmadan çalıştırırsan taze bir canary üretilir ve betik bunu
"gövde kanıtı sayılmaz" diye işaretler: o dizge hiçbir yere gönderilmediği
için yokluğu hiçbir şey kanıtlamaz. Yalnız IP taraması o koşuda da geçerlidir.

Seçenekler: `--ip`, `--token`, `--since`, `--root` (tekrarlanabilir),
`--ip-only`, `--token-only`.

### Ne kanıtlar

- Canary IP, tarama anında yukarıdaki köklerin altındaki **okunabilir
  dosyalarda ve journald'da** yok. Yani o isteğin istemci adresi diske
  yazılmamış.
- Gövde canary'si yalnız yayınlanmış DB satırında (`$ZIFIRI_DB_DIR/*.db`,
  `*.db-wal`) bulunuyor. Başka her yerde bulunması kırmızıdır: log, tmp,
  volume dışı dosya, `-shm`, journald.

### Ne kanıtlamaz (dürüst sınır)

- **Silinmiş dosyalar ve boş bloklar.** `grep` yalnız canlı dosya ağacını
  görür. Silinmiş bir log dosyasının blokları, dosya sistemi journal'ı,
  SSD wear-leveling kopyaları taranmaz. Bunlar §6.1 **Seviye 3**'tür ve
  garanti edilmez; azaltma tam disk şifrelemesidir (§11.4).
- **Taranmayan bağlama noktaları.** `--root` ile eklenmeyen her yol, ayrı
  disk, ağ paylaşımı, NFS, container dışındaki bir host kapsam dışıdır.
  `-xdev` bilinçli bir sınır koyar.
- **Bellek.** Bu ayak diske bakar. RAM için `memdump_scan.sh`.
- **A3 (ileriye dönük gözetim).** Sunucu ele geçirilmişse saldırgan tarama
  anında olmayan bir kopyayı çoktan almış olabilir. Bu betik "şu an diskte
  yok" der, "hiç olmadı" demez.
- **Journald'ın kendisi.** `journalctl` erişilemezse (root değil, journal
  yok, systemd yok) betik `2` döner; "journald temiz" demez.

### Yorumlama

- `ip-*` isabeti = kırmızı, tartışmasız.
- `token` isabeti `*.db`/`*.db-wal` içinde = beklenen (yayınlanmış içerik),
  raporun "Beklenen" bölümünde görünür, yeşili bozmaz.
- `token` isabeti `*.db-shm` içinde = kırmızı. `-shm` yalnız WAL indeksidir,
  sayfa içeriği taşımaz; orada gövde varsa bir şey yanlış.

---

## 2. `write_allowlist.sh` — yazma allowlist'i (§5.2 madde 2 ve 3)

### Ne yapar

`docker diff` çıktısını izinli kümeyle karşılaştırır. İzinli:

```
/var/lib/zifiri/zifiri.db
/var/lib/zifiri/zifiri.db-wal
/var/lib/zifiri/zifiri.db-shm
/var/lib/zifiri/err.log
+ üst dizinleri: /var, /var/lib, /var/lib/zifiri
+ /tmp ve /run tmpfs olmalı: diff'te görünürlerse tmpfs yok sayılır,
  kırmızıdır (§5.1)
```

Fazlası kırmızı. `A` (eklendi), `C` (değişti), `D` (silindi) ayrımı korunur:
izinli bir dizinin `D` olması da kırmızıdır.

`--volume-dir` verilirse volume'ün **tam dosya kümesi** de denetlenir:
`zifiri.db`, `-wal`, `-shm`, `err.log` dışında her şey (alt dizin dahil)
kırmızı.

### Önemli teknik nokta: `docker diff` volume'ü görmez

Docker, volume ve tmpfs bağlama noktalarının içeriğini `docker diff`
çıktısına **dahil etmez**. `/var/lib/zifiri` bir named volume ise
`zifiri.db` satırları diff'te hiç görünmez. Bu yüzden:

- diff tarafı, container'ın **yazılabilir katmanında** allowlist dışı bir
  yol oluşmadığını kanıtlar (root fs `read_only: true` iken bu küme
  gerçekten küçük olmalı);
- volume'ün dosya kümesi ayrı bir iddiadır ve `--volume-dir` ile ölçülür.

İkisi ayrı kanıttır; biri diğerinin yerine geçmez.

### Nasıl çalıştırılır

```bash
# yük testinden sonra
./write_allowlist.sh zifiri-app --volume-dir /var/lib/docker/volumes/zifiri-data/_data

# ya da diff'i boru ile
docker diff zifiri-app | ./write_allowlist.sh --stdin
```

### Ne kanıtlar

- Container'ın yazılabilir katmanında, izinli dört dosya ve üst dizinleri
  dışında hiçbir oluşma/değişme/silinme yok.
- (volume denetimi verildiyse) volume'de tam olarak beklenen dosya kümesi
  var; `zifiri.db-journal`, `*.log.1`, geçici dosya, alt dizin yok.

### Ne kanıtlamaz

- **Dosyaların içeriğini.** İzinli dosyanın içine ne yazıldığını söylemez;
  onun için `canary_scan.sh`.
- **Yazılıp silinen dosyaları.** `A` sonra `D` olmuş bir dosya diff'te
  yalnızca `D` olarak görünür. İçerik diske gitmiş olabilir (Seviye 3).
- **Host tarafını.** Docker dışında, host'ta bir sürecin yazdığı hiçbir şey
  bu çıktıda yok. `journalctl`, `/var/log`, uygulama dışı süreçler kapsam
  dışı.
- **tmpfs içeriğini.** `/tmp` ve `/run` diff'te görünmez; oraya yazılan
  canary bu betikle yakalanmaz (`canary_scan.sh` `/tmp`'yi tarar, `/run`'ı
  taramaz — bilinçli: `/run` pepper ve pid dosyaları içindir, dökümler de
  oraya yazılır).
- Boş diff tek başına yeşil değildir: uygulama hiç yazmamışsa test boştur.
  `--volume-dir` yoksa betik `2` döner.

---

## 3. `memdump_scan.sh` — bellek dökümü (§5.2 madde 4)

### Ne yapar

1. Trafik kesildikten sonra `DRILL_QUIET_SECONDS` (varsayılan **60**) bekler.
2. nginx worker'larını yeniler (`nginx -s reload`, gerekirse
   `NGINX_RELOAD_CMD` ya da `systemctl reload nginx`). Eski worker'ların
   çıkmasını 30 saniye bekler; çıkmazlarsa uyarır (dökümleri yanıltıcı olur).
3. `gcore` ile BEAM (`beam.smp`) ve nginx worker'larının belleğini döker.
4. Dökümlerde canary IP'yi dört biçimde arar; gövde canary'sini bilgi
   olarak raporlar.

Sıra önemli: **önce yenile, sonra dök.** Eski worker'ın belleğinde istek
tamponu vardır; onu dökmek tatbikatı değil, tatbikatın başarısızlığını
ölçer.

### Nasıl çalıştırılır

```bash
# trafiği kes, sonra:
./memdump_scan.sh                       # host'ta çalışan nginx + BEAM
CANARY_TOKEN=zifiri-canary-... ./memdump_scan.sh

# her şey container içindeyse:
DRILL_EXEC_PREFIX="docker exec -u root zifiri-app" \
NGINX_RELOAD_CMD="docker exec zifiri-app nginx -s reload" \
CANARY_TOKEN=zifiri-canary-... ./memdump_scan.sh
```

Container modunda `gcore` dökümü container'ın içine yazar. Betik dökümün
host'tan okunabildiğini doğrular; okunamıyorsa yeşil demez, `2` ile durur.
Bu yüzden `$DRILL_OUT` dizinini container'a bind mount edin:

```bash
docker run -v /run/zifiri-drill:/run/zifiri-drill ...
```

Dökümler varsayılan olarak `/run/zifiri-drill/memdump-<zaman>/` altına
yazılır (tmpfs — `/tmp` taranan bir yer olduğu için oraya yazılmaz; ayrıca
disk imajına döküm sızdırmamak için). Yeşil koşuda dökümler silinir,
kırmızıda saklanır; `--keep` her durumda saklar.

`--dry-run` yalnız ne yapılacağını yazar, `--no-reload` eski worker'ları
bilerek tarar (yenileme davranışını test ederken).

### Ne kanıtlar

- Trafik kesildikten 60 saniye sonra, **yenilenmiş** nginx worker'larında
  ve BEAM'de canary IP yok. Yani istek adresi bu süreçlerin canlı
  belleğinde tutulmuyor.
- BEAM tarafında IP'nin hiç görünmemesi §5.1'deki iddianın doğrudan
  kanıtıdır: unix soket + `X-Forwarded-For`/`X-Real-IP`/`Forwarded`
  boşaltma çalışıyor.

### Ne kanıtlamaz — A3 sınırı

Bu betiğin sınırı planın A3 satırıyla aynıdır ve **pazarlık konusu değildir**:

- **Canlı trafik sırasında alınan döküm kapsam dışıdır.** Betik trafik
  kesildikten sonra çalışır; kesilmeden alınan bir dökümde IP olması
  beklenir ve bu bir hata değil, A3'ün tanımıdır.
- **Serbest bırakılmış sayfalar.** `gcore` sürecin o anki eşlemesini alır.
  Allocator'ın işletim sistemine geri verdiği sayfalar, `madvise(MADV_DONTNEED)`
  ile atılan bölgeler ve sürecin hiç dokunmadığı sayfalar dökümde yoktur.
  "Dökümde yok" ≠ "RAM'de hiç olmadı".
- **Fiziksel RAM imajı.** Soğuk önyükleme saldırısı, DMA, hypervisor
  düzeyinde dump bu betiğin dışındadır.
- **Çekirdek tamponları.** Socket tamponları, `sk_buff`, conntrack,
  page cache kullanıcı süreçlerinin dökümünde görünmez. Kernel dump ayrı
  bir iştir ve burada yok.
- **Dökemediğimiz süreçler.** `gcore` başarısız olursa (ptrace izni,
  setuid, farklı kullanıcı) betik `2` döner. Dökülemeyen süreç "temiz"
  sayılmaz.
- **Swap ve core dosyaları.** Swap kapalı olmalı (§5.1); bu betik swap'ı
  denetlemez. `swapon --show` ayrı bir kontrol.
- **Dökümün kendisi bir sızıntıdır.** Kırmızı koşuda saklanan core
  dosyaları canary IP'yi içerir. İnceleme bitince silinmeli; `/run`
  (tmpfs) seçilmesinin nedeni budur.

---

## 4. `negative/plant.sh` — negatif kontrol (zorunlu)

### Ne yapar

Canary'yi bilerek üç yere yazar ve `canary_scan.sh`'in üçünü de bulmasını
şart koşar: düz metin erişim kaydı, docker json-file log'u, `/proc/<pid>/environ`.
Ayrıca komşu bir adres (`172.31.77.70`) ile yanlış pozitif kontrolü yapar.

### Neden zorunlu

Yeşil bir tarama hiçbir şey kanıtlamaz: yanlış kök, yanlış desen, izin hatası
ve çalışan tarayıcı aynı çıktıyı verir. Kırmızı gösteremeyen bir tarayıcının
"temiz" demesi test edilmemiş bir iddiadır. Ayrıntı: `negative/README.md`.

### Nasıl çalıştırılır

```bash
./negative/plant.sh        # kontrol; geçmezse tarayıcıya güvenme
./negative/plant.sh -v     # tarayıcıyı ayrıntılı koştur
```

Docker gerekmez; geliştirme makinesinde de koşar.

---

## 5. `run-all.sh` — hepsini sırayla koştur

```bash
./run-all.sh              # tam tatbikat, özet tablo
./run-all.sh -v           # her adımın çıktısıyla
./run-all.sh --only kontrol,canary
./run-all.sh --json       # CI için tek JSON nesnesi
```

Sıra: negatif kontrol → canary → allowlist → memdump. Negatif kontrol
düşerse kalan adımların sonucu **geçersiz** sayılır ve toplam `1` olur.

Tabloda `PASS` / `FAIL` / `SKIP` görünür; `SKIP` ya `2` (kanıtlanmadı) ya da
`3` (ortam eksik) demektir ve ikisi de yeşil değildir.

---

## Tatbikat sırası

Her fazın çıkışında (§13):

```bash
# 0) trafiği kes
# 1) tarayıcı kör mü? — her zaman ilk
./negative/plant.sh
# 2) disk ayağı
CANARY_TOKEN=... ./canary_scan.sh
./write_allowlist.sh zifiri-app --volume-dir "$VOLUME"
# 3) bellek ayağı
CANARY_TOKEN=... ./memdump_scan.sh
# 4) ağ ayağı — ayrı ölçüm, §4.2 anonimlik kümesi (n)
```

Ya da tek komut: `./run-all.sh`.

Hepsi `0` dönerse fazın tatbikatı yeşildir. Herhangi biri `1` ise faz
bitmemiştir. Herhangi biri `2` ise **kanıt yoktur**: eksik aracı tamamla
veya neden kanıtlanamadığını `docs/verify.md`'ye yaz. Herhangi biri `3` ise
ortam eksiktir (docker yok) — bu da kanıt değildir, aynı şekilde yazılır.

## P0 notu

P0'da bu betikler iskelet olarak yeşil dönmelidir (§13). Boş bir kurulumda
`canary_scan.sh` "dizin yok, atlandı" uyarılarıyla `2` dönebilir; bu
beklenen davranıştır — kanıtlanacak bir şey henüz yok. P1'den itibaren
`0` beklenir.

Docker'ı olmayan bir geliştirme makinesinde `canary_scan.sh` **`3`** döner
(`docker yok, atlandı`). Bu bir hata değil, kapsamın eksik olduğunun
raporudur: `--root` ile hedefli tarama yapılabilir, ama tatbikat kanıtı
tam tarama ister. `negative/plant.sh` bu makinede de yeşil döner.

## Sorun giderme

| belirti | neden | çözüm |
|---|---|---|
| `canary_scan.sh` çok yavaş | `/var/lib/docker` büyük, ham bayt taraması her ikili dosyayı okuyor | normaldir; `DRILL_MAX_SCAN_BYTES` ile üst sınır koy (kanıt zayıflar) |
| `journalctl okunamadı` | root değil ya da journal yok | `sudo` ile çalıştır; yoksa `2` kabul et |
| `docker diff` boş | volume içeriği diff'te görünmez | `--volume-dir` ver |
| `gcore bulunamadı` | gdb kurulu değil | `apt install gdb` ya da `DRILL_EXEC_PREFIX` |
| `gcore` `ptrace: Operation not permitted` | `yama/ptrace_scope` ya da farklı kullanıcı | root ile çalıştır, container'a `SYS_PTRACE` ver |
| reload `BAŞARISIZ` | nginx container içinde | `NGINX_RELOAD_CMD="docker exec ... nginx -s reload"` |
| `ne BEAM ne nginx süreci bulundu` | süreçler container içinde | `DRILL_EXEC_PREFIX` ver |
| `döküm container içinde oluştu ama host'tan görünmüyor` | `$DRILL_OUT` bind mount değil | `-v /run/zifiri-drill:/run/zifiri-drill` |
| `C /tmp` diff'te görünüyor | `/tmp` tmpfs değil | tmpfs mount ekle (§5.1); bu gerçek bir bulgudur |
| `docker yok, atlandı` + `exit 3` | `/var/lib/docker` yok (docker kurulu değil) | normaldir; tatbikat için docker'lı host kullan ya da `--root` ile kapsamı daralt |
| `negatif kontrol` düştü | tarayıcı bitkileri görmüyor | `negative/plant.sh -v`; `scan.log`'a bak. Düzelene kadar hiçbir yeşili raporlama |
| `allowlist okunamadı` | `allowlist.txt` yok/taşınmış | `--allowlist` ile yolu ver |
| `journald: ATLANDI` | `journalctl` yok ya da root değil | `sudo`; yoksa `2` kabul et |
