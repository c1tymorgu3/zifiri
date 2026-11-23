#!/usr/bin/env bash
# shellcheck shell=bash
#
# verify_onion.sh — onion/clearnet iddia denetimi
#
# Ne yapar: `nginx -T` (tam çözülmüş yapılandırma) çıktısını server bloklarına
# ayırır ve mod başına iddianın dayandığı satırların gerçekten orada olduğunu
# denetler:
#
#   1. `access_log off`        — her proxy bloğunda; hiçbir yerde dosya logu yok
#   2. `proxy_set_header X-Forwarded-For ""` — her proxy bloğunda (IP sızmasın)
#   3. `Onion-Location`        — YALNIZ clearnet bloğunda, onion bloğunda değil
#   4. `real_ip` / `set_real_ip_from` / `proxy_protocol` — hiçbir yerde yok
#
# Neden `nginx -T`: şablon değil, nginx'in gerçekten yüklediği ağaç denetlenir;
# include'lar, http düzeyi ve server blokları tek akışta görünür.
#
# Çıkış kodları:
#   0  tüm denetimler geçti
#   1  en az bir denetim düştü (eksik satır adıyla yazılır)
#   2  kullanım hatası
#   3  nginx bulunamadı (sessiz geçiş YOK — doğrulanmamış iddia yeşil sayılmaz)
#
# Yalnız bash + awk + grep. `--docker` ile konteynerdeki nginx denetlenir.

set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=

NGINX_BIN=${NGINX_BIN:-nginx}
CONFIG=
USE_DOCKER=0
COMPOSE_FILE=${COMPOSE_FILE:-$SELF_DIR/../infra/docker-compose.yml}
VERBOSE=0

FAILS=0
CHECKS=0
TMPDIR_V=

usage() {
  cat <<EOF
$PROG — onion/clearnet iddia denetimi (nginx -T üzerinden)

Kullanım:
  $PROG [seçenekler]

Seçenekler:
  --config DOSYA    Şablon yerine bu dosyayı denetle: \`nginx -T -c DOSYA\`
                    (render edilmiş nginx.conf.rendered için)
  --nginx YOL       nginx ikilisi (varsayılan: \$NGINX_BIN veya PATH'teki nginx)
  --docker          Konteynerdeki nginx'i denetle:
                    docker compose -f <compose> exec -T nginx nginx -T
  --compose DOSYA   --docker için compose dosyası
                    (varsayılan: $COMPOSE_FILE)
  -v, --verbose     Denetlenen her satırı da yazdır
  -h, --help        Bu metin

Denetimler:
  * her proxy bloğunda \`access_log off;\`
  * her proxy bloğunda \`proxy_set_header X-Forwarded-For "";\`
  * \`Onion-Location\` yalnız clearnet (443) bloğunda
  * hiçbir yerde \`real_ip\`, \`set_real_ip_from\`, \`proxy_protocol\`

Çıkış kodları: 0 geçti · 1 denetim düştü · 2 kullanım hatası · 3 nginx yok

Örnek:
  $PROG --config infra/nginx.conf.rendered
  $PROG --docker
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'Yardım: %s --help\n' "$PROG" >&2
  exit 2
}

cleanup() {
  # EXIT tuzağının son komutu çıkış kodunu ezer; her zaman 0 dön.
  if [ -n "$TMPDIR_V" ]; then rm -rf -- "$TMPDIR_V"; fi
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case $1 in
    --config)   [ $# -ge 2 ] || die_usage "--config değer ister"; CONFIG=$2; shift 2 ;;
    --config=*) CONFIG=${1#*=}; shift ;;
    --nginx)    [ $# -ge 2 ] || die_usage "--nginx değer ister"; NGINX_BIN=$2; shift 2 ;;
    --nginx=*)  NGINX_BIN=${1#*=}; shift ;;
    --docker)   USE_DOCKER=1; shift ;;
    --compose)  [ $# -ge 2 ] || die_usage "--compose değer ister"; COMPOSE_FILE=$2; shift 2 ;;
    --compose=*) COMPOSE_FILE=${1#*=}; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die_usage "bilinmeyen argüman: $1" ;;
  esac
done

ok()   { CHECKS=$((CHECKS + 1)); printf '  ok    %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  EKSİK %s\n' "$1" >&2; }
note() { [ "$VERBOSE" -eq 1 ] && printf '        %s\n' "$1" || true; }

# --- nginx'i bul ----------------------------------------------------------
DUMP=
if [ "$USE_DOCKER" -eq 1 ]; then
  command -v docker >/dev/null 2>&1 || {
    printf '%s: nginx bulunamadı — docker da yok, konteyner denetimi yapılamaz\n' "$PROG" >&2
    exit 3
  }
  [ -f "$COMPOSE_FILE" ] || {
    printf '%s: compose dosyası yok: %s\n' "$PROG" "$COMPOSE_FILE" >&2
    exit 3
  }
  printf '%s: konteynerdeki nginx denetleniyor (%s)\n' "$PROG" "$COMPOSE_FILE"
  if ! DUMP=$(docker compose -f "$COMPOSE_FILE" exec -T nginx nginx -T 2>&1); then
    printf '%s: nginx bulunamadı — konteyner çalışmıyor ya da imajda nginx yok\n' "$PROG" >&2
    printf '%s\n' "$DUMP" | tail -n 5 >&2
    exit 3
  fi
else
  if ! command -v "$NGINX_BIN" >/dev/null 2>&1; then
    printf '%s: nginx bulunamadı (%s) — bu makinede denetim yapılamaz.\n' "$PROG" "$NGINX_BIN" >&2
    printf '%s: iddia DOĞRULANMADI; --docker ile konteyneri ya da --config ile render edilmiş dosyayı dene.\n' "$PROG" >&2
    exit 3
  fi
  printf '%s: %s -T çalıştırılıyor\n' "$PROG" "$NGINX_BIN"
  if [ -n "$CONFIG" ]; then
    [ -f "$CONFIG" ] || { printf '%s: dosya yok: %s\n' "$PROG" "$CONFIG" >&2; exit 2; }
    if ! DUMP=$("$NGINX_BIN" -T -c "$CONFIG" 2>&1); then
      printf '%s: nginx -T başarısız (yapılandırma geçersiz):\n' "$PROG" >&2
      printf '%s\n' "$DUMP" | tail -n 10 >&2
      exit 1
    fi
  else
    if ! DUMP=$("$NGINX_BIN" -T 2>&1); then
      printf '%s: nginx -T başarısız (yapılandırma geçersiz):\n' "$PROG" >&2
      printf '%s\n' "$DUMP" | tail -n 10 >&2
      exit 1
    fi
  fi
fi

[ -n "$DUMP" ] || { printf '%s: nginx -T boş çıktı verdi\n' "$PROG" >&2; exit 3; }

TMPDIR_V=$(mktemp -d "${TMPDIR:-/tmp}/verify_onion.XXXXXX")
ALL=$TMPDIR_V/all.conf
# Yorum satırları atılır: denetimler yalnız ETKİN direktiflere bakar. Aksi
# hâlde "Onion-Location YOK" gibi bir açıklama, denetimi yanlış yönde tetikler.
printf '%s\n' "$DUMP" | sed -E '/^[[:space:]]*#/d' > "$ALL"

# --- server bloklarını ayır ----------------------------------------------
# `nginx -T` her dosyayı "# configuration file ..." başlığıyla basar; blok
# sınırları süslü parantez sayımıyla bulunur. nginx tek satırda blok açmaz
# (üretilen ağaçta `server {` kendi satırındadır), bu yüzden sayım yeterli.
awk -v out="$TMPDIR_V" '
  function brace_count(s,   t, o, c) { t = s; o = gsub(/\{/, "", t); c = gsub(/\}/, "", t); return o - c }
  /^[[:space:]]*server[[:space:]]*\{[[:space:]]*$/ && !inb {
    inb = 1; n++; f = sprintf("%s/srv.%03d.conf", out, n); depth = 0
  }
  inb {
    print >> f
    depth += brace_count($0)
    if (depth <= 0) { inb = 0; close(f) }
  }
' "$ALL"

SRV_FILES=("$TMPDIR_V"/srv.*.conf)
if [ ! -e "${SRV_FILES[0]}" ]; then
  printf '%s: hiç server bloğu bulunamadı — yapılandırma beklenen biçimde değil\n' "$PROG" >&2
  exit 1
fi

PROXY_BLOCKS=0
ONION_BLOCKS=0
CLEARNET_BLOCKS=0

for f in "${SRV_FILES[@]}"; do
  name=$(basename -- "$f" .conf)
  listens=$(grep -Eo '^[[:space:]]*listen[[:space:]]+[^;]+' "$f" | awk '{print $2}' | paste -sd, - || true)
  sname=$(grep -Eo '^[[:space:]]*server_name[[:space:]]+[^;]+' "$f" | sed -E 's/^[[:space:]]*server_name[[:space:]]+//' | paste -sd, - || true)
  label="$name (listen=$listens server_name=$sname)"

  is_proxy=0
  grep -qE '^[[:space:]]*proxy_pass[[:space:]]' "$f" && is_proxy=1
  is_onion=0
  printf '%s' "$listens" | grep -q '8081' && is_onion=1
  is_clearnet=0
  printf '%s' "$listens" | grep -qE '(^|,)443($|,)' && is_clearnet=1

  if [ "$is_proxy" -eq 1 ]; then
    PROXY_BLOCKS=$((PROXY_BLOCKS + 1))
    printf '%s:\n' "$label"

    if grep -qE '^[[:space:]]*access_log[[:space:]]+off;' "$f"; then
      ok "access_log off"
    else
      fail "$label — 'access_log off;' yok (erişim logu açık kalabilir)"
    fi

    if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]+"";' "$f"; then
      ok 'proxy_set_header X-Forwarded-For ""'
    else
      fail "$label — 'proxy_set_header X-Forwarded-For \"\";' yok (istemci IP'si BEAM'e geçer)"
    fi

    if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+X-Real-IP[[:space:]]+"";' "$f"; then
      ok 'proxy_set_header X-Real-IP ""'
    else
      fail "$label — 'proxy_set_header X-Real-IP \"\";' yok"
    fi

    if grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+Accept-Encoding[[:space:]]+"";' "$f"; then
      ok 'proxy_set_header Accept-Encoding ""'
    else
      fail "$label — 'proxy_set_header Accept-Encoding \"\";' yok (kova boyutu bozulur)"
    fi
  fi

  if [ "$is_onion" -eq 1 ]; then
    ONION_BLOCKS=$((ONION_BLOCKS + 1))
    if grep -qE '^[[:space:]]*add_header[[:space:]]+Onion-Location' "$f"; then
      fail "$label — onion bloğunda 'Onion-Location' var (yalnız clearnet'te olmalı)"
    else
      ok "onion bloğunda Onion-Location yok"
    fi
    if grep -qE '^[[:space:]]*access_log[[:space:]]+off;' "$f"; then
      : # proxy bloğuysa yukarıda sayıldı; değilse burada doğrulandı
      [ "$is_proxy" -eq 1 ] || ok "access_log off"
    else
      [ "$is_proxy" -eq 1 ] || fail "$label — 'access_log off;' yok"
    fi
  fi

  if [ "$is_clearnet" -eq 1 ]; then
    CLEARNET_BLOCKS=$((CLEARNET_BLOCKS + 1))
    # Render sonrası değer .onion adresidir; şablon değişkeni değil, biçim
    # denetlenir: add_header Onion-Location "http://<adres><yol>" always;
    if grep -qE '^[[:space:]]*add_header[[:space:]]+Onion-Location[[:space:]]+"http://[^"]+"[[:space:]]+always;' "$f"; then
      ok "clearnet bloğunda Onion-Location"
    else
      fail "$label — 'add_header Onion-Location \"http://<onion-adresi>\" always;' yok (§11.3 duyurusu düşer)"
    fi
  fi
done

printf 'http düzeyi:\n'
if grep -qE '^[[:space:]]*access_log[[:space:]]+off;' "$ALL"; then
  ok "access_log off (en az bir yerde etkin)"
else
  fail "http düzeyi — 'access_log off;' hiç yok"
fi

BAD_LOG=$(awk '/^[[:space:]]*access_log[[:space:]]/ && $0 !~ /^[[:space:]]*access_log[[:space:]]+off[[:space:]]*;/ {print NR": "$0}' "$ALL" | head -n 3 | paste -sd';' - || true)
if [ -n "$BAD_LOG" ]; then
  fail "bir yerde dosya/hedef logu tanımlı: $BAD_LOG"
else
  ok "hiçbir yerde dosya logu tanımlı değil"
fi

if grep -qE '^[[:space:]]*(real_ip_header|set_real_ip_from)\b|proxy_protocol' "$ALL"; then
  fail "real_ip / set_real_ip_from / proxy_protocol kullanılıyor — XFF'ye güvenilir, IP sızabilir"
else
  ok "real_ip / proxy_protocol yok"
fi

if grep -q 'proxy_set_header[[:space:]]*X-Forwarded-For' "$ALL"; then
  xff=$(grep -cE '^[[:space:]]*proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]+"";' "$ALL" || true)
  if [ "$xff" -ge "$PROXY_BLOCKS" ] && [ "$PROXY_BLOCKS" -gt 0 ]; then
    ok "X-Forwarded-For boşaltması $xff/$PROXY_BLOCKS proxy bloğunda"
  else
    fail "X-Forwarded-For boşaltması $xff satırda, $PROXY_BLOCKS proxy bloğu var"
  fi
else
  fail "hiçbir yerde 'proxy_set_header X-Forwarded-For \"\";' yok"
fi

if [ "$ONION_BLOCKS" -eq 0 ]; then
  fail "onion bloğu yok (listen 127.0.0.1:8081) — onion iddiası yapılandırmada karşılıksız"
fi
if [ "$CLEARNET_BLOCKS" -eq 0 ]; then
  fail "clearnet 443 bloğu yok"
fi

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%s: DÜŞTÜ — %d/%d denetim başarısız. Onion/clearnet iddiası bu yapılandırmada savunulamaz.\n' \
    "$PROG" "$FAILS" "$CHECKS" >&2
  exit 1
fi

printf '%s: geçti — %d denetim (proxy bloğu: %d, onion: %d, clearnet: %d)\n' \
  "$PROG" "$CHECKS" "$PROXY_BLOCKS" "$ONION_BLOCKS" "$CLEARNET_BLOCKS"
