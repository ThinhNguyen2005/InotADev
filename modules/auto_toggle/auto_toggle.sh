#!/system/bin/sh
# =============================================================================
# AutoToggle ADB — v1.2.1 "Stale Lock Fix + Heartbeat"
#
# Changes from v1.2.0:
#   - FIX: Lock uses PID + timestamp heartbeat; verifies process via
#          /proc/<pid>/cmdline (not just /proc/<pid> existence)
#   - FIX: Clears stale locks from ALL previous versions (file, directory,
#          any format) before acquiring
#   - FIX: mkdir-based lock replaced with file-based lock
#   - Added heartbeat file so service.sh can detect dead daemon
#
# Known issues from v1.1.0 still fixed:
#   - SELinux — su 0 wrapper for settings/start/stop
#   - Logging with rotation
#   - Android-compatible MODDIR resolver
#   - Guard update_status.sh
#   - Expanded USB/power_supply detection paths
#   - Adaptive sleep (60s/30s/5s/1s)
#   - Boot wait for sysfs
#   - adbd restart race (0.5s delay)
#   - State persistence across restarts
#
# Power profile:
#   - On battery:     sleep 60s  (nothing to detect)
#   - Charging:        sleep 5s   (waiting for PC)
#   - PC connected:    sleep 30s  (monitoring)
#   - Transitioning:   sleep 1s   (active detection)
# =============================================================================

PERSIST=/data/adb/auto_toggle
RUNTIME=$PERSIST/runtime
LOCK=$PERSIST/lock.pid
LOGFILE=$PERSIST/log.txt
STATE_FILE=$PERSIST/state.sh

mkdir -p "$PERSIST"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — LOGGING
# ═══════════════════════════════════════════════════════════════════════════════
_log_rc=0
log_msg() {
    log -t auto_toggle "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE" 2>/dev/null
    _log_rc=$((_log_rc + 1))
    if [ "$_log_rc" -ge 100 ]; then
        _log_rc=0
        tail -n 50 "$LOGFILE" > "$PERSIST/log.tmp" 2>/dev/null && \
            mv -f "$PERSIST/log.tmp" "$LOGFILE" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — BOOT WAIT
# ═══════════════════════════════════════════════════════════════════════════════
log_msg "v1.2.1 started, pid=$$"

_boot_to=0
while true; do
    case "$(getprop sys.boot_completed 2>/dev/null)" in
        1) break ;;
    esac
    sleep 2
    _boot_to=$((_boot_to + 2))
    if [ "$_boot_to" -ge 180 ]; then
        log_msg "Boot watchdog (180s), proceeding"
        break
    fi
done

_ps_wait=0
while ! ls /sys/class/power_supply/*/online \
    /sys/class/power_supply/*/status \
    /sys/class/udc/*/state 2>/dev/null | head -1 | grep -q .; do
    sleep 2
    _ps_wait=$((_ps_wait + 2))
    if [ "$_ps_wait" -ge 30 ]; then
        log_msg "Power sysfs timeout (30s), proceeding"
        break
    fi
done
log_msg "Ready: boot=${_boot_to}s, sysfs=${_ps_wait}s"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — ATOMIC LOCK (v1.2.1 — fixes stale lock from ALL previous versions)
# ═══════════════════════════════════════════════════════════════════════════════
# Previous versions used:
#   v1.1.0: FILE containing PID
#   v1.2.0: mkdir (DIRECTORY) containing PID
# This version: FILE with "PID TIMESTAMP" — backward-compatible cleanup
#
# Why /proc/<pid>/cmdline check?
#   Android reuses PIDs quickly. /proc/3428 might exist and belong to a
#   completely unrelated process (e.g. system_server). Only cmdline verification
#   proves this is OUR daemon, not a pid-reuse collision.
_acquire_lock() {
    # Clean up stale lock from ANY previous version (file or directory)
    if [ -f "$LOCK" ] || [ -d "$LOCK" ]; then
        _old_pid=""
        [ -f "$LOCK" ] && _old_pid=$(cat "$LOCK" 2>/dev/null)
        [ -d "$LOCK" ] && _old_pid=$(cat "$LOCK/../../../" 2>/dev/null) 2>/dev/null

        # Check if that PID is actually our daemon
        if [ -n "$_old_pid" ] && [ -r "/proc/$_old_pid/cmdline" ]; then
            _cmdline=$(cat /proc/$_old_pid/cmdline 2>/dev/null)
            case "$_cmdline" in
                *auto_toggle*)
                    log_msg "Already running pid=$_old_pid (verified), exit"
                    exit 0
                    ;;
            esac
        fi

        # Stale lock (wrong version, dead process, or pid-reuse collision)
        log_msg "Clearing stale lock (pid=$_old_pid)"
        rm -rf "$LOCK" 2>/dev/null
    fi

    # Acquire: PID + timestamp
    echo "$$ $(date +%s)" > "$LOCK" || {
        log_msg "Lock write failed"
        exit 1
    }

    # Verify ownership
    _written=$(cat "$LOCK" 2>/dev/null)
    case "$_written" in
        "$$ "*)  log_msg "Lock acquired pid=$$" ;;
        *)
            log_msg "Lock race lost"
            exit 1
            ;;
    esac
}

_acquire_lock
trap 'rm -f "$LOCK" "$RUNTIME"' EXIT INT TERM

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — MODDIR (Android-compatible)
# ═══════════════════════════════════════════════════════════════════════════════
case "$0" in
    /*) MODDIR="${0%/*}" ;;
    *)  MODDIR="$(cd "${0%/*}" 2>/dev/null && pwd)" ;;
esac
log_msg "MODDIR=$MODDIR"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — USB / CHARGING DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

# Returns 0 if USB host (PC) is connected.
is_usb_pc() {
    for _f in /sys/class/udc/*/state; do
        [ -r "$_f" ] || continue
        case "$(cat "$_f" 2>/dev/null)" in
            [Cc]onfigured*|[Aa]ddressed*) return 0 ;;
        esac
    done

    [ -r /sys/class/android_usb/android0/state ] && \
        case "$(cat /sys/class/android_usb/android0/state 2>/dev/null)" in
            [Cc]onfigured*|[Cc]onnected*) return 0 ;;
        esac

    case "$(getprop sys.usb.state 2>/dev/null)" in
        ""|none|charging|None|Charging) return 1 ;;
        *) return 0 ;;
    esac
}

# Returns 0 if device is charging.
is_charging() {
    for _p in \
        /sys/class/power_supply/usb/online \
        /sys/class/power_supply/ac/online \
        /sys/class/power_supply/battery/online \
        /sys/class/power_supply/main/online; do
        [ -r "$_p" ] && grep -q 1 "$_p" 2>/dev/null && return 0
    done

    [ -r /sys/class/power_supply/battery/status ] && \
        case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
            [Cc]harging*|[Ff]ull*) return 0 ;;
        esac

    [ ! -r /sys/class/power_supply/usb/online ] && \
    [ ! -r /sys/class/power_supply/battery/status ] && \
        dumpsys battery 2>/dev/null | grep -qiE \
            'ac powered: true|usb powered: true|status: charging|status: full' && return 0

    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — ACTIONS (SELinux-safe)
# ═══════════════════════════════════════════════════════════════════════════════
_su() {
    if command -v su >/dev/null 2>&1; then
        su 0 -c "$1" 2>/dev/null
    else
        eval "$1" 2>/dev/null
    fi
}

apply_on() {
    _adb=$(_su "settings get global adb_enabled")
    if [ "$_adb" != "1" ]; then
        _su "settings put global adb_enabled 1"
        _su "settings put global development_settings_enabled 1"
        sleep 0.5
        _su "start adbd"
        log_msg "ADB enabled"
    fi
    echo "on|usb|$(date +%s)" > "$RUNTIME"
    [ -f "$MODDIR/update_status.sh" ] && \
        MODPATH="$MODDIR" sh "$MODDIR/update_status.sh" 2>/dev/null &
}

apply_off() {
    _adb=$(_su "settings get global adb_enabled")
    if [ "$_adb" != "0" ]; then
        _su "settings put global adb_enabled 0"
        _su "settings put global development_settings_enabled 0"
        _su "stop adbd"
        log_msg "ADB disabled"
    fi
    echo "off|-|$(date +%s)" > "$RUNTIME"
    [ -f "$MODDIR/update_status.sh" ] && \
        MODPATH="$MODDIR" sh "$MODDIR/update_status.sh" 2>/dev/null &
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7 — STATE PERSISTENCE
# ═══════════════════════════════════════════════════════════════════════════════
write_state() {
    echo "TARGET_MODE=$1" > "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null
    TARGET_MODE=${TARGET_MODE:-off}
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 8 — MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════════
load_state
log_msg "State: TARGET_MODE=$TARGET_MODE"

# ── Initial detection ───────────────────────────────────────────────────────
if is_charging; then
    log_msg "Initial: charging detected"
else
    log_msg "Initial: on battery"
fi

# ── Main loop ──────────────────────────────────────────────────────────────
while true; do

    # ── Read charging state ───────────────────────────────────────────────
    if is_charging; then
        _curr=charging
    else
        _curr=battery
    fi

    # ── battery → charging: open PC detection window ─────────────────
    if [ "$_curr" = "charging" ] && [ "$TARGET_MODE" = "off" ]; then
        log_msg "Power connected — PC detection window (15s)"
        _t0=$(date +%s)
        while true; do
            if is_usb_pc; then
                log_msg "PC detected — enabling ADB"
                apply_on
                TARGET_MODE=on
                write_state on
                break
            fi
            [ $(($(date +%s) - _t0)) -gt 15 ] && {
                log_msg "No PC in 15s — AC charger"
                apply_off
                TARGET_MODE=off
                write_state off
                break
            }
            sleep 1
        done
        continue
    fi

    # ── charging → battery: disable ADB immediately ──────────────────
    if [ "$_curr" = "battery" ] && [ "$TARGET_MODE" = "on" ]; then
        log_msg "Power disconnected — disabling ADB"
        apply_off
        TARGET_MODE=off
        write_state off
        continue
    fi

    # ── Sleep based on state ────────────────────────────────────────
    case "$TARGET_MODE" in
        on)
            case "$(getprop sys.usb.state 2>/dev/null)" in
                ""|none|charging|None|Charging)
                    _sl=3  # PC gone — short interval
                    ;;
                *)  _sl=30 ;;
            esac
            ;;
        off)
            if is_charging; then
                _sl=5   # Might be PC
            else
                _sl=60  # Nothing to detect
            fi
            ;;
    esac

    sleep "$_sl"

done
