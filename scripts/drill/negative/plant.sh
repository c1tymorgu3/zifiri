#!/usr/bin/env bash
# shellcheck shell=bash
#
# plant.sh — negatif kontrol: tarayıcının gerçekten bulduğunu kanıtla
#
# Neden var: yeşil bir tarama hiçbir şey kanıtlamaz. Tarayıcı bozuk, kök yanlış
# ya da desen hiç eşleşmiyor olabilir; üç durumda da çıktı "temiz" olur.
# Bu betik canary'yi bilerek üç yere yazar ve tarayıcının üçünü de bulmasını
# şart koşar. Bulamazsa kontrol BAŞARISIZ (exit 1) — yani tarayıcıya
# güvenilmez ve tatbikat sonucu da geçersizdir.
#
# Üç bitki (plant):
#   A  düz metin dosyası   var/log/nginx/access.log      (IP satır içinde)
#   B  JSON log            var/lib/docker/containers/…-json.log (docker json-file)
#   C  ortam değişkeni     /proc/<pid>/environ           (diske hiç yazılmaz)
#
# Dördüncü kontrol (yanlış pozitif): 172.31.77.70 gibi bir komşu IP'yi içeren
# masum dosya isabet ÜRETMEMELİ. Desen çok genişse burada yakalanır.
#
# Docker gerekmez. gdb gerekmez. Yalnız bash + grep + python3.
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=.
SCANNER=${DRILL_SCANNER:-$SELF_DIR/../canary_scan.sh}

IP=${CANARY_IP:-172.31.77.7}
TOKEN=${CANARY_TOKEN:-zifiri-canary-negatif-kontrol-0000000000000000}
KEEP=0
VERBOSE=0
STATE=${DRILL_STATE_DIR:-${TMPDIR:-/tmp}}
SLEEP_SECONDS=${DRILL_PLANT_SLEEP:-900}

usage() {
  cat <<EOF
$PROG — canary tarayıcısı için negatif kontrol

Kullanım:
  $PROG [seçenekler]

Ne yapar:
  1. masum bir dosyaya komşu IP (${IP%.*}.70) yazar, tarar: isabet OLMAMALI
  2. canary'yi üç yere bitkiler, tarar: ÜÇÜ DE bulunmalı
  3. bitkileri temizler (--keep ile bırakır)

Seçenekler:
  --ip ADRES        Bitkilenecek IP (varsayılan: $IP)
  --token DIZGE     Gövde canary'si (varsayılan: sabit test dizgesi)
  --state DIZIN     Bitkilerin kurulacağı üst dizin (varsayılan: $STATE)
  --scanner DOSYA   Taranacak betik (varsayılan: $SCANNER)
  --keep            Bitkileri ve süreci bırak (elle incelemek için)
  -v, --verbose     Tarayıcıyı --verbose ile koştur, her adımı yaz
  -h, --help        Bu metin

Çıkış kodları:
  0  kontrol GEÇTİ: tarayıcı bitkilerin üçünü de buldu, masumu bulmadı
  1  kontrol BAŞARISIZ: tarayıcı kör — bu makinede yapılan hiçbir yeşil
     tarama kanıt sayılmaz
  2  kontrol koşturulamadı (tarayıcı yok, izin yok, ortam eksik)

Örnek:
  ./negative/plant.sh -v
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
vlog() { if ((VERBOSE)); then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

need_value() {
  if (($# >= 2)) && [[ -n $2 ]]; then return 0; fi
  die "$1 değer istiyor"
}

while (($#)); do
  case $1 in
    --ip) need_value "$@"; IP=$2; shift 2 ;;
    --token) need_value "$@"; TOKEN=$2; shift 2 ;;
    --state) need_value "$@"; STATE=$2; shift 2 ;;
    --scanner) need_value "$@"; SCANNER=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: bilinmeyen argüman: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "geçersiz IPv4: $IP"
[[ -x $SCANNER ]] || die "tarayıcı çalıştırılabilir değil: $SCANNER"

mkdir -p -- "$STATE" 2>/dev/null || die "durum dizini açılamadı: $STATE"
ROOT=$(mktemp -d "$STATE/zifiri-negative.XXXXXX") || die "geçici dizin açılamadı: $STATE"

PLANT_PIDS=()
# shellcheck disable=SC2329  # trap ile çağrılıyor
cleanup() {
  local pid
  if ((${#PLANT_PIDS[@]})); then
    for pid in "${PLANT_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  fi
  if ((KEEP)); then
    printf '%s: bitkiler bırakıldı: %s\n' "$PROG" "$ROOT" >&2
    if ((${#PLANT_PIDS[@]})); then
      printf '%s: canlı süreç: %s (kill ile temizle)\n' "$PROG" "${PLANT_PIDS[*]}" >&2
    fi
  else
    rm -rf -- "$ROOT"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- tarayıcı çağrısı

# run_scan <kök> <isabet dosyası> <ek bayraklar...>
# Çıkış kodu global SCAN_RC'ye yazılır; betiğin kendisi ölmez.
SCAN_RC=0
run_scan() {
  local root=$1 hits=$2
  shift 2
  local -a flags=()
  if ((VERBOSE)); then flags+=(--verbose); fi
  : >"$hits"
  SCAN_RC=0
  "$SCANNER" --root "$root" --hits-file "$hits" \
    --ip "$IP" --token "$TOKEN" "${flags[@]}" "$@" >"$ROOT/scan.log" 2>&1 || SCAN_RC=$?
  vlog "tarama $root -> exit $SCAN_RC"
  return 0
}

hits_count() {
  if [[ -s $1 ]]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi
}

# awk yok: sözleşme yalnız bash + coreutils + grep + python3 diyor.
has_hit() {
  local hits=$1 want_form=$2 want_path=$3 form path
  if [[ ! -s $hits ]]; then return 1; fi
  while IFS=$'\t' read -r form path _; do
    if [[ $form == "$want_form" && $path == "$want_path" ]]; then return 0; fi
  done <"$hits"
  return 1
}

printf '\n== negatif kontrol: canary tarayıcısı kör mü? ==\n'
printf 'IP        : %s\n' "$IP"
printf 'tarayıcı  : %s\n' "$SCANNER"
printf 'bitki kökü: %s\n\n' "$ROOT"

FAILURES=0

# ---------------------------------------------------------------- 1) yanlış pozitif

BASE=$ROOT/baseline
mkdir -p -- "$BASE"
# Komşu IP: desen "172.31.77.7" ise bunu YAKALAMAMALI.
printf 'masum satır, komşu adres %s.70 ve %s0 burada geçiyor\n' "${IP%.*}" "$IP" >"$BASE/decoy.log"
printf 'another line mentioning %s.70 and 10.0.0.1\n' "${IP%.*}" >>"$BASE/decoy.log"

run_scan "$BASE" "$ROOT/hits-baseline.tsv" --no-proc-env
base_hits=$(hits_count "$ROOT/hits-baseline.tsv")
vlog "baseline isabet: $base_hits"

if ((base_hits == 0)) && ((SCAN_RC == 0)); then
  printf '  [PASS] yanlış pozitif yok: masum dosya (%s.70) isabet üretmedi\n' "${IP%.*}"
else
  printf '  [FAIL] yanlış pozitif: %s isabet, exit %s (masum dosya taranmamalı)\n' "$base_hits" "$SCAN_RC"
  if [[ -s $ROOT/hits-baseline.tsv ]]; then
    while IFS= read -r line; do printf '         %s\n' "$line"; done <"$ROOT/hits-baseline.tsv"
  fi
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------- 2) bitkiler

PLANT=$ROOT/plant
mkdir -p -- "$PLANT/var/log/nginx" "$PLANT/var/lib/docker/containers"

# A) düz metin: nginx erişim kaydı
ACCESS=$PLANT/var/log/nginx/access.log
printf '%s - - [22/Nov/2026:16:41:02 +0000] "POST /api/posts HTTP/1.1" 201 812 "-" "%s"\n' \
  "$IP" "$TOKEN" >"$ACCESS"
printf '%s - - [22/Nov/2026:16:41:03 +0000] "GET /feed HTTP/1.1" 200 900 "-" "curl/8.5"\n' \
  "$IP" >>"$ACCESS"

# B) JSON log: docker json-file sürücüsünün yazdığı biçim
CID=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
JSONLOG=$PLANT/var/lib/docker/containers/$CID/$CID-json.log
mkdir -p -- "$PLANT/var/lib/docker/containers/$CID"
printf '{"log":"2026-11-22T16:41:02.113000000Z POST /api/posts from %s ua=%s\\n","stream":"stdout","time":"2026-11-22T16:41:02.113000000Z"}\n' \
  "$IP" "$TOKEN" >"$JSONLOG"
printf '{"log":"2026-11-22T16:41:03.004000000Z GET /feed 200\\n","stream":"stdout","time":"2026-11-22T16:41:03.004000000Z"}\n' \
  >>"$JSONLOG"

# C) ortam değişkeni: diske hiç yazılmaz, yalnız /proc/<pid>/environ içinde durur
CANARY_IP="$IP" ZIFIRI_CANARY="$TOKEN" HTTP_X_FORWARDED_FOR="$IP" \
  sleep "$SLEEP_SECONDS" >/dev/null 2>&1 &
ENV_PID=$!
PLANT_PIDS+=("$ENV_PID")
vlog "ortam bitkisi pid=$ENV_PID"

# Süreç ortamı okunabilir olana kadar bekle (en çok 5 sn).
waited=0
while ((waited < 50)); do
  if [[ -r /proc/$ENV_PID/environ ]] && grep -aqF -e "$IP" "/proc/$ENV_PID/environ" 2>/dev/null; then
    break
  fi
  sleep 0.1
  waited=$((waited + 1))
done
if [[ ! -r /proc/$ENV_PID/environ ]]; then
  printf '  [FAIL] ortam bitkisi kurulamadı: /proc/%s/environ okunamıyor\n' "$ENV_PID"
  printf '         (bu çekirdek /proc/<pid>/environ sunmuyor; ortam ayağı ölçülemez)\n'
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------- 3) tarama

run_scan "$PLANT" "$ROOT/hits-plant.tsv"
plant_hits=$(hits_count "$ROOT/hits-plant.tsv")
vlog "bitki isabet: $plant_hits, exit $SCAN_RC"

if ((SCAN_RC == 1)); then
  printf '  [PASS] tarayıcı kırmızı döndü (exit 1)\n'
else
  printf '  [FAIL] tarayıcı bitkileri görünce exit 1 dönmeliydi, döndü: %s\n' "$SCAN_RC"
  FAILURES=$((FAILURES + 1))
fi

check_plant() {
  local label=$1 form=$2 path=$3
  if has_hit "$ROOT/hits-plant.tsv" "$form" "$path"; then
    printf '  [PASS] %-28s bulundu (%s)\n' "$label" "$form"
    return 0
  fi
  printf '  [FAIL] %-28s BULUNAMADI (%s, %s)\n' "$label" "$form" "$path"
  FAILURES=$((FAILURES + 1))
  return 0
}

check_plant 'A düz metin (access.log)' ip-plain "$ACCESS"
check_plant 'B JSON log (docker)' ip-plain "$JSONLOG"
check_plant 'C ortam (/proc/PID/environ)' ip-plain "/proc/$ENV_PID/environ"

# ---------------------------------------------------------------- 4) karar

printf '\n'
if ((FAILURES == 0)); then
  printf 'SONUÇ: KONTROL GEÇTİ — tarayıcı üç bitkiyi de buldu, masumu bulmadı.\n'
  printf '       Bu makinede canary_scan.sh sonucu kanıt sayılabilir.\n'
  printf '       (isabet: %s satır; ayrıntı: %s)\n' "$plant_hits" "$ROOT/hits-plant.tsv"
  if ((KEEP)); then
    printf '       --keep: bitkiler duruyor, elle bakabilirsin.\n'
  fi
  exit 0
fi

printf 'SONUÇ: KONTROL BAŞARISIZ — %d kontrol düştü.\n' "$FAILURES"
printf '       Tarayıcı kör. Bu makinede alınan "temiz" sonuç kanıt değildir.\n'
printf '       Tarayıcı günlüğü: %s\n' "$ROOT/scan.log"
if [[ -s $ROOT/scan.log ]]; then
  printf '\n--- tarayıcı çıktısı (son 20 satır) ---\n'
  tail -n 20 "$ROOT/scan.log"
fi
exit 1
