#!/system/bin/sh
# Customize script chạy khi Magisk/KernelSU cài module.

SKIPUNZIP=0

ui_print "- HideDevMode Zygisk Module v1.3.0"
ui_print "- Author: InotADev"

if [ "$KSU" = "true" ] || [ "$APATCH" = "true" ]; then
    ui_print "- Phát hiện $([ "$KSU" = "true" ] && echo KernelSU || echo APatch)."
    ui_print "- Yêu cầu zygisk-next được bật."
elif [ "$ZYGISK_ENABLED" = "true" ]; then
    ui_print "- Magisk Zygisk đã bật."
else
    ui_print "! CẢNH BÁO: Zygisk chưa bật."
    ui_print "! Module sẽ không chạy cho đến khi bạn bật Zygisk."
fi

ui_print "- Thiết bị ABI: $(getprop ro.product.cpu.abilist)"
ui_print ""
ui_print "- Để bypass app ngân hàng, cài thêm AutoToggle module."

mkdir -p $MODPATH/system/etc/hide_devmode
if [ ! -f $MODPATH/system/etc/hide_devmode/targets.txt ]; then
    cat > $MODPATH/system/etc/hide_devmode/targets.txt << 'EOF'
*
!com.android.settings
!com.android.systemui
!com.google.android.gms
EOF
fi

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/system/etc/hide_devmode/targets.txt 0 0 0644
[ -f $MODPATH/service.sh ] && set_perm $MODPATH/service.sh 0 0 0755

if [ -d "$MODPATH/webroot" ]; then
    set_perm_recursive $MODPATH/webroot 0 0 0755 0644
    ui_print "- WebUI sẵn sàng."
fi

mkdir -p /data/adb/hide_devmode
ui_print "- Reboot để bắt đầu sử dụng."
