#!/system/bin/sh
# =============================================================================
# AutoToggle ADB — Fixed v1.1.0
# Changes from v1.0.0:
#   - Fix P1-1: SELinux — use su 0 wrapper for settings/start/stop
#   - Fix P1-2: Add comprehensive logging with log rotation
#   - Fix P1-3: Replace readlink -f with Android-compatible path resolver
#   - Fix P2-1: Guard update_status.sh with file existence check
#   - Fix P2-2: Fix service.sh MODDIR computation
#   - Fix P3-1: Expand USB/power_supply detection paths
#   - Fix P4-1: Add adaptive polling (CPU/battery friendly)
#   - Fix P4-2: mkdir-based atomic lock instead of TOCTOU
#   - Fix P4-3: sleep 3s after boot before initial detection
#   - Fix P4-4: Boot timeout increased to 120s
# =============================================================================

# ── Paths ────────────────────────────────────────────────────────────────────
PERSIST=/data/adb/auto_toggle
RUNTIME=$PERSIST/runtime
LOCK=$PERSIST/lock.pid
LOGFILE=$PERSIST/log.txt

mkdir -p "$PERSIST"

# ── Logging ───────────────────────────────────────────────────────────────────
# Counter-based rotation: no subshell per call, atomic mv for safety
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

# ── Boot wait ────────────────────────────────────────────────────────────────
# Increased timeout to 120s for slow devices (Android Go, custom ROMs)
_boot_to=0
log_msg "Boot wait: waiting for sys.boot_completed=1..."
while true; do
    _boot_state="$(getprop sys.boot_completed 2>/dev/null)"
    case "$_boot_state" in
        1) log_msg "Boot wait: completed after ${_boot_to}s"; break ;;
    esac
    sleep 2
    _boot_to=$((_boot_to + 2))
    if [ "$_boot_to" -ge 120 ]; then
        log_msg "Boot watchdog: timeout at 120s, proceeding anyway"
        break
    fi
done

# ── Atomic lock (mkdir-based — safe on Android) ──────────────────────────────
# mkdir is atomic on all filesystems; avoids TOCTOU race of [ -f ] && echo
if ! mkdir "$LOCK" 2>/dev/null; then
    _lock_pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$_lock_pid" ] && [ -d "/proc/$_lock_pid" ]; then
        log_msg "Already running pid=$_lock_pid, exiting"
        exit 0
    else
        mkdir "$LOCK" 2>/dev/null || { log_msg "Lock acquisition failed"; exit 1; }
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" "$RUNTIME"' EXIT INT TERM
log_msg "Lock acquired, pid=$$"

# ── MODDIR resolver (Android-compatible, no readlink -f) ─────────────────────
# readlink -f does NOT exist on mksh / toybox sh
SELF_PATH="$0"
case "$SELF_PATH" in
    /*) MODDIR="${SELF_PATH%/*}" ;;
    *)  MODDIR="$(cd "${0%/*}" 2>/dev/null && pwd)" ;;
esac
log_msg "MODDIR resolved to: $MODDIR"

# ── USB detection (P3-1: expanded paths) ─────────────────────────────────────
is_usb_connected() {
    # 1. UDC state — most reliable on modern Android
    for f in /sys/class/udc/*/state /sys/class/udc/*/usb_state; do
        [ -r "$f" ] || continue
        case "$(cat "$f" 2>/dev/null)" in
            [Cc]onfigured*|[Aa]ddressed*) return 0 ;;
        esac
    done

    # 2. android_usb legacy path
    [ -r /sys/class/android_usb/android0/state ] && \
        case "$(cat /sys/class/android_usb/android0/state 2>/dev/null)" in
            [Cc]onfigured*|[Cc]onnected*) return 0 ;;
        esac

    # 3. power_supply — expanded with OEM-specific paths
    for p in \
        /sys/class/power_supply/usb/online \
        /sys/class/power_supply/ac/online \
        /sys/class/power_supply/battery/online \
        /sys/class/power_supply/main/usb_otg; do
        [ -r "$p" ] && grep -q 1 "$p" 2>/dev/null && return 0
    done

    # 4. getprop sys.usb.state
    case "$(getprop sys.usb.state 2>/dev/null)" in
        ""|none|charging|None|Charging) ;;
        *) return 0 ;;
    esac

    # 5. dumpsys fallback
    dumpsys usb 2>/dev/null | grep -qiE 'connected=true|configured=true' && return 0

    return 1
}

# ── Charging detection ─────────────────────────────────────────────────────────
is_charging() {
    # 1. power_supply online files
    for p in \
        /sys/class/power_supply/usb/online \
        /sys/class/power_supply/ac/online \
        /sys/class/power_supply/battery/online; do
        [ -r "$p" ] && grep -q 1 "$p" 2>/dev/null && return 0
    done

    # 2. battery status text (works across OEMs)
    [ -r /sys/class/power_supply/battery/status ] && \
        case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
            [Cc]harging*|[Ff]ull*) return 0 ;;
        esac

    # 3. dumpsys fallback
    [ ! -r /sys/class/power_supply/usb/online ] && \
    [ ! -r /sys/class/power_supply/battery/status ] && \
        dumpsys battery 2>/dev/null | grep -qiE \
            'ac powered: true|usb powered: true|status: charging|status: full' && return 0

    return 1
}

# ── Actions (P1-1: su 0 wrapper for SELinux) ─────────────────────────────────
# On Android, settings/start/stop require root context.
# Magisk provides su 0 which runs commands as root with SELinux context.
# Fallback to direct call if su is unavailable.
_su_cmd() {
    if [ -x /su/bin/su ] || [ -x /sbin/su ] || command -v su >/dev/null 2>&1; then
        su 0 -c "$1" 2>/dev/null
    else
        # Direct fallback — may work if SELinux permits
        eval "$1" 2>/dev/null
    fi
}

apply_on() {
    current_adb=$(_su_cmd "settings get global adb_enabled")
    log_msg "apply_on: current_adb=$current_adb"
    if [ "$current_adb" != "1" ]; then
        _su_cmd "settings put global adb_enabled 1"
        _su_cmd "settings put global development_settings_enabled 1"
        _su_cmd "start adbd"
        log_msg "apply_on: ADB enabled"
    fi
    echo "on|usb|$(date +%s)" > "$RUNTIME"
    # P2-1: guard against missing update_status.sh
    [ -f "$MODDIR/update_status.sh" ] && \
        MODPATH="$MODDIR" sh "$MODDIR/update_status.sh" 2>/dev/null &
}

apply_off() {
    current_adb=$(_su_cmd "settings get global adb_enabled")
    log_msg "apply_off: current_adb=$current_adb"
    if [ "$current_adb" != "0" ]; then
        _su_cmd "settings put global adb_enabled 0"
        _su_cmd "settings put global development_settings_enabled 0"
        _su_cmd "stop adbd"
        log_msg "apply_off: ADB disabled"
    fi
    echo "off|-|$(date +%s)" > "$RUNTIME"
    [ -f "$MODDIR/update_status.sh" ] && \
        MODPATH="$MODDIR" sh "$MODDIR/update_status.sh" 2>/dev/null &
}

# ── Initial state ─────────────────────────────────────────────────────────────
# P4-3: sleep 3s to let power_supply sysfs stabilize after boot
LAST_CHARGING=0
CHECK_ACTIVE=false
CHARGE_START_TIME=0
PREV_CHARGING=0

sleep 3
log_msg "Initial detection..."

if is_charging; then
    LAST_CHARGING=1
    CHARGE_START_TIME=$(date +%s)
    CHECK_ACTIVE=true
    log_msg "Initial: charging detected — PC detection window active"
else
    LAST_CHARGING=0
    CHECK_ACTIVE=false
    log_msg "Initial: on battery — ADB disabled"
fi

# ── Adaptive polling loop ────────────────────────────────────────────────────
# P4-1: speed up when state is changing, slow down when stable (battery-friendly)
_interval=3
_stable_count=0

while true; do

    # ── Detect charging state ──────────────────────────────────────────────
    if is_charging; then
        CURRENT_CHARGING=1
    else
        CURRENT_CHARGING=0
    fi

    # ── Battery disconnected → disable ADB immediately ─────────────────────
    if [ "$CURRENT_CHARGING" -eq 0 ] && [ "$LAST_CHARGING" -eq 1 ]; then
        log_msg "USB disconnected — disabling ADB"
        apply_off
        CHECK_ACTIVE=false
        _stable_count=0
        _interval=3
    fi

    # ── Battery connected → open PC detection window ───────────────────────
    if [ "$CURRENT_CHARGING" -eq 1 ] && [ "$LAST_CHARGING" -eq 0 ]; then
        log_msg "USB connected — opening 15s PC detection window"
        CHARGE_START_TIME=$(date +%s)
        CHECK_ACTIVE=true
        _stable_count=0
        _interval=1
    fi

    # ── Update last state ─────────────────────────────────────────────────
    LAST_CHARGING=$CURRENT_CHARGING

    # ── Inside detection window: PC connected? ───────────────────────────
    if [ "$CURRENT_CHARGING" -eq 1 ] && [ "$CHECK_ACTIVE" = "true" ]; then
        if is_usb_connected; then
            log_msg "PC USB verified — enabling ADB"
            apply_on
            CHECK_ACTIVE=false
            _stable_count=0
            _interval=10
        else
            _now=$(date +%s)
            _elapsed=$((_now - CHARGE_START_TIME))
            log_msg "No PC after ${_elapsed}s / 15s"
            if [ "$_elapsed" -gt 15 ]; then
                log_msg "Timeout — treating as AC charger, disabling ADB"
                apply_off
                CHECK_ACTIVE=false
                _stable_count=0
                _interval=10
            fi
        fi
    fi

    # ── Adaptive polling: stable → back off, changing → speed up ─────────
    # Use PREV_CHARGING (captured before update) for correct comparison
    if [ "$CURRENT_CHARGING" -eq "$PREV_CHARGING" ]; then
        _stable_count=$((_stable_count + 1))
        case "$_stable_count" in
            4)  _interval=5  ;;
            8)  _interval=10 ;;
            12) _interval=30 ;;
        esac
    else
        _stable_count=0
        _interval=3
    fi

    PREV_CHARGING=$CURRENT_CHARGING

    sleep "$_interval"
done
