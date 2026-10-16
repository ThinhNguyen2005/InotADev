#!/system/bin/sh
MODDIR="${0%/*}"
BIN="$MODDIR/bin/auto_toggle_d"
DATA_DIR="/data/adb/auto_toggle"
ERR_LOG="$DATA_DIR/service_error.txt"
PROP_FILE="$MODDIR/module.prop"
TILE_PKG="com.inotadev.adbtoggler"

# 1. Đợi hệ thống khởi động hoàn tất
while [ "$(getprop sys.boot_completed)" != "1" ] || [ ! -d "/sdcard/Android" ]; do
    sleep 2
done

mkdir -p "$DATA_DIR" 2>/dev/null
chmod 755 "$BIN" 2>/dev/null

# 2. Cấp quyền cho App Quick Settings Tile (nếu đã cài)
if pm list packages 2>/dev/null | grep -q "^package:${TILE_PKG}$"; then
    pm grant "$TILE_PKG" android.permission.WRITE_SECURE_SETTINGS >/dev/null 2>&1
fi

# 3. Giám sát tiến trình kèm bảo vệ chống Crash-Loop (Dùng monotonic uptime thay vì date +%s)
get_uptime() {
    read -r up _ < /proc/uptime 2>/dev/null
    echo "${up%%.*}"
}

restart_count=0
window_start=$(get_uptime)
[ -z "$window_start" ] && window_start=0

while true; do
    "$BIN"
    exit_code=$?

    # Nếu tiến trình thoát có chủ đích (code 0, VD: đã có instance khác đang chạy và giữ flock), thoát bình thường
    if [ "$exit_code" -eq 0 ]; then
        exit 0
    fi

    now=$(get_uptime)
    [ -z "$now" ] && now=0
    if [ $((now - window_start)) -gt 60 ]; then
        restart_count=0
        window_start=$now
    fi

    restart_count=$((restart_count + 1))

    if [ "$restart_count" -gt 5 ]; then
        printf '%s [CRITICAL] Daemon crash-loop (exit=%s, %s lần trong 60s). Dừng hẳn service.\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$exit_code" "$restart_count" >> "$ERR_LOG" 2>/dev/null

        if [ -w "$PROP_FILE" ]; then
            sed -i "s|^description=.*|description=[Lỗi] Daemon dừng do crash-loop (Xem service_error.txt)|" "$PROP_FILE" 2>/dev/null
        fi
        break
    fi

    sleep 3
done