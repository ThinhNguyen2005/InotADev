#!/system/bin/sh
# service.sh — late_start service trigger.
# Khởi tạo config + spawn daemon background.

MODDIR=${0%/*}
PERSIST_DIR=/data/adb/auto_toggle

mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"

# Seed default config
if [ ! -f "$PERSIST_DIR/config.conf" ]; then
    cat > "$PERSIST_DIR/config.conf" << 'EOF'
# AutoToggle config. WebUI ghi đè file này.
# 1 = bật, 0 = tắt.
mode_usb=0
mode_app=0
poll_interval=2
restore_delay=3
EOF
fi

# Seed danger apps list
if [ ! -f "$PERSIST_DIR/danger_apps.txt" ]; then
    cat > "$PERSIST_DIR/danger_apps.txt" << 'EOF'
# Mỗi dòng 1 package; # là comment.
# Khi app trong danh sách trở thành foreground, daemon sẽ tắt ADB/Dev options.
# Sửa qua WebUI hoặc trực tiếp file này.
EOF
fi

chmod 0644 "$PERSIST_DIR"/*.conf 2>/dev/null
chmod 0644 "$PERSIST_DIR"/*.txt  2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR"/* 2>/dev/null

# Spawn daemon detached background
if [ -x "$MODDIR/auto_toggle.sh" ]; then
    nohup sh "$MODDIR/auto_toggle.sh" >/dev/null 2>&1 &
fi

exit 0
