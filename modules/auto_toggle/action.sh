#!/system/bin/sh
# action.sh - Nút hành động nhanh trong KernelSU / Magisk Manager
CONF_DIR="/data/adb/auto_toggle"
CONF_FILE="$CONF_DIR/config.sh"

mkdir -p "$CONF_DIR" 2>/dev/null

current_mode="auto"
if [ -f "$CONF_FILE" ]; then
    current_mode=$(grep '^MODE=' "$CONF_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d "'\" ")
fi

if [ "$current_mode" = "off" ]; then
    target_mode="auto"
else
    target_mode="off"
fi

# Ghi ý định thay đổi vào file cấu hình (Daemon sẽ nhận qua inotify và thực thi)
if grep -q '^MODE=' "$CONF_FILE" 2>/dev/null; then
    sed -i "s|^MODE=.*|MODE=$target_mode|" "$CONF_FILE" 2>/dev/null
else
    echo "MODE=$target_mode" >> "$CONF_FILE"
fi



echo "AutoToggle ADB: Đã chuyển chế độ sang [$target_mode]"
