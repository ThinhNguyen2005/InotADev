/* HideDevMode WebUI — chỉ quản lý Zygisk hooks. */
(() => {
'use strict';

const PERSIST_DIR = '/data/adb/hide_devmode';
const CFG_PATH    = PERSIST_DIR + '/targets.txt';
const FEAT_PATH   = PERSIST_DIR + '/features.conf';
const MOD_DIR     = '/data/adb/modules/hide_devmode';

const bridge = (() => {
    const k = (typeof ksu !== 'undefined' && ksu) || window.ksu;
    if (k && typeof k.exec === 'function') {
        return {
            kind: 'ksu',
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
    return { kind: 'mock', exec: (c) => { console.log('[mock]', c); return Promise.resolve({errno:0,stdout:'',stderr:''}); } };
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
    rules: [], wildcard: false, rawHeader: '',
    features: { master_enabled:true, spoof_props:true, hide_dev_options:true, hide_adb:true, hide_adb_wifi:true },
    moduleProp: {}, sysInfo: {}, appLabels: new Map(),
};

function parseTargets(text) {
    const rules = []; let wildcard = false;
    const head = []; let past = false;
    text.split(/\r?\n/).forEach((line) => {
        const t = line.trim();
        if (!past && (!t || t.startsWith('#') || t.startsWith('//'))) { head.push(line); return; }
        past = true;
        if (!t || t.startsWith('#') || t.startsWith('//')) return;
        if (t === '*') { wildcard = true; return; }
        if (t.startsWith('!')) rules.push({ pkg: t.slice(1), exclude: true });
        else                    rules.push({ pkg: t,         exclude: false });
    });
    return { rules, wildcard, header: head.join('\n') };
}
function serializeTargets() {
    const out = [];
    if (state.rawHeader) out.push(state.rawHeader);
    if (state.wildcard) out.push('*');
    state.rules.forEach((r) => out.push((r.exclude ? '!' : '') + r.pkg));
    return out.join('\n') + '\n';
}
function parseFeatures(text) {
    const out = { ...state.features };
    text.split(/\r?\n/).forEach((line) => {
        const t = line.trim();
        if (!t || t.startsWith('#')) return;
        const i = t.indexOf('='); if (i < 0) return;
        const k = t.slice(0, i).trim();
        const v = t.slice(i + 1).trim().toLowerCase();
        const truthy = (v === '1' || v === 'true' || v === 'yes' || v === 'on');
        if (k === 'enabled' || k === 'master_enabled') out.master_enabled = truthy;
        else if (k in out) out[k] = truthy;
    });
    return out;
}
function serializeFeatures() {
    return [
        '# Tự động ghi bởi WebUI. 1 = bật, 0 = tắt.',
        `master_enabled=${+state.features.master_enabled}`,
        `spoof_props=${+state.features.spoof_props}`,
        `hide_dev_options=${+state.features.hide_dev_options}`,
        `hide_adb=${+state.features.hide_adb}`,
        `hide_adb_wifi=${+state.features.hide_adb_wifi}`, '',
    ].join('\n');
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
    const tmp = '/data/local/tmp/hdm_' + Math.random().toString(36).slice(2);
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

async function loadConfig() {
    await bridge.exec(`mkdir -p ${shQuote(PERSIST_DIR)}`);
    const [r1, r2] = await Promise.all([
        bridge.exec(`cat ${shQuote(CFG_PATH)} 2>/dev/null`),
        bridge.exec(`cat ${shQuote(FEAT_PATH)} 2>/dev/null`),
    ]);
    const t = parseTargets(r1.stdout || '');
    state.rules = t.rules; state.wildcard = t.wildcard; state.rawHeader = t.header;
    state.features = parseFeatures(r2.stdout || '');
}
async function saveConfig() {
    await writeFileAtomic(CFG_PATH,  serializeTargets());
    await writeFileAtomic(FEAT_PATH, serializeFeatures());
}
async function loadModuleProp() {
    const r = await bridge.exec(`cat ${shQuote(MOD_DIR + '/module.prop')} 2>/dev/null`);
    const props = {};
    (r.stdout || '').split(/\r?\n/).forEach((l) => {
        const i = l.indexOf('='); if (i > 0) props[l.slice(0, i).trim()] = l.slice(i + 1).trim();
    });
    state.moduleProp = props;
}
async function loadSysInfo() {
    const r = await bridge.exec(`getprop ro.build.version.sdk; getprop ro.product.cpu.abi`);
    const lines = (r.stdout || '').split(/\r?\n/).map((s) => s.trim());
    state.sysInfo = { sdk: lines[0] || '?', abi: lines[1] || '?' };
}
async function detectZygisk() {
    const r = await bridge.exec(
        `if [ -d /data/adb/modules/zygisksu ] || [ -d /data/adb/modules/zygisk-next ]; then echo NEXT; ` +
        `elif [ -x /system/bin/magisk ] || [ -x /sbin/magisk ]; then magisk --zygisk-status 2>/dev/null; ` +
        `else echo OFF; fi`);
    const out = (r.stdout || '').toLowerCase();
    if (out.includes('next')) return 'next';
    if (out.includes('enabled')) return 'magisk';
    return 'off';
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
    const r = await bridge.exec(`logcat -d -t 200 -s zn_hdm:V 2>&1 | tail -n 200`);
    return r.stdout || r.stderr || '(không có log)';
}

function setStatus(id, kind, text) {
    const el = $('#' + id);
    el.className = 'pill pill-' + kind; el.textContent = text;
}

function renderRules() {
    const list = $('#rules');
    list.innerHTML = '';
    if (!state.rules.length) {
        list.innerHTML = `<div class="empty">Chưa có quy tắc. Thêm package ở trên hoặc bật wildcard <code>*</code>.</div>`;
    } else {
        state.rules.forEach((r, idx) => {
            const av = avatarFor(r.pkg);
            const row = document.createElement('div');
            row.className = 'rule ' + (r.exclude ? 'exclude' : 'include');
            row.innerHTML = `
                <div class="app-icon" style="background:${av.bg}">${av.letter}</div>
                <div class="app-meta">
                    <div class="app-name" data-label-for="${r.pkg}">${r.pkg}</div>
                    <div class="app-pkg">${r.pkg}</div>
                </div>
                <div class="rule-actions">
                    <span class="rule-tag">${r.exclude ? 'Loại trừ' : 'Bật ẩn'}</span>
                    <button class="rule-toggle" data-act="toggle" data-idx="${idx}" title="Đảo">
                        <svg viewBox="0 0 24 24" width="14" height="14"><path fill="currentColor" d="M16 12V8h-3v4h-3l4 5 4-5h-2Zm-7 0h2V8h3l-4-5-4 5h3v4Z"/></svg>
                    </button>
                    <button class="rule-toggle rule-del" data-act="del" data-idx="${idx}" title="Xoá">
                        <svg viewBox="0 0 24 24" width="14" height="14"><path fill="currentColor" d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12ZM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4Z"/></svg>
                    </button>
                </div>`;
            list.appendChild(row);
        });
        state.rules.forEach((r) => {
            getAppLabel(r.pkg).then((label) => {
                if (label !== r.pkg) {
                    const el = list.querySelector(`[data-label-for="${CSS.escape(r.pkg)}"]`);
                    if (el) el.textContent = label;
                }
            });
        });
    }
    $('#rules-count').textContent = state.rules.length;
    $('#wildcard-toggle').checked = state.wildcard;
}
function renderFeatures() {
    $('#ft-master').checked  = state.features.master_enabled;
    $('#ft-props').checked   = state.features.spoof_props;
    $('#ft-dev').checked     = state.features.hide_dev_options;
    $('#ft-adb').checked     = state.features.hide_adb;
    $('#ft-adbwifi').checked = state.features.hide_adb_wifi;
}

function addRule(rawPkg) {
    let pkg = rawPkg.trim(); if (!pkg) return false;
    let exclude = false;
    if (pkg.startsWith('!')) { exclude = true; pkg = pkg.slice(1).trim(); }
    if (!/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg)) {
        toast('Tên package không hợp lệ', 'error'); return false;
    }
    if (state.rules.some((r) => r.pkg === pkg)) { toast('Đã có trong danh sách', 'error'); return false; }
    state.rules.push({ pkg, exclude });
    renderRules(); return true;
}

function bindEvents() {
    $('#btn-add').addEventListener('click', () => {
        const inp = $('#pkg-input');
        if (addRule(inp.value)) { inp.value = ''; $('#suggest-list').hidden = true; }
    });
    $('#pkg-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#btn-add').click(); });

    $('#rules').addEventListener('click', (e) => {
        const btn = e.target.closest('button[data-act]'); if (!btn) return;
        const idx = +btn.dataset.idx;
        if (btn.dataset.act === 'del') state.rules.splice(idx, 1);
        else if (btn.dataset.act === 'toggle') state.rules[idx].exclude = !state.rules[idx].exclude;
        renderRules();
    });
    $('#wildcard-toggle').addEventListener('change', (e) => { state.wildcard = e.target.checked; });

    const ftMap = { 'ft-master': 'master_enabled', 'ft-props': 'spoof_props',
        'ft-dev': 'hide_dev_options', 'ft-adb': 'hide_adb', 'ft-adbwifi': 'hide_adb_wifi' };
    Object.entries(ftMap).forEach(([id, key]) => {
        $('#' + id).addEventListener('change', (e) => { state.features[key] = e.target.checked; });
    });

    $('#btn-save').addEventListener('click', async () => {
        const btn = $('#btn-save'); const orig = btn.innerHTML;
        btn.disabled = true; btn.textContent = 'Đang lưu…';
        try { await saveConfig(); toast('Đã lưu cấu hình', 'ok'); }
        catch (err) { toast('Lỗi lưu: ' + err.message, 'error'); console.error(err); }
        finally { btn.disabled = false; btn.innerHTML = orig; }
    });

    $('#btn-forcestop').addEventListener('click', async () => {
        const pkgs = state.rules.filter((r) => !r.exclude).map((r) => r.pkg);
        if (state.wildcard) {
            const all = await listInstalledPackages();
            const excl = new Set(state.rules.filter((r) => r.exclude).map((r) => r.pkg));
            all.forEach((p) => { if (!excl.has(p) && !pkgs.includes(p)) pkgs.push(p); });
        }
        if (!pkgs.length) return toast('Không có app', 'error');
        if (!confirm(`Force stop ${pkgs.length} app?`)) return;
        await bridge.exec(pkgs.map((p) => `am force-stop ${shQuote(p)}`).join('; '));
        toast(`Đã force stop ${pkgs.length} app`, 'ok');
    });

    $('#btn-reboot').addEventListener('click', async () => {
        if (confirm('Khởi động lại?')) await bridge.exec('reboot');
    });
    $('#btn-reload').addEventListener('click', () => init(true));

    $('#btn-pick').addEventListener('click', async () => {
        const list = $('#suggest-list');
        if (!list.hidden) { list.hidden = true; return; }
        list.innerHTML = '<div class="suggest-item"><span class="pkg">Đang tải…</span></div>';
        list.hidden = false;
        const pkgs = await listInstalledPackages();
        const have = new Set(state.rules.map((r) => r.pkg));
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
        if (addRule(item.dataset.pkg)) item.remove();
    });
    $('#pkg-input').addEventListener('input', (e) => {
        const list = $('#suggest-list'); if (list.hidden) return;
        const q = e.target.value.trim().toLowerCase();
        list.querySelectorAll('.suggest-item').forEach((it) => {
            it.style.display = (it.textContent || '').toLowerCase().includes(q) ? '' : 'none';
        });
    });

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
    setStatus('status-pill', 'loading', 'Đang kiểm tra…');
    setStatus('zygisk-pill', 'mute', '—');
    try {
        await Promise.all([loadModuleProp(), loadConfig(), loadSysInfo()]);
        const z = await detectZygisk();
        if (state.moduleProp.name)    $('#module-name').textContent    = state.moduleProp.name;
        if (state.moduleProp.version) $('#module-version').textContent = state.moduleProp.version;
        $('#sdk-info').textContent = `API ${state.sysInfo.sdk} · ${state.sysInfo.abi}`;
        renderFeatures(); renderRules();

        if (z === 'next')        setStatus('zygisk-pill', 'ok',    'Zygisk-Next');
        else if (z === 'magisk') setStatus('zygisk-pill', 'ok',    'Magisk Zygisk');
        else                     setStatus('zygisk-pill', 'error', 'Tắt');

        if (z === 'off')                          setStatus('status-pill', 'error', 'Cần bật Zygisk');
        else if (!state.features.master_enabled)  setStatus('status-pill', 'warn',  'Đã tắt');
        else                                      setStatus('status-pill', 'ok',    'Đang hoạt động');
    } catch (err) {
        setStatus('status-pill', 'error', 'Lỗi: ' + err.message);
        console.error(err);
    }
}
document.addEventListener('DOMContentLoaded', () => init(false));
})();
