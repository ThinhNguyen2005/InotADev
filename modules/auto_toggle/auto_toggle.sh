#!/system/bin/sh
# auto_toggle.sh — Event-driven daemon tự bật/tắt ADB + Developer Options.
#
# Lắng nghe sự kiện hệ thống bằng "am monitor" của Android:
#   - Không hao pin (0% CPU khi màn hình tắt hoặc khi không chuyển app).
#   - Phản ứng tức thì (trong mili-giây) trước khi app ngân hàng kịp khởi chạy.
#   - Lắng nghe trạng thái USB cực nhẹ.

TAG=auto_toggle
PERSIST=/data/adb/auto_toggle
CONFIG=$PERSIST/config.conf
APPLIST=$PERSIST/danger_apps.txt
STATEFILE=$PERSIST/state.bak
RUNTIME=$PERSIST/runtime
FG_FILE=$PERSIST/fg_app
LOCK=$PERSIST/lock.pid

mkdir -p "$PERSIST"

# --- single-instance lock ---------------------------------------------------
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        log -t "$TAG" "Daemon đã chạy pid=$pid, thoát"
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" "$RUNTIME" "$FG_FILE"; pkill -P $$' EXIT INT TERM

log -t "$TAG" "Event-driven daemon started pid=$$"

# --- helpers ----------------------------------------------------------------

is_usb_connected() {
    if [ -r /sys/class/android_usb/android0/state ]; then
        s=$(cat /sys/class/android_usb/android0/state 2>/dev/null)
        [ "$s" = "CONFIGURED" ] && return 0
        return 1
    fi
    if dumpsys usb 2>/dev/null | grep -q 'mConnected=true'; then
        return 0
    fi
    return 1
}

is_in_applist() {
    [ -z "$1" ] && return 1
    [ -f "$APPLIST" ] || return 1
    awk -v p="$1" '!/^#/ && $1==p {found=1} END{exit !found}' "$APPLIST"
}

save_state() {
    adb_v=$(settings get global adb_enabled 2>/dev/null)
    dev_v=$(settings get global development_settings_enabled 2>/dev/null)
    adbw_v=$(settings get global adb_wifi_enabled 2>/dev/null)
    {
        echo "adb=$adb_v"
        echo "dev=$dev_v"
        echo "adbw=$adbw_v"
    } > "$STATEFILE"
    log -t "$TAG" "saved state adb=$adb_v dev=$dev_v adbw=$adbw_v"
}

apply_off() {
    settings put global adb_enabled 0 2>/dev/null
    settings put global development_settings_enabled 0 2>/dev/null
    settings put global adb_wifi_enabled 0 2>/dev/null
    stop adbd 2>/dev/null
}

restore_state() {
    [ -f "$STATEFILE" ] || return
    adb=
    dev=
    adbw=
    . "$STATEFILE"
    [ -n "$adb" ]  && [ "$adb" != "null" ]  && settings put global adb_enabled "$adb" 2>/dev/null
    [ -n "$dev" ]  && [ "$dev" != "null" ]  && settings put global development_settings_enabled "$dev" 2>/dev/null
    [ -n "$adbw" ] && [ "$adbw" != "null" ] && settings put global adb_wifi_enabled "$adbw" 2>/dev/null
    if [ "$adb" = "1" ]; then
        start adbd 2>/dev/null
    fi
    log -t "$TAG" "restored adb=$adb dev=$dev adbw=$adbw"
}

write_runtime() { echo "$1" > "$RUNTIME"; }

evaluate_state() {
    # Đọc cấu hình
    [ -f "$CONFIG" ] && . "$CONFIG"

    should_off=0
    reason="-"

    if [ "$mode_usb" = "1" ] && is_usb_connected; then
        should_off=1
        reason="usb"
    fi

    if [ "$mode_app" = "1" ] && [ "$should_off" = "0" ]; then
        fg_app=$(cat "$FG_FILE" 2>/dev/null)
        if [ -n "$fg_app" ] && is_in_applist "$fg_app"; then
            should_off=1
            reason="app:$fg_app"
        fi
    fi

    # Đọc trạng thái cũ từ runtime file
    is_off=0
    if [ -f "$RUNTIME" ]; then
        current_run_state=$(cat "$RUNTIME" 2>/dev/null | cut -d'|' -f1)
        [ "$current_run_state" = "off" ] && is_off=1
    fi

    if [ "$should_off" = "1" ]; then
        if [ "$is_off" = "0" ]; then
            save_state
            apply_off
            log -t "$TAG" "TẮT ADB vì $reason"
        fi
        write_runtime "off|$reason|$(date +%s)"
    else
        if [ "$is_off" = "1" ]; then
            restore_state
            log -t "$TAG" "BẬT lại ADB"
        fi
        write_runtime "on||$(date +%s)"
    fi
}

# --- Background Loops --------------------------------------------------------

# 1. Loop lắng nghe sự kiện chuyển App bằng "am monitor" (Event-driven)
am_monitor_loop() {
    while true; do
        am monitor 2>/dev/null | while read -r line; do
            case "$line" in
                *"Activity starting:"*)
                    pkg=${line#*Activity starting: }
                    pkg=${pkg%%/*}
                    pkg=$(echo "$pkg" | tr -d '[:space:]')
                    echo "$pkg" > "$FG_FILE"
                    evaluate_state
                    ;;
            esac
        done
        # Nếu am monitor bị crash hoặc chưa khởi tạo xong, ngủ 2s rồi thử lại
        sleep 2
    done
}

# 2. Loop kiểm tra trạng thái USB định kỳ cực nhẹ
usb_monitor_loop() {
    while true; do
        [ -f "$CONFIG" ] && . "$CONFIG"
        if [ "$mode_usb" = "1" ]; then
            evaluate_state
        fi
        sleep 3
    done
}

# 3. Loop lắng nghe logcat START sớm (Đón đầu trước khi tiến trình app kịp fork)
logcat_monitor_loop() {
    # Xoá bớt buffer cũ để tránh đọc log cũ khi khởi động
    logcat -c 2>/dev/null
    while true; do
        logcat -b main -v brief ActivityTaskManager:I ActivityManager:I *:S 2>/dev/null | while read -r line; do
            if [[ "$line" == *"START u0"* ]] && [[ "$line" == *"cmp="* ]]; then
                pkg=${line#*cmp=}
                pkg=${pkg%%/*}
                pkg=$(echo "$pkg" | tr -d '[:space:]')
                if [ -n "$pkg" ]; then
                    echo "$pkg" > "$FG_FILE"
                    evaluate_state
                fi
            fi
        done
        sleep 2
    done
}

# Chạy song song 3 loop
usb_monitor_loop &
am_monitor_loop &
logcat_monitor_loop &

# Đợi cho các tiến trình con chạy vô hạn
wait
