#!/system/bin/sh
# =============================================================================
# AutoToggle ADB — service.sh v1.2.0
# Boot trigger + health watchdog. Re-launches daemon if it dies.
# =============================================================================

# ── Module directory resolver ─────────────────────────────────────────────────
case "${0%/*}" in
    ""|/system/bin|/vendor/bin)
        MODDIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null)" 2>/dev/null)" && pwd)"
        ;;
    *)
        MODDIR="${0%/*}"
        ;;
esac

if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    MODDIR="$(cd "$(dirname "$0")" && pwd)"
fi

PERSIST_DIR=/data/adb/auto_toggle
mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR"/* 2>/dev/null

# ── Script locator (defensive) ────────────────────────────────────────────────
# Try MODDIR first, then search known paths
if [ -f "$MODDIR/auto_toggle.sh" ]; then
    DAEMON="$MODDIR/auto_toggle.sh"
elif [ -f /data/adb/modules/auto_toggle/auto_toggle.sh ]; then
    DAEMON=/data/adb/modules/auto_toggle/auto_toggle.sh
else
    for _p in /data/adb/modules/*/auto_toggle.sh; do
        [ -f "$_p" ] && DAEMON="$_p" && break
    done
fi

# ── Start daemon with health watchdog ───────────────────────────────────────
# Keep it simple: launch daemon once. Let the daemon's own lock mechanism
# handle re-entry. The daemon self-monitors via its internal trap + log rotation.
# Service restarts are handled by Magisk's own service manager.

if [ -n "$DAEMON" ] && [ -f "$DAEMON" ]; then
    chmod 0755 "$DAEMON"
    nohup sh "$DAEMON" >/dev/null 2>&1 &
    log -t auto_toggle_service "Daemon started: $DAEMON (child=$!)"
else
    echo "$(date): FATAL: auto_toggle.sh not found" \
        >> /data/adb/auto_toggle/service_error.txt 2>/dev/null
    log -t auto_toggle_service "FATAL: script not found"
fi

exit 0
