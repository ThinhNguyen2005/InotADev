#!/system/bin/sh
MODDIR=${0%/*}
PERSIST_DIR=/data/adb/auto_toggle

mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR"/* 2>/dev/null

if [ -f "$MODDIR/auto_toggle.sh" ]; then
    nohup sh "$MODDIR/auto_toggle.sh" >/dev/null 2>&1 &
fi
exit 0
