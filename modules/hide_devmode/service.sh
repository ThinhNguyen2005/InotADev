#!/system/bin/sh
# service.sh — chạy ở giai đoạn late_start service.
# Khởi tạo persistent config cho hide_devmode (Zygisk hooks).

MODDIR=${0%/*}
PERSIST_DIR=/data/adb/hide_devmode
TEMPLATE_DIR=$MODDIR/system/etc/hide_devmode

mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"

if [ ! -f "$PERSIST_DIR/targets.txt" ] && [ -f "$TEMPLATE_DIR/targets.txt" ]; then
    cp "$TEMPLATE_DIR/targets.txt" "$PERSIST_DIR/targets.txt"
fi

if [ ! -f "$PERSIST_DIR/features.conf" ]; then
    cat > "$PERSIST_DIR/features.conf" << 'EOF'
master_enabled=1
spoof_props=1
hide_dev_options=1
hide_adb=1
hide_adb_wifi=1
EOF
fi

chmod 0644 "$PERSIST_DIR"/*.txt 2>/dev/null
chmod 0644 "$PERSIST_DIR"/*.conf 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR"/* 2>/dev/null

exit 0
