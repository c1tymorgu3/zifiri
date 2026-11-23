#!/usr/bin/env bash
# shellcheck shell=bash
#
# write_allowlist.sh — zifiri el koyma tatbikatı, ayak 1 (disk imajı)
#
# Ne yapar: `docker diff` çıktısını izinli kümeyle karşılaştırır. İzinli küme
# bu betiğin içinde gömülü DEĞİLDİR: aynı dizindeki `allowlist.txt` dosyasından
# okunur (--allowlist ile değiştirilebilir). Kümeyi gözden geçirmek için kodu
# değil, veriyi düzenlersin.
#
# allowlist.txt biçimi (satır: <tür> <değer>, # yorum):
#
#   file            /var/lib/zifiri/zifiri.db      diff'te izinli dosya
#   dir             /var/lib                     izinli üst dizin (D hariç)
#   managed         /etc/hosts                   docker'ın yönettiği, bilgi
#   tmpfs           /tmp                         diff'te görünürse kırmızı
#   volume-required zifiri.db                    volume'de olması gereken
#   volume-allowed  zifiri.db-wal                volume'de izinli ad
#
# Değerlerde ${ZIFIRI_DB_DIR} genişletilir.
#
# Fazlası = kırmızı (exit 1).
#
# ÖNEMLİ: `docker diff` volume içeriğini göstermez; /var/lib/zifiri bir
# volume ise zifiri.db satırları diff'te hiç çıkmaz. Bu yüzden volume'un
# gerçek dosya kümesi --volume-dir ile ayrıca denetlenir (§5.2 madde 2).
#
# --json: stdout'a tek bir JSON nesnesi yazar (CI için); insan raporu stderr'e
# gider. Çıkış kodu JSON'daki "exit" alanıyla aynıdır.
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=.

CONTAINER=${ZIFIRI_CONTAINER:-zifiri-app}
DB_DIR=${ZIFIRI_DB_DIR:-/var/lib/zifiri}
VOLUME_DIR=
SOURCE=container
DIFF_FILE=
ALLOWLIST=${DRILL_ALLOWLIST:-$SELF_DIR/allowlist.txt}
STRICT_EMPTY=1
JSON=0
VERBOSE=0

usage() {
  cat <<EOF
$PROG — docker diff / volume yazma allowlist denetimi

Kullanım:
  $PROG [CONTAINER] [seçenekler]
  docker diff CONTAINER | $PROG --stdin [seçenekler]

Seçenekler:
  --stdin               diff'i stdin'den oku
  --diff-file DOSYA     diff'i dosyadan oku
  --allowlist DOSYA     İzinli küme dosyası (varsayılan: $ALLOWLIST)
  --volume-dir DIZIN    volume dizinini de denetle (tam dosya kümesi)
  --allow-empty-diff    boş diff'i yeşil say (varsayılan: kanıtlanmadı)
  --json                stdout'a JSON yaz (CI için; rapor stderr'e)
  -v, --verbose         Ayrıntılı: allowlist yolu, satır sayısı, her karar
  -h, --help            Bu metin

Ortam: ZIFIRI_CONTAINER (varsayılan: $CONTAINER), ZIFIRI_DB_DIR,
       DRILL_ALLOWLIST

Çıkış kodları:
  0  yeşil: izinli kümenin dışında hiçbir şey yok
  1  kırmızı: allowlist dışı yazma var
  2  kanıtlanmadı: diff boş, allowlist yok, docker yok ya da hata
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
    --stdin) SOURCE=stdin; shift ;;
    --diff-file) need_value "$@"; DIFF_FILE=$2; SOURCE=diff_file; shift 2 ;;
    --allowlist) need_value "$@"; ALLOWLIST=$2; shift 2 ;;
    --volume-dir) need_value "$@"; VOLUME_DIR=$2; shift 2 ;;
    --allow-empty-diff) STRICT_EMPTY=0; shift ;;
    --json) JSON=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -*) printf '%s: bilinmeyen seçenek: %s\n' "$PROG" "$1" >&2; exit 2 ;;
    *) CONTAINER=$1; shift ;;
  esac
done

# ---------------------------------------------------------------- izinli küme

ALLOWED_FILES=()
ALLOWED_DIRS=()
DOCKER_MANAGED=()
TMPFS_REQUIRED=()
VOLUME_REQUIRED=()
VOLUME_ALLOWED=()

expand_vars() {
  local v=$1
  # Tek tırnak bilinçli: aranan şey "${ZIFIRI_DB_DIR}" metninin kendisi.
  # shellcheck disable=SC2016
  v=${v//'${ZIFIRI_DB_DIR}'/$DB_DIR}
  # shellcheck disable=SC2016
  v=${v//'${DB_DIR}'/$DB_DIR}
  printf '%s' "$v"
}

ALLOWLIST_LINES=0
load_allowlist() {
  local file=$1 line kind value lineno=0
  [[ -r $file ]] || die "allowlist okunamadı: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    if [[ -z $line || $line == '#'* ]]; then continue; fi
    kind=${line%%[[:space:]]*}
    value=${line#"$kind"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [[ -n $value ]] || die "$file:$lineno: değer yok: $line"
    value=$(expand_vars "$value")
    case $kind in
      file) ALLOWED_FILES+=("$value") ;;
      dir) ALLOWED_DIRS+=("$value") ;;
      managed) DOCKER_MANAGED+=("$value") ;;
      tmpfs) TMPFS_REQUIRED+=("$value") ;;
      volume-required) VOLUME_REQUIRED+=("$value") ;;
      volume-allowed) VOLUME_ALLOWED+=("$value") ;;
      *) die "$file:$lineno: bilinmeyen tür: $kind" ;;
    esac
    ALLOWLIST_LINES=$((ALLOWLIST_LINES + 1))
  done <"$file"
  if ((ALLOWLIST_LINES == 0)); then
    die "$file: boş allowlist — her satır ya da her şey izinli olur, ikisi de yanlış"
  fi
}

load_allowlist "$ALLOWLIST"
vlog "allowlist: $ALLOWLIST ($ALLOWLIST_LINES kural, ${#ALLOWED_FILES[@]} dosya, ${#ALLOWED_DIRS[@]} dizin)"

normalize() {
  local p=$1
  while [[ $p == *//* ]]; do p=${p//\/\//\/}; done
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  printf '%s' "$p"
}

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    if [[ $needle == "$item" ]]; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------- diff kaynağı

WORK=$(mktemp -d "${DRILL_STATE_DIR:-${TMPDIR:-/var/tmp}}/zifiri-diff.XXXXXX" 2>/dev/null) ||
  WORK=$(mktemp -d) || die "geçici dizin açılamadı"
# shellcheck disable=SC2064
trap "rm -rf -- '$WORK'" EXIT

RAW=$WORK/diff.txt
case $SOURCE in
  stdin)
    cat >"$RAW"
    ;;
  diff_file)
    [[ -r $DIFF_FILE ]] || die "okunamadı: $DIFF_FILE"
    cp -- "$DIFF_FILE" "$RAW"
    ;;
  container)
    if ! command -v docker >/dev/null 2>&1; then
      die "docker bulunamadı; --stdin ya da --diff-file kullan"
    fi
    docker diff "$CONTAINER" >"$RAW" 2>"$WORK/docker.err" ||
      die "docker diff $CONTAINER başarısız: $(head -n 1 "$WORK/docker.err")"
    ;;
esac

LINES=$(wc -l <"$RAW" | tr -d ' ')
vlog "diff: $LINES satır"

# ---------------------------------------------------------------- karşılaştırma

VIOLATIONS=()
MANAGED=()
SEEN_ALLOWED=()

while IFS= read -r line || [[ -n $line ]]; do
  line=${line%$'\r'}
  if [[ -z ${line//[[:space:]]/} ]]; then continue; fi
  case $line in
    [ACD]" "*) : ;;
    *)
      warn "tanınmayan diff satırı: $line"
      VIOLATIONS+=("?|$line")
      continue
      ;;
  esac
  status=${line%% *}
  path=$(normalize "${line#* }")

  if in_list "$path" ${ALLOWED_FILES[@]+"${ALLOWED_FILES[@]}"}; then
    SEEN_ALLOWED+=("$status $path")
    vlog "izinli dosya: $status $path"
    continue
  fi
  if in_list "$path" ${ALLOWED_DIRS[@]+"${ALLOWED_DIRS[@]}"}; then
    # Dizin üst kayıtları: A (Docker volume mountpoint'i oluşturdu) ya da
    # C (içerik değişti) olabilir. D (silinmiş) hiç beklenmez.
    if [[ $status == D ]]; then
      VIOLATIONS+=("$status|$path (izinli dizin silinmiş)")
    else
      SEEN_ALLOWED+=("$status $path")
    fi
    continue
  fi
  hit_tmpfs=0
  for t in ${TMPFS_REQUIRED[@]+"${TMPFS_REQUIRED[@]}"}; do
    case $path in
      "$t" | "$t"/*) hit_tmpfs=1 ;;
    esac
  done
  if ((hit_tmpfs)); then
    # tmpfs olmalı; diff'te görünmesi tmpfs'in kurulmadığı anlamına gelir
    # ve canary'nin diske yazılmasına açık kapı bırakır (§5.1).
    VIOLATIONS+=("$status|$path (tmpfs değil — §5.1 ihlali)")
    continue
  fi
  if in_list "$path" ${DOCKER_MANAGED[@]+"${DOCKER_MANAGED[@]}"}; then
    MANAGED+=("$status $path")
    continue
  fi
  VIOLATIONS+=("$status|$path")
  vlog "ihlal: $status $path"
done <"$RAW"

# ---------------------------------------------------------------- volume kümesi

VOLUME_EXTRA=()
VOLUME_MISSING=()
VOLUME_CHECKED=0
if [[ -n $VOLUME_DIR ]]; then
  [[ -d $VOLUME_DIR ]] || die "volume dizini yok: $VOLUME_DIR"
  VOLUME_CHECKED=1
  declare -A PRESENT=()
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    PRESENT[$name]=1
    if [[ -d $entry ]]; then
      VOLUME_EXTRA+=("$name/ (dizin)")
      continue
    fi
    in_list "$name" ${VOLUME_ALLOWED[@]+"${VOLUME_ALLOWED[@]}"} || VOLUME_EXTRA+=("$name")
  done < <(find "$VOLUME_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)
  for name in ${VOLUME_REQUIRED[@]+"${VOLUME_REQUIRED[@]}"}; do
    if [[ -z ${PRESENT[$name]:-} ]]; then VOLUME_MISSING+=("$name"); fi
  done
fi

# ---------------------------------------------------------------- karar

STATUS=green
EXIT_CODE=0
if ((${#VIOLATIONS[@]})); then
  STATUS=red
  EXIT_CODE=1
elif ((${#VOLUME_EXTRA[@]})); then
  STATUS=red
  EXIT_CODE=1
elif ((${#VOLUME_MISSING[@]})); then
  STATUS=unproven
  EXIT_CODE=2
elif ((LINES == 0)); then
  if ((STRICT_EMPTY)) && ((VOLUME_CHECKED == 0)); then
    STATUS=unproven
    EXIT_CODE=2
  fi
fi

# ---------------------------------------------------------------- rapor

REPORT_FD=1
if ((JSON)); then REPORT_FD=2; fi

# shellcheck disable=SC2059  # biçim dizgesi bilinçli olarak çağırandan geliyor
say() { printf "$@" >&"$REPORT_FD"; }

say '\n== yazma allowlist denetimi ==\n'
case $SOURCE in
  container) say 'kaynak       : docker diff %s\n' "$CONTAINER" ;;
  stdin) say 'kaynak       : stdin\n' ;;
  diff_file) say 'kaynak       : %s\n' "$DIFF_FILE" ;;
esac
say 'allowlist    : %s (%d kural)\n' "$ALLOWLIST" "$ALLOWLIST_LINES"
say 'diff satırı  : %s\n' "$LINES"
say 'volume       : %s\n\n' "${VOLUME_DIR:-(denetlenmedi)}"

if ((${#SEEN_ALLOWED[@]})); then
  say 'İzinli:\n'
  for entry in "${SEEN_ALLOWED[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#MANAGED[@]})); then
  say 'Docker tarafından yönetilen (bilgi):\n'
  for entry in "${MANAGED[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#VOLUME_MISSING[@]})); then
  say 'Volume içinde beklenen dosya yok:\n'
  for entry in "${VOLUME_MISSING[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#VOLUME_EXTRA[@]})); then
  say 'Volume içinde izinsiz dosya:\n'
  for entry in "${VOLUME_EXTRA[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

if ((${#VIOLATIONS[@]})); then
  say 'ALLOWLIST DIŞI:\n'
  for entry in "${VIOLATIONS[@]}"; do say '  %s\n' "$entry"; done
  say '\n'
fi

case $STATUS in
  red)
    if ((${#VIOLATIONS[@]})); then
      say 'SONUÇ: KIRMIZI — %d izinsiz yol. Tatbikat başarısız.\n' "${#VIOLATIONS[@]}"
    else
      say 'SONUÇ: KIRMIZI — volume içinde %d izinsiz dosya.\n' "${#VOLUME_EXTRA[@]}"
    fi
    ;;
  unproven)
    if ((${#VOLUME_MISSING[@]})); then
      say 'SONUÇ: KANITLANMADI — volume eksik: %s\n' "${VOLUME_MISSING[*]}"
    else
      say 'SONUÇ: KANITLANMADI — diff boş ve volume denetlenmedi.\n'
      say '       Uygulama hiç yazmamış olabilir; --volume-dir ver ya da\n'
      say '       yük testinden sonra çalıştır.\n'
    fi
    ;;
  green)
    if ((${#MANAGED[@]})); then
      say 'SONUÇ: YEŞİL — allowlist dışı yazma yok (Docker yönetimli %d satır bilgi).\n' "${#MANAGED[@]}"
    elif ((LINES == 0)); then
      say 'SONUÇ: YEŞİL — diff boş (yazma yok).\n'
    else
      say 'SONUÇ: YEŞİL — %s satır, hepsi izinli kümede.\n' "$LINES"
    fi
    ;;
esac

# ---------------------------------------------------------------- JSON

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_array() {
  local first=1 item
  local -n _ref=$1
  printf '['
  for item in "${_ref[@]}"; do
    if ((first)); then first=0; else printf ','; fi
    printf '"%s"' "$(json_escape "$item")"
  done
  printf ']'
}

json_nullable() {
  if [[ -z $1 ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

emit_json() {
  printf '{"tool":"write_allowlist","schema":1'
  printf ',"source":"%s"' "$SOURCE"
  printf ',"container":%s' "$(json_nullable "$([[ $SOURCE == container ]] && printf '%s' "$CONTAINER")")"
  printf ',"allowlist":"%s"' "$(json_escape "$ALLOWLIST")"
  printf ',"allowlist_rules":%d' "$ALLOWLIST_LINES"
  printf ',"diff_lines":%d' "$LINES"
  printf ',"volume_dir":%s' "$(json_nullable "$VOLUME_DIR")"
  printf ',"volume_checked":%s' "$([[ $VOLUME_CHECKED == 1 ]] && printf 'true' || printf 'false')"
  printf ',"status":"%s"' "$STATUS"
  printf ',"exit":%d' "$EXIT_CODE"
  printf ',"allowed":'
  json_array SEEN_ALLOWED
  printf ',"managed":'
  json_array MANAGED
  printf ',"violations":'
  json_array VIOLATIONS
  printf ',"volume_extra":'
  json_array VOLUME_EXTRA
  printf ',"volume_missing":'
  json_array VOLUME_MISSING
  printf '}\n'
}

if ((JSON)); then emit_json; fi

exit "$EXIT_CODE"
