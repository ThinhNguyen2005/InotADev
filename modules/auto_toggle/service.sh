#!/system/bin/sh
# =============================================================================
# AutoToggle ADB — service.sh (boot trigger)
# Runs at boot to launch the daemon. Safe to re-run; daemon exits if already running.
# =============================================================================

# Determine module directory.
# In Magisk, $0 during early-boot service execution is an absolute path.
# Handle ${var%suffix} compatible with mksh/toybox, with dirname fallback.
case "${0%/*}" in
    ""|/system/bin|/vendor/bin)
        # Fallback: compute from /proc/pid
        MODDIR="$(dirname "$(readlink -f "$0" 2>/dev/null)" 2>/dev/null)""
        ;;
    *)
        MODDIR="${0%/*}"
        ;;
esac

# If MODDIR is still empty (toybox/mksh edge case), use pwd-based fallback
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    MODDIR="$(cd "$(dirname "$0")" && pwd)""
fi

PERSIST_DIR=/data/adb/auto_toggle
mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"

# Restore SELinux context for the persist directory
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR"/* 2>/dev/null

# Resolve absolute path to auto_toggle.sh
if [ -f "$MODDIR/auto_toggle.sh" ]; then
    SCRIPT="$MODDIR/auto_toggle.sh"
else
    # Last resort: search common paths
    for _p in \
        /data/adb/modules/auto_toggle/auto_toggle.sh \
        /data/adb/modules/auto_toggle/system/bin/auto_toggle.sh; do
        [ -f "$_p" ] && SCRIPT="$_p" && break
    done
fi

if [ -n "$SCRIPT" ] && [ -f "$SCRIPT" ]; then
    chmod 0755 "$SCRIPT"
    nohup sh "$SCRIPT" >/dev/null 2>&1 &
else
    # Emergency fallback: write error to a known location
    echo "$(date): FATAL: auto_toggle.sh not found. Searched: $MODDIR" \
        >> /data/adb/auto_toggle/service_error.txt 2>/dev/null
fi

exit 0
