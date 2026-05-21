#!/system/bin/sh
TAG=auto_toggle
PERSIST=/data/adb/auto_toggle
RUNTIME=$PERSIST/runtime
LOCK=$PERSIST/lock.pid

mkdir -p "$PERSIST"
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" "$RUNTIME"' EXIT INT TERM

log -t "$TAG" "AutoToggle daemon started (pid=$$)"

is_usb_connected() {
    if [ -r /sys/class/android_usb/android0/state ]; then
        [ "$(cat /sys/class/android_usb/android0/state 2>/dev/null)" = "CONFIGURED" ] && return 0
        return 1
    fi
    dumpsys usb 2>/dev/null | grep -q 'mConnected=true' && return 0
    return 1
}

is_charging() {
    for p in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online; do
        if [ -r "$p" ]; then
            [ "$(cat "$p" 2>/dev/null)" = "1" ] && return 0
        fi
    done
    if [ -r /sys/class/power_supply/battery/status ]; then
        s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
        [ "$s" = "Charging" ] || [ "$s" = "Full" ] && return 0
    fi
    dumpsys battery 2>/dev/null | grep -q 'AC powered: true\|USB powered: true' && return 0
    return 1
}

apply_on() {
    if [ "$(settings get global adb_enabled 2>/dev/null)" != "1" ]; then
        settings put global adb_enabled 1 2>/dev/null
        settings put global development_settings_enabled 1 2>/dev/null
        start adbd 2>/dev/null
        log -t "$TAG" "Enabled ADB (USB connected)"
    fi
    echo "on|usb|$(date +%s)" > "$RUNTIME"
}

apply_off() {
    if [ "$(settings get global adb_enabled 2>/dev/null)" != "0" ]; then
        settings put global adb_enabled 0 2>/dev/null
        settings put global development_settings_enabled 0 2>/dev/null
        stop adbd 2>/dev/null
        log -t "$TAG" "Disabled ADB"
    fi
    echo "off|-|$(date +%s)" > "$RUNTIME"
}

LAST_CHARGING=-1
while true; do
    if is_charging; then
        CURRENT_CHARGING=1
    else
        CURRENT_CHARGING=0
    fi

    if [ "$CURRENT_CHARGING" -ne "$LAST_CHARGING" ]; then
        if [ "$CURRENT_CHARGING" -eq 1 ]; then
            usb_connected=false
            for i in 1 2 3 4 5; do
                if is_usb_connected; then
                    usb_connected=true
                    break
                fi
                sleep 1
            done
            if $usb_connected; then
                apply_on
            else
                apply_off
            fi
        else
            apply_off
        fi
        LAST_CHARGING=$CURRENT_CHARGING
    fi
    sleep 3
done
