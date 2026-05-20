#!/system/bin/sh
# Customize script chạy khi Magisk/KernelSU cài module.

SKIPUNZIP=0

ui_print "- HideDevMode Zygisk Module"
ui_print "- Author: InotADev"

# Kiểm tra Zygisk có bật không. KSU dùng zygisk-next nên ZYGISK_ENABLED có thể không tồn tại.
if [ "$KSU" = "true" ] || [ "$APATCH" = "true" ]; then
  ui_print "- Phát hiện $([ "$KSU" = "true" ] && echo KernelSU || echo APatch). Yêu cầu module zygisk-next được bật."
elif [ "$ZYGISK_ENABLED" = "true" ]; then
  ui_print "- Magisk Zygisk đã bật."
else
  ui_print "! CẢNH BÁO: Zygisk chưa bật. Module sẽ không hoạt động cho đến khi bạn bật Zygisk (hoặc cài zygisk-next)."
fi

ABILIST=$(getprop ro.product.cpu.abilist)
ui_print "- Thiết bị ABI: $ABILIST"

# Tạo thư mục cấu hình mặc định
mkdir -p $MODPATH/system/etc/hide_devmode
if [ ! -f $MODPATH/system/etc/hide_devmode/targets.txt ]; then
  cat > $MODPATH/system/etc/hide_devmode/targets.txt << 'EOF'
# Mỗi dòng là một package cần ẩn Developer/Debug.
# Thêm tiền tố ! để loại trừ. Dùng "*" để áp dụng cho TẤT CẢ ứng dụng non-system.
# Ví dụ:
#   *
#   !com.android.settings
#   com.example.bank
#   com.zhiliaoapp.musically
*
!com.android.settings
!com.android.systemui
!com.google.android.gms
EOF
fi

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/system/etc/hide_devmode/targets.txt 0 0 0644

# Web UI assets — manager đọc từ $MODPATH/webroot/index.html
if [ -d "$MODPATH/webroot" ]; then
    set_perm_recursive $MODPATH/webroot 0 0 0755 0644
    ui_print "- WebUI sẵn sàng. Mở trong KernelSU/APatch Manager."
fi
