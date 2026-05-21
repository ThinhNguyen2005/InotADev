#!/system/bin/sh
# Customize script chạy khi cài module.

SKIPUNZIP=0

ui_print "- AutoToggle ADB v1.0.0"
ui_print "- Author: InotADev"
ui_print ""
ui_print "- Module này KHÔNG dùng Zygisk."
ui_print "- Tự động tắt thật ADB/Dev khi:"
ui_print "    1. Cắm cáp USB vào máy tính (tuỳ chọn)"
ui_print "    2. Mở app trong danh sách (tuỳ chọn)"
ui_print "- Bật lại khi điều kiện không còn."

# Khởi tạo persistent dir
mkdir -p /data/adb/auto_toggle
ui_print "- Config tại: /data/adb/auto_toggle/"

set_perm_recursive $MODPATH 0 0 0755 0644
[ -f $MODPATH/auto_toggle.sh ] && set_perm $MODPATH/auto_toggle.sh 0 0 0755
[ -f $MODPATH/service.sh    ] && set_perm $MODPATH/service.sh    0 0 0755

if [ -d "$MODPATH/webroot" ]; then
    set_perm_recursive $MODPATH/webroot 0 0 0755 0644
    ui_print "- WebUI sẵn sàng. Cấu hình trong KSU/APatch Manager."
fi

ui_print "- Reboot để daemon khởi động."
