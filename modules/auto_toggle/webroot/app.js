/* AutoToggle WebUI — quản lý daemon tắt thật ADB/Dev. */
(() => {
'use strict';

const PERSIST_DIR = '/data/adb/auto_toggle';
const CFG_PATH    = PERSIST_DIR + '/config.conf';
const APPS_PATH   = PERSIST_DIR + '/danger_apps.txt';
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
function avatarFor(pkg) {
    let h = 0;
    for (let i = 0; i < pkg.length; i++) h = ((h << 5) - h + pkg.charCodeAt(i)) | 0;
    const hue = Math.abs(h) % 360;
    const bg = `linear-gradient(135deg,hsl(${hue} 65% 56%),hsl(${(hue+30)%360} 60% 48%))`;
    const seg = pkg.split('.').filter(Boolean);
    const last = seg[seg.length - 1] || pkg;
    return { bg, letter: (last[0] || '?').toUpperCase() };
}

const state = {
    config: { mode_usb: false, mode_app: false, poll_interval: 2, restore_delay: 3 },
    apps: [],
    runtime: null,
    moduleProp: {},
    appLabels: new Map(),
};

function parseConfig(text) {
    const out = { ...state.config };
    text.split(/\r?\n/).forEach((line) => {
        const t = line.trim();
        if (!t || t.startsWith('#')) return;
        const i = t.indexOf('='); if (i < 0) return;
        const k = t.slice(0, i).trim();
        const v = t.slice(i + 1).trim().toLowerCase();
        if (k === 'mode_usb' || k === 'mode_app') {
            out[k] = (v === '1' || v === 'true' || v === 'yes' || v === 'on');
        } else if (k === 'poll_interval' || k === 'restore_delay') {
            const n = parseInt(v, 10);
            if (Number.isFinite(n) && n > 0) out[k] = n;
        }
    });
    return out;
}
function serializeConfig() {
    const c = state.config;
    return [
        '# AutoToggle config. WebUI tự động ghi.',
        `mode_usb=${+c.mode_usb}`,
        `mode_app=${+c.mode_app}`,
        `poll_interval=${c.poll_interval}`,
        `restore_delay=${c.restore_delay}`, '',
    ].join('\n');
}
function parseApps(text) {
    return text.split(/\r?\n/).map((l) => l.trim())
               .filter((l) => l && !l.startsWith('#'));
}
function serializeApps() {
    return ['# Danh sách app foreground sẽ trigger tắt ADB.',
            ...state.apps, ''].join('\n');
}
function parseRuntime(text) {
    const parts = (text || '').trim().split('|');
    if (!parts[0]) return null;
    return { state: parts[0], reason: parts[1] || '', ts: parseInt(parts[2] || '0', 10) };
}

function utf8ToBase64(str) {
    const bytes = new TextEncoder().encode(str);
    let bin = '';
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
}
async function writeFileAtomic(path, content) {
    const b64 = utf8ToBase64(content);
    const expectedBytes = new TextEncoder().encode(content).length;
    const tmp = '/data/local/tmp/at_' + Math.random().toString(36).slice(2);
    const cmd =
        `mkdir -p ${shQuote(PERSIST_DIR)} && ` +
        `echo ${shQuote(b64)} | base64 -d > ${shQuote(tmp)} && ` +
        `mv ${shQuote(tmp)} ${shQuote(path)} && ` +
        `chmod 0644 ${shQuote(path)}; ` +
        `chcon u:object_r:system_data_file:s0 ${shQuote(path)} 2>/dev/null; ` +
        `rm -f ${shQuote(tmp)} 2>/dev/null; true`;
    const r = await bridge.exec(cmd);
    const sz = await bridge.exec(`wc -c < ${shQuote(path)} 2>/dev/null`);
    const got = parseInt((sz.stdout || '').trim(), 10);
    if (!Number.isFinite(got) || got !== expectedBytes) {
        throw new Error(`byte mismatch: expect=${expectedBytes} got=${got}. ${(r.stderr || '').trim()}`);
    }
}

async function loadAll() {
    await bridge.exec(`mkdir -p ${shQuote(PERSIST_DIR)}`);
    const [r1, r2, r3] = await Promise.all([
        bridge.exec(`cat ${shQuote(CFG_PATH)} 2>/dev/null`),
        bridge.exec(`cat ${shQuote(APPS_PATH)} 2>/dev/null`),
        bridge.exec(`cat ${shQuote(RUNTIME)} 2>/dev/null`),
    ]);
    state.config  = parseConfig(r1.stdout || '');
    state.apps    = parseApps(r2.stdout || '');
    state.runtime = parseRuntime(r3.stdout || '');
}
async function saveAll() {
    await writeFileAtomic(CFG_PATH,  serializeConfig());
    await writeFileAtomic(APPS_PATH, serializeApps());
}
async function loadModuleProp() {
    const r = await bridge.exec(`cat ${shQuote(MOD_DIR + '/module.prop')} 2>/dev/null`);
    const props = {};
    (r.stdout || '').split(/\r?\n/).forEach((l) => {
        const i = l.indexOf('='); if (i > 0) props[l.slice(0, i).trim()] = l.slice(i + 1).trim();
    });
    state.moduleProp = props;
}

/* Status detection */
async function detectDaemon() {
    const r = await bridge.exec(`pgrep -f auto_toggle.sh | head -1`);
    return (r.stdout || '').trim() ? 'running' : 'stopped';
}
async function detectUSB() {
    const r = await bridge.exec(`cat /sys/class/android_usb/android0/state 2>/dev/null`);
    return (r.stdout || '').trim() || 'unknown';
}
async function detectADB() {
    const r = await bridge.exec(`settings get global adb_enabled 2>/dev/null`);
    return (r.stdout || '').trim() === '1' ? 'on' : 'off';
}
async function detectForeground() {
    const r = await bridge.exec(
        `dumpsys activity activities 2>/dev/null | ` +
        `grep -m1 -E 'topResumedActivity|mResumedActivity' | ` +
        `sed -nE 's/.* u[0-9]+ ([a-zA-Z0-9_.]+)\\/.*/\\1/p'`);
    return (r.stdout || '').trim() || '?';
}
async function listInstalledPackages() {
    const r = await bridge.exec(`cmd package list packages -3 2>/dev/null | awk -F: '{print $2}' | sort -u`);
    return (r.stdout || '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
}
async function getAppLabel(pkg) {
    if (state.appLabels.has(pkg)) return state.appLabels.get(pkg);
    const r = await bridge.exec(
        `dumpsys package ${shQuote(pkg)} 2>/dev/null | awk -F= '/nonLocalizedLabel/{print; exit}'`);
    let label = pkg;
    const m = (r.stdout || '').match(/nonLocalizedLabel=([^\s]+(?: [^\s]+)*)/);
    if (m && m[1]) label = m[1].trim();
    state.appLabels.set(pkg, label);
    return label;
}
async function fetchLogs() {
    const r = await bridge.exec(`logcat -d -t 100 -s auto_toggle:V 2>&1 | tail -n 100`);
    return r.stdout || r.stderr || '(không có log)';
}
async function restartDaemon() {
    /* Kill cũ rồi spawn lại từ module dir. */
    await bridge.exec(
        `pkill -f auto_toggle.sh 2>/dev/null; ` +
        `sleep 1; ` +
        `nohup sh ${shQuote(MOD_DIR + '/auto_toggle.sh')} >/dev/null 2>&1 &`);
}

function setStatus(id, kind, text) {
    const el = $('#' + id);
    el.className = 'pill pill-' + kind; el.textContent = text;
}

function renderConfig() {
    $('#mode-usb').checked = state.config.mode_usb;
    $('#mode-app').checked = state.config.mode_app;
    $('#poll-input').value    = state.config.poll_interval;
    $('#restore-input').value = state.config.restore_delay;
    $('#poll-disp').textContent = state.config.poll_interval;
}

function renderApps() {
    const list = $('#apps-list');
    list.innerHTML = '';
    if (!state.apps.length) {
        list.innerHTML = `<div class="empty">Chưa có app. Thêm app banking ở trên.</div>`;
    } else {
        state.apps.forEach((pkg, idx) => {
            const av = avatarFor(pkg);
            const row = document.createElement('div');
            row.className = 'rule include';
            row.innerHTML = `
                <div class="app-icon" style="background:${av.bg}">${av.letter}</div>
                <div class="app-meta">
                    <div class="app-name" data-label-for="${pkg}">${pkg}</div>
                    <div class="app-pkg">${pkg}</div>
                </div>
                <div class="rule-actions">
                    <button class="rule-toggle rule-del" data-idx="${idx}" title="Xoá">
                        <svg viewBox="0 0 24 24" width="14" height="14"><path fill="currentColor" d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12ZM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4Z"/></svg>
                    </button>
                </div>`;
            list.appendChild(row);
        });
        state.apps.forEach((pkg) => {
            getAppLabel(pkg).then((label) => {
                if (label !== pkg) {
                    const el = list.querySelector(`[data-label-for="${CSS.escape(pkg)}"]`);
                    if (el) el.textContent = label;
                }
            });
        });
    }
    $('#apps-count').textContent = state.apps.length;
}

async function refreshStatus() {
    const [d, usb, adb, fg] = await Promise.all([
        detectDaemon(), detectUSB(), detectADB(), detectForeground(),
    ]);
    if (d === 'running') setStatus('daemon-pill', 'ok', 'Đang chạy');
    else                 setStatus('daemon-pill', 'error', 'Đã dừng');

    if (usb === 'CONFIGURED')  setStatus('usb-pill', 'warn', 'Cắm PC');
    else if (usb === 'CONNECTED') setStatus('usb-pill', 'mute', 'Sạc');
    else                       setStatus('usb-pill', 'mute', 'Rút');

    if (adb === 'on')  setStatus('adb-pill', 'ok',   'Bật');
    else               setStatus('adb-pill', 'warn', 'Tắt');

    /* Foreground: highlight đỏ nếu nằm trong danger list. */
    const fgEl = $('#fg-info');
    fgEl.textContent = fg;
    fgEl.style.color = state.apps.includes(fg) ? 'var(--danger)' : 'var(--text)';
    fgEl.style.fontWeight = state.apps.includes(fg) ? '700' : '400';
}

function addApp(rawPkg) {
    const pkg = rawPkg.trim();
    if (!/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg)) {
        toast('Tên package không hợp lệ', 'error'); return false;
    }
    if (state.apps.includes(pkg)) { toast('Đã có trong danh sách', 'error'); return false; }
    state.apps.push(pkg);
    renderApps();
    return true;
}

function bindEvents() {
    $('#mode-usb').addEventListener('change', (e) => { state.config.mode_usb = e.target.checked; });
    $('#mode-app').addEventListener('change', (e) => { state.config.mode_app = e.target.checked; });
    $('#poll-input').addEventListener('change', (e) => {
        const n = parseInt(e.target.value, 10);
        if (Number.isFinite(n) && n > 0) state.config.poll_interval = n;
        $('#poll-disp').textContent = state.config.poll_interval;
    });
    $('#restore-input').addEventListener('change', (e) => {
        const n = parseInt(e.target.value, 10);
        if (Number.isFinite(n) && n >= 0) state.config.restore_delay = n;
    });

    $('#btn-add').addEventListener('click', () => {
        const inp = $('#pkg-input');
        if (addApp(inp.value)) { inp.value = ''; $('#suggest-list').hidden = true; }
    });
    $('#pkg-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#btn-add').click(); });

    $('#apps-list').addEventListener('click', (e) => {
        const btn = e.target.closest('button.rule-del'); if (!btn) return;
        state.apps.splice(+btn.dataset.idx, 1);
        renderApps();
    });

    $('#btn-pick').addEventListener('click', async () => {
        const list = $('#suggest-list');
        if (!list.hidden) { list.hidden = true; return; }
        list.innerHTML = '<div class="suggest-item"><span class="pkg">Đang tải…</span></div>';
        list.hidden = false;
        const pkgs = await listInstalledPackages();
        const have = new Set(state.apps);
        const items = pkgs.filter((p) => !have.has(p));
        list.innerHTML = items.length ? items.map((p) => {
            const av = avatarFor(p);
            return `<div class="suggest-item" data-pkg="${p}">
                <div class="app-icon" style="background:${av.bg};width:24px;height:24px;font-size:11px;border-radius:6px">${av.letter}</div>
                <span class="pkg">${p}</span>
            </div>`;
        }).join('') : '<div class="suggest-item"><span class="pkg">Tất cả đã có</span></div>';
    });
    $('#suggest-list').addEventListener('click', (e) => {
        const item = e.target.closest('.suggest-item');
        if (!item || !item.dataset.pkg) return;
        if (addApp(item.dataset.pkg)) item.remove();
    });
    $('#pkg-input').addEventListener('input', (e) => {
        const list = $('#suggest-list'); if (list.hidden) return;
        const q = e.target.value.trim().toLowerCase();
        list.querySelectorAll('.suggest-item').forEach((it) => {
            it.style.display = (it.textContent || '').toLowerCase().includes(q) ? '' : 'none';
        });
    });

    $('#btn-save').addEventListener('click', async () => {
        const btn = $('#btn-save'); const orig = btn.innerHTML;
        btn.disabled = true; btn.textContent = 'Đang lưu…';
        try { await saveAll(); toast('Đã lưu — daemon sẽ áp dụng ngay', 'ok'); }
        catch (err) { toast('Lỗi lưu: ' + err.message, 'error'); console.error(err); }
        finally { btn.disabled = false; btn.innerHTML = orig; }
    });

    $('#btn-test-off').addEventListener('click', async () => {
        if (!confirm('Tắt ADB ngay (không qua daemon)? Dùng để test.')) return;
        await bridge.exec(
            `settings put global adb_enabled 0; ` +
            `settings put global development_settings_enabled 0; ` +
            `stop adbd 2>/dev/null; true`);
        toast('Đã tắt thật ADB', 'ok');
        setTimeout(refreshStatus, 800);
    });

    $('#btn-restart').addEventListener('click', async () => {
        if (!confirm('Restart daemon?')) return;
        await restartDaemon();
        toast('Đã restart daemon', 'ok');
        setTimeout(refreshStatus, 1500);
    });

    $('#btn-reload').addEventListener('click', () => init(true));

    $('#btn-logs').addEventListener('click', async () => {
        const sec = $('#log-section'); sec.hidden = false;
        sec.scrollIntoView({ behavior: 'smooth', block: 'end' });
        const out = $('#log-output'); out.textContent = 'Đang đọc logcat…';
        const text = await fetchLogs();
        out.innerHTML = text.split('\n').map((line) => {
            const lvl = line.match(/\s([VDIWE])\s/);
            if (!lvl) return line;
            const cls = { I:'ll-i', W:'ll-w', E:'ll-e' }[lvl[1]] || '';
            return cls ? `<span class="${cls}">${line}</span>` : line;
        }).join('\n');
    });
    $('#btn-log-close').addEventListener('click', () => { $('#log-section').hidden = true; });
}

async function init(reload) {
    if (!reload) bindEvents();
    setStatus('daemon-pill', 'loading', 'Đang kiểm tra…');
    try {
        await Promise.all([loadModuleProp(), loadAll()]);
        if (state.moduleProp.name)    $('#module-name').textContent    = state.moduleProp.name;
        if (state.moduleProp.version) $('#module-version').textContent = state.moduleProp.version;
        renderConfig();
        renderApps();
        await refreshStatus();
    } catch (err) {
        setStatus('daemon-pill', 'error', 'Lỗi: ' + err.message);
        console.error(err);
    }
}

document.addEventListener('DOMContentLoaded', () => init(false));

/* Status realtime mỗi 2.5s */
setInterval(refreshStatus, 2500);
})();
