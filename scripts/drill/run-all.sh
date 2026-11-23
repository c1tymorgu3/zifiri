#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-all.sh — tatbikatı sırayla koştur, tek tabloda raporla
#
# Sıra keyfi değil:
#
#   0. negatif kontrol   tarayıcı gerçekten buluyor mu? (plant.sh)
#   1. canary_scan.sh    disk + /proc ortamı + journald
#   2. write_allowlist   docker diff / volume kümesi
#   3. memdump_scan.sh   BEAM/nginx bellek dökümü
#
# Negatif kontrol düşerse kalan adımların "temiz" sonucu GEÇERSİZ sayılır:
# kör bir tarayıcının yeşili, hiçbir şeyin kanıtı değildir (scripts/SHARE.md).
#
# Tablo durumları:
#   PASS   adım yeşil (exit 0)
#   FAIL   adım kırmızı (exit 1)
#   SKIP   adım koşmadı ya da eksik kaldı (exit 2: kanıtlanmadı,
#          exit 3: ortam eksik — docker yok)
#
# SKIP yeşil değildir. Docker'ı olmayan bir makinede bu betik asla PASS
# toplamı vermez; vermesi de yanlış olurdu.
#
set -euo pipefail

PROG=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=.

VERBOSE=0
JSON=0
ONLY=
STATE=${DRILL_STATE_DIR:-${TMPDIR:-/tmp}}

usage() {
  cat <<EOF
$PROG — bütün el koyma tatbikatını koştur ve özetle

Kullanım:
  $PROG [seçenekler]

Seçenekler:
  --only ADLAR      Yalnız seçili adımlar (virgüllü): kontrol,canary,allowlist,memdump
  --json            stdout'a JSON özet (CI için); ayrıntılı çıktı stderr'e
  -v, --verbose     Her adımı --verbose ile koştur, çıktıyı da bas
  -h, --help        Bu metin

Ortam:
  DRILL_STATE_DIR        Geçici durum dizini (varsayılan: $STATE)
  ZIFIRI_DB_DIR          Yayınlanmış DB dizini (varsayılan: /var/lib/zifiri)
  DRILL_DOCKER_ROOT      Docker veri dizini (varsayılan: /var/lib/docker)
  DRILL_TMP_ROOT         Geçici dosya kökü (varsayılan: /tmp)
  CANARY_TOKEN           Sabit canary; yoksa canary_scan üretir

Çıkış kodları:
  0  bütün adımlar PASS
  1  en az bir FAIL (ya da negatif kontrol düştü → hepsi geçersiz)
  3  FAIL yok, ama en az bir adım ortam eksikliğinden koşmadı (docker yok)
  2  FAIL yok, ama en az bir adım kanıtlanmadı

Örnek:
  ./run-all.sh -v
  ./run-all.sh --only kontrol,canary
  ./run-all.sh --json | jq -r '.steps[] | "\\(.status)\\t\\(.step)"'
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
need_value() {
  if (($# >= 2)) && [[ -n $2 ]]; then return 0; fi
  die "$1 değer istiyor"
}

while (($#)); do
  case $1 in
    --only) need_value "$@"; ONLY=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: bilinmeyen argüman: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for s in canary_scan.sh write_allowlist.sh memdump_scan.sh negative/plant.sh; do
  [[ -x $SELF_DIR/$s ]] || die "betik yok ya da çalıştırılabilir değil: $SELF_DIR/$s"
done

mkdir -p -- "$STATE" 2>/dev/null || true
WORK=$(mktemp -d "$STATE/zifiri-runall.XXXXXX") || die "geçici dizin açılamadı"
# shellcheck disable=SC2064
trap "rm -rf -- '$WORK'" EXIT

wanted() {
  if [[ -z $ONLY ]]; then return 0; fi
  case ",$ONLY," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

STEPS=()
STATUSES=()
CODES=()
NOTES=()

run_step() {
  local name=$1 label=$2
  shift 2
  local out=$WORK/$name.log rc=0 status note
  local -a extra=()
  if ((VERBOSE)); then extra+=(--verbose); fi
  "$SELF_DIR/$label" "${extra[@]}" "$@" >"$out" 2>&1 || rc=$?
  case $rc in
    0) status=PASS ;;
    1) status=FAIL ;;
    2) status=SKIP ;;
    3) status=SKIP ;;
    *) status=FAIL ;;
  esac
  note=$(grep -m1 '^SONUÇ:' "$out" 2>/dev/null | sed 's/^SONUÇ: //' || true)
  if [[ -z $note ]]; then
    note=$(grep -m1 -E '^[^ ]+: ' "$out" 2>/dev/null | sed 's/^[^ ]*: //' || true)
  fi
  STEPS+=("$name")
  STATUSES+=("$status")
  CODES+=("$rc")
  NOTES+=("${note:-(çıktı yok)}")
  printf '  %-16s %-4s (exit %s) %s\n' "$name" "$status" "$rc" "${note:0:80}" >&2
  if ((VERBOSE)); then
    sed 's/^/      | /' "$out" >&2 || true
  fi
  return 0
}

printf '\n== tatbikat: run-all ==\n\n' >&2

if wanted kontrol; then run_step 'negatif kontrol' negative/plant.sh; fi
if wanted canary; then run_step 'canary_scan' canary_scan.sh; fi
if wanted allowlist; then run_step 'write_allowlist' write_allowlist.sh; fi
if wanted memdump; then run_step 'memdump_scan' memdump_scan.sh; fi

if ((${#STEPS[@]} == 0)); then
  die "--only hiçbir adımla eşleşmedi: $ONLY"
fi

# ---------------------------------------------------------------- karar

CONTROL_FAILED=0
FAIL_COUNT=0
SKIP_COUNT=0
ENV_SKIP=0
for i in "${!STEPS[@]}"; do
  case ${STATUSES[$i]} in
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      if [[ ${STEPS[$i]} == 'negatif kontrol' ]]; then CONTROL_FAILED=1; fi
      ;;
    SKIP)
      SKIP_COUNT=$((SKIP_COUNT + 1))
      if [[ ${CODES[$i]} == 3 ]]; then ENV_SKIP=1; fi
      ;;
  esac
done

OVERALL=0
if ((FAIL_COUNT > 0)); then
  OVERALL=1
elif ((ENV_SKIP)); then
  OVERALL=3
elif ((SKIP_COUNT > 0)); then
  OVERALL=2
fi

# ---------------------------------------------------------------- tablo

table() {
  local i
  printf '\n%-18s %-6s %-4s %s\n' 'ADIM' 'DURUM' 'KOD' 'NOT'
  printf '%-18s %-6s %-4s %s\n' '------------------' '------' '----' '---'
  for i in "${!STEPS[@]}"; do
    printf '%-18s %-6s %-4s %s\n' "${STEPS[$i]}" "${STATUSES[$i]}" "${CODES[$i]}" "${NOTES[$i]}"
  done
  printf '\n'
  case $OVERALL in
    0) printf 'TOPLAM: PASS — %d adım yeşil.\n' "${#STEPS[@]}" ;;
    1)
      if ((CONTROL_FAILED)); then
        printf 'TOPLAM: FAIL — negatif kontrol düştü.\n'
        printf '        Tarayıcı kör: diğer adımların sonucu GEÇERSİZ.\n'
      else
        printf 'TOPLAM: FAIL — %d adım kırmızı.\n' "$FAIL_COUNT"
      fi
      ;;
    3) printf 'TOPLAM: SKIP — %d adım ortam eksikliğinden koşmadı (docker yok?).\n' "$SKIP_COUNT" ;;
    2) printf 'TOPLAM: SKIP — %d adım kanıtlanmadı.\n' "$SKIP_COUNT" ;;
  esac
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

if ((JSON)); then
  table >&2
  printf '{'
  printf '"tool":"run-all","schema":1,"overall":"%s","exit":%d,"steps":[' \
    "$(case $OVERALL in 0) printf PASS ;; 1) printf FAIL ;; *) printf SKIP ;; esac)" "$OVERALL"
  for i in "${!STEPS[@]}"; do
    if ((i > 0)); then printf ','; fi
    printf '{"step":"%s","status":"%s","exit":%s,"note":"%s"}' \
      "$(json_escape "${STEPS[$i]}")" "${STATUSES[$i]}" "${CODES[$i]}" "$(json_escape "${NOTES[$i]}")" 
  done
  printf ']}\n'
else
  table
fi

exit "$OVERALL"
