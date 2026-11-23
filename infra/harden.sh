#!/usr/bin/env bash
# zifiri — host sertleştirme. plan §5.1 (log yok), §11.4 (disk ve bellek).
#
# NE YAPAR
#   swap'i kapatır · çekirdek dökümünü üç katmanda keser · journald'ı diske
#   yazmaz hâle getirir · /var/log'taki eski kayıtları siler.
#   Her adım IDEMPOTENT: ikinci çalıştırma aynı durumu üretir, hata vermez.
#
# NE YAPMAZ
#   LUKS kurmaz (kurulum anında yapılmalı — harden.md §"LUKS"), sağlayıcı
#   loglarını, ağ gözlemini veya RAM'deki veriyi engellemez. Bu sınırlar
#   harden.md'de tek tek yazılı; betiğin yeşil dönmesi "anonim" demek değildir.
#
# KULLANIM
#   sudo ./harden.sh                    # uygula (root)
#   ./harden.sh --dry-run               # planı yazdır, hiçbir şeyi değiştirme
#   sudo ./harden.sh --log-age-days 3   # /var/log eşiği (varsayılan 7 gün)
#
# ÇIKIŞ KODLARI
#   0 başarılı · 1 hata (root değil, geçersiz argüman) · 2 Linux değil.
#
# Geri alma: her adımın altında tek satır yazıyor; toplu geri alma harden.md'de.

set -euo pipefail

PROG=${0##*/}

DRY_RUN=0
LOG_AGE_DAYS=7

SYSCTL_FILE=/etc/sysctl.d/90-zifiri-hardening.conf
LIMITS_FILE=/etc/security/limits.conf
LIMITS_BEGIN='# BEGIN zifiri-harden (core dump kapalı)'
LIMITS_END='# END zifiri-harden (core dump kapalı)'
LIMITS_DROPIN=/etc/systemd/system.conf.d/90-zifiri-core.conf
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/90-zifiri.conf
FSTAB_BACKUP=/etc/fstab.zifiri.bak
# Tek yerde durur: hem uygulanan komut hem dry-run çıktısı aynı metni gösterir.
FSTAB_SED='s|^([^#].*[[:space:]]swap[[:space:]].*)$|# zifiri: swap kapalı — \1|'

# ---------------------------------------------------------------------------
# yardımcılar
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }
rollback() { printf '  geri alma: %s\n' "$*"; }
would() { printf '  [dry-run] %s\n' "$*"; }

is_linux() {
  [ "$(uname -s 2>/dev/null || echo unknown)" = Linux ] && [ -d /proc/sys/kernel ]
}

# Komutu çalıştır; dry-run'da yalnız yazdır. Redirection gerektiren işler
# buradan geçmez — onlar install_content/find gibi kendi dry-run dalını taşır.
do_cmd() {
  if (( DRY_RUN )); then
    would "$*"
  else
    "$@"
  fi
}

# İçeriği yalnız değiştiyse yaz (idempotentlik burada). install -D dizini kurar.
install_content() {
  local path=$1 content=$2 mode=${3:-0644} tmp

  if (( DRY_RUN )); then
    would "yazılacak: $path (mode $mode)"
    printf '%s\n' "$content" | sed 's/^/      | /'
    return 0
  fi

  tmp=$(mktemp)
  printf '%s\n' "$content" >"$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    say "  değişiklik yok: $path"
    rm -f "$tmp"
    return 0
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  say "  yazıldı: $path"
}

usage() {
  cat <<EOF
$PROG — zifiri host sertleştirme (plan §5.1, §11.4)

  sudo $PROG [--dry-run] [--log-age-days N]

  --dry-run            Hiçbir şeyi değiştirme; her adımın komutunu ve
                       geri alma satırını yazdır.
  --log-age-days N     /var/log altında N günden eski *.log dosyalarını sil
                       (varsayılan: 7).
  -h, --help           Bu metin.

Adımlar: swap kapat · core dump kapat (sysctl + limits + coredump.socket) ·
journald Storage=none · /var/log temizliği · doğrulama.

LUKS bu betiğin işi DEĞİLDİR: şifreleme kurulum anında yapılır (harden.md).
EOF
}

# ---------------------------------------------------------------------------
# 1. swap
# ---------------------------------------------------------------------------

step_swap() {
  step "2/7 swap kapat"
  say "  Ne yapar: açık swap alanlarını kapatır, /etc/fstab'taki swap satırlarını"
  say "            yorumlar, swap/hibernate hedeflerini maskeler."
  say "  Neden: swap, RAM'in diske yazılmış hâlidir. Mesaj metni, oturum"
  say "            anahtarı ya da pepper oraya düşerse 'diske yazılmaz' (§7.1)"
  say "            iddiası çöker. Hibernate aynı şeyi tüm RAM için yapar."
  rollback "sudo cp -a $FSTAB_BACKUP /etc/fstab && sudo swapon -a && sudo systemctl unmask swap.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

  if is_linux; then
    local n
    n=$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')
    say "  mevcut: $n açık swap alanı"
  else
    say "  mevcut: okunamadı (Linux değil)"
  fi

  do_cmd swapoff -a

  if ! is_linux; then
    would "sed -i -E '$FSTAB_SED' /etc/fstab"
  elif [ -f /etc/fstab ]; then
    # Yedek her durumda bir kez alınır: geri alma komutu dosyayı gösteriyor,
    # yoksa komut yalan söylemiş olur.
    if [ ! -e "$FSTAB_BACKUP" ]; then
      do_cmd cp -a /etc/fstab "$FSTAB_BACKUP"
    fi
    if grep -Eq '^[[:space:]]*[^#[:space:]].*[[:space:]]swap[[:space:]]' /etc/fstab; then
      # Yorumlanan satır geri alınabilir kalsın: özgün metin satır sonunda.
      do_cmd sed -i -E "$FSTAB_SED" /etc/fstab
    else
      say "  /etc/fstab: yorumlanacak swap satırı yok (idempotent)"
    fi
  fi

  # Maskeleme, birinin sonradan 'swapon -a' ya da 'systemctl hibernate'
  # demesini engeller. Hata (birim yok) yutulur: eksik olması sorun değil.
  do_cmd systemctl mask swap.target 2>/dev/null || true
  do_cmd systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. çekirdek dökümü (sysctl)
# ---------------------------------------------------------------------------

step_sysctl() {
  step "3/7 çekirdek dökümü — sysctl"
  say "  Ne yapar: core_pattern'i çöpe borular, setuid dökümünü ve dmesg"
  say "            okumasını kapatır, swappiness'i sıfırlar."
  say "  Neden: BOŞ core_pattern işe yaramaz — boş bırakmak 'core' adında"
  say "            dosyayı çalışma dizinine yazar. Kapatmanın yolu |/bin/false."
  say "            dmesg_restrict: çekirdek halkası süreç adı/adres taşır."
  rollback "sudo rm -f $SYSCTL_FILE && sudo sysctl --system"

  local content
  content=$(cat <<'EOF'
# zifiri — plan §5.1. YÖNETİLEN DOSYA: infra/harden.sh yazar.
# Elle düzenleme bir sonraki çalıştırmada ezilir; değişiklik betiğe girer.

# Çekirdek dökümü hiçbir süreç için yazılmaz (boru → /bin/false).
kernel.core_pattern = |/bin/false
kernel.core_uses_pid = 0
# setuid süreçler de döküm yazamaz (sudo ile çalışan bir çökme RAM'i diske taşır).
fs.suid_dumpable = 0
# Çekirdek halkası ve sembol adresleri root dışına kapalı.
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
# Swap kapalıyken etkisiz; açılırsa bile agresif takas yapılmasın.
vm.swappiness = 0
# "Martian" paketler kaynak adresiyle loglanır — istemci IP sızıntısı (§5.1).
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
EOF
)
  install_content "$SYSCTL_FILE" "$content" 0644
  do_cmd sysctl --system

  say "  systemd-coredump ayrı bir yoldur; sysctl onu kapsamaz, ayrıca kapatılır."
  do_cmd systemctl disable --now systemd-coredump.socket 2>/dev/null || true
  do_cmd systemctl mask systemd-coredump.socket systemd-coredump@.service 2>/dev/null || true
  rollback "sudo systemctl unmask systemd-coredump.socket systemd-coredump@.service && sudo systemctl enable --now systemd-coredump.socket"
}

# ---------------------------------------------------------------------------
# 3. ulimit core 0
# ---------------------------------------------------------------------------

step_limits() {
  step "4/7 ulimit core 0"
  say "  Ne yapar: PAM oturumları için core limitini 0 yapar; systemd"
  say "            servisleri için DefaultLimitCORE=0 drop-in'i yazar."
  say "  Neden: core_pattern'e ek olarak RLIMIT_CORE=0, çekirdeğin döküm"
  say "            yolunu hiç denememesini sağlar. limits.conf tek başına"
  say "            systemd servislerini kapsamaz — iki katman gerekir."
  rollback "sudo sed -i '/BEGIN zifiri-harden/,/END zifiri-harden/d' $LIMITS_FILE && sudo rm -f $LIMITS_DROPIN"

  if [ -f "$LIMITS_FILE" ] && grep -qF "$LIMITS_BEGIN" "$LIMITS_FILE"; then
    say "  $LIMITS_FILE: zifiri bloğu zaten var (idempotent)"
  else
    local block
    block=$(cat <<EOF
$LIMITS_BEGIN
# core 0: çöken süreç RAM'ini diske dökemez. PAM oturumları içindir;
# systemd servisleri $LIMITS_DROPIN ve unit içindeki LimitCORE=0 ile kapsanır.
*       hard    core    0
*       soft    core    0
root    hard    core    0
root    soft    core    0
$LIMITS_END
EOF
)
    if (( DRY_RUN )); then
      would "eklenecek blok: $LIMITS_FILE"
      printf '%s\n' "$block" | sed 's/^/      | /'
    else
      [ -d "$(dirname "$LIMITS_FILE")" ] || install -d -m 0755 "$(dirname "$LIMITS_FILE")"
      if ! printf '\n%s\n' "$block" >>"$LIMITS_FILE"; then
        warn "$LIMITS_FILE yazılamadı — bu adım ATLANDI"
        return 1
      fi
      say "  eklendi: $LIMITS_FILE (zifiri bloğu)"
    fi
  fi

  local dropin
  dropin=$(cat <<'EOF'
# zifiri — plan §5.1. YÖNETİLEN DOSYA: infra/harden.sh yazar.
# Yeni başlayan tüm servisler için core limiti 0. Çalışan servisler bu
# değeri ancak yeniden başlatılınca alır; zifiri unit'leri ayrıca kendi
# içinde LimitCORE=0 taşır (infra/systemd/*.service).
[Manager]
DefaultLimitCORE=0
EOF
)
  install_content "$LIMITS_DROPIN" "$dropin" 0644
}

# ---------------------------------------------------------------------------
# 4. journald
# ---------------------------------------------------------------------------

step_journald() {
  step "5/7 journald — Storage=none"
  say "  Ne yapar: journald'ı diske hiç yazmayacak şekilde yapılandırır ve"
  say "            mevcut journal dosyalarını boşaltır."
  say "  Neden: journald; unit çıktısını, çekirdek mesajlarını ve (açıksa)"
  say "            audit kayıtlarını diske yazar. Tor ve nginx'in stdout'u"
  say "            buraya düşer; Storage=none ile hiçbiri kalıcı olmaz."
  rollback "sudo rm -f $JOURNALD_DROPIN && sudo systemctl restart systemd-journald"

  local dropin
  dropin=$(cat <<'EOF'
# zifiri — plan §5.1. YÖNETİLEN DOSYA: infra/harden.sh yazar.
# Storage=none: journal DOSYASI hiç oluşturulmaz. Kayıt yalnız çalışma
# zamanında bellekte tutulur, yeniden başlatmada kaybolur. `journalctl`
# bu makinede geçmiş göstermez — bilinçli, hata ayıklarken geçici aç.
[Journal]
Storage=none
# syslog'a köprüleme: rsyslog varsa orası diske yazar, köprüyü kes.
ForwardToSyslog=no
EOF
)
  install_content "$JOURNALD_DROPIN" "$dropin" 0644
  do_cmd systemctl restart systemd-journald

  say "  mevcut journal dosyaları boşaltılıyor (drop-in yalnız yeni kaydı keser)."
  do_cmd journalctl --rotate 2>/dev/null || true
  do_cmd journalctl --vacuum-time=1s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5. /var/log
# ---------------------------------------------------------------------------

step_logs() {
  step "6/7 /var/log — eski kayıtları sil"
  say "  Ne yapar: döndürülmüş/sıkıştırılmış logları ve $LOG_AGE_DAYS günden eski"
  say "            *.log dosyalarını siler."
  say "  Neden: log rotasyonu kayıtları aylarca tutar; canary taraması (§5.2)"
  say "            eski dosyalarda isabet bulursa faz kırmızıdır. Silme, ömrü"
  say "            kısaltır — içerik zaten yazılmamalıydı, bu ikinci savunma."
  say "  Korunan: wtmp, btmp, lastlog (istemci değil OPERATÖR oturum kaydı,"
  say "            §5 son paragraf) ve /var/log/journal (5. adımda boşaltıldı)."
  rollback "yok — silinen dosya geri gelmez. Önce --dry-run ile listeyi görün."

  local common=(-xdev -type f ! -path '/var/log/journal/*'
                ! -name wtmp ! -name btmp ! -name lastlog)

  if (( DRY_RUN )) || ! is_linux; then
    would "find /var/log ${common[*]} \\( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' -o -name '*.old' -o -name '*.log.[0-9]*' \\) -delete"
    would "find /var/log ${common[*]} -name '*.log' -mtime +$LOG_AGE_DAYS -delete"
    if is_linux; then
      say "  (dry-run listesi:)"
      find /var/log "${common[@]}" \
        \( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' \
           -o -name '*.old' -o -name '*.log.[0-9]*' \) \
        -printf '      silinecek: %p (%s bayt)\n' 2>/dev/null || true
      find /var/log "${common[@]}" -name '*.log' -mtime +"$LOG_AGE_DAYS" \
        -printf '      silinecek: %p (%s bayt)\n' 2>/dev/null || true
    fi
    return 0
  fi

  local before after
  before=$(du -sk /var/log 2>/dev/null | awk '{print $1}' || echo 0)
  find /var/log "${common[@]}" \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.zst' -o -name '*.bz2' \
       -o -name '*.old' -o -name '*.log.[0-9]*' \) -delete 2>/dev/null || true
  find /var/log "${common[@]}" -name '*.log' -mtime +"$LOG_AGE_DAYS" \
    -delete 2>/dev/null || true
  after=$(du -sk /var/log 2>/dev/null | awk '{print $1}' || echo 0)
  say "  /var/log: ${before:-?} KB → ${after:-?} KB"
}

# ---------------------------------------------------------------------------
# 6. ön kontrol (LUKS uyarısı) — bilgi, hata değil
# ---------------------------------------------------------------------------

step_preflight() {
  step "1/7 kapsam ve ön kontrol"
  say "  Bu betik diski şifrelemez. LUKS kurulum anında yapılmalı (harden.md)."
  if is_linux; then
    if dmsetup ls --target crypt 2>/dev/null | grep -q .; then
      say "  dm-crypt aygıtı var: $(dmsetup ls --target crypt 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    else
      warn "dm-crypt aygıtı görünmüyor: disk şifrelemesi (§11.4) karşılanmıyor olabilir."
    fi
  else
    say "  dm-crypt durumu okunamadı (Linux değil)."
  fi
  say "  Kapsam dışı: sağlayıcı logları, ağ gözlemi, RAM imajı, DNS, yedek."
}

# ---------------------------------------------------------------------------
# 7. doğrulama
# ---------------------------------------------------------------------------

step_verify() {
  step "7/7 doğrulama"
  say "  Beklenen:"
  say "    swapon --show                 → boş"
  say "    sysctl -n kernel.core_pattern → |/bin/false"
  say "    sysctl -n fs.suid_dumpable    → 0"
  say "    sysctl -n kernel.dmesg_restrict → 1"
  say "    sysctl -n vm.swappiness       → 0"
  say "    journalctl --disk-usage       → 'No journal files were found'"
  say "    grep core /etc/security/limits.conf → soft/hard 0"

  if (( DRY_RUN )) || ! is_linux; then
    say ""
    say "  (dry-run: ölçüm yapılmadı)"
    return 0
  fi

  local swaps pattern suid dmesg swappiness usage cores
  swaps=$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')
  pattern=$(sysctl -n kernel.core_pattern 2>/dev/null || echo '?')
  suid=$(sysctl -n fs.suid_dumpable 2>/dev/null || echo '?')
  dmesg=$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo '?')
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo '?')
  usage=$(journalctl --disk-usage 2>&1 | tr '\n' ' ' || true)
  cores=$(awk '/^[^#]/ && $3=="core" {printf "%s=%s ", $2, $4}' "$LIMITS_FILE" 2>/dev/null || true)

  say ""
  say "  --- şimdiki durum ---"
  say "    swap alanı sayısı:      $swaps (0 beklenir)"
  say "    kernel.core_pattern:    $pattern"
  say "    fs.suid_dumpable:       $suid"
  say "    kernel.dmesg_restrict:  $dmesg"
  say "    vm.swappiness:          $swappiness"
  say "    journal:                ${usage:-?}"
  say "    limits.conf core:       ${cores:-<yok>}"
}

# ---------------------------------------------------------------------------
# ana akış
# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) DRY_RUN=1 ;;
      --log-age-days)
        LOG_AGE_DAYS=${2:?"--log-age-days bir sayı ister"}
        shift
        ;;
      --log-age-days=*) LOG_AGE_DAYS=${1#*=} ;;
      -h|--help) usage; exit 0 ;;
      *) printf '%s: bilinmeyen argüman: %s\n\n' "$PROG" "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done

  case "$LOG_AGE_DAYS" in
    ''|*[!0-9]*) printf '%s: --log-age-days pozitif tam sayı olmalı: %s\n' "$PROG" "$LOG_AGE_DAYS" >&2; exit 1 ;;
  esac

  say "zifiri sertleştirme — plan §5.1, §11.4"
  say "ortam: $(uname -srm 2>/dev/null || echo bilinmiyor)"
  if (( DRY_RUN )); then
    say "mod: DRY-RUN (hiçbir şey değiştirilmez)"
  else
    say "mod: UYGULA"
  fi

  # --- platform kapısı ------------------------------------------------------
  # Betik Linux'a özgüdür: /proc/sys, sysctl, systemctl, find -printf.
  # Linux olmayan ortamda (macOS, Windows/MSYS, konteyner host'u) sessizce
  # yarım iş yapmak yerine durur. Dry-run planı yine yazdırır — komutlar
  # çalıştırılmaz, yalnız görünür — ve 2 ile çıkar.
  if ! is_linux; then
    say ""
    say "HATA: bu betik Linux sunucu içindir; bu ortamda uygulanamaz."
    say "  tespit: $(uname -s 2>/dev/null || echo bilinmiyor)"
    say "  gerekli: Linux çekirdeği + /proc/sys + systemd (Debian/Ubuntu VPS,"
    say "           infra/deploy.md). Windows/macOS'ta swapoff, sysctl,"
    say "           systemctl yoktur; komutlar burada çalışmaz."
    if (( DRY_RUN )); then
      say ""
      say "Dry-run planı aşağıda; HİÇBİR komut çalıştırılmadı, hiçbir dosya değiştirilmedi."
      DRY_RUN=1
      step_preflight
      step_swap
      step_sysctl
      step_limits
      step_journald
      step_logs
      step_verify
      say ""
      say "SONUÇ: plan yazdırıldı; uygulanmadı (Linux değil)."
    fi
    exit 2
  fi

  if (( ! DRY_RUN )) && [ "$(id -u)" -ne 0 ]; then
    printf '%s: uygulamak için root gerekli (sudo %s)\n' "$PROG" "$PROG" >&2
    exit 1
  fi

  step_preflight
  step_swap
  step_sysctl
  step_limits
  step_journald
  step_logs
  step_verify

  say ""
  if (( DRY_RUN )); then
    say "SONUÇ: dry-run tamam; hiçbir şey değiştirilmedi."
  else
    say "SONUÇ: sertleştirme uygulandı. Kapsam dışı olanlar harden.md'de."
  fi
}

main "$@"
