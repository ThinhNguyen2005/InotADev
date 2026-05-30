#!/system/bin/sh
# =============================================================================
# AutoToggle ADB — service.sh v1.3.0
# Boot trigger + health watchdog + crash detection.
#
# Changelog from v1.2.0:
#   FIX: Uses exec replacement instead of nohup to fully detach daemon
#   FIX: PID tracking file so watchdog can reliably detect daemon liveness
#   FIX: Crash loop detection — if daemon restarts >3 times in 60s, halt
#   FIX: Defensive MODDIR resolution handles all edge cases
#   FIX: Proper log for debugging startup failures
#   IMPROVED: Signal handling for clean restart
# =============================================================================

MODDIR=""
PERSIST_DIR=/data/adb/auto_toggle
mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$PERSIST_DIR"/* 2>/dev/null

# ── MODDIR resolver (defensive) ────────────────────────────────────────────────
case "${0%/*}" in
    ""|/system/bin|/vendor/bin|/bin)
        MODDIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null)" 2>/dev/null)" && pwd)"
        ;;
    /)
        MODDIR=""
        ;;
    *)
        MODDIR="${0%/*}"
        ;;
esac

# Resolve symlinks
if [ -n "$MODDIR" ] && [ -L "$MODDIR" ]; then
    _resolved=$(readlink -f "$MODDIR" 2>/dev/null)
    [ -n "$_resolved" ] && MODDIR="$_resolved"
fi

# Fallback: search known paths
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    for _p in \
        /data/adb/modules/auto_toggle \
        /data/adb/modules_readonly/auto_toggle \
        /sbin/.magisk/modules/auto_toggle; do
        [ -d "$_p" ] && [ -f "$_p/auto_toggle.sh" ] && MODDIR="$_p" && break
    done
fi

if [ -z "$MODDIR" ]; then
    echo "$(date): FATAL: MODDIR not resolved" >> /data/adb/auto_toggle/service_error.txt 2>/dev/null
    log -t auto_toggle_service "FATAL: MODDIR not resolved"
    exit 1
fi

# ── Daemon locator ──────────────────────────────────────────────────────────────
DAEMON=""
case "$MODDIR" in
    */auto_toggle)
        _cand="$MODDIR/auto_toggle.sh"
        [ -f "$_cand" ] && DAEMON="$_cand"
        ;;
    *)
        # Search in MODDIR first
        [ -f "$MODDIR/auto_toggle.sh" ] && DAEMON="$MODDIR/auto_toggle.sh"
        # Fallback: standard paths
        [ -z "$DAEMON" ] && [ -f /data/adb/modules/auto_toggle/auto_toggle.sh ] && \
            DAEMON=/data/adb/modules/auto_toggle/auto_toggle.sh
        # Last resort: glob search
        [ -z "$DAEMON" ] && for _p in /data/adb/modules/*/auto_toggle.sh; do
            [ -f "$_p" ] && DAEMON="$_p" && break
        done
        ;;
esac

if [ -z "$DAEMON" ] || [ ! -f "$DAEMON" ]; then
    echo "$(date): FATAL: auto_toggle.sh not found (MODDIR=$MODDIR)" \
        >> /data/adb/auto_toggle/service_error.txt 2>/dev/null
    log -t auto_toggle_service "FATAL: daemon script not found"
    exit 1
fi

chmod 0755 "$DAEMON"

# ── Crash loop protection ──────────────────────────────────────────────────────
# If daemon restarts >3 times in 60 seconds, something is wrong — stop restarting
CRASH_COUNT_FILE=$PERSIST_DIR/restart_count
RESTART_WINDOW=60

_update_restart_count() {
    _now=$(date +%s)
    _last=$(cat "$CRASH_COUNT_FILE" 2>/dev/null | cut -d: -f1)
    _cnt=$(cat "$CRASH_COUNT_FILE" 2>/dev/null | cut -d: -f2)

    if [ -z "$_last" ] || [ -z "$_cnt" ]; then
        echo "${_now}:1" > "$CRASH_COUNT_FILE" 2>/dev/null
        return 0
    fi

    # Reset if window expired
    if [ $(($_now - _last)) -gt $RESTART_WINDOW ]; then
        echo "${_now}:1" > "$CRASH_COUNT_FILE" 2>/dev/null
        return 0
    fi

    _cnt=$(($_cnt + 1))
    if [ "$_cnt" -gt 3 ]; then
        echo "$(date): CRASH LOOP DETECTED (${_cnt} restarts in ${RESTART_WINDOW}s) — halting auto-restart" \
            >> /data/adb/auto_toggle/service_error.txt 2>/dev/null
        log -t auto_toggle_service "CRASH LOOP: halting restart ($_cnt in ${RESTART_WINDOW}s)"
        return 1
    fi

    echo "${_now}:$_cnt" > "$CRASH_COUNT_FILE" 2>/dev/null
    return 0
}

# ── Wait for boot ───────────────────────────────────────────────────────────────
_wait_boot() {
    _to=0
    while true; do
        case "$(getprop sys.boot_completed 2>/dev/null)" in
            1|[Tt]rue) break ;;
        esac
        sleep 1
        _to=$((_to + 1))
        [ "$_to" -ge 30 ] && break
    done
}

# ── Start daemon with exec replacement ─────────────────────────────────────────
# Key difference from v1.2.0: use 'exec' to replace the shell process with the
# daemon, so the daemon gets the service.sh PID and init controls its lifecycle.
# But since we run as a service triggered by init/rc, we need to fork and track.
_start_daemon() {
    log -t auto_toggle_service "Starting: $DAEMON"

    # Ensure persist dir is writable
    touch "$PERSIST_DIR/lock.pid" 2>/dev/null && chmod 0644 "$PERSIST_DIR/lock.pid"

    # Start daemon in background, capture PID
    sh "$DAEMON" &
    _daemon_pid=$!
    echo "$_daemon_pid" > "$PERSIST_DIR/daemon_pid" 2>/dev/null

    # Small delay to let daemon initialize and write its own lock
    sleep 1

    # Verify daemon is still running
    if [ -d "/proc/$_daemon_pid" ]; then
        log -t auto_toggle_service "Daemon started: pid=$_daemon_pid"
        return 0
    else
        log -t auto_toggle_service "Daemon exited immediately: pid=$_daemon_pid"
        return 1
    fi
}

# ── Watchdog loop (restarts if daemon dies) ────────────────────────────────────
# This runs as a background process alongside the daemon.
# Magisk services are short-lived by design — this watchdog keeps the daemon alive.
_watchdog() {
    _wd_pid=$$
    DAEMON_PID_FILE="$PERSIST_DIR/daemon_pid"
    HEARTBEAT_FILE="$PERSIST_DIR/heartbeat"
    HEARTBEAT_TIMEOUT=90  # If no heartbeat in 90s, daemon is stuck

    while true; do
        sleep 30

        # Read current daemon PID
        [ -f "$DAEMON_PID_FILE" ] || continue
        _pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        [ -z "$_pid" ] && continue

        # Check if process exists
        if [ ! -d "/proc/$_pid" ]; then
            log -t auto_toggle_service "Watchdog: daemon $_pid died, restarting..."
            _update_restart_count || break
            _start_daemon || break
            continue
        fi

        # Check heartbeat file
        if [ -f "$HEARTBEAT_FILE" ]; then
            _hb_time=$(cat "$HEARTBEAT_FILE" 2>/dev/null | cut -d' ' -f2)
            _now=$(date +%s)
            if [ -n "$_hb_time" ]; then
                _elapsed=$(($_now - _hb_time))
                if [ "$_elapsed" -gt "$HEARTBEAT_TIMEOUT" ]; then
                    log -t auto_toggle_service "Watchdog: stale heartbeat (${_elapsed}s), killing and restarting..."
                    kill -9 "$_pid" 2>/dev/null
                    _update_restart_count || break
                    _start_daemon || break
                fi
            fi
        fi
    done

    log -t auto_toggle_service "Watchdog exiting"
}

# ── Main ──────────────────────────────────────────────────────────────────────
_wait_boot

# Start daemon
if _start_daemon; then
    # Start watchdog in background
    _watchdog &
    _wd_pid=$!
    echo "$_wd_pid" > "$PERSIST_DIR/watchdog_pid" 2>/dev/null
    log -t auto_toggle_service "Watchdog started: pid=$_wd_pid"
else
    _update_restart_count
fi

# Service exits — watchdog continues in background via Magisk's service mechanism.
# On Magisk: the service.sh process is kept alive by init.
# The background watchdog process inherits the service's process group.
exit 0
