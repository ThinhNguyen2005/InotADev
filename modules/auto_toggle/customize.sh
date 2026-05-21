#!/system/bin/sh
SKIPUNZIP=0

ui_print "- AutoToggle ADB v1.0.0"
ui_print "- Author: InotADev"
ui_print "- Action: USB Auto-Toggle (PC ONLY)"

mkdir -p /data/adb/auto_toggle

set_perm_recursive $MODPATH 0 0 0755 0644
[ -f $MODPATH/auto_toggle.sh ] && set_perm $MODPATH/auto_toggle.sh 0 0 0755
[ -f $MODPATH/service.sh    ] && set_perm $MODPATH/service.sh    0 0 0755
[ -f $MODPATH/update_status.sh ] && set_perm $MODPATH/update_status.sh 0 0 0755

ui_print "- Reboot your device."
