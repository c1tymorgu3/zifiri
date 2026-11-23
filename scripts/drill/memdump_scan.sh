#!/usr/bin/env bash
# shellcheck shell=bash
#
# memdump_scan.sh — zifiri el koyma tatbikatı, ayak 2 (bellek dökümü)
#
# Trafik kesildikten sonra bekler, nginx worker'larını yeniler, BEAM ve
# nginx süreçlerinin belleğini gcore ile döker ve dökümlerde canary arar.
#
# Neden worker yenileme: eski nginx worker'ları istek sırasında istemci
# adresini tamponlarında tutmuş olabilir. Yenileme onları öldürür; yeni
# worker'lar hiç trafik görmediği için temiz olmalıdır. BEAM tarafında
# canary IP hiç görünmemelidir (unix soket + başlık boşaltma, §5.1).
#
# Gereksinim: gdb (gcore), coreutils. gcore yoksa betik sessizce geçmez,
# açık hata verir ve exit 2 döner.
#
set -euo pipefail

PROG=${0##*/}
CANARY_IP=${CANARY_IP:-172.31.77.7}
QUIET_SECONDS=${DRILL_QUIET_SECONDS:-60}
OUT=${DRILL_OUT:-/run/zifiri-drill}
TOKEN=${CANARY_TOKEN:-}
KEEP=auto
DO_RELOAD=1
INCLUDE_OLD=0
DRY_RUN=0
NGINX_RELOAD_CMD=${NGINX_RELOAD_CMD:-}
EXEC_PREFIX=${DRILL_EXEC_PREFIX:-}
EXEC=()
VERBOSE=0

usage() {
  cat <<EOF
$PROG — el koyma tatbikatı, ayak 2: bellek dökümü taraması

Kullanım:
  $PROG [seçenekler]

Seçenekler:
  --quiet-seconds N   Trafik kesildikten sonra beklenecek saniye (varsayılan: $QUIET_SECONDS)
  --out DIZIN         Dökümlerin yazılacağı dizin (varsayılan: $OUT)
  --keep              Dökümleri yeşil olsa da silme
  --no-reload         nginx worker'larını yenileme (eski worker'lar taranır)
  --include-old       Yenilenemeyen eski worker'ları da dök (kırmızıya yol açar)
  --dry-run           Sadece ne yapılacağını yazdır
  --ip ADRES          Test ağı IP'si
  -v, --verbose       Ayrıntılı: süreçler, döküm boyutları, her tarama adımı
  -h, --help          Bu metin

Ortam:
  CANARY_IP, CANARY_TOKEN, DRILL_QUIET_SECONDS, DRILL_OUT,
  NGINX_RELOAD_CMD, DRILL_EXEC_PREFIX

  DRILL_EXEC_PREFIX: komutları container içinde çalıştırmak için,
  örn. DRILL_EXEC_PREFIX="docker exec -u root zifiri-app"
  NGINX_RELOAD_CMD: varsayılan 'nginx -s reload' yerine kullanılacak komut.

Çıkış kodları:
  0  yeşil: dökümlerde canary IP yok
  1  kırmızı: canary IP dökümde bulundu
  2  kanıtlanmadı: gcore yok, reload başarısız, döküm alınamadı
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: uyarı: %s\n' "$PROG" "$*" >&2; }
vlog() { if ((VERBOSE)); then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

while (($#)); do
  case $1 in
    --quiet-seconds) QUIET_SECONDS=${2:-}; shift 2 || die "değer eksik" ;;
    --out) OUT=${2:-}; shift 2 || die "değer eksik" ;;
    --keep) KEEP=yes; shift ;;
    --no-reload) DO_RELOAD=0; shift ;;
    --include-old) INCLUDE_OLD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --ip) CANARY_IP=${2:-}; shift 2 || die "değer eksik" ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: bilinmeyen argüman: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $QUIET_SECONDS =~ ^[0-9]+$ ]] || die "geçersiz saniye: $QUIET_SECONDS"
[[ $CANARY_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "geçersiz IPv4: $CANARY_IP"

if [[ -n $EXEC_PREFIX ]]; then
  # shellcheck disable=SC2206
  EXEC=($EXEC_PREFIX)
fi
run() { "${EXEC[@]}" "$@"; }

# ---------------------------------------------------------------- ön koşullar

if ((DRY_RUN == 0)) && ! command -v gcore >/dev/null 2>&1 && [[ -z $EXEC_PREFIX ]]; then
  die "gcore bulunamadı. gdb kur (Debian/Ubuntu: apt install gdb) ya da
     DRILL_EXEC_PREFIX ile container içinde çalıştır. Sessizce geçmek yok:
     bellek kanıtı olmadan tatbikat yeşil sayılmaz."
fi
if [[ -n $EXEC_PREFIX ]] && ((DRY_RUN == 0)); then
  run sh -c 'command -v gcore >/dev/null' ||
    die "gcore $EXEC_PREFIX içinde yok. Container'a gdb kur ya da dökümü host'tan al."
fi

if [[ $EUID -ne 0 ]]; then
  SCOPE=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || printf '0')
  if [[ $SCOPE != 0 ]]; then
    warn "yama/ptrace_scope=$SCOPE; gcore başarısız olabilir (root ya da aynı kullanıcı gerekir)"
  fi
fi

IFS=. read -r O1 O2 O3 O4 <<<"$CANARY_IP"
TUPLE="{$O1,$O2,$O3,$O4}"
PLAIN_RE="(^|[^0-9.])${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"
MAPPED_RE="::ffff:${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"

if [[ -z $TOKEN ]]; then
  TOKEN=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ -n $TOKEN ]] || TOKEN=$(python3 -c 'import os;print(os.urandom(16).hex())' 2>/dev/null)
  TOKEN="zifiri-canary-${TOKEN:-00000000000000000000000000000000}"
  warn "CANARY_TOKEN verilmedi; gövde canary'si anlamsız (yalnız IP aranır)"
  SCAN_TOKEN=0
else
  SCAN_TOKEN=1
fi

# ---------------------------------------------------------------- bekleme

printf '\n== bellek dökümü taraması ==\n'
printf 'IP            : %s\n' "$CANARY_IP"
printf 'bekleme       : %s sn (trafik kesilmiş olmalı)\n' "$QUIET_SECONDS"
if ((DRY_RUN)); then
  printf 'kip           : dry-run, hiçbir şey yapılmadı\n'
fi
if ((DRY_RUN == 0 && QUIET_SECONDS > 0)); then
  sleep "$QUIET_SECONDS"
fi

# ---------------------------------------------------------------- nginx reload

mapfile -t OLD_WORKERS < <(run pgrep -f 'nginx: worker process' 2>/dev/null || true)
RELOAD_STATUS="atlandı"
if ((DO_RELOAD)); then
  if ((DRY_RUN)); then
    RELOAD_STATUS="dry-run"
  elif [[ -n $NGINX_RELOAD_CMD ]]; then
    if $NGINX_RELOAD_CMD >/dev/null 2>&1; then RELOAD_STATUS="tamam (özel komut)"; else RELOAD_STATUS="BAŞARISIZ"; fi
  elif run nginx -s reload >/dev/null 2>&1; then
    RELOAD_STATUS="tamam"
  elif command -v systemctl >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
    RELOAD_STATUS="tamam (systemctl)"
  else
    RELOAD_STATUS="BAŞARISIZ"
  fi

  if [[ $RELOAD_STATUS == BAŞARISIZ ]]; then
    printf 'nginx reload  : BAŞARISIZ\n'
    die "nginx worker'ları yenilenemedi. NGINX_RELOAD_CMD ver (örn.
     NGINX_RELOAD_CMD='docker exec zifiri-app nginx -s reload') ya da
     --no-reload ile eski worker'ları bilerek tara."
  fi

  # Eski worker'ların çıkmasını bekle; çıkmazlarsa dökümleri yanıltıcı olur.
  if ((DRY_RUN == 0 && ${#OLD_WORKERS[@]} > 0)); then
    waited=0
    while ((waited < 30)); do
      alive=0
      for pid in "${OLD_WORKERS[@]}"; do
        run kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
      done
      ((alive == 0)) && break
      sleep 1
      waited=$((waited + 1))
    done
    if ((alive > 0)); then
      warn "eski nginx worker'ları hâlâ yaşıyor: $alive adet (drain 30 sn)"
      RELOAD_STATUS="$RELOAD_STATUS, drain eksik"
    fi
  fi
fi
printf 'nginx reload  : %s (eski worker: %d)\n' "$RELOAD_STATUS" "${#OLD_WORKERS[@]}"

# ---------------------------------------------------------------- süreçler

mapfile -t BEAM_PIDS < <(run pgrep -x beam.smp 2>/dev/null || true)
if ((${#BEAM_PIDS[@]} == 0)); then
  mapfile -t BEAM_PIDS < <(run pgrep -f 'beam.smp' 2>/dev/null || true)
fi

if ((DO_RELOAD)); then
  mapfile -t NGINX_PIDS < <(run pgrep -f 'nginx: worker process' 2>/dev/null || true)
  if ((${#NGINX_PIDS[@]} == 0)); then
    mapfile -t NGINX_PIDS < <(run pgrep -x nginx 2>/dev/null || true)
  fi
else
  NGINX_PIDS=("${OLD_WORKERS[@]}")
fi

if ((INCLUDE_OLD)) && ((${#OLD_WORKERS[@]})); then
  for pid in "${OLD_WORKERS[@]}"; do
    run kill -0 "$pid" 2>/dev/null && NGINX_PIDS+=("$pid")
  done
fi

if ((${#BEAM_PIDS[@]} == 0 && ${#NGINX_PIDS[@]} == 0)); then
  die "ne BEAM ne nginx süreci bulundu. Container içindeyse DRILL_EXEC_PREFIX ver."
fi

printf 'BEAM          : %s\n' "${BEAM_PIDS[*]:-(yok)}"
printf 'nginx         : %s\n' "${NGINX_PIDS[*]:-(yok)}"
vlog "reload durumu: $RELOAD_STATUS"
vlog "dökülecek: ${#BEAM_PIDS[@]} BEAM + ${#NGINX_PIDS[@]} nginx süreç"

# ---------------------------------------------------------------- yer kontrolü

mkdir -p -- "$OUT" 2>/dev/null || die "çıktı dizini açılamadı: $OUT"
if [[ -z $EXEC_PREFIX ]]; then
  FREE_KB=$(df -Pk "$OUT" 2>/dev/null | awk 'NR==2{print $4}' || true)
  vlog "disk: $OUT üzerinde ${FREE_KB:-?} KB boş"
  RSS_KB=0
  for pid in "${BEAM_PIDS[@]}" "${NGINX_PIDS[@]}"; do
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
    [[ -n $rss ]] && RSS_KB=$((RSS_KB + rss))
  done
  if [[ -n ${FREE_KB:-} && $FREE_KB -lt $((RSS_KB * 3 / 2)) ]]; then
    warn "$OUT üzerinde ${FREE_KB}KB boş, süreç RSS toplamı ${RSS_KB}KB. Döküm sığmayabilir."
  fi
fi

if ((DRY_RUN)); then
  printf 'dökümler      : (dry-run) %s\n\nSONUÇ: KANITLANMADI — dry-run.\n' "$OUT"
  exit 2
fi

# ---------------------------------------------------------------- döküm

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMPDIR=$OUT/memdump-$STAMP
mkdir -p -- "$DUMPDIR" || die "döküm dizini açılamadı: $DUMPDIR"

CORES=()
FAILED=0
dump_one() {
  local label=$1 pid=$2 out
  out=$DUMPDIR/$label
  if run gcore -o "$out" "$pid" >"$DUMPDIR/$label.gcore.log" 2>&1; then
    if [[ ! -f $out.$pid ]]; then
      # DRILL_EXEC_PREFIX ile gcore container içinde yazmış olabilir; o
      # durumda döküm host'tan okunamaz ve "temiz" sayılamaz.
      if [[ -n $EXEC_PREFIX ]] && run test -f "$out.$pid"; then
        die "döküm container içinde oluştu ama host'tan görünmüyor: $out.$pid
     $OUT dizinini container'a bind mount edin (docker run -v $OUT:$OUT)
     ya da dökümü host'tan al. Görünmeyen dökümü 'temiz' saymıyoruz."
      fi
      printf '  %-14s pid=%-7s BAŞARISIZ (döküm dosyası yok)\n' "$label" "$pid"
      FAILED=$((FAILED + 1))
      return 1
    fi
    CORES+=("$out.$pid")
    vlog "döküm yazıldı: $out.$pid"
    printf '  %-14s pid=%-7s %s\n' "$label" "$pid" "$(du -h "$out.$pid" 2>/dev/null | cut -f1)"
    return 0
  fi
  printf '  %-14s pid=%-7s BAŞARISIZ (%s)\n' "$label" "$pid" "$(tail -n 1 "$DUMPDIR/$label.gcore.log" 2>/dev/null)"
  FAILED=$((FAILED + 1))
  return 1
}

printf 'döküm dizini  : %s\n' "$DUMPDIR"
for pid in "${BEAM_PIDS[@]}"; do dump_one beam "$pid" || true; done
for pid in "${NGINX_PIDS[@]}"; do dump_one nginx "$pid" || true; done

((${#CORES[@]})) || die "hiçbir döküm alınamadı ($FAILED başarısız). gdb/ptrace izinlerini kontrol et."

# ---------------------------------------------------------------- tarama

RED=0
printf '\ndöküm taraması:\n'
for core in "${CORES[@]}"; do
  name=${core##*/}
  flags=()
  hit=0
  vlog "taranıyor: $core"

  if grep -aqE -e "$PLAIN_RE" "$core"; then flags+=("ip-plain"); hit=1; fi
  if grep -aqF -e "$TUPLE" "$core"; then flags+=("ip-tuple"); hit=1; fi
  if grep -aqE -e "$MAPPED_RE" "$core"; then flags+=("ip-mapped"); hit=1; fi

  if python3 - "$CANARY_IP" "$core" <<'PY'
import sys

ip, path = sys.argv[1], sys.argv[2]
needle = bytes(int(p) for p in ip.split("."))
chunk = 8 << 20
prev = b""
with open(path, "rb") as fh:
    while True:
        data = fh.read(chunk)
        if not data:
            break
        buf = prev + data
        if needle in buf:
            sys.exit(0)
        prev = buf[-(len(needle) - 1):]
sys.exit(1)
PY
  then
    flags+=("ip-raw")
    hit=1
  fi

  token_hit="yok"
  if ((SCAN_TOKEN)) && grep -aqF -e "$TOKEN" "$core"; then
    token_hit="VAR (bilgi: yayınlanmış içerik)"
  fi

  if ((hit)); then
    RED=$((RED + 1))
    printf '  %-28s KIRMIZI: %s | token: %s\n' "$name" "${flags[*]}" "$token_hit"
  else
    printf '  %-28s temiz | token: %s\n' "$name" "$token_hit"
  fi
done

# ---------------------------------------------------------------- temizlik

if ((RED == 0)) && [[ $KEEP != yes ]]; then
  rm -rf -- "$DUMPDIR"
  printf '\ndökümler silindi (yeşil). Saklamak için --keep.\n'
else
  printf '\ndökümler: %s\n' "$DUMPDIR"
fi

if ((RED > 0)); then
  printf '\nSONUÇ: KIRMIZI — %d dökümde canary IP var. Tatbikat başarısız.\n' "$RED"
  exit 1
fi
if ((FAILED > 0)); then
  printf '\nSONUÇ: KANITLANMADI — %d süreç dökülemedi, tarama eksik.\n' "$FAILED"
  exit 2
fi
printf '\nSONUÇ: YEŞİL — %d dökümde canary IP yok.\n' "${#CORES[@]}"
exit 0
