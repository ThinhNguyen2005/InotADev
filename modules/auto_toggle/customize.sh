#!/system/bin/sh
SKIPUNZIP=0

if [ "$API" -lt 26 ]; then
    abort "! Module yêu cầu Android 8.0 (API 26) trở lên."
fi

ui_print "- Đang cài đặt AutoToggle ADB (Rust Daemon v2.1)..."
mkdir -p "/data/adb/auto_toggle"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/auto_toggle_d" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

ui_print "- Hoàn tất! Hãy khởi động lại máy."