#!/bin/bash
# ============================================================
# Android Bilgi Toplayıcı - Live USB Otomatik Başlatma
# /usr/local/bin/android_collect.sh
#
# Live Linux açılınca systemd bu scripti çalıştırır.
# Android cihaz bağlanınca ADB ile bilgileri çeker,
# USB belleğin /reports/ klasörüne kaydeder.
# ============================================================

TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
REPORT_DIR=""
LOG_FILE="/tmp/collector.log"

# Terminale ve log'a yaz
log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============================================================
# USB KAYIT DİSKİNİ BUL (kendimiz, live usb)
# ============================================================
find_save_dir() {
    # Live USB'nin mount noktasını bul (ext4 veya vfat olan)
    for mp in /media /mnt /run/media/user /run/media; do
        while IFS= read -r dir; do
            [ -w "$dir" ] && echo "$dir/reports" && return 0
        done < <(find "$mp" -maxdepth 3 -type d 2>/dev/null)
    done
    # Fallback: /tmp
    echo "/tmp/reports"
}

# ============================================================
# ADB CİHAZ BEKLE
# ============================================================
wait_for_devices() {
    log "Android cihaz bekleniyor... (USB kabloyu takın)"
    log "Cihazda: Ayarlar → Geliştirici → USB Hata Ayıklama AÇIK olmalı"

    while true; do
        # Bağlı ve yetkili cihazları al
        DEVICES=$(adb devices 2>/dev/null \
            | grep -v "List of" \
            | grep -v "^$" \
            | grep "device$" \
            | awk '{print $1}')

        # Unauthorized cihaz varsa uyar
        UNAUTH=$(adb devices 2>/dev/null | grep "unauthorized")
        if [ -n "$UNAUTH" ]; then
            log "⚠ Cihaz bağlı ama 'Bu bilgisayara güven?' onayı bekleniyor!"
            log "  Lütfen cihaz ekranında ONAYLA tuşuna bas."
        fi

        if [ -n "$DEVICES" ]; then
            DEVICE_COUNT=$(echo "$DEVICES" | wc -l)
            log "✓ $DEVICE_COUNT cihaz bulundu"
            echo "$DEVICES"
            return 0
        fi

        sleep 3
    done
}

# ============================================================
# TEK CİHAZDAN BİLGİ ÇEK
# ============================================================
collect_device() {
    local SERIAL="$1"
    local ADB="adb -s $SERIAL"

    log "─────────────────────────────────"
    log "Cihaz: $SERIAL"
    log "Bilgiler alınıyor..."

    # --- Temel bilgiler ---
    BRAND=$(        $ADB shell getprop ro.product.brand            2>/dev/null | tr -d '\r\n')
    MODEL=$(        $ADB shell getprop ro.product.model            2>/dev/null | tr -d '\r\n')
    MANUFACTURER=$( $ADB shell getprop ro.product.manufacturer     2>/dev/null | tr -d '\r\n')
    ANDROID_VER=$(  $ADB shell getprop ro.build.version.release    2>/dev/null | tr -d '\r\n')
    SDK=$(          $ADB shell getprop ro.build.version.sdk        2>/dev/null | tr -d '\r\n')
    BUILD_ID=$(     $ADB shell getprop ro.build.id                 2>/dev/null | tr -d '\r\n')
    SECURITY=$(     $ADB shell getprop ro.build.version.security_patch 2>/dev/null | tr -d '\r\n')
    BOARD=$(        $ADB shell getprop ro.board.platform           2>/dev/null | tr -d '\r\n')
    CPU_ABI=$(      $ADB shell getprop ro.product.cpu.abi          2>/dev/null | tr -d '\r\n')
    HARDWARE=$(     $ADB shell getprop ro.hardware                 2>/dev/null | tr -d '\r\n')
    DEVICE=$(       $ADB shell getprop ro.product.device           2>/dev/null | tr -d '\r\n')

    # --- RAM ---
    RAM_KB=$($ADB shell cat /proc/meminfo 2>/dev/null \
        | grep MemTotal | awk '{print $2}' | tr -d '\r\n')
    RAM_MB=$(( ${RAM_KB:-0} / 1024 ))
    RAM_GB=$(( RAM_MB / 1024 ))

    # --- Depolama ---
    STORAGE_KB=$($ADB shell df /data 2>/dev/null \
        | tail -1 | awk '{print $2}' | tr -d 'KkGgMm\r\n')
    # Bazı cihazlar farklı birim verir, basit tahmin:
    if [ "${STORAGE_KB:-0}" -gt 1000000 ] 2>/dev/null; then
        STORAGE_GB=$(( STORAGE_KB / 1024 / 1024 ))
    else
        STORAGE_GB="?"
    fi

    # --- Ekran ---
    RESOLUTION=$($ADB shell wm size 2>/dev/null \
        | grep -o '[0-9]*x[0-9]*' | head -1 | tr -d '\r\n')
    DENSITY=$($ADB shell wm density 2>/dev/null \
        | grep -o '[0-9]*$' | tr -d '\r\n')

    # --- İşlemci ---
    CPU_MODEL=$($ADB shell cat /proc/cpuinfo 2>/dev/null \
        | grep -iE "^Hardware|^Processor|model name" \
        | head -1 | cut -d: -f2 | xargs | tr -d '\r\n')
    CPU_CORES=$($ADB shell nproc 2>/dev/null | tr -d '\r\n')

    # --- Pil ---
    BAT_LEVEL=$(  $ADB shell cat /sys/class/power_supply/battery/capacity  2>/dev/null | tr -d '\r\n')
    BAT_STATUS=$( $ADB shell cat /sys/class/power_supply/battery/status    2>/dev/null | tr -d '\r\n')
    BAT_HEALTH=$( $ADB shell cat /sys/class/power_supply/battery/health    2>/dev/null | tr -d '\r\n')
    BAT_TEMP_RAW=$($ADB shell cat /sys/class/power_supply/battery/temp     2>/dev/null | tr -d '\r\n')
    BAT_TEMP=$(( ${BAT_TEMP_RAW:-0} / 10 ))

    # --- WiFi MAC ---
    WIFI_MAC=$($ADB shell cat /sys/class/net/wlan0/address 2>/dev/null | tr -d '\r\n')

    log "  $BRAND $MODEL | Android $ANDROID_VER | ${RAM_MB}MB RAM | %${BAT_LEVEL}"

    # ---- JSON dosyası ----
    local SAFE_MODEL=$(echo "$MODEL" | tr ' /\\:*?"<>|' '_________')
    local JSON_FILE="${REPORT_DIR}/${SAFE_MODEL}_${SERIAL}.json"

    cat > "$JSON_FILE" << EOF
{
  "toplama_tarihi": "${TIMESTAMP}",
  "seri_no": "${SERIAL}",
  "cihaz": {
    "marka": "${BRAND}",
    "uretici": "${MANUFACTURER}",
    "model": "${MODEL}",
    "device_kodu": "${DEVICE}"
  },
  "yazilim": {
    "android_surum": "${ANDROID_VER}",
    "sdk_seviyesi": "${SDK}",
    "build_id": "${BUILD_ID}",
    "guvenlik_yamasi": "${SECURITY}"
  },
  "islemci": {
    "platform": "${BOARD}",
    "model": "${CPU_MODEL}",
    "cekirdek_sayisi": "${CPU_CORES}",
    "mimari": "${CPU_ABI}",
    "hardware": "${HARDWARE}"
  },
  "bellek": {
    "ram_mb": ${RAM_MB},
    "ram_gb": ${RAM_GB}
  },
  "depolama_gb": "${STORAGE_GB}",
  "ekran": {
    "cozunurluk": "${RESOLUTION}",
    "yogunluk_dpi": "${DENSITY}"
  },
  "pil": {
    "seviye_yuzde": "${BAT_LEVEL}",
    "durum": "${BAT_STATUS}",
    "saglik": "${BAT_HEALTH}",
    "sicaklik_c": ${BAT_TEMP}
  },
  "ag": {
    "wifi_mac": "${WIFI_MAC}"
  }
}
EOF

    log "  ✓ JSON kaydedildi: $(basename $JSON_FILE)"
    echo "${TIMESTAMP},${SERIAL},${BRAND},${MODEL},${ANDROID_VER},${SDK},${RAM_MB},${STORAGE_GB},${RESOLUTION},${CPU_CORES},${BOARD},${BAT_LEVEL}%,${BAT_HEALTH}" >> "${REPORT_DIR}/rapor.csv"
}

# ============================================================
# ANA PROGRAM
# ============================================================

clear
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Android Cihaz Bilgi Toplayıcı                 ║"
echo "║        Live USB - Otomatik Mod                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Kayıt dizinini hazırla
REPORT_DIR=$(find_save_dir)
mkdir -p "$REPORT_DIR"
log "Kayıt dizini: $REPORT_DIR"

# CSV başlığı
CSV_HEADER="Tarih,Seri,Marka,Model,Android,SDK,RAM_MB,Depolama_GB,Ekran,CPU_Cekirdek,CPU_Platform,Pil,Pil_Saglik"
if [ ! -f "${REPORT_DIR}/rapor.csv" ]; then
    echo "$CSV_HEADER" > "${REPORT_DIR}/rapor.csv"
fi

# ADB server başlat
adb kill-server 2>/dev/null
adb start-server 2>/dev/null
log "ADB hazır"
echo ""

# Sürekli döngü - birden fazla cihaz işle
log "Hazır. Android cihazı USB ile bağlayın."
log "(Çıkmak için Ctrl+C)"
echo ""

PROCESSED=()

while true; do
    # Bağlı yetkili cihazları al
    mapfile -t CURRENT_DEVICES < <(adb devices 2>/dev/null \
        | grep -v "List of" | grep "device$" | awk '{print $1}')

    # Unauthorized varsa uyar
    UNAUTH_COUNT=$(adb devices 2>/dev/null | grep -c "unauthorized" || true)
    if [ "$UNAUTH_COUNT" -gt 0 ]; then
        log "⚠ Cihaz bağlı! Ekranda 'Bu bilgisayara güven?' çıktıysa ONAYLA!"
    fi

    for SERIAL in "${CURRENT_DEVICES[@]}"; do
        [ -z "$SERIAL" ] && continue

        # Daha önce işlendi mi?
        ALREADY=0
        for P in "${PROCESSED[@]}"; do
            [ "$P" = "$SERIAL" ] && ALREADY=1 && break
        done

        if [ "$ALREADY" -eq 0 ]; then
            collect_device "$SERIAL"
            PROCESSED+=("$SERIAL")
            sync
            log "Sonraki cihazı bağlayabilirsiniz."
            echo ""
        fi
    done

    sleep 3
done
