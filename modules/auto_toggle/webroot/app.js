/* AutoToggle WebUI Monitor & Diagnostics */
(() => {
'use strict';

const PERSIST_DIR = '/data/adb/auto_toggle';
const LOG_PATH    = PERSIST_DIR + '/log.txt';
const RUNTIME     = PERSIST_DIR + '/runtime';
const MOD_DIR     = '/data/adb/modules/auto_toggle';

const bridge = (() => {
    const k = (typeof ksu !== 'undefined' && ksu) || window.ksu;
    if (k && typeof k.exec === 'function') {
        return {
            exec(cmd) {
                return new Promise((resolve) => {
                    const cb = '__ksu_cb_' + Math.random().toString(36).slice(2) + Date.now();
                    window[cb] = (errno, stdout, stderr) => {
                        delete window[cb];
                        resolve({ errno: +errno || 0, stdout: stdout ?? '', stderr: stderr ?? '' });
                    };
                    try { k.exec(cmd, '{}', cb); }
                    catch (e) { delete window[cb]; resolve({ errno: -1, stdout: '', stderr: String(e) }); }
                });
            },
        };
    }
    return { exec: (c) => { console.log('[mock]', c); return Promise.resolve({errno:0,stdout:'',stderr:''}); } };
})();

const $ = (s) => document.querySelector(s);
let toastTimer = null;
function toast(msg, kind = '') {
    const el = $('#toast');
    el.textContent = msg;
    el.className = 'toast show ' + kind;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2400);
}
function shQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

/* Chẩn đoán trạng thái hệ thống */
async function detectDaemon() {
    const r = await bridge.exec(`pgrep -f auto_toggle.sh | head -1`);
    const pid = (r.stdout || '').trim();
    return pid ? { running: true, pid } : { running: false };
}

async function detectUSBState() {
    // 1. Kiểm tra xem có đang cắm nguồn sạc không
    const rCharge = await bridge.exec(
        `is_ch=0; ` +
        `for p in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online; do ` +
        `  if [ -r "$p" ] && grep -q '1' "$p"; then is_ch=1; break; fi; ` +
        `done; ` +
        `if [ "$is_ch" -eq 0 ] && [ -r /sys/class/power_supply/battery/status ]; then ` +
        `  s=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z'); ` +
        `  if [ "$s" = "charging" ] || [ "$s" = "full" ]; then is_ch=1; fi; ` +
        `fi; ` +
        `echo "$is_ch"`
    );
    
    const isCharging = (rCharge.stdout || '').trim() === '1';
    if (!isCharging) {
        return 'battery'; // Đang chạy pin (không sạc)
    }

    // 2. Nếu đang sạc, kiểm tra xem có kết nối dữ liệu PC không
    const rPC = await bridge.exec(
        `is_pc=0; ` +
        `for f in /sys/class/udc/*/state; do ` +
        `  s=$(cat "$f" 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z'); ` +
        `  if [ "$s" = "configured" ] || [ "$s" = "addressed" ]; then is_pc=1; break; fi; ` +
        `done; ` +
        `if [ "$is_pc" -eq 0 ]; then ` +
        `  s=$(getprop sys.usb.state 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z'); ` +
        `  if [ -n "$s" ] && [ "$s" != "none" ] && [ "$s" != "charging" ]; then is_pc=1; fi; ` +
        `fi; ` +
        `echo "$is_pc"`
    );

    return (rPC.stdout || '').trim() === '1' ? 'pc' : 'ac';
}

async function detectADB() {
    const r = await bridge.exec(`settings get global adb_enabled 2>/dev/null`);
    return (r.stdout || '').trim() === '1' ? 'on' : 'off';
}

async function fetchLogs() {
    const r = await bridge.exec(`cat ${shQuote(LOG_PATH)} 2>/dev/null | tail -n 60`);
    return (r.stdout || '').trim() || '(Không có dữ liệu nhật ký mới)';
}

async function clearLogs() {
    await bridge.exec(`echo "$(date '+%Y-%m-%d %H:%M:%S') - Clear log file" > ${shQuote(LOG_PATH)}`);
}

async function restartDaemon() {
    await bridge.exec(
        `pkill -f auto_toggle.sh 2>/dev/null; ` +
        `sleep 1; ` +
        `nohup sh ${shQuote(MOD_DIR + '/auto_toggle.sh')} >/dev/null 2>&1 &`
    );
}

async function toggleADB() {
    const adb = await detectADB();
    if (adb === 'on') {
        await bridge.exec(
            `settings put global adb_enabled 0; ` +
            `settings put global development_settings_enabled 0; ` +
            `stop adbd 2>/dev/null; true`
        );
        toast('Đã tắt ADB thủ công', 'warn');
    } else {
        await bridge.exec(
            `settings put global adb_enabled 1; ` +
            `settings put global development_settings_enabled 1; ` +
            `start adbd 2>/dev/null; true`
        );
        toast('Đã bật ADB thủ công', 'ok');
    }
}

function setStatus(id, kind, text) {
    const el = $('#' + id);
    el.className = 'pill pill-' + kind; el.textContent = text;
}

async function refreshLogs() {
    const out = $('#log-output');
    const logs = await fetchLogs();
    
    out.innerHTML = logs.split('\n').map((line) => {
        if (!line.trim()) return '';
        // Phân màu log
        let cls = '';
        if (line.includes('ENABLED') || line.includes('verified') || line.includes('completed')) {
            cls = 'll-i'; // Màu xanh lá / OK
        } else if (line.includes('DISABLED') || line.includes('AC charger') || line.includes('disconnected')) {
            cls = 'll-w'; // Màu vàng / Cảnh báo
        }
        return cls ? `<span class="${cls}">${line}</span>` : `<span>${line}</span>`;
    }).join('\n');
}

async function refreshStatus() {
    const [d, usb, adb] = await Promise.all([
        detectDaemon(), detectUSBState(), detectADB(),
    ]);

    if (d.running) {
        setStatus('daemon-pill', 'ok', `Đang chạy (PID: ${d.pid})`);
    } else {
        setStatus('daemon-pill', 'error', 'Đã dừng');
    }

    if (usb === 'pc') {
        setStatus('usb-pill', 'warn', 'Kết nối Máy tính (PC)');
    } else if (usb === 'ac') {
        setStatus('usb-pill', 'mute', 'Cắm sạc thường (AC)');
    } else {
        setStatus('usb-pill', 'mute', 'Chạy bằng Pin (Unplugged)');
    }

    if (adb === 'on') {
        setStatus('adb-pill', 'ok', 'Đang BẬT');
    } else {
        setStatus('adb-pill', 'warn', 'Đang TẮT');
    }
}

function bindEvents() {
    $('#btn-reload').addEventListener('click', async () => {
        toast('Làm mới thành công', 'ok');
        await Promise.all([refreshStatus(), refreshLogs()]);
    });

    $('#btn-toggle-adb').addEventListener('click', async () => {
        await toggleADB();
        setTimeout(refreshStatus, 800);
    });

    $('#btn-clear-logs').addEventListener('click', async () => {
        if (!confirm('Xóa toàn bộ file log chẩn đoán?')) return;
        await clearLogs();
        toast('Đã xóa log file', 'ok');
        await refreshLogs();
    });

    $('#btn-restart').addEventListener('click', async () => {
        if (!confirm('Bạn có chắc chắn muốn khởi động lại Daemon?')) return;
        await restartDaemon();
        toast('Đang khởi động lại daemon...', 'ok');
        setTimeout(async () => {
            await Promise.all([refreshStatus(), refreshLogs()]);
        }, 1500);
    });

    $('#btn-refresh-logs').addEventListener('click', async () => {
        await refreshLogs();
        toast('Đã cập nhật log chẩn đoán', 'ok');
    });
}

async function init() {
    bindEvents();
    setStatus('daemon-pill', 'loading', 'Đang kết nối…');
    
    // Đọc thông tin phiên bản module
    const r = await bridge.exec(`cat ${shQuote(MOD_DIR + '/module.prop')} 2>/dev/null`);
    const props = {};
    (r.stdout || '').split(/\r?\n/).forEach((l) => {
        const i = l.indexOf('='); if (i > 0) props[l.slice(0, i).trim()] = l.slice(i + 1).trim();
    });
    if (props.name) $('#module-name').textContent = props.name;
    if (props.version) $('#module-version').textContent = props.version + ' | Monitor & Diagnostics';

    await Promise.all([refreshStatus(), refreshLogs()]);
}

document.addEventListener('DOMContentLoaded', init);

// Tự động làm mới trạng thái mỗi 3 giây
setInterval(refreshStatus, 3000);
})();
