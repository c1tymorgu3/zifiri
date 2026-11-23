# Sağlamlık ölçümleri

Bu dosyadaki her sayı `scripts/measure/` altındaki bir betiğin **çalıştırılmış**
çıktısıdır. Ölçülmeyen bir şey varsa tabloda "ölçülmedi" yazar ve nedeni
belirtilir; tahmin, tasarım hedefi veya "yaklaşık" sayı buraya girmez.

Vitrin (README) yazılmadan önce alınmıştır: README'deki her sayı buradan
gelmeli, buradaki her sayı da tekrar üretilebilir olmalı.

## Ortam

| | |
|---|---|
| Donanım | 13th Gen Intel Core i3-13100F, Windows 11 |
| Erlang / Elixir | OTP 29 (erts 17.1.1) / Elixir 1.20.5 |
| Node | v24.16.0 |
| `@noble/hashes` | 2.4.0 (`client/node_modules`) |
| Veritabanı | SQLite, `ecto_sqlite3`; `secure_delete=ON`, `journal_mode=WAL`, `synchronous=NORMAL` |
| Ortam | `MIX_ENV=test`, `pool_size` 8 |

Betiklerin hepsi `--help` destekler. Ölçüm veritabanı her koşudan sonra silinir
(`_build/test/zifiri_load.db*`); `_build/test/` altında ölçüm sonrası dosya
kalmaz.

## Özet

| # | Ölçüm | Komut | Sayı | Eşik | Sonuç |
|---|---|---|---|---|---|
| 1 | Yayın gecikmesi, 200 eşzamanlı yazma, p95 | `publish_latency.exs` | **50,4 ms** (8 koşu; 39,7–110,9) | < 2 000 ms | **GEÇTİ** |
| 2 | Yayın gecikmesi, p50 | aynı | 35,0–48,7 ms | bilgi | — |
| 3 | Yayın gecikmesi, p99 | aynı | 59,0–135,9 ms | bilgi | — |
| 4 | Silme, 50 ilan, `erase_many/1` süresi | `erase_latency.exs` | **8,0–11,7 ms** | ≤ 5 000 ms | **GEÇTİ** |
| 5 | Silme, canary'nin dosyada/WAL'de yok olduğu an | aynı | **7–10 ms** | ≤ 5 000 ms | **GEÇTİ** |
| 6 | Silme, 5,2 MB dosya (50 canary + 5 000 dolgu) | `erase_latency.exs --filler 5000` | **45,4–59,1 ms** (4 koşu) | ≤ 5 000 ms | **GEÇTİ** |
| 7 | PoW 20 bit, masaüstü (Node) | `pow_browser.js` | **1 838,8 ms** medyan (431,7–4 338,4) | ≈ 250 ms (`pow.ex` iddiası) | **KALDI** |
| 8 | PoW 20 bit, 4× yavaş CPU (simülasyon) | aynı | **7 563,9 ms** medyan | bilgi | — |
| 9 | PoW 20 bit, 8× yavaş CPU (simülasyon) | aynı | **13 338,5 ms** medyan | bilgi | — |
| 10 | Kimlik satırı uzunluğu (`zifiri1` + 40 bayt base32) | `identity_line.exs`, `node -e` | **71 karakter** | 71 | **GEÇTİ** |

## 1–3. Yayın gecikmesi (200 eşzamanlı yazma)

```
MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs
```

200 yazma aynı anda başlar; her biri kendi sahip anahtarı ve kendi 8 bitlik
kanıtıyla `POST /api/listings` yapar. Ölçülen süre TCP bağlantısı + kanıt
kontrolü + gövde kontrolü + ekleme + yanıt. 8 bit, sunucu tarafı gecikmesini
ölçmek için sabitlenmiştir — istemcinin gerçek 20 bitlik maliyeti 7–9.
satırlarda. 10 yazmalık ısınma atılır.

Sekiz koşu (her koşuda 200/200 `HTTP 201`, yanıt boyu tek değer: **16 384 bayt**):

| koşu | p50 | p95 | p99 | max |
|---|---|---|---|---|
| 1 | 31,1 | 39,7 | 69,9 | 91,2 |
| 2 | 36,2 | 48,3 | 63,8 | 89,0 |
| 3 | 42,5 | 53,1 | 69,1 | 95,9 |
| 4 | 48,7 | 110,9 | 135,9 | 155,1 |
| 5 | 35,3 | 50,9 | 68,2 | 86,5 |
| 6 | 48,0 | 63,4 | 89,1 | 93,4 |
| 7 | 35,0 | 47,3 | 59,0 | 117,7 |
| 8 | 37,5 | 49,9 | 75,7 | 112,3 |

p95 medyanı **50,4 ms**, en kötü koşu **110,9 ms**. Eşik 2 000 ms; en kötü koşu
eşiğin 18 katı altında.

Koşular arası fark (~3×) gerçektir ve tek bir koşuyu "sayı" diye yazmamak için
burada sekizi de duruyor. Tamamlanan yazma sayısı, tablo satır sayısı (200) ve
sabit yanıt boyu her koşuda doğrulanır; betik bunlardan biri tutmazsa KALDI verir.

Ham çıktı (koşu 5):

```
                  min       p50       p95       p99       max       mean      (ms)
write_ms          4.0       35.3      50.9      68.2      86.5      34.9      ms
created       200/200 (HTTP 201)
failed        0
rows in table 200
response size [16384] bytes (fixed-size check)
wall clock    100 ms for the whole batch
```

## 4–6. Silme süresi ve diskteki kanıt

```
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs --filler 5000
```

50 ilan yazılır; her birinin **gövdesinde** (zarf içinde) ve **başlığında**
(şifresiz) ayrı, rastgele, tekil bir canary vardır. Betik önce veritabanı
dosyasını ve `-wal` dosyasını tarar — canary orada **bulunmalıdır**, yoksa
silme sonrası tarama hiçbir şey kanıtlamaz — sonra `Zifiri.Vanish.erase_many/1`
süresini ölçer, sonra tekrar tarar ve canary'ler kaybolana kadar taramayı
tekrarlar.

Küçük veritabanı (ana dosya 4 KB + 1,0 MB WAL; silmeden sonra 45 KB, 50 ilan):

```
written        50 rows in 29 ms
canary before  body %{total: 296, wal: 296, db: 0, found_in_wal: 50 of 50}
erase_many     {:ok, 50} in 9.6 ms
canary after   body %{total: 0, wal: 0, db: 0, found_in_db: 0, found_in_wal: 0}
time to absent 9 ms
rows after     0
freelist       0 pages   page_count 11
wal file       0 bytes
```

Altı koşu: `erase_many` **8,0 / 8,3 / 8,3 / 9,6 / 10,8 / 11,7 ms**. Canary'nin
yok olduğu an son üç koşuda **7 / 9 / 10 ms**; ilk koşularda görünen 26–27 ms
tarayıcının kendi maliyetiydi (dosya 50 canary için 50 kez okunuyordu) ve betik
tek okumaya çevrildikten sonra düştü — ölçülen şey artık silme, tarama değil.
Silmeden önce canary her koşuda 50/50 ilanda, toplam **296** kez (WAL
karelerinde birden çok kopya) bulundu; sonra **0**. Tablo satırı 0,
`freelist_count` 0, `-wal` 0 bayt.

Gerçek boyutlu dosya (5,2 MB, 1 258 sayfa, 50 canary + 5 000 dolgu ilan; dolgu
satırları silinmez ve yerinde kalır):

```
canary before  body %{total: 50, db: 50, wal: 0, found_in_db: 50 of 50}
erase_many     {:ok, 50} in 52.8 ms
canary after   body %{total: 0, db: 0, wal: 0}
time to absent 52 ms
rows after     5000   (dolgu; canary'li 50 satır gitti)
freelist       0 pages   page_count 1258
```

Dört koşu: `erase_many` **45,4 / 52,8 / 56,0 / 59,1 ms**, canary'nin yok olduğu
an aynı koşularda **52 / 59 ms** (45,4 ve 56,0'lık koşularda `time to absent`
tarayıcı düzeltmesinden önce ölçüldüğü için 334 ve 378 ms yazıyor — o sayı
taramanın maliyeti, silmenin değil; `erase_many` süresi her koşuda geçerli).

Bu satır önemli: küçük dosyada VACUUM neredeyse bedava; 5,2 MB'ta silme
45–59 ms. Eşiğin (5 000 ms) iki mertebe altında.

**Bulgu — ölçülen mekanizma, tasarlanan mekanizma değil.** `docs/scope-v5.md`
§Silme, VACUUM'un silme yolundan **çıktığını** ve yalnız gece bakımında
çalıştığını yazıyor (gerekçe: her silmede tüm dosyayı yeniden yazmak p95 < 2 sn
eşiğini aşar). Kodda ise `Vanish.erase_many/1` hâlâ `purge/0` çağırıyor:
checkpoint → `VACUUM` → checkpoint, silme isteğinin içinde. Yukarıdaki sayılar
**VACUUM dahil** ölçüldü — yani tasarımın istediğinden daha ağır bir yol, ve
5,2 MB'ta bile 59 ms. Tasarımın kendi yolu (secure_delete + checkpoint, VACUUM
yok) ayrı ölçülmedi; `auto_vacuum=INCREMENTAL` pragması da `Zifiri.Repo`'da
kurulu değil, yani §Silme'nin ikinci ayağı kodda yok.

Ölçümün sınırı: 1 GB mertebesinde bir dosya **ölçülmedi**. VACUUM maliyeti sayfa
sayısıyla büyür; 5,2 MB'ta 53 ms olan bir işin 1 GB'ta aynı kalacağı
söylenemez. Bu satır ölçülene kadar README'de "her boyutta 5 sn" yazılmamalı.

## 7–9. PoW: 20 bit ne kadar sürüyor

```
node scripts/measure/pow_browser.js --bits 20 --trials 5
```

Sunucunun doğruladığı mesaj aynen kurulur: `challenge_id` (16 bayt) ‖
`payload_hash` (32 bayt) ‖ nonce (u64be), SHA-256, baştaki 20 bit sıfır.
Hash `@noble/hashes`'in tarayıcı istemcisinin kullandığı sürümü. Saat
`process.hrtime.bigint()` — duvar saati.

Üç senaryo aynı beş challenge'ı çözer (deneme sayısı birebir aynı: **1 572 449**
ortalama), tek fark CPU hızı: yavaş CPU, aynı hash'i 4/8 kez hesaplar. Yani
uyku yok, sonuca çarpan uygulanmıyor — ölçülen gerçek süre.

| senaryo | deneme (ort.) | min | medyan | max | Mhash/s |
|---|---|---|---|---|---|
| masaüstü (1×) | 1 572 449 | 431,7 ms | **1 838,8 ms** | 4 338,4 ms | 0,78 |
| telefon varsayımı 4× | 1 572 449 | 1 682,3 ms | **7 563,9 ms** | 15 875,3 ms | 0,81 |
| telefon varsayımı 8× | 1 572 449 | 3 259,9 ms | **13 338,5 ms** | 30 586,1 ms | 0,84 |

`lib/zifiri/pow.ex` modül dokümanı "20 bit tarayıcı worker'ında kabaca çeyrek
saniye" diyor. Ölçüm bunu **tutmuyor**: masaüstünde medyan 1,84 s, en iyi koşuda
0,43 s. Yani iddia ~7× iyimser. Bu bir ölçüm sonucudur, düzeltme kararı ayrı:
ya zorluk düşer, ya iddia değişir — ikisi de bu dosyanın işi değil, ama
README'ye "çeyrek saniye" yazılamaz.

Dağılım geniştir (PoW geometrik): medyan 1,84 s, min 0,43 s, max 4,34 s. Tek
koşu yazmak yanıltıcı olurdu; bu yüzden beş bağımsız challenge ve min/medyan/max.

Ölçümün sınırı: bu bir Node süreci, gerçek telefon değil. 4×/8× senaryoları
CPU'yu yavaşlatır ama mobil tarayıcının JIT farkını, termal kısıtı, arka plan
kısıtlamasını veya gerçek cihaz bellek baskısını modellemez. Gerçek cihazda
ölçüm **ölçülmedi**.

## 10. Kimlik satırı

```
node -e "...base32(40 bayt)..."   → base32 64 karakter
MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs --samples 3
```

Öneki `"zifiri1"` (7 karakter), gövdesi 40 baytın dolgusuz base32'si
(64 karakter). Toplam **71 karakter** — kodun ürettiği satır:

```
zifiri1ISLO6YWRUEWPFN2Q2FJ6MVZYUBPAZBJRTSJAPF22VA6SRYTA5YOACAAAA6ME5JZE
  length           71
  prefix           "zifiri1" (7 chars)
  base32 part      64 chars
```

`node -e` ile bağımsız kontrol: 40 bayt → 64 base32 karakteri; `"zifiri1"` +
64 = **71**, `"zifir1"` + 64 = 70.

**Bulgu:** `docs/identity.md` hâlâ "70 karakter, 6 karakterlik `zifir1` öneki"
diyor ve bayat. Kod `zifiri1` (7) önekini kullanıyor, 71 üretiyor; `zifir1`
yalnızca eski satırları çözmek için kabul ediliyor. `docs/scope-v5.md` §Kimlik
satırı 71 diyor — ölçüm onu doğruluyor. README 71 yazmalı; `docs/identity.md`
güncellenmeli.

## Ölçülmeyenler

| ne | neden |
|---|---|
| 1 GB mertebesinde veritabanında silme | VACUUM maliyeti dosya boyutuyla büyür; yalnız 45 KB ve 5,2 MB ölçüldü |
| Gerçek telefonda PoW | 4×/8× CPU simülasyonu; cihaz, JIT, termal ve arka plan kısıtı yok |
| 20 bit PoW'un sunucu tarafı doğrulama maliyeti | `publish_latency` 8 bit ile sabitlendi; 20 bitlik doğrulama ayrı ölçülmedi |
| Eşzamanlı okuma altında silme (`{:error, :busy}` yolu) | Ölçüm tek başına çalışır; okuyucu varken VACUUM'un busy vermesi ayrı bir ölçüm konusu |
| 4'lü gruplu gösterim uzunluğu | `docs/scope-v5.md` 85 diyor; betiğin kendi 4'lü gruplaması 88 veriyor (71 + 17 boşluk). Kodda gösterim biçimleyicisi yok, bu yüzden doğrulanamadı |

## Tekrar üretme

```
MIX_ENV=test mix run --no-start scripts/measure/publish_latency.exs
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs
MIX_ENV=test mix run --no-start scripts/measure/erase_latency.exs --filler 5000 --trace
MIX_ENV=test mix run --no-start scripts/measure/identity_line.exs
node scripts/measure/pow_browser.js --bits 20 --trials 5
```

Her betik `scripts/measure/results/` altına JSON yazar (koşu zamanı, donanım,
ham sayılar, eşik, sonuç). Eşiği tutmayan betik çıkış kodu 1 ile döner, böylece
CI'da kullanılabilir.
