# Host sertleştirme — ne kapatır, ne kapatmaz

`harden.sh` sunucunun **kendi** ürettiği izleri azaltır: çekirdek dökümü, swap,
journal, eski log dosyaları. Disk şifrelemesini **yapmaz** (kurulum anında
olmalı, aşağıda), sağlayıcıyı ve ağı **kapsamaz**.

Üç katmanı karıştırmamak gerekir:

| katman | kim kapatır | bu betik |
|---|---|---|
| süreç/çekirdek izleri (core, swap, journald, /var/log) | işletim sistemi | **evet** |
| disk (blok cihaz, snapshot, çöp VM imajı) | LUKS — kurulum anında | hayır |
| çevre (sağlayıcı logu, ağ gözlemi, hypervisor RAM'i) | sağlayıcı sözleşmesi / tehdit modeli | hayır |

Betiğin yeşil dönmesi "anonim" demek değildir; plan §5.1'in "log yok" iddiası
yalnız birinci katmanı kapsar, §11.4'ün disk iddiası ikinci katmanı.

Kullanım:

```sh
sudo ./harden.sh --dry-run     # planı gör, hiçbir şeyi değiştirme
sudo ./harden.sh               # uygula (idempotent, tekrar çalıştırılabilir)
sudo ./harden.sh --log-age-days 3
```

Linux olmayan ortamda betik durur (çıkış 2): `swapoff`, `sysctl`, `systemctl`
orada yoktur; `--dry-run` yalnız planı yazdırır, hiçbir komut çalıştırmaz.

Yönetilen dosyalar — elle düzenleme bir sonraki çalıştırmada ezilir:

```
/etc/sysctl.d/90-zifiri-hardening.conf
/etc/systemd/journald.conf.d/90-zifiri.conf
/etc/systemd/system.conf.d/90-zifiri-core.conf
/etc/security/limits.conf        (yalnız "BEGIN/END zifiri-harden" bloğu)
/etc/fstab                       (yalnız swap satırları yorumlanır)
```

---

## Adım adım

| # | adım | engellediği | geri alma |
|---|---|---|---|
| 1 | ön kontrol | — (LUKS yoksa uyarır) | — |
| 2 | swap kapat | RAM'in diske yazılması, hibernate imajı | `cp /etc/fstab.zifiri.bak /etc/fstab && swapon -a && systemctl unmask swap.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target` |
| 3 | core dump kapat | çöken süreç belleğinin diske dökülmesi | `rm /etc/sysctl.d/90-zifiri-hardening.conf && sysctl --system` |
| 4 | ulimit core 0 | RLIMIT_CORE>0 ile döküm denemesi | blok sil + drop-in sil |
| 5 | journald `Storage=none` | unit çıktısı, çekirdek mesajı, tor/nginx logu | drop-in sil + `systemctl restart systemd-journald` |
| 6 | `/var/log` temizliği | eski rotasyon dosyaları | **yok** — önce `--dry-run` |
| 7 | doğrulama | — (ölçüm) | — |

### 2. swap — RAM'in diske kopyası

Swap, çekirdeğin "bu sayfayı bellekte tutmayayım" dediği sayfaları diske
yazdığı alandır. Oraya bir mesaj gövdesi, açık oturum token'ı ya da pepper
kopyası düşerse "mesaj diske yazılmaz" (§7.1) iddiası çöker: disk imajını alan
kişi swap dosyasında düz metin okur. Hibernate aynı işi **tüm RAM** için yapar
ve tek dosyada tüm belleği bırakır — bu yüzden hedefleri maskelenir.

- **Engeller:** çekirdeğin soğuk sayfaları swap'a taşıması; `systemctl hibernate`
  ile RAM'in tek dosyaya yazılması; birinin sonradan `swapon -a` demesi
  (`swap.target` maskeli).
- **Engellemez:** çalışma anında RAM (§A3); `/tmp` disk üzerindeyse oradaki
  dosyalar; sağlayıcının VM belleğine erişimi.
- **Bedeli:** swap'siz makinede OOM killer daha erken devreye girer. Bu yüzden
  §11.4 belleği küçük tutuyor (SQLite + tek BEAM düğümü). `zram` de `swapoff -a`
  ile kapanır — zram RAM'de kaldığı için gizlilik riski değildi, ama iki farklı
  takas yolu bırakmamak için kapatılıyor.

### 3. core dump — üç ayrı kapı, üçü de kapatılır

Tek bir ayar yetmez, çünkü dökümün yazılmasına üç ayrı mekanizma karar verir:

1. `kernel.core_pattern` — çekirdeğin nereye yazacağı. **Boş bırakmak kapalı
   demek değildir**: boş desen "çalışma dizinine `core` adlı dosya yaz" demektir.
   Kapalı olan tek biçim bir borudur: `|/bin/false` → çekirdek veriyi `/bin/false`'a
   borular, o da okumadan çıkar; diske hiçbir şey yazılmaz.
2. `RLIMIT_CORE` — süreç başına sınır. `limits.conf` PAM oturumlarını kapsar,
   **systemd servislerini kapsamaz**; bu yüzden ayrıca
   `DefaultLimitCORE=0` drop-in'i ve her unit'te `LimitCORE=0` var.
3. `systemd-coredump` — kendi boru hattıyla dökümü alıp journal'a/sisteme yazar;
   `core_pattern` değişse bile ayrı yoldan çalışabilir, maskelenir.

Ek olarak `fs.suid_dumpable=0`: `2` "yalnız root yazsın" demektir, yani döküm
hâlâ diske düşer — root'un okuduğu bir dosya, disk imajını alan için de okunur.
BEAM tarafında `ERL_CRASH_DUMP=/dev/null` + `ERL_CRASH_DUMP_SECONDS=0` aynı işi
Erlang'ın kendi dökümü için yapar (varsayılan `erl_crash.dump` repo kökünde
6 MB'lık bir dosya bırakır — bu repoda bir tane duruyor, `.gitignore`'a bak).

- **Engeller:** çöken süreç belleğinin (mesajlar, token'lar, SQLite sayfaları,
  pepper) tek dosyada diske yazılması; `sudo` ile çalışan bir sürecin çökmesi
  hâlinde root'a ait belleğin dökülmesi.
- **Engellemez:** canlı süreç belleği — aynı kullanıcı (ya da root) `ptrace`,
  `/proc/<pid>/mem`, `process_vm_readv` ile okur; hypervisor'un bellek dökümü
  bunun tamamen dışındadır.

### 4. ulimit core 0 — üçüncü katman

`core_pattern` "nereye yazılacağını", `RLIMIT_CORE` "yazılsın mı"yı belirler;
ikisi ayrı kapıdır. Limit sıfırken çekirdek döküm yolunu hiç denemez, yani
`core_pattern` yanlışlıkla değişse bile dosya oluşmaz.

- `/etc/security/limits.conf` bloğu — PAM oturumları (ssh, su, sudo).
- `/etc/systemd/system.conf.d/90-zifiri-core.conf` → `DefaultLimitCORE=0` —
  **systemd servisleri limits.conf'u okumaz**; bu drop-in onları kapsar.
  Yalnız yeni başlayan servislerde etkilidir; çalışan bir servis değeri
  yeniden başlatılınca alır (bu yüzden `harden.sh`'ı servisleri kurmadan önce
  çalıştır).
- Her unit'te `LimitCORE=0` — drop-in'i beklemeden, unit kendi başına kapalı.

`ulimit -c 0` kabukta elle de çalışır ama kalıcı değildir ve servisleri
kapsamaz; betik bu yüzden üç kalıcı yolu da yazar.

- **Engeller:** limit `0` iken döküm dosyası oluşması; `su`/`sudo` ile başlayan
  oturumların varsayılan limitsiz açılması.
- **Engellemez:** `ulimit -c unlimited` diyen bir süreç (hard limit 0 ise
  yükseltemez — root hariç); root'un `sysctl kernel.core_pattern` ile geri
  açması (root zaten her şeyi okur, §A3).

### Ek — 3. adımın devamı: sysctl'in geri kalanı

- `kernel.dmesg_restrict=1` — çekirdek halkası süreç adı, adres, modül yolu ve
  aygıt bilgisi taşır; root dışına kapanır.
- `kernel.kptr_restrict=2` — `/proc` üzerinden çekirdek işaretçisi sızmaz
  (KASLR'ı kırmaya yarayan adresler).
- `net.ipv4.conf.*.log_martians=0` — "martian" paketler kaynak adresiyle
  loglanır; bu satır, yanlış yapılandırılmış bir ağın istemci IP'sini çekirdek
  loguna yazmasını engeller.
- `vm.swappiness=0` — swap kapalıyken etkisiz; biri swap'ı geri açarsa bile
  çekirdek istekli takas yapmasın (savunma derinliği).

### 5. journald — `Storage=none`

journald; unit'lerin stdout/stderr'ini, çekirdek mesajlarını ve (açıksa) audit
kayıtlarını diske yazar. Tor `Log notice stdout` ile, nginx `error_log /dev/null`
ile çalışsa bile **systemd'nin kendisi** unit çıktısını toplar. `Storage=none`
journal dosyasını hiç oluşturmaz: kayıt yalnız çalışma zamanında bellekte durur,
yeniden başlatmada kaybolur. `ForwardToSyslog=no` rsyslog köprüsünü keser —
yoksa `Storage=none` bir işe yaramaz, rsyslog aynı satırları `/var/log/syslog`'a
yazar.

- **Engeller:** unit çıktısının, çekirdek mesajlarının ve tor/nginx hatalarının
  kalıcı olması; `journalctl` ile geçmişe bakılması.
- **Engellemez:** çalışma anında `journalctl` (root RAM'deki halkayı okur);
  ayrı çalışan `auditd` (kapatılmıyor — açıksa §5.1 ihlalidir, `systemctl
  disable --now auditd` ayrı bir karardır); rsyslog kendi yapılandırmasıyla
  başka dosya yazıyorsa o dosya (6. adım ikinci savunma).

### 6. `/var/log` temizliği

Rotasyon kayıtları aylarca tutar; `access.log.1`, `syslog.2.gz` gibi dosyalar
"artık yazmıyoruz" dedikten sonra bile geçmişi taşır. Betik döndürülmüş/
sıkıştırılmış dosyaları ve `--log-age-days` (varsayılan 7) günden eski `*.log`
dosyalarını siler.

- **Korunan:** `wtmp`, `btmp`, `lastlog` — bunlar istemci değil **operatör**
  oturum kaydıdır (§5 son paragraf); silmek `last`/`lastb` teşhisini kör eder,
  gizlilik kazancı yok. `/var/log/journal` ayrıca ele alınır (5. adım).
- **Engellemez:** silinen dosyanın blok cihazda kalması. Dosya sistemi "sildim"
  der, bloklar kalır; SSD'de TRIM/GC zamanla temizler, snapshot ve yedeklerde
  hiç temizlenmez. **Bu yüzden silme bir gizlilik garantisi değildir** — disk
  şifrelemesi olmadan eski log "silindi" sayılmaz.

### 7. Doğrulama

```sh
swapon --show                                   # boş
sysctl -n kernel.core_pattern                   # |/bin/false
sysctl -n fs.suid_dumpable                      # 0
sysctl -n kernel.dmesg_restrict                 # 1
sysctl -n vm.swappiness                         # 0
journalctl --disk-usage                         # "No journal files were found"
grep -E '^[^#].*core' /etc/security/limits.conf  # soft/hard 0
systemd-analyze verify /etc/systemd/system/zifiri*.service
```

`harden.sh` son adımda bu ölçümlerin çoğunu kendisi basar. Ölçüm yeşilse
birinci katman kapalıdır; ikinci ve üçüncü katman için aşağıya bak.

---

## systemd unit'leri (`infra/systemd/`)

Üç unit, release'i doğrudan host üzerinde çalıştırma yoludur; varsayılan dağıtım
docker compose'dur (`infra/deploy.md`). İkisini birlikte kullanma — aynı SQLite
dosyasına iki yazıcı olur.

| unit | neyi daraltır |
|---|---|
| `zifiri.service` | boş yetenek kümesi, salt-okunur kök, iki yazma yolu, `LimitCORE=0`, `ERL_CRASH_DUMP=/dev/null`, pepper'ı `LoadCredential` ile |
| `zifiri-tor.service` | boş yetenek kümesi, yalnız `/var/lib/tor` yazılabilir, `MemoryDenyWriteExecute=yes` (C, JIT yok) |
| `zifiri-nginx.service` | yalnız 4 yetki (bind/setuid/setgid/dac_override), yalnız `/run` yazılabilir, `LimitCORE=0` |

Ortak ilkeler ve gerekçeleri:

- `ProtectSystem=strict` + `ReadWritePaths=/var/lib/zifiri /run/zifiri` — kök
  dosya sistemi salt-okunur; uygulama yalnız veritabanını, hata logunu ve unix
  soketini yazar. `/opt/zifiri` koddur, yazılmaz.
- `ProtectHome=yes` — `/home`, `/root`, `/run/user` süreç için yok. Release
  `/opt`'ta, `HOME=/var/lib/zifiri`; kimsenin ev dizinine ihtiyaç yok.
- `NoNewPrivileges=yes` + `CapabilityBoundingSet=` — süreç setuid ikili, dosya
  yeteneği ya da polkit ile yükselemez. BEAM unix soketine bağlanır, 1024 altı
  port açmaz; yeteneğe ihtiyacı yok.
- `MemoryDenyWriteExecute=no` **yalnız zifiri.service'te**: BEAM JIT kodu
  yazılabilir sayfaya yazar, sonra `mprotect` ile çalıştırılabilir yapar.
  systemd'nin W^X seccomp filtresi tam bu deseni reddeder; `yes` yazmak
  emülatörü açılışta EPERM ile öldürür. Yani burada `no` bir eksiklik değil,
  JIT'in çalışması için zorunlu. JIT'siz derlenmiş bir ERTS'te `yes` yapılabilir.
  tor ve nginx C'dir; tor'da `yes`, nginx'te PCRE JIT derlemesine bağlı olduğu
  için `no` (yorumda gerekçesi var).
- `LoadCredential=pepper:/run/zifiri-pepper/pepper` — pepper diske yazılmaz;
  systemd dosyayı unit'e özel tmpfs kopyasına alır, uygulama `%d/pepper`'ı okur.
  Dosya yoksa unit açılmaz (fail-fast): pepper'sız açılan bir kurulum, pepper'ı
  kaybetmiş kurulumla aynı sessiz hatadır.
- Syscall filtresi bilinçli olarak yok: BEAM'in kullandığı set dağıtımdan
  dağıtıma değişir (io_uring, `sched_setaffinity`, `prctl`, `madvise`); yanlış
  filtre çalışma zamanında sessiz EPERM üretir. Yüzey bunun yerine yetenek
  kümesi + salt-okunur kök + `NoNewPrivileges` ile daraltıldı.
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` — uygulama yalnız unix
  soketi kullanır; INET/INET6, bir kütüphane sessizce DNS açarsa çökmesin diye
  açık. Daha dar istersen yalnız `AF_UNIX` yaz ve bir hafta hatasız çalıştığını
  doğrula.

**Engellemez:** aynı makinede root olan biri bu unit'lerin dosyalarını okur
(§A3); unit sertleştirmesi root'u durdurmaz, yalnız ele geçirilmiş bir uygulama
sürecinin yatay hareketini daraltır. Sağlayıcının konsolu ve hypervisor erişimi
tamamen dışındadır.

> Not: unit'ler bu makinede (Windows) `systemd-analyze verify` ile
> doğrulanamadı — systemd yok. Linux'ta kurmadan önce şunu çalıştır:
> `systemd-analyze verify infra/systemd/zifiri.service` (dosya yolunu mutlak
> ver; `Documentation=` ve `LoadCredential=` yollarının var olması gerekir).

---

## LUKS neden kurulum anında olmak zorunda

Bu betik LUKS kurmaz ve kurmamalı. Sebep "zahmetli" değil, **geçmişi
şifreleyemiyor olması**:

1. **Şifreleme öncesi yazılmış her blok düz metindir.** Dosya sisteminden
   silinmiş bir dosya, blok cihazda durmaya devam eder; sonradan LUKS kurmak
   yalnız bundan sonraki yazmaları şifreler. Eski log, eski SQLite sayfası,
   eski `erl_crash.dump` kalıntısı okunur kalır. `cryptsetup reencrypt` bunu
   üzerine yazarak çözer ama: boş alan ister, saatler/günler sürer ve yarıda
   kalırsa veri gider — canlı bir sunucuda yapılacak iş değildir.
2. **Sağlayıcı snapshot'ları geçmişi dondurur.** Şifrelemeden önce alınmış her
   snapshot, sonradan şifrelesen de düz metin kalır. Sağlayıcı geçmişe dönük
   snapshot siliyor mu, ne kadar tutuyor — sözleşme meselesi; teknik olarak
   senin elinde değil.
3. **Anahtar teslimi.** Kurulum anında diski açan parola/anahtar operatörde
   olur. Sonradan "şifreleyelim" adımı çoğu pratikte anahtarı ya diske ya da
   sağlayıcının panelindeki bir alana bırakır — o zaman şifreleme yoktur,
   yalnız gecikme vardır.
4. **Kurulum anı tek temiz andır.** Yeni VM'de disk boştur: hiçbir düz metin
   kalıntısı yoktur, snapshot yoktur, kesinti maliyeti yoktur. Bu pencere bir
   kez kaçar.

Doğru sıra: sağlayıcının "encrypted disk" seçeneği ya da rescue modda tam disk
LUKS + uzaktan açma (`dropbear-initramfs`). Sonra işletim sistemi kurulur, sonra
`harden.sh`. Ters sıra (önce kur, sonra şifrele) yukarıdaki üç kalıntıyı
bırakır.

**LUKS ne engeller:** diski söküp götürmek, çöp VM imajını okumak, sağlayıcının
aldığı snapshot'ı incelemek, yanlışlıkla silinmiş VM'in artıklarını kurtarmak.

**LUKS ne engellemez:** çalışan VM (anahtar açıkken disk şeffaftır), hypervisor'ın
bellek erişimi, sağlayıcı konsolu, yasal zorlama, uygulama seviyesindeki hatalar.
Disk şifrelemesi "sunucu çalışırken kimse okuyamaz" demek değildir; "sunucu
kapalıyken/atılken disk okunamaz" demektir.

---

## Kapsam dışı — bilinçli olarak yapılmayanlar

- **Sağlayıcı logları:** ağ akış kayıtları (flow logs), konsol erişimi, snapshot
  geçmişi, destek ekibinin erişimi. Bunlar sözleşme ve sağlayıcı seçimi
  meselesidir; betik bunları göremez.
- **Ağ katmanı:** TLS terminasyonu, DNS, zaman senkronu, IP başlıkları. Tor
  tarafı `infra/onion.md`, clearnet tarafı `infra/nginx.conf` konusu.
- **RAM:** çalışma anında bellek, `/proc/<pid>/mem`, hypervisor dökümü.
- **Yedekler:** §11.5 yedeğin kendisini ayrı ele alıyor; yedek alınan yer
  şifrelenmemişse disk şifrelemesi onu kurtarmaz.
- **auditd / rsyslog:** kapatılmıyor. Kuruluysa §5.1 ihlali üretirler; kapatmak
  ayrı bir karar (denetim ihtiyacı olan makinede zifiri çalıştırılmaz).
- **Docker yolu:** compose kullanılıyorsa journald yerine konteyner log sürücüsü
  (`json-file` limiti / `none`) ve `--log-driver` ayrıca ayarlanmalı; bu betik
  host'taki journald'ı kapatır, konteynerlerin kendi log dosyalarını silmez.
