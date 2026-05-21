#!/system/bin/sh
PERSIST=/data/adb/auto_toggle
RUNTIME=$PERSIST/runtime
LOCK=$PERSIST/lock.pid

mkdir -p "$PERSIST"

# Đợi hệ thống Android khởi động hoàn tất
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" "$RUNTIME"' EXIT INT TERM

is_usb_connected() {
    for f in /sys/class/udc/*/state; do
        if [ -r "$f" ]; then
            read -r s < "$f" 2>/dev/null
            case "$s" in
                [Cc]onfigured*|[Aa]ddressed*)
                    return 0
                    ;;
            esac
        fi
    done

    if [ -r /sys/class/android_usb/android0/state ]; then
        read -r s < /sys/class/android_usb/android0/state 2>/dev/null
        case "$s" in
            [Cc]onfigured*|[Cc]onnected*)
                return 0
                ;;
        esac
    fi

    usb_state=$(getprop sys.usb.state 2>/dev/null)
    case "$usb_state" in
        ""|none|charging|None|Charging)
            ;;
        *)
            return 0
            ;;
    esac

    if dumpsys usb 2>/dev/null | grep -iqE 'connected=true|mconnected=true|connected: true'; then
        return 0
    fi

    return 1
}

is_charging() {
    for p in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online; do
        if [ -r "$p" ]; then
            read -r val < "$p" 2>/dev/null
            case "$val" in
                1*) return 0 ;;
            esac
        fi
    done

    if [ -r /sys/class/power_supply/battery/status ]; then
        read -r s < /sys/class/power_supply/battery/status 2>/dev/null
        case "$s" in
            [Cc]harging*|[Ff]ull*) return 0 ;;
        esac
    fi

    # Dự phòng qua dumpsys battery chỉ chạy khi sysfs không đọc được
    if [ ! -r /sys/class/power_supply/usb/online ] && [ ! -r /sys/class/power_supply/battery/status ]; then
        if dumpsys battery 2>/dev/null | grep -iqE 'ac powered: true|usb powered: true|status: charging|status: full'; then
            return 0
        fi
    fi

    return 1
}

MODDIR=${0%/*}

apply_on() {
    current_adb=$(settings get global adb_enabled 2>/dev/null)
    if [ "$current_adb" != "1" ]; then
        settings put global adb_enabled 1 2>/dev/null
        settings put global development_settings_enabled 1 2>/dev/null
        start adbd 2>/dev/null
    fi
    echo "on|usb|$(date +%s)" > "$RUNTIME"
    MODPATH="$MODDIR" sh "$MODDIR/update_status.sh" 2>/dev/null &
}

apply_off() {
    current_adb=$(settings get global adb_enabled 2>/dev/null)
    if [ "$current_adb" != "0" ]; then
        settings put global adb_enabled 0 2>/dev/null
        settings put global development_settings_enabled 0 2>/dev/null
        stop adbd 2>/dev/null
    fi
    echo "off|-|$(date +%s)" > "$RUNTIME"
    MODPATH="$MODDIR" sh "$MODDIR/update_status.sh" 2>/dev/null &
}

LAST_CHARGING=0
CHECK_ACTIVE=false
CHARGE_START_TIME=0

if is_charging; then
    LAST_CHARGING=1
    CHARGE_START_TIME=$(date +%s)
    CHECK_ACTIVE=true
else
    apply_off
fi

while true; do
    if is_charging; then
        CURRENT_CHARGING=1
    else
        CURRENT_CHARGING=0
    fi

    if [ "$CURRENT_CHARGING" -eq 1 ] && [ "$LAST_CHARGING" -eq 0 ]; then
        CHARGE_START_TIME=$(date +%s)
        CHECK_ACTIVE=true
    fi

    if [ "$CURRENT_CHARGING" -eq 0 ] && [ "$LAST_CHARGING" -eq 1 ]; then
        apply_off
        CHECK_ACTIVE=false
    fi

    LAST_CHARGING=$CURRENT_CHARGING

    if [ "$CURRENT_CHARGING" -eq 1 ] && [ "$CHECK_ACTIVE" = "true" ]; then
        if is_usb_connected; then
            apply_on
            CHECK_ACTIVE=false
        else
            NOW=$(date +%s)
            ELAPSED=$((NOW - CHARGE_START_TIME))
            if [ "$ELAPSED" -gt 15 ]; then
                apply_off
                CHECK_ACTIVE=false
            fi
        fi
    fi

    sleep 3
done