# Onion servisi

Plan §11.3: clearnet + onion birlikte. Bu dosya onion tarafının nasıl kurulduğunu,
neyi çözdüğünü ve **neyi çözmediğini** yazar. İddia/mod eşlemesi:
`docs/onion-claim.md`. Yapılandırma denetimi: `scripts/verify_onion.sh`.

## Neden var

Onion, sunucunun istemci IP'sini hiç görmemesinin tek tam yoludur. Tor devresi
son düğümde biter; nginx'e gelen bağlantının kaynağı 127.0.0.1'dir. Ağ
gözlemcisi (A2) için ise bağlantı, çıkış düğümü ile sunucu arasındaki bir
şifreli akıştır: hangi kullanıcının hangi sayfayı açtığı eşleştirilemez.
İleriye dönük gözetimde (A3) elimizdeki tek ek savunma budur (§14 #8).

## Neden IP limiti anlamsız (§4.4)

- Clearnet'te nginx istemciyi görür ama **limiti uygulayacak bir yer yoktur**:
  `X-Forwarded-For` altta yatan iddiadır, istemci uydurabilir; gerçek adres
  TCP kaynağıdır ve o da NAT/CGNAT arkasında yüzlerce kişiyi tek adreste
  toplar.
- Onion'da istemci zaten tek adrestir: 127.0.0.1.
- İkisi birlikteyken: aynı kullanıcı clearnet'ten de onion'dan da gelebilir;
  "adres başına N istek" sayacı, onion'daki tüm kullanıcıları tek kovaya atar
  ve kova dolduğunda hizmeti herkese kapatır.

Bu yüzden `nginx.conf`'ta `limit_req` / `limit_conn` **yoktur** ve olmamalıdır.
Yük koruması PoW (§4.4) ve tor'un kendi intro-DoS savunması üzerinden yapılır.
Doğrulama: `docker compose exec nginx nginx -T | grep -cE '^\s*limit_(req|conn)'` → `0`
(yorum satırları da `limit_req` içerdiği için çapa şart).

## Kurulum

1. Dizinler (host, repo içinde):

   ```bash
   mkdir -p infra/tor/data/hidden_service
   chmod 700 infra/tor/data infra/tor/data/hidden_service
   ```

2. Sahiplik. Tor, veri dizinine **kendi kullanıcısıyla** yazmak zorundadır ve
   tor, sahibi olduğu olmayan bir `HiddenServiceDir`'i reddeder. Imajdaki
   kullanıcının UID'ini tahmin etme, sor:

   ```bash
   docker run --rm --entrypoint sh dockurr/tor -c 'id'
   # örn: uid=100 gid=101(tor)
   sudo chown -R 100:101 infra/tor/data
   ```

3. `docker-compose.yml` içindeki `tor` servisi nginx'in ağ ad alanını paylaşır
   (`network_mode: "service:nginx"`). Bu, "aynı makinede loopback" ifadesinin
   konteyner karşılığıdır: `HiddenServicePort 80 127.0.0.1:8081` gerçekten
   loopback'e gider, docker köprüsü üzerinden bir konteyner IP'sine değil.
   Köprü IP'si kullanmak da çalışırdı ama o zaman "tek adres" iddiası docker
   ağına bağlı kalırdı; loopback niyeti açıkça yazar.

4. Açılış:

   ```bash
   docker compose up -d tor
   cat infra/tor/data/hidden_service/hostname      # → xxxxxxxxxxxxxxxx.onion
   ```

   Bu adres onion v3 anahtarından türer. `infra/tor/data` silinirse adres
   **değişir** ve eski adres bir daha çalışmaz. Yedek politikası yoktur
   (§11.5) ama bu dizin kullanıcı verisi değildir; kaybı içerik kaybı değil,
   adres kaybıdır.

## HiddenServicePort yönlendirmesi

Zincirin tamamı tek satırda:

```text
istemci → tor devresi (3 düğüm) → bu makinedeki tor daemon
        → HiddenServicePort 80 127.0.0.1:8081   (infra/tor/config/torrc)
        → nginx  server { listen 127.0.0.1:8081; server_name $ONION_HOST; }
        → unix soket → BEAM
```

| Adım | Dosya | Satır | Yanlış olursa |
|---|---|---|---|
| tor → nginx hedefi | `infra/tor/config/torrc` | `HiddenServicePort 80 127.0.0.1:8081` | onion açılır, 502 döner |
| nginx listener | `infra/nginx.conf` | `listen 127.0.0.1:8081;` | tor bağlanamaz, servis ölü |
| nginx Host eşleşmesi | `infra/nginx.conf` | `server_name $ONION_HOST;` | istek varsayılan bloğa (clearnet) düşer, onion adresinde clearnet içeriği servis edilir |
| `$ONION_HOST` render | `infra/deploy.md` (iki geçişli render) | `hostname` dosyasındaki adres | `server_name` boş kalır, `nginx -t` düşer |

`HiddenServicePort`'un ilk sayısı **sanal** porttur (tor'un dinlediği 80), ikincisi
gerçek hedeftir. 8081 dışarı açılmaz; `docker-compose.yml`'de publish edilmez ve
`listen` yalnız loopback'tedir — yani 8081'e ulaşmanın tek yolu tor'dur. Bu, "IP
yok" iddiasının yapılandırma karşılığıdır (`docs/onion-claim.md`).

Doğrulama:

```bash
# tor gerçekten loopback'e mi bağlanıyor? (dışarıdan gelen bağlantı görünmemeli)
ss -tnp | grep 8081                      # yalnız 127.0.0.1

# iddianın dayandığı satırlar yüklü mü?
scripts/verify_onion.sh --docker         # 0 = geçti, 1 = eksik, 3 = nginx yok
```

## İki onion adresi: gerçek + decoy

Tek onion adresi **kalıcı bir tanıtıcıdır**. Adres onion v3 anahtarından türer ve
anahtar silinmedikçe değişmez; yani aynı adrese gelen her oturum, aynı ziyaretçi
olmasa bile tek bir ada bağlanır. Onion IP'yi kaldırır, ama bu kez adresin kendisi
korelasyon yüzeyi olur: bir gözlemci "bu adrese şu saatlerde giren akışlar aynı
kişi olabilir" diyebilir; adres bir forumda paylaşıldıysa o paylaşım da izdir.

Öneri: **iki ayrı HiddenServiceDir** — biri gerçek servis, biri decoy. İkisi de
aynı nginx listener'ına gider, ikisi de aynı içeriği sunar; dışarıdan ayırt
edilemezler (aynı gövde, aynı başlıklar, aynı zamanlama — decoy kova mantığının
adres düzeyindeki karşılığı, §6.2).

```conf
# infra/tor/config/torrc — ikinci (decoy) adres
HiddenServiceDir /var/lib/tor/hidden_service_decoy
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:8081
HiddenServiceEnableIntroDoSDefense 1
HiddenServicePoWDefensesEnabled 1
```

Neden:

1. **Korelasyonu böler.** İki adresin trafiği ayrı ayrı toplanır; tek adresin
   "tek kullanıcı" gibi okunması zorlaşır.
2. **Link rotasını böler.** Adreslerden biri ifşa olursa (forumda paylaşım, ekran
   görüntüsü) diğeri temiz kalır — gerçek adres anahtar silinmeden değiştirilemez,
   decoy değiştirilebilir.
3. **Maliyeti yok.** İkinci servis aynı tor sürecinde, aynı nginx bloğunda çalışır;
   ek süreç, ek port, ek log yok.

Sınırı: decoy **korelasyonu zorlaştırır, imkânsız kılmaz** ve "kimlik yok"
demek değildir. `server_name` yalnız gerçek adresi eşler; decoy adresin Host'u
farklı olacağı için ya `server_name`'a eklenmeli ya da ikinci listener açılmalıdır —
eklenmezse decoy istekleri varsayılan bloğa düşer. Adres eklemek `nginx.conf`'ta
tek satırdır — ama render adımına da yazılmalı, yoksa `$ONION_HOST_DECOY` değişken
olarak kalır ve `nginx -t` düşer:

```nginx
server_name $ONION_HOST $ONION_HOST_DECOY;
```

```bash
# deploy.md'deki render komutuna ek satır — SIRASI ÖNEMLİ:
# `$ONION_HOST_DECOY`, `$ONION_HOST` ile başlar. Uzun değişken önce değiştirilmezse
# `$ONION_HOST` kuralı onu `adres.onion_DECOY` yapar.
sed -e "s|\$ONION_HOST_DECOY|$DECOY|g" -e "s|\$ONION_HOST|$ONION|g" nginx.conf > nginx.conf.rendered
```

## Onion-Location

Clearnet yanıtları `Onion-Location: http://$ONION_HOST<yol>` başlığını taşır
(`nginx.conf`, 443 sunucusu). Tor Browser bu başlığı görünce adres çubuğunda
"onion sitesinde aç" düğmesi gösterir; kullanıcı clearnet'ten onion'a tek
tıkla geçer. Bu, kullanıcıyı zorlamaz — yönlendirme değil, duyuru.

`$ONION_HOST` deploy sırasında `nginx.conf`'a yazılır (deploy.md, iki geçişli
render). Onion cevaplarında bu başlık yoktur, HSTS de yoktur: onion http
üzerinden servis edilir ve tarayıcı `.onion`'ı güvenli kaynak sayar.

Onion bloğunun `server_name`'i `_` değil `$ONION_HOST`'tur: tor orijinal Host
başlığını korur, yani onion isteği kendi adıyla gelir. Bu, bloğun niyetini
yapılandırmada yazar; ayrıca `verify_onion.sh` "Onion-Location yalnız clearnet'te
var mı" denetimini bu ayrım üzerinden yapar.

Hangi iddianın hangi modda geçerli olduğu (ve hangisinin **geçersiz** olduğu):
`docs/onion-claim.md`. Özet: clearnet'te "IP uygulamaya girmez" denir, "IP yok"
denmez; "IP yok" yalnız onion modunda söylenebilir.

## Neyi gizlemez

Dürüstlük listesi. Bunlar hata değil, sınır:

1. **Sunucunun nerede olduğunu gizlemez.** Onion servisi, sunucunun IP'sini
   gizlemez; tor devreleri sunucuya bağlanır. Konum gizleme ayrı bir iştir ve
   kapsam dışıdır (§1).
2. **Aynı içeriğin clearnet'te olduğunu gizlemez.** Clearnet açık kaldığı
   sürece bir gözlemci iki yüzeyi karşılaştırabilir; onion, clearnet'in
   zayıflığını geri almaz (§14 #1).
3. **Sunucudaki canlı akışı gizlemez (A3).** Sunucu ele geçirilirse onion
   kullanıcısının isteği nginx'te 127.0.0.1 olarak görünür — kimlik yok, ama
   istek ve zaman var. Onion'ın kazancı "kim" değil, "nereden"in kaybıdır.
4. **Zamanlama sızıntısını gizlemez.** Sohbet gerçek zamanlıdır ve tor
   gecikmesi mesaj-bağlantı eşleştirmesini zorlaştırır, imkânsız kılmaz
   (§7.4, §14 #4).
5. **Yazının kendisini gizlemez.** Üslup kimliktir (§14 #12). Onion, ağ
   katmanını kapatır, metni kapatmaz.
6. **Hizmet reddini gizlemez.** Onion adresi de taranır ve dövülür; intro-DoS
   savunması ve PoW bunu yavaşlatır, durdurmaz.

## Bakım

- `tor` imajı `dockurr/tor:latest` — üretimde digest'e sabitlenmeli (§10.3
  mantığı imajlar için de geçerli).
- Tor sürümü onion PoW savunmasını desteklemeli (`HiddenServicePoWDefensesEnabled`,
  tor ≥ 0.4.8). Desteklenmezse tor bu satırı yok sayar, açılış düşmez.
- Hata ayıklarken `logging.driver: none` yüzünden hiçbir şey görünmez. Geçici
  olarak o servisi `json-file`'a çevir, işin bitince geri al — kalıcı bırakmak
  §5.1'i çiğnemek demektir.
