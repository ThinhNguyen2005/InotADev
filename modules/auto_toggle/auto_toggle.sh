#!/system/bin/sh
TAG=auto_toggle
PERSIST=/data/adb/auto_toggle
RUNTIME=$PERSIST/runtime
LOCK=$PERSIST/lock.pid
LOGFILE=$PERSIST/log.txt

mkdir -p "$PERSIST"

log_msg() {
    log -t "$TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
    if [ "$(wc -l < "$LOGFILE" 2>/dev/null)" -gt 100 ]; then
        tail -n 50 "$LOGFILE" > "$PERSIST/log.tmp"
        mv "$PERSIST/log.tmp" "$LOGFILE"
    fi
}

# Đợi hệ thống Android khởi động hoàn tất
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

log_msg "System boot completed. Initializing AutoToggle daemon (pid=$$)..."

if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        log_msg "Daemon already running at pid=$pid. Exiting."
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" "$RUNTIME"' EXIT INT TERM

is_usb_connected() {
    for f in /sys/class/udc/*/state; do
        if [ -r "$f" ]; then
            s=$(cat "$f" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [ "$s" = "configured" ] || [ "$s" = "addressed" ]; then
                log_msg "is_usb_connected: UDC state is '$s' (PC connected)"
                return 0
            fi
        fi
    done

    if [ -r /sys/class/android_usb/android0/state ]; then
        s=$(cat /sys/class/android_usb/android0/state 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [ "$s" = "configured" ] || [ "$s" = "connected" ]; then
            log_msg "is_usb_connected: android_usb state is '$s' (PC connected)"
            return 0
        fi
    fi

    usb_state=$(getprop sys.usb.state 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [ -n "$usb_state" ] && [ "$usb_state" != "none" ] && [ "$usb_state" != "charging" ]; then
        log_msg "is_usb_connected: sys.usb.state is '$usb_state' (PC connected)"
        return 0
    fi

    if dumpsys usb 2>/dev/null | grep -iqE 'connected=true|mconnected=true|connected: true'; then
        log_msg "is_usb_connected: dumpsys usb reports connected=true (PC connected)"
        return 0
    fi

    return 1
}

is_charging() {
    for p in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online; do
        if [ -r "$p" ]; then
            read -r val < "$p" 2>/dev/null
            val=${val%%[[:space:]]*} # Strip trailing spaces/carriage returns
            if [ "$val" = "1" ]; then
                return 0
            fi
        fi
    done

    if [ -r /sys/class/power_supply/battery/status ]; then
        read -r s < /sys/class/power_supply/battery/status 2>/dev/null
        s=${s%%[[:space:]]*}
        if [ "$s" = "Charging" ] || [ "$s" = "Full" ] || [ "$s" = "charging" ] || [ "$s" = "full" ]; then
            return 0
        fi
    fi

    # Dự phòng qua dumpsys battery chỉ chạy khi sysfs không đọc được
    if [ ! -r /sys/class/power_supply/usb/online ] && [ ! -r /sys/class/power_supply/battery/status ]; then
        if dumpsys battery 2>/dev/null | grep -iqE 'ac powered: true|usb powered: true|status: charging|status: full'; then
            return 0
        fi
    fi

    return 1
}

apply_on() {
    current_adb=$(settings get global adb_enabled 2>/dev/null)
    if [ "$current_adb" != "1" ]; then
        settings put global adb_enabled 1 2>/dev/null
        settings put global development_settings_enabled 1 2>/dev/null
        start adbd 2>/dev/null
        log_msg "apply_on: ADB enabled successfully"
    fi
    echo "on|usb|$(date +%s)" > "$RUNTIME"
}

apply_off() {
    current_adb=$(settings get global adb_enabled 2>/dev/null)
    if [ "$current_adb" != "0" ]; then
        settings put global adb_enabled 0 2>/dev/null
        settings put global development_settings_enabled 0 2>/dev/null
        stop adbd 2>/dev/null
        log_msg "apply_off: ADB disabled successfully"
    fi
    echo "off|-|$(date +%s)" > "$RUNTIME"
}

LAST_CHARGING=0
CHECK_ACTIVE=false
CHARGE_START_TIME=0

if is_charging; then
    log_msg "Initial state: Charging. Starting USB detection..."
    LAST_CHARGING=1
    CHARGE_START_TIME=$(date +%s)
    CHECK_ACTIVE=true
else
    log_msg "Initial state: On Battery. Ensuring ADB is off."
    apply_off
fi

while true; do
    if is_charging; then
        CURRENT_CHARGING=1
    else
        CURRENT_CHARGING=0
    fi

    if [ "$CURRENT_CHARGING" -eq 1 ] && [ "$LAST_CHARGING" -eq 0 ]; then
        log_msg "Power connected. Starting USB detection window..."
        CHARGE_START_TIME=$(date +%s)
        CHECK_ACTIVE=true
    fi

    if [ "$CURRENT_CHARGING" -eq 0 ] && [ "$LAST_CHARGING" -eq 1 ]; then
        log_msg "Power disconnected. Disabling ADB immediately."
        apply_off
        CHECK_ACTIVE=false
    fi

    LAST_CHARGING=$CURRENT_CHARGING

    if [ "$CURRENT_CHARGING" -eq 1 ] && $CHECK_ACTIVE; then
        if is_usb_connected; then
            log_msg "PC USB connection verified!"
            apply_on
            CHECK_ACTIVE=false
        else
            NOW=$(date +%s)
            ELAPSED=$((NOW - CHARGE_START_TIME))
            if [ "$ELAPSED" -gt 15 ]; then
                log_msg "No PC host detected after 15s. Treating as AC charger."
                apply_off
                CHECK_ACTIVE=false
            fi
        fi
    fi

    sleep 3
done