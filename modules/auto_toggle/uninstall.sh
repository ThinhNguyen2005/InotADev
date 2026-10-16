#!/system/bin/sh
# uninstall.sh - Dọn dẹp và khôi phục cài đặt hệ thống về trạng thái an toàn khi gỡ module

# 1. Dừng daemon nếu đang chạy
if [ -r "/dev/auto_toggle.lock" ]; then
    read -r _pid < "/dev/auto_toggle.lock" 2>/dev/null
    [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
fi
pkill -f "auto_toggle_d" 2>/dev/null

# 2. Khôi phục lại Developer Options và ADB về trạng thái mặc định an toàn
# Tránh trường hợp người dùng gỡ module khi ADB/DevSettings đang bị tắt làm ẩn mất menu Cài đặt
settings put global development_settings_enabled 1 2>/dev/null
settings put global adb_enabled 1 2>/dev/null
start adbd 2>/dev/null

# 3. Dọn dẹp thư mục cấu hình và khóa lock
rm -rf /data/adb/auto_toggle 2>/dev/null
rm -f /dev/auto_toggle.lock 2>/dev/null