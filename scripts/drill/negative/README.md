# Negatif kontrol — neden bu dosya var

`plant.sh` bu dizinin en önemli betiği. Sebebi tek cümle:

> Yeşil bir tarama hiçbir şey kanıtlamaz. Kırmızı gösteremeyen bir tarayıcının
> "temiz" demesi, test edilmemiş bir iddiadır.

## Problem

`canary_scan.sh` sıfır isabetle döndüğünde iki farklı dünya aynı görünür:

1. Gerçekten sızıntı yok. İstediğimiz bu.
2. Tarayıcı bozuk: yanlış kök, yanlış desen, `grep` yerine sessizce hiçbir şey,
   izin hatası, `find` listesi boş, WAL dosyası okunmuyor, `/proc` yok.

İkinci durumda çıktı yine "SONUÇ: YEŞİL"dir. Üstelik bu, tatbikatın en pahalı
hatasıdır: yanlış güven, hiç güvenmemekten kötüdür — çünkü rapor yazılır,
`docs/verify.md`'de iddia "kanıtlandı" işaretlenir ve bir daha bakılmaz.

## Çözüm

Kontrollü bir sızıntı üret, tarayıcının onu bulduğunu gör. Bulmuyorsa tarayıcı
kör, dolayısıyla o makinede alınan hiçbir yeşil sonuç kanıt değil.

`plant.sh` canary'yi **üç ayrı taşıma yoluna** bilerek yazar ve üçünün de
bulunmasını şart koşar:

| # | bitki | yol | neden bu |
|---|---|---|---|
| A | düz metin | `var/log/nginx/access.log` | en yaygın sızıntı: erişim kaydı |
| B | JSON log | `var/lib/docker/containers/…/…-json.log` | docker json-file sürücüsü; kaçışlı `\n` içinde IP |
| C | ortam değişkeni | `/proc/<pid>/environ` | diske hiç yazılmaz; yalnız süreç ortamında durur |

C özellikle önemli: bir uygulama `X-Forwarded-For` değerini ortam değişkenine
koyup orada unutabilir. Bu, dosya taramasında görünmez; `/proc` taranmazsa
sızıntı sessizce yeşil kalır.

Buna ek olarak bir **yanlış pozitif** kontrolü vardır: masum bir dosyaya
`172.31.77.70` yazılır (canary `172.31.77.7`). Desen sınır kontrolü yapmıyorsa
burada yakalanır; yakalanmazsa tarayıcı her `172.31.77.7x` adresinde kırmızı
yanar ve gürültüden kullanılamaz hale gelir.

## Kullanım

```bash
./negative/plant.sh          # kontrolü koştur, bitkileri temizle
./negative/plant.sh -v       # tarayıcıyı da ayrıntılı koştur
./negative/plant.sh --keep   # bitkileri bırak, elle incele
```

Çıktı:

```
  [PASS] yanlış pozitif yok: masum dosya (172.31.77.70) isabet üretmedi
  [PASS] tarayıcı kırmızı döndü (exit 1)
  [PASS] A düz metin (access.log)    bulundu (ip-plain)
  [PASS] B JSON log (docker)          bulundu (ip-plain)
  [PASS] C ortam (/proc/PID/environ)  bulundu (ip-plain)

SONUÇ: KONTROL GEÇTİ — tarayıcı üç bitkiyi de buldu, masumu bulmadı.
```

## Çıkış kodları

| kod | anlam | ne yapmalı |
|---|---|---|
| `0` | kontrol geçti | `canary_scan.sh` sonucu bu makinede kanıt sayılabilir |
| `1` | kontrol düştü, tarayıcı kör | `scan.log`'a bak; tarayıcı düzelene kadar hiçbir yeşil sonucu raporlama |
| `2` | kontrol koşturulamadı | ortam eksik (bash/grep yok, dizin açılamıyor) |

## Docker gerekmez

Bu kontrolün tamamı host üzerinde koşar: dosya yazma, `sleep` süreci, `grep`.
Docker yalnız *bitkinin şeklini* taklit eder (json-file biçimi), çalışan bir
docker gerektirmez. Bu yüzden geliştirme makinesinde de koşabilir — ve
koşmalıdır: tarayıcıya dokunan her değişiklikten sonra.

`run-all.sh` bu kontrolü ilk adım olarak koşturur ve düşerse kalan adımların
sonucunu geçersiz sayar.

## Ne kanıtlamaz

- **Container içini kanıtlamaz.** Bitkiler host dosya sistemine yazılır.
  `docker diff`'in gördüğü katman ile bu kontrolün gördüğü dizin aynı şey
  değildir; container içi sızıntı için `write_allowlist.sh` gerekir.
- **journald'ı kanıtlamaz.** Bitkiler journal'a yazılmaz; journald ayağı
  `canary_scan.sh` içinde ayrıca raporlanır (`journald: ATLANDI`).
- **Bellek ayağını kanıtlamaz.** Bu, `memdump_scan.sh`'in işi; orada da aynı
  mantık geçerlidir (dökümde canary yoksa döküm alınmamış olabilir).
- **Ağ ayağını kanıtlamaz.** §4.2'nin `n` ölçüsü ayrı bir iştir.

Kontrolün kanıtladığı tek şey dar ama kritiktir: *bu tarayıcı, bu makinede,
bilerek konmuş bir canary'yi üç taşıma yolunda da görüyor.*
