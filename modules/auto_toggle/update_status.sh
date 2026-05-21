#!/system/bin/sh
PERSIST=/data/adb/auto_toggle
RUNTIME=$PERSIST/runtime
MODPATH=${MODPATH:-.}
MODULE_PROP="$MODPATH/module.prop"

if [ ! -f "$RUNTIME" ]; then
    exit 0
fi

read -r status rest < "$RUNTIME" 2>/dev/null

case "$status" in
    on)
        STATUS_TEXT="✓ ADB: ON (USB)"
        ;;
    off)
        STATUS_TEXT="✗ ADB: OFF"
        ;;
    *)
        exit 0
        ;;
esac

if [ -w "$MODULE_PROP" ]; then
    sed -i "s/^description=.*/description=$STATUS_TEXT - Tự động BẬT ADB khi cắm vào máy tính, TẮT ADB khi rút ra./" "$MODULE_PROP" 2>/dev/null
fi

exit 0
