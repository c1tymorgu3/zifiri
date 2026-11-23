#!/usr/bin/env bash
# shellcheck shell=bash
#
# canary_scan.sh — zifiri el koyma tatbikatı, ayak 1 (disk imajı)
#
# Ne yapar: sabit bir test ağı IP'sini ve rastgele bir canary dizgesini
# diskte ve süreç ortamlarında arar. IP dört biçimde aranır:
#
#   1. düz metin          172.31.77.7
#   2. Erlang tuple        {172,31,77,7}
#   3. ham dört bayt       (grep -a, bayt deseni; ikili dosyalar)
#   4. IPv4-mapped IPv6    ::ffff:172.31.77.7
#
# Taranan yerler (varsayılan): /var/lib/docker (container json log dahil),
# $ZIFIRI_DB_DIR/*.db + *.db-wal + *.db-shm, /tmp, /proc/*/environ,
# journald (journalctl --since).
#
# Tüm grep çağrıları `-a` ile yapılır: WAL/SHM, container json log ve core
# dosyaları ikilidir; `-a` olmadan grep "binary file matches" der ve satır
# bağlamını kaybeder. Dosya boyutu bir tarama sınırı değildir
# (DRILL_MAX_SCAN_BYTES yalnız ham bayt aşamasını sınırlar).
#
# Tek isabet = kırmızı (exit 1).
#
# Yalnız coreutils + grep kullanır. Bash 4.4+ (mapfile -d).
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=

CANARY_IP=${CANARY_IP:-172.31.77.7}
SINCE=${DRILL_SINCE:-"2 hours ago"}
DB_DIR=${ZIFIRI_DB_DIR:-/var/lib/zifiri}
DOCKER_ROOT=${DRILL_DOCKER_ROOT:-/var/lib/docker}
TMP_ROOT=${DRILL_TMP_ROOT:-/tmp}
MAX_BYTES=${DRILL_MAX_SCAN_BYTES:-0}
TOKEN=${CANARY_TOKEN:-}
MODE=full
VERBOSE=0
ROOTS=()
ROOTS_EXPLICIT=0
FORCE_JOURNALD=0
SCAN_PROC_ENV=1
HITS_FILE=

usage() {
  cat <<EOF
$PROG — el koyma tatbikatı, ayak 1: canary taraması

Kullanım:
  $PROG [seçenekler]
  $PROG --root DIZIN [--root DIZIN...]      (hedefli tarama)

Seçenekler:
  --ip ADRES        Test ağı IP'si (varsayılan: $CANARY_IP)
  --token DIZGE     Kullanılacak canary dizgesi (varsayılan: üretilir)
  --since ZAMAN     journalctl --since değeri (varsayılan: "$SINCE")
  --root DIZIN      Ek taranacak dizin (tekrarlanabilir)
  --docker-root D   Docker veri dizini (varsayılan: $DOCKER_ROOT)
  --db-dir D        Yayınlanmış DB dizini (varsayılan: $DB_DIR)
  --tmp-root D      Geçici dosya kökü (varsayılan: $TMP_ROOT)
  --max-bytes N     Ham bayt aşamasında dosya başına üst sınır (0 = sınırsız)
  --hits-file F     İsabetleri makine okunur biçimde F dosyasına yaz
                    (satır: form<TAB>yol<TAB>kirmizi|bilgi)
  --emit            Yalnız canary üret, gönderim örneğini yazdır, çık
  --ip-only         Yalnız IP biçimlerini ara
  --token-only      Yalnız gövde canary'sini ara
  --no-proc-env     /proc/*/environ taranmasın
  --journald        --root verilmiş olsa da journald'ı tara
  -v, --verbose     Ne taranıyor, kaç dosya, hangi aşama — ayrıntılı
  -h, --help        Bu metin

Ortam değişkenleri:
  CANARY_IP, CANARY_TOKEN, DRILL_SINCE, DRILL_STATE_DIR,
  DRILL_MAX_SCAN_BYTES, ZIFIRI_DB_DIR, DRILL_DOCKER_ROOT, DRILL_TMP_ROOT

Kapsam kuralı:
  --root verilmezse docker + DB + $TMP_ROOT + journald taranır.
  --root verilirse YALNIZ verilen kökler taranır; docker/DB/journald
  otomatik denetimleri kapanır (journald için --journald). Bu, hedefli
  (negatif kontrol) tarama içindir; tatbikat raporunda tam tarama gerekir.

Çıkış kodları:
  0  yeşil: hiçbir yerde canary yok
  1  kırmızı: en az bir isabet
  2  kanıtlanmadı: tarama eksik kaldı (journald yok, izin yok, boş test)
  3  ortam eksik: docker yok — disk ayağının bir kısmı taranamadı

  3 yeşil değildir. Sessizce geçen tatbikat, kırmızıdan daha kötüdür.

Örnek:
  # 1) canary üret, trafiği gönder
  $PROG --emit
  # 2) aynı canary ile tara
  CANARY_TOKEN=zifiri-canary-... $PROG
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: uyarı: %s\n' "$PROG" "$*" >&2; }
vlog() { if ((VERBOSE)); then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

need_value() {
  if (($# >= 2)) && [[ -n $2 ]]; then return 0; fi
  die "$1 değer istiyor"
}

while (($#)); do
  case $1 in
    --ip) need_value "$@"; CANARY_IP=$2; shift 2 ;;
    --token) need_value "$@"; TOKEN=$2; shift 2 ;;
    --since) need_value "$@"; SINCE=$2; shift 2 ;;
    --root) need_value "$@"; ROOTS+=("$2"); ROOTS_EXPLICIT=1; shift 2 ;;
    --docker-root) need_value "$@"; DOCKER_ROOT=$2; shift 2 ;;
    --db-dir) need_value "$@"; DB_DIR=$2; shift 2 ;;
    --tmp-root) need_value "$@"; TMP_ROOT=$2; shift 2 ;;
    --max-bytes) need_value "$@"; MAX_BYTES=$2; shift 2 ;;
    --hits-file) need_value "$@"; HITS_FILE=$2; shift 2 ;;
    --emit) MODE=emit; shift ;;
    --ip-only) MODE=ip; shift ;;
    --token-only) MODE=token; shift ;;
    --no-proc-env) SCAN_PROC_ENV=0; shift ;;
    --journald) FORCE_JOURNALD=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    *) printf '%s: bilinmeyen argüman: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done
while (($#)); do ROOTS+=("$1"); ROOTS_EXPLICIT=1; shift; done

# ---------------------------------------------------------------- doğrulama

valid_ipv4() {
  local ip=$1 octet
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    ((10#$octet <= 255)) || return 1
  done
  return 0
}

valid_ipv4 "$CANARY_IP" || die "geçersiz IPv4: $CANARY_IP"
[[ $MAX_BYTES =~ ^[0-9]+$ ]] || die "DRILL_MAX_SCAN_BYTES sayı olmalı: $MAX_BYTES"

IFS=. read -r O1 O2 O3 O4 <<<"$CANARY_IP"
TUPLE="{$O1,$O2,$O3,$O4}"
MAPPED="::ffff:$CANARY_IP"
# Düz IP: kendisinden sonra rakam gelmeyen eşleşme (172.31.77.70 yanlış pozitif olmasın).
PLAIN_RE="(^|[^0-9.])${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"
MAPPED_RE="::ffff:${O1}\.${O2}\.${O3}\.${O4}([^0-9]|$)"
# Ham bayt deseni: 172.31.77.7 -> \xac\x1f\x4d\x07. grep deseni NUL ya da
# satır sonu baytı içeremez; öyle bir IP verilirse aşama atlanır (sessizce değil).
RAW_OK=1
for octet in "$O1" "$O2" "$O3" "$O4"; do
  if ((10#$octet == 0 || 10#$octet == 10)); then RAW_OK=0; fi
done
if ((RAW_OK)); then
  # '\\%03o' -> metin kaçış dizisi, sonra %b ile bayta çevrilir (iç içe tırnak yok).
  ESC=$(printf '\\%03o\\%03o\\%03o\\%03o' "$O1" "$O2" "$O3" "$O4")
  printf -v RAW_PAT '%b' "$ESC"
fi


# ---------------------------------------------------------------- canary

gen_token() {
  local hex=
  if [[ -r /dev/urandom ]]; then
    hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') || hex=
  fi
  if [[ -z $hex ]]; then
    hex=$(python3 -c 'import os;print(os.urandom(16).hex())' 2>/dev/null) ||
      die "rastgele canary üretilemedi"
  fi
  printf 'zifiri-canary-%s' "$hex"
}

if [[ -z $TOKEN ]]; then
  TOKEN=$(gen_token)
  FRESH_TOKEN=1
else
  FRESH_TOKEN=0
fi

if [[ $MODE == emit ]]; then
  cat <<EOF
CANARY_TOKEN=$TOKEN
CANARY_IP=$CANARY_IP

# Test ağından gönderilecek istek (HOST'u kendin koy):
curl -sS -o /dev/null -w '%{http_code}\n' \\
  --interface $CANARY_IP \\
  -H 'User-Agent: $TOKEN' \\
  -H 'X-Forwarded-For: $CANARY_IP' \\
  -H 'X-Real-IP: $CANARY_IP' \\
  --data-binary '$TOKEN' \\
  'https://HOST/api/posts'

# Sonra aynı canary ile tara:
CANARY_TOKEN=$TOKEN $PROG
EOF
  exit 0
fi

# ---------------------------------------------------------------- kökler

DO_DOCKER=0
DO_DB=0
DO_JOURNAL=0
if ((ROOTS_EXPLICIT)); then
  if ((FORCE_JOURNALD)); then DO_JOURNAL=1; fi
  vlog "hedefli tarama: yalnız ${ROOTS[*]}"
else
  ROOTS=("$DOCKER_ROOT" "$DB_DIR" "$TMP_ROOT")
  DO_DOCKER=1
  DO_DB=1
  DO_JOURNAL=1
fi

# ---------------------------------------------------------------- durum

declare -A SEEN=()
RED_HITS=()
INFO_HITS=()
SKIPPED=()
DOCKER_MISSING=0

# Ham bayt aşaması grep deseniyle ifade edilemiyorsa bu sessiz bir boşluk
# olmamalı: kanıt eksikse sonuç 2'dir.
if ((RAW_OK == 0)) && [[ $MODE != token ]]; then
  warn "ham bayt araması yapılamadı: IP'de 0 ya da 10 baytı var (grep deseni ifade edemez)"
  SKIPPED+=("ip-raw (IP baytları grep deseni olarak yazılamıyor)")
fi

is_published_db() {
  case $1 in
    "$DB_DIR"/*.db | "$DB_DIR"/*.db-wal) return 0 ;;
  esac
  return 1
}

record() {
  local form=$1 file=$2 key
  key="$form|$file"
  if [[ -n ${SEEN[$key]:-} ]]; then return 0; fi
  SEEN[$key]=1
  if [[ $form == token ]] && is_published_db "$file"; then
    INFO_HITS+=("$key")
  else
    RED_HITS+=("$key")
  fi
  vlog "isabet: $form $file"
  return 0
}

# ---------------------------------------------------------------- geçici dizin

STATE_ROOT=${DRILL_STATE_DIR:-${TMPDIR:-/var/tmp}}
mkdir -p -- "$STATE_ROOT" 2>/dev/null || true
TMPD=$(mktemp -d "$STATE_ROOT/zifiri-canary.XXXXXX") || die "geçici dizin açılamadı: $STATE_ROOT"
# shellcheck disable=SC2064
trap "rm -rf -- '$TMPD'" EXIT

# ---------------------------------------------------------------- dosya listesi

FILELIST=$TMPD/files.nul
: >"$FILELIST"

for root in "${ROOTS[@]}"; do
  if [[ ! -d $root ]]; then
    if ((DO_DOCKER)) && [[ $root == "$DOCKER_ROOT" ]]; then
      # Docker yok: sessizce geçmek yok, ayrı çıkış koduyla raporlanır.
      DOCKER_MISSING=1
      printf '%s: docker yok, atlandı: %s\n' "$PROG" "$root" >&2
      SKIPPED+=("docker ($root yok)")
    else
      warn "dizin yok, atlandı: $root"
      SKIPPED+=("$root")
    fi
    continue
  fi
  n0=$(tr -cd '\000' <"$FILELIST" | wc -c | tr -d ' ')
  # Betiğin kendi dizini dışlanır: varsayılan IP bu dosyaların içinde yazılı,
  # yoksa tarama her koşuda kendini bulur.
  if [[ -n $SELF_DIR ]]; then
    find "$root" -xdev -type f -readable \
      ! -path "$TMPD/*" ! -path "$SELF_DIR/*" -print0 >>"$FILELIST" 2>/dev/null || true
  else
    find "$root" -xdev -type f -readable \
      ! -path "$TMPD/*" -print0 >>"$FILELIST" 2>/dev/null || true
  fi
  n1=$(tr -cd '\000' <"$FILELIST" | wc -c | tr -d ' ')
  vlog "kök $root: $((n1 - n0)) dosya"
done

FILE_COUNT=$(tr -cd '\000' <"$FILELIST" | wc -c | tr -d ' ')
vlog "toplam dosya: $FILE_COUNT"
((FILE_COUNT > 0)) || die "taranacak dosya bulunamadı (kökler: ${ROOTS[*]})"

# SQLite üçlüsü ayrıca raporlanır: WAL ve SHM birincil kanıt yeridir (§6.1).
DB_FILES=0
if ((DO_DB)); then
  for ext in db db-wal db-shm; do
    c=0
    if [[ -d $DB_DIR ]]; then
      c=$(find "$DB_DIR" -maxdepth 1 -type f -name "*.$ext" 2>/dev/null | wc -l | tr -d ' ')
    fi
    vlog "db: *.$ext -> $c dosya"
    DB_FILES=$((DB_FILES + c))
  done
  if ((DB_FILES == 0)); then
    warn "$DB_DIR altında *.db / *.db-wal / *.db-shm yok — yayınlanmış satır iddiası ölçülemedi"
    SKIPPED+=("db ($DB_DIR boş ya da yok)")
  fi
fi

# ---------------------------------------------------------------- aday dosyalar

# Dört biçim tek grep çağrısında aranamaz: -E ile -F karışmaz. Bu yüzden
# iki geçişte aday listesi çıkarılır (E: düz + mapped, F: tuple + ham bayt,
# ayrıca F: token), sonra yalnız adaylar tek tek sınıflandırılır. 40 bin
# dosyalı bir /tmp'de bu, biçim başına tam geçişten kat kat ucuzdur.
CANDS=$TMPD/cands.nul
: >"$CANDS"

xargs_grep() { LC_ALL=C xargs -0 -r -a "$FILELIST" grep -a -l -Z "$@" 2>/dev/null || true; }

if [[ $MODE != token ]]; then
  xargs_grep -E -e "$PLAIN_RE" -e "$MAPPED_RE" >>"$CANDS"
  if ((RAW_OK)); then
    xargs_grep -F -e "$TUPLE" -e "$RAW_PAT" >>"$CANDS"
  else
    xargs_grep -F -e "$TUPLE" >>"$CANDS"
  fi
fi
if [[ $MODE != ip ]]; then
  xargs_grep -F -e "$TOKEN" >>"$CANDS"
fi

CANDIDATES=()
if [[ -s $CANDS ]]; then
  if printf '' | sort -z -u >/dev/null 2>&1; then
    mapfile -d '' -t CANDIDATES < <(sort -z -u "$CANDS")
  else
    mapfile -d '' -t CANDIDATES < <(sort -u "$CANDS")
  fi
fi
vlog "aday dosya: ${#CANDIDATES[@]} / $FILE_COUNT"

# ---------------------------------------------------------------- sınıflandırma

if ((${#CANDIDATES[@]})); then
  for f in "${CANDIDATES[@]}"; do
    if [[ ! -f $f ]]; then continue; fi
    if [[ $MODE != token ]]; then
      if LC_ALL=C grep -aqE -e "$PLAIN_RE" -- "$f" 2>/dev/null; then record ip-plain "$f"; fi
      if LC_ALL=C grep -aqF -e "$TUPLE" -- "$f" 2>/dev/null; then record ip-tuple "$f"; fi
      if LC_ALL=C grep -aqE -e "$MAPPED_RE" -- "$f" 2>/dev/null; then record ip-mapped "$f"; fi
      if ((RAW_OK)); then
        if LC_ALL=C grep -aqF -e "$RAW_PAT" -- "$f" 2>/dev/null; then record ip-raw "$f"; fi
      fi
    fi
    if [[ $MODE != ip ]]; then
      if LC_ALL=C grep -aqF -e "$TOKEN" -- "$f" 2>/dev/null; then record token "$f"; fi
    fi
  done
fi

# ---------------------------------------------------------------- süreç ortamı

# IP bir ortam değişkenine düşerse diske hiç yazılmaz ama /proc/<pid>/environ
# içinde durur. Bu yüzden ortam da bir tarama yeridir.
PROC_UNREADABLE=0
if ((SCAN_PROC_ENV)) && [[ $MODE != token ]]; then
  seen_proc=0
  for envf in /proc/[0-9]*/environ; do
    [[ -e $envf ]] || continue
    seen_proc=$((seen_proc + 1))
    if [[ ! -r $envf ]]; then
      PROC_UNREADABLE=$((PROC_UNREADABLE + 1))
      vlog "ortam okunamadı: $envf"
      continue
    fi
    if grep -aqE -e "$PLAIN_RE" -- "$envf" 2>/dev/null; then record ip-plain "$envf"; fi
    if grep -aqF -e "$TUPLE" -- "$envf" 2>/dev/null; then record ip-tuple "$envf"; fi
  done
  vlog "/proc: $seen_proc ortam, $PROC_UNREADABLE okunamadı"
  if ((PROC_UNREADABLE > 0)); then
    warn "/proc: $PROC_UNREADABLE süreç ortamı okunamadı (başka kullanıcı/root gerekir)"
    SKIPPED+=("proc-environ ($PROC_UNREADABLE okunamadı)")
  fi
fi

# ---------------------------------------------------------------- journald

JOURNAL_OK=0
JOURNAL_FILE=$TMPD/journal.txt
if ((DO_JOURNAL)); then
  if command -v journalctl >/dev/null 2>&1; then
    if journalctl --since "$SINCE" --no-pager -o short-iso >"$JOURNAL_FILE" 2>"$TMPD/journal.err"; then
      JOURNAL_OK=1
      vlog "journald: $(wc -l <"$JOURNAL_FILE" | tr -d ' ') satır"
    else
      warn "journalctl okunamadı: $(head -n 1 "$TMPD/journal.err" 2>/dev/null)"
      SKIPPED+=("journald")
    fi
  else
    warn "journalctl yok; journald taranmadı"
    SKIPPED+=("journald")
  fi
fi

if ((JOURNAL_OK)); then
  if [[ $MODE != token ]]; then
    grep -aqE -e "$PLAIN_RE" "$JOURNAL_FILE" && record ip-plain '<journald>'
    grep -aqF -e "$TUPLE" "$JOURNAL_FILE" && record ip-tuple '<journald>'
    grep -aqE -e "$MAPPED_RE" "$JOURNAL_FILE" && record ip-mapped '<journald>'
    # journald ikili alanlar ham bayt olarak da bulunabilir
    if ((RAW_OK)) && LC_ALL=C grep -aqF -e "$RAW_PAT" "$JOURNAL_FILE"; then
      record ip-raw '<journald>'
    fi
  fi
  if [[ $MODE != ip ]] && grep -aqF -e "$TOKEN" "$JOURNAL_FILE"; then
    record token '<journald>'
  fi
fi

# ---------------------------------------------------------------- gövde canary'si (dosyalar)

if [[ $MODE != ip ]]; then
  while IFS= read -r -d '' f; do
    record token "$f"
  done < <(xargs -0 -r -a "$FILELIST" grep -a -l -Z -F -e "$TOKEN" 2>/dev/null || true)
fi

# ---------------------------------------------------------------- makine okunur isabet

if [[ -n $HITS_FILE ]]; then
  : >"$HITS_FILE"
  for key in ${INFO_HITS[@]+"${INFO_HITS[@]}"}; do
    printf '%s\t%s\t%s\n' "${key%%|*}" "${key#*|}" bilgi >>"$HITS_FILE"
  done
  for key in ${RED_HITS[@]+"${RED_HITS[@]}"}; do
    printf '%s\t%s\t%s\n' "${key%%|*}" "${key#*|}" kirmizi >>"$HITS_FILE"
  done
  vlog "isabet dosyası: $HITS_FILE"
fi

# ---------------------------------------------------------------- rapor

print_group() {
  local title=$1 key form file count=0
  local -a lines=()
  for key in "${@:2}"; do
    form=${key%%|*}
    file=${key#*|}
    lines+=("$form|$file")
  done
  if ((${#lines[@]} == 0)); then return 0; fi
  printf '%s\n' "$title"
  local -A forms=()
  for key in "${lines[@]}"; do
    form=${key%%|*}
    file=${key#*|}
    forms[$form]=$((${forms[$form]:-0} + 1))
    if ((count < 40)); then
      printf '  %-12s %s\n' "$form" "$file"
    fi
    count=$((count + 1))
  done
  if ((count > 40)); then
    printf '  ... %d kayıt daha (toplam %d)\n' "$((count - 40))" "$count"
  fi
  printf '  özet:'
  for form in "${!forms[@]}"; do printf ' %s=%d' "$form" "${forms[$form]}"; done
  printf '\n\n'
  return 0
}

printf '\n== canary taraması ==\n'
printf 'IP           : %s\n' "$CANARY_IP"
printf 'tuple        : %s\n' "$TUPLE"
printf 'mapped       : %s\n' "$MAPPED"
printf 'canary       : %s%s\n' "$TOKEN" "$([[ ${FRESH_TOKEN:-0} == 1 ]] && printf ' (bu koşuda üretildi — gövde kanıtı sayılmaz)')"
if ((JOURNAL_OK)); then JOURNAL_NOTE=; else JOURNAL_NOTE=' (ATLANDI)'; fi
printf 'journald     : --since "%s"%s\n' "$SINCE" "$JOURNAL_NOTE"
printf 'proc ortamı  : %s\n' "$([[ $SCAN_PROC_ENV == 1 && $MODE != token ]] && printf 'tarandı' || printf 'atlandı')"
printf 'kökler       : %s\n' "${ROOTS[*]}"
printf 'dosya sayısı : %s\n\n' "$FILE_COUNT"

if ((${#RED_HITS[@]})); then print_group 'KIRMIZI isabetler:' "${RED_HITS[@]}"; fi
if ((${#INFO_HITS[@]})); then print_group 'Beklenen (yayınlanmış DB satırı):' "${INFO_HITS[@]}"; fi

if ((${#RED_HITS[@]})); then
  printf 'SONUÇ: KIRMIZI — %d isabet. Tatbikat başarısız.\n' "${#RED_HITS[@]}"
  exit 1
fi

if ((DOCKER_MISSING)); then
  printf 'SONUÇ: ORTAM EKSİK — docker yok, %s taranamadı (diğer kökler temiz).\n' "$DOCKER_ROOT"
  printf '       Bu koşu yeşil değildir. Docker kur ya da --root ile kapsamı daralt.\n'
  exit 3
fi

if ((${#SKIPPED[@]})); then
  printf 'SONUÇ: KANITLANMADI — isabet yok ama şu yerler taranamadı: %s\n' "${SKIPPED[*]}"
  exit 2
fi

# Yeşil mesajı ne tarandığını abartmadan söyler: hedefli taramada journald yoktur.
if ((JOURNAL_OK)); then JN='journald tarandı'; else JN='journald taranmadı'; fi
if ((SCAN_PROC_ENV)) && [[ $MODE != token ]]; then PN='proc ortamı tarandı'; else PN='proc ortamı taranmadı'; fi
printf 'SONUÇ: YEŞİL — %d dosya, %s, %s, canary yok.\n' "$FILE_COUNT" "$JN" "$PN"
exit 0
