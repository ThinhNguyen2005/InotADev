/* ===========================================================================
 * HideDevMode WebUI — app logic
 *
 * Chạy trong KernelSU Manager / APatch Manager / MMRL bằng cách shell out
 * qua window.ksu.exec() (KernelSU/APatch) hoặc window.$KSU bridge (MMRL).
 *
 * Toàn bộ thao tác (đọc/ghi config, list packages, force-stop, reboot) đều
 * thông qua shell command với quyền root mà manager đã cấp.
 * ======================================================================== */
(() => {
'use strict';

const CFG_PATH = '/data/adb/modules/hide_devmode/system/etc/hide_devmode/targets.txt';
const MOD_DIR  = '/data/adb/modules/hide_devmode';

/* ---------------------------------------------------------------------------
 * Bridge: phát hiện môi trường (KernelSU / APatch / MMRL / fallback)
 * và normalize về một hàm exec(cmd) -> Promise<{errno, stdout, stderr}>.
 * ------------------------------------------------------------------------- */
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
                    try {
                        k.exec(cmd, '{}', cb);
                    } catch (e) {
                        delete window[cb];
                        resolve({ errno: -1, stdout: '', stderr: String(e) });
                    }
                });
            },
            toast(msg) { try { k.toast(msg); } catch (e) {} },
        };
    }
    /* Fallback cho dev/test trên trình duyệt PC. */
    return {
        kind: 'mock',
        exec(cmd) {
            console.log('[mock-exec]', cmd);
            return Promise.resolve({ errno: 0, stdout: '', stderr: '' });
        },
        toast(msg) { console.log('[toast]', msg); },
    };
})();

const $  = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

/* ---------------------------------------------------------------------------
 * Toast helper.
 * ------------------------------------------------------------------------- */
let toastTimer = null;
function toast(msg, kind = '') {
    const el = $('#toast');
    el.textContent = msg;
    el.className = 'toast show ' + kind;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
    if (bridge.kind === 'ksu') bridge.toast(msg);
}

/* ---------------------------------------------------------------------------
 * Shell quoting helper (escape strings cho sh -c '...').
 * Cách an toàn: bọc single-quote, escape ' nội tại bằng '\''.
 * ------------------------------------------------------------------------- */
function shQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

/* ---------------------------------------------------------------------------
 * Config model.
 * ------------------------------------------------------------------------- */
const state = {
    rules: [],          // [{ pkg, exclude }]
    wildcard: false,    // có dòng "*" hay không
    rawHeader: '',      // comment đầu file để giữ lại khi save
    moduleProp: {},
    sysInfo: {},
};

function parseConfig(text) {
    const rules = [];
    let wildcard = false;
    const headerLines = [];
    let pastHeader = false;

    text.split(/\r?\n/).forEach((line) => {
        const t = line.trim();
        if (!pastHeader && (t === '' || t.startsWith('#') || t.startsWith('//'))) {
            headerLines.push(line); return;
        }
        pastHeader = true;
        if (t === '' || t.startsWith('#') || t.startsWith('//')) return;
        if (t === '*') { wildcard = true; return; }
        if (t.startsWith('!')) {
            rules.push({ pkg: t.slice(1), exclude: true });
        } else {
            rules.push({ pkg: t, exclude: false });
        }
    });
    return { rules, wildcard, header: headerLines.join('\n') };
}

function serializeConfig() {
    const lines = [];
    if (state.rawHeader) lines.push(state.rawHeader);
    if (state.wildcard) lines.push('*');
    state.rules.forEach((r) => lines.push((r.exclude ? '!' : '') + r.pkg));
    return lines.join('\n') + '\n';
}

/* ---------------------------------------------------------------------------
 * I/O.
 * ------------------------------------------------------------------------- */
async function loadConfig() {
    const r = await bridge.exec(`cat ${shQuote(CFG_PATH)} 2>/dev/null`);
    const parsed = parseConfig(r.stdout || '');
    state.rules = parsed.rules;
    state.wildcard = parsed.wildcard;
    state.rawHeader = parsed.header;
}

async function saveConfig() {
    const content = serializeConfig();
    const tmp = '/data/local/tmp/hide_devmode_targets.txt';
    /* Heredoc với token kết thúc unique để tránh xung đột với nội dung. */
    const tag = 'EOF_' + Math.random().toString(36).slice(2, 10).toUpperCase();
    const cmd =
        `cat > ${shQuote(tmp)} <<'${tag}'\n${content}${tag}\n` +
        `&& cp ${shQuote(tmp)} ${shQuote(CFG_PATH)} ` +
        `&& chmod 0644 ${shQuote(CFG_PATH)} ` +
        `&& chcon u:object_r:system_file:s0 ${shQuote(CFG_PATH)} 2>/dev/null; ` +
        `rm -f ${shQuote(tmp)}`;
    const r = await bridge.exec(cmd);
    if (r.errno !== 0) throw new Error(r.stderr || 'lưu thất bại');
}

async function loadModuleProp() {
    const r = await bridge.exec(`cat ${shQuote(MOD_DIR + '/module.prop')} 2>/dev/null`);
    const props = {};
    (r.stdout || '').split(/\r?\n/).forEach((l) => {
        const i = l.indexOf('=');
        if (i > 0) props[l.slice(0, i).trim()] = l.slice(i + 1).trim();
    });
    state.moduleProp = props;
}

async function loadSysInfo() {
    const r = await bridge.exec(
        `getprop ro.build.version.sdk; ` +
        `getprop ro.product.cpu.abi; ` +
        `getprop ro.product.model`
    );
    const lines = (r.stdout || '').split(/\r?\n/).map((s) => s.trim());
    state.sysInfo = { sdk: lines[0] || '?', abi: lines[1] || '?', model: lines[2] || '?' };
}

async function detectZygisk() {
    /* Trả về một trong: 'magisk-on', 'ksunext', 'apatch-zn', 'off'. */
    const r = await bridge.exec(
        `[ -d /data/adb/modules/zygisksu ] && echo zygisksu; ` +
        `[ -d /data/adb/modules/zygisk-next ] && echo zn; ` +
        `magisk --zygisk-status 2>/dev/null; true`
    );
    const out = (r.stdout || '').toLowerCase();
    if (out.includes('zygisksu') || out.includes('zn')) return 'next';
    if (out.includes('zygisk: enabled') || out.includes('on')) return 'magisk';
    return 'off';
}

async function listInstalledPackages() {
    /* `pm list packages` cần shell có quyền truy cập package manager.
     * Trên Android 11+ root, đường dẫn an toàn nhất: cmd package list packages.
     * Lọc bỏ system app bằng cờ -3. */
    const r = await bridge.exec(`cmd package list packages -3 2>/dev/null | sed 's/^package://' | sort -u`);
    return (r.stdout || '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
}

/* ---------------------------------------------------------------------------
 * Renderers.
 * ------------------------------------------------------------------------- */
function renderRules() {
    const list = $('#rules');
    list.innerHTML = '';

    if (!state.rules.length) {
        list.innerHTML = `
            <div class="empty">Chưa có quy tắc nào. Thêm package ở trên hoặc bật chế độ wildcard <code>*</code>.</div>`;
    } else {
        state.rules.forEach((r, idx) => {
            const row = document.createElement('div');
            row.className = 'rule ' + (r.exclude ? 'exclude' : 'include');
            row.innerHTML = `
                <div class="rule-icon">${r.exclude ? '−' : '+'}</div>
                <div class="rule-pkg" title="${r.pkg}">${r.pkg}</div>
                <button class="rule-del" data-idx="${idx}" title="Xoá">
                    <svg viewBox="0 0 24 24" width="16" height="16">
                        <path fill="currentColor" d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12ZM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4Z"/>
                    </svg>
                </button>`;
            list.appendChild(row);
        });
    }

    $('#rules-count').textContent = state.rules.length;
    $('#wildcard-toggle').checked = state.wildcard;
    $('#stat-targets').textContent = state.rules.length + (state.wildcard ? 1 : 0);
    $('#stat-includes').textContent = state.rules.filter((r) => !r.exclude).length;
    $('#stat-excludes').textContent = state.rules.filter((r) => r.exclude).length;
}

function renderModuleInfo() {
    if (state.moduleProp.name) $('#module-name').textContent = state.moduleProp.name;
    if (state.moduleProp.version) $('#module-version').textContent = state.moduleProp.version;
}

function renderSysInfo() {
    $('#sdk-info').textContent = `API ${state.sysInfo.sdk} · ${state.sysInfo.abi}`;
}

function setStatus(pillId, kind, text) {
    const el = $('#' + pillId);
    el.className = 'pill pill-' + kind;
    el.textContent = text;
}

/* ---------------------------------------------------------------------------
 * Interactions.
 * ------------------------------------------------------------------------- */
function addRule(rawPkg) {
    let pkg = rawPkg.trim();
    if (!pkg) return false;
    let exclude = false;
    if (pkg.startsWith('!')) { exclude = true; pkg = pkg.slice(1).trim(); }
    if (!/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$/.test(pkg)) {
        toast('Tên package không hợp lệ', 'error');
        return false;
    }
    if (state.rules.some((r) => r.pkg === pkg)) {
        toast('Package đã có trong danh sách', 'error');
        return false;
    }
    state.rules.push({ pkg, exclude });
    renderRules();
    return true;
}

function bindEvents() {
    $('#btn-add').addEventListener('click', () => {
        const inp = $('#pkg-input');
        if (addRule(inp.value)) {
            inp.value = '';
            $('#suggest-list').hidden = true;
        }
    });
    $('#pkg-input').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') $('#btn-add').click();
    });

    $('#rules').addEventListener('click', (e) => {
        const btn = e.target.closest('.rule-del');
        if (!btn) return;
        const idx = +btn.dataset.idx;
        state.rules.splice(idx, 1);
        renderRules();
    });

    $('#wildcard-toggle').addEventListener('change', (e) => {
        state.wildcard = e.target.checked;
        renderRules();
    });

    $('#btn-save').addEventListener('click', async () => {
        const btn = $('#btn-save');
        btn.disabled = true; btn.textContent = 'Đang lưu…';
        try {
            await saveConfig();
            toast('Đã lưu cấu hình', 'ok');
        } catch (err) {
            toast('Lỗi lưu: ' + err.message, 'error');
        } finally {
            btn.disabled = false; btn.innerHTML = `
                <svg viewBox="0 0 24 24" width="16" height="16"><path fill="currentColor" d="M17 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V7l-4-4Zm-5 16a3 3 0 1 1 0-6 3 3 0 0 1 0 6Zm3-10H5V5h10v4Z"/></svg>
                Lưu cấu hình`;
        }
    });

    $('#btn-forcestop').addEventListener('click', async () => {
        if (!state.rules.length && !state.wildcard) {
            return toast('Không có app nào để force stop', 'error');
        }
        const pkgs = state.rules.filter((r) => !r.exclude).map((r) => r.pkg);
        if (state.wildcard) {
            // wildcard: lấy tất cả non-system app
            const all = await listInstalledPackages();
            const excl = new Set(state.rules.filter((r) => r.exclude).map((r) => r.pkg));
            all.forEach((p) => { if (!excl.has(p)) pkgs.push(p); });
        }
        if (!pkgs.length) return toast('Không có app nào để force stop', 'error');
        const cmd = pkgs.map((p) => `am force-stop ${shQuote(p)}`).join('; ');
        await bridge.exec(cmd);
        toast(`Đã force stop ${pkgs.length} app`, 'ok');
    });

    $('#btn-reboot').addEventListener('click', async () => {
        if (!confirm('Khởi động lại thiết bị ngay?')) return;
        await bridge.exec('reboot');
    });

    $('#btn-reload').addEventListener('click', () => init(true));

    /* ---- Picker app từ thiết bị --------------------------------------- */
    $('#btn-pick').addEventListener('click', async () => {
        const list = $('#suggest-list');
        if (!list.hidden) { list.hidden = true; return; }
        list.innerHTML = '<div class="suggest-item">Đang tải…</div>';
        list.hidden = false;
        const pkgs = await listInstalledPackages();
        if (!pkgs.length) {
            list.innerHTML = '<div class="suggest-item">Không tìm thấy app nào</div>';
            return;
        }
        const have = new Set(state.rules.map((r) => r.pkg));
        list.innerHTML = pkgs
            .filter((p) => !have.has(p))
            .map((p) => `<div class="suggest-item" data-pkg="${p}">${p}</div>`)
            .join('') || '<div class="suggest-item">Tất cả đã có trong danh sách</div>';
    });
    $('#suggest-list').addEventListener('click', (e) => {
        const item = e.target.closest('.suggest-item');
        if (!item || !item.dataset.pkg) return;
        if (addRule(item.dataset.pkg)) item.remove();
    });

    /* Filter realtime trong suggest list */
    $('#pkg-input').addEventListener('input', (e) => {
        const list = $('#suggest-list');
        if (list.hidden) return;
        const q = e.target.value.trim().toLowerCase();
        list.querySelectorAll('.suggest-item').forEach((it) => {
            it.style.display = it.textContent.toLowerCase().includes(q) ? '' : 'none';
        });
    });
}

/* ---------------------------------------------------------------------------
 * Bootstrap.
 * ------------------------------------------------------------------------- */
async function init(reload) {
    if (!reload) bindEvents();
    setStatus('status-pill', 'loading', 'Đang kiểm tra…');
    setStatus('zygisk-pill', 'mute', '—');

    try {
        await Promise.all([loadModuleProp(), loadConfig(), loadSysInfo()]);
        const z = await detectZygisk();

        renderModuleInfo();
        renderSysInfo();
        renderRules();

        if (z === 'next')         setStatus('zygisk-pill', 'ok',    'Zygisk-Next');
        else if (z === 'magisk')  setStatus('zygisk-pill', 'ok',    'Magisk Zygisk');
        else                      setStatus('zygisk-pill', 'error', 'Tắt');

        if (z === 'off') setStatus('status-pill', 'error', 'Cần bật Zygisk');
        else             setStatus('status-pill', 'ok',    'Đang hoạt động');
    } catch (err) {
        setStatus('status-pill', 'error', 'Lỗi: ' + err.message);
        console.error(err);
    }
}

document.addEventListener('DOMContentLoaded', () => init(false));
})();
