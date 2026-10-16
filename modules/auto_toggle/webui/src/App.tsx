import { useEffect, useState, useRef, useCallback } from 'react'
import { i18n } from './lib/I18n'
import { Cli, type AutoToggleConfig, type RuntimeState } from './lib/Cli'
import { Terminal } from './lib/Terminal'
import Header from './components/Header'
import SwitchItem from './components/SwitchItem'
import TerminalView from './components/Terminal'
import Layout from './components/Layout'
import HelpDialog from './components/dialog/HelpDialog'
import type { MdDialog } from '@material/web/dialog/dialog.js'

export default function App() {
  const [terminal] = useState(() => new Terminal())
  const helpDialogRef = useRef<MdDialog | null>(null)

  const [runtime, setRuntime] = useState<RuntimeState>({
    stateOn: false,
    mode: 'auto',
    reason: '',
    isUsbPc: false,
    pid: '--',
  })

  const [config, setConfig] = useState<AutoToggleConfig>({
    mode: 'auto',
    turnOffWifiAdb: true,
    hideDevSettings: false,
    onlyUnlocked: false,
    notify: true,
    debounceMs: 4000,
  })

  const [loading, setLoading] = useState(false)
  const [, setTranslationRev] = useState(0)

  // Subscribe to language changes
  useEffect(() => {
    return i18n.subscribe(() => setTranslationRev((n) => n + 1))
  }, [])

  const refreshState = useCallback(async () => {
    try {
      const rt = await Cli.getRuntimeState()
      setRuntime(rt)
    } catch (e) {
      console.error(e)
    }
  }, [])

  const loadAll = useCallback(async () => {
    setLoading(true)
    try {
      const [rt, cfg, logs] = await Promise.all([
        Cli.getRuntimeState(),
        Cli.loadConfig(),
        Cli.getLogs(),
      ])
      setRuntime(rt)
      setConfig(cfg)
      terminal.clear()
      logs.split('\n').forEach((line) => {
        if (line.trim()) terminal.output(line)
      })
    } finally {
      setLoading(false)
    }
  }, [terminal])

  // Initialize on mount
  useEffect(() => {
    i18n.loadTranslations().then(() => {
      loadAll()
    })

    const interval = setInterval(refreshState, 3000)
    return () => clearInterval(interval)
  }, [loadAll, refreshState])

  const handleToggleAdb = async () => {
    const nextState = !runtime.stateOn
    setLoading(true)
    await Cli.toggleAdb(nextState)
    await refreshState()
    setLoading(false)
  }

  const handleModeChange = async (mode: 'auto' | 'on' | 'off') => {
    const nextCfg: AutoToggleConfig = { ...config, mode }
    setConfig(nextCfg)
    await Cli.saveConfig(nextCfg)
    await refreshState()
  }

  const handleConfigToggle = async (key: keyof AutoToggleConfig, value: boolean | number) => {
    const nextCfg: AutoToggleConfig = { ...config, [key]: value }
    setConfig(nextCfg)
    await Cli.saveConfig(nextCfg)
  }

  const t = (key: string, fallback?: string) => i18n.t(key, fallback)

  return (
    <Layout
      header={
        <Header
          onHelpClick={() => helpDialogRef.current?.show()}
          onRefreshClick={loadAll}
        />
      }
    >
      <div className="w-full flex-1 flex flex-col items-center px-2 py-4 gap-4 overflow-y-auto max-w-xl mx-auto">
        {/* Hero ADB Status Card */}
        <div className="w-full bg-surface border border-outline/20 rounded-3xl p-5 shadow-lg flex flex-col gap-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div
                className={`w-3.5 h-3.5 rounded-full transition-all duration-300 ${
                  runtime.stateOn
                    ? 'bg-green-500 shadow-[0_0_12px_rgba(34,197,94,0.6)]'
                    : 'bg-zinc-600'
                }`}
              />
              <span
                className={`text-lg font-bold ${
                  runtime.stateOn ? 'text-green-400' : 'text-on-surface-variant'
                }`}
              >
                {runtime.stateOn ? t('adb_enabled', 'ADB: [BẬT]') : t('adb_disabled', 'ADB: [TẮT]')}
              </span>
            </div>

            <button
              onClick={handleToggleAdb}
              disabled={loading}
              className={`px-4 py-2 rounded-xl text-xs font-bold transition-all flex items-center gap-2 active:scale-95 ${
                runtime.stateOn
                  ? 'bg-red-500/20 text-red-300 border border-red-500/30 hover:bg-red-500/30'
                  : 'bg-primary text-on-primary hover:opacity-90'
              }`}
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-4 h-4 fill-current">
                <path d="M13 3h-2v10h2V3zm4.83 2.17l-1.42 1.42C17.99 7.86 19 9.81 19 12c0 3.87-3.13 7-7 7s-7-3.13-7-7c0-2.19 1.01-4.14 2.58-5.42L6.17 5.17C4.23 6.82 3 9.26 3 12c0 4.97 4.03 9 9 9s9-4.03 9-9c0-2.74-1.23-5.18-3.17-6.83z" />
              </svg>
              <span>{t('toggle_adb', 'Chuyển trạng thái')}</span>
            </button>
          </div>

          <div className="bg-surface-container rounded-2xl p-3.5 text-xs flex flex-col gap-2">
            <div className="flex items-center justify-between">
              <span className="text-outline flex items-center gap-1.5">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-3.5 h-3.5 fill-current">
                  <path d="M15 7v4h1v2h-3V5h2l-3-4-3 4h2v8H8v-2.07c.7-.37 1.2-1.08 1.2-1.93 0-1.21-.99-2.2-2.2-2.2-1.21 0-2.2.99-2.2 2.2 0 .85.5 1.56 1.2 1.93V13c0 1.11.89 2 2 2h3v3.05c-.71.37-1.2 1.1-1.2 1.95a2.2 2.2 0 0 0 4.4 0c0-.85-.49-1.58-1.2-1.95V15h3c1.11 0 2-.89 2-2v-2h1V7h-4z"/>
                </svg>
                {t('usb_status', 'Trạng thái USB')}:
              </span>
              <span className={`font-semibold ${runtime.isUsbPc ? 'text-primary' : 'text-on-surface'}`}>
                {runtime.isUsbPc ? t('usb_connected', 'Đang kết nối PC') : t('usb_disconnected', 'Đã rút cáp PC')}
              </span>
            </div>

            <div className="flex items-center justify-between">
              <span className="text-outline flex items-center gap-1.5">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-3.5 h-3.5 fill-current">
                  <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
                </svg>
                {t('current_reason', 'Lý do')}:
              </span>
              <span className="font-semibold text-on-surface">
                {runtime.reason || '--'}
              </span>
            </div>

            <div className="flex items-center justify-between">
              <span className="text-outline flex items-center gap-1.5">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-3.5 h-3.5 fill-current">
                  <path d="M20 8h-2.81c-.45-.78-1.07-1.45-1.82-1.96L17 4.41 15.59 3l-2.17 2.17C12.96 5.06 12.49 5 12 5c-.49 0-.96.06-1.41.17L8.41 3 7 4.41l1.62 1.63C7.88 6.55 7.26 7.22 6.81 8H4v2h2.09c-.05.33-.09.66-.09 1v1H4v2h2v1c0 .34.04.67.09 1H4v2h2.81c1.04 1.79 2.97 3 5.19 3s4.15-1.21 5.19-3H20v-2h-2.09c.05-.33.09-.66.09-1v-1h2v-2h-2v-1c0-.34-.04-.67-.09-1H20V8zm-6 8h-4v-2h4v2zm0-4h-4v-2h4v2z"/>
                </svg>
                {t('daemon_pid', 'Tiến trình Daemon')}:
              </span>
              <span className="font-mono text-on-surface">
                PID: {runtime.pid}
              </span>
            </div>
          </div>
        </div>

        {/* Operation Mode Selector */}
        <div className="w-full flex flex-col gap-2">
          <span className="text-xs font-bold uppercase tracking-wider text-outline px-1 flex items-center gap-1.5">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-3.5 h-3.5 fill-current">
              <path d="M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z"/>
            </svg>
            {t('mode_section', 'Chế độ hoạt động')}
          </span>

          <div className="grid grid-cols-3 gap-2 bg-surface-container border border-outline/20 p-1.5 rounded-2xl">
            <button
              onClick={() => handleModeChange('auto')}
              className={`py-3 px-2 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                config.mode === 'auto'
                  ? 'bg-primary-container text-primary shadow'
                  : 'text-on-surface-variant hover:bg-surface-container-high'
              }`}
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-4 h-4 fill-current">
                <path d="M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6 0 1.01-.25 1.97-.7 2.8l1.46 1.46C19.54 15.03 20 13.57 20 12c0-4.42-3.58-8-8-8zm0 14c-3.31 0-6-2.69-6-6 0-1.01.25-1.97.7-2.8L5.24 7.74C4.46 8.97 4 10.43 4 12c0 4.42 3.58 8 8 8v3l4-4-4-4v3z"/>
              </svg>
              <span>{t('mode_auto', 'Tự động')}</span>
            </button>

            <button
              onClick={() => handleModeChange('on')}
              className={`py-3 px-2 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                config.mode === 'on'
                  ? 'bg-primary-container text-primary shadow'
                  : 'text-on-surface-variant hover:bg-surface-container-high'
              }`}
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-4 h-4 fill-current">
                <path d="M7 2v11h3v9l7-12h-4l4-8z"/>
              </svg>
              <span>{t('mode_on', 'Luôn Bật')}</span>
            </button>

            <button
              onClick={() => handleModeChange('off')}
              className={`py-3 px-2 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                config.mode === 'off'
                  ? 'bg-primary-container text-primary shadow'
                  : 'text-on-surface-variant hover:bg-surface-container-high'
              }`}
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-4 h-4 fill-current">
                <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1c1.06 1.45 1.69 3.15 1.69 4.9 0 4.42-3.58 8-8 8z"/>
              </svg>
              <span>{t('mode_off', 'Luôn Tắt')}</span>
            </button>
          </div>
        </div>

        {/* Configuration Toggles */}
        <div className="w-full flex flex-col gap-2">
          <span className="text-xs font-bold uppercase tracking-wider text-outline px-1 flex items-center gap-1.5">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-3.5 h-3.5 fill-current">
              <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/>
            </svg>
            {t('config_section', 'Cấu hình Daemon')}
          </span>

          <div className="bg-surface border border-outline/20 rounded-3xl overflow-hidden divide-y divide-white/5">
            <SwitchItem
              label={t('cfg_wifi_title', 'Tắt ADB Wi-Fi khi rút cáp')}
              description={t('cfg_wifi_desc', 'Tự động ngắt kết nối không dây khi rút cáp')}
              selected={config.turnOffWifiAdb}
              onChange={(v) => handleConfigToggle('turnOffWifiAdb', v)}
            />

            <SwitchItem
              label={t('cfg_dev_title', 'Ẩn Tùy chọn nhà phát triển khi tắt')}
              description={t('cfg_dev_desc', 'development_settings_enabled = 0 khi tắt ADB')}
              selected={config.hideDevSettings}
              onChange={(v) => handleConfigToggle('hideDevSettings', v)}
            />

            <SwitchItem
              label={t('cfg_unlocked_title', 'Chỉ bật khi đã mở khóa màn hình')}
              description={t('cfg_unlocked_desc', 'Bảo vệ thiết bị khi cắm sạc nơi công cộng')}
              selected={config.onlyUnlocked}
              onChange={(v) => handleConfigToggle('onlyUnlocked', v)}
            />

            <SwitchItem
              label={t('cfg_notify_title', 'Hiển thị thông báo trạng thái')}
              description={t('cfg_notify_desc', 'Gửi thông báo hệ thống khi chuyển trạng thái')}
              selected={config.notify}
              onChange={(v) => handleConfigToggle('notify', v)}
            />

            {/* Debounce delay slider */}
            <div className="p-4 flex flex-col gap-2">
              <div className="flex justify-between items-center text-sm">
                <span className="font-medium text-on-surface">
                  {t('cfg_debounce_title', 'Thời gian trễ ngắt')}
                </span>
                <span className="font-mono text-primary font-bold">
                  {(config.debounceMs / 1000).toFixed(1)}s
                </span>
              </div>
              <p className="text-xs text-outline">
                {t('cfg_debounce_desc', 'Thời gian chờ trước khi ngắt ADB khi rút cáp (chống chập chờn)')}
              </p>
              <input
                type="range"
                min="1000"
                max="10000"
                step="500"
                value={config.debounceMs}
                onChange={(e) => handleConfigToggle('debounceMs', parseInt(e.target.value, 10))}
                className="w-full accent-primary mt-1"
              />
            </div>
          </div>
        </div>

        {/* Daemon Log Terminal */}
        <div className="w-full flex flex-col gap-2">
          <div className="flex items-center justify-between px-1">
            <span className="text-xs font-bold uppercase tracking-wider text-outline flex items-center gap-1.5">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="w-3.5 h-3.5 fill-current">
                <path d="M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm-5 14H4v-4h11v4zm0-5H4V9h11v4zm5 5h-4V9h4v9z"/>
              </svg>
              {t('terminal_title', 'Nhật ký Daemon')}
            </span>
          </div>

          <div className="w-full rounded-2xl overflow-hidden border border-outline/20">
            <TerminalView terminal={terminal} />
          </div>
        </div>
      </div>

      <HelpDialog dialogRef={(el) => (helpDialogRef.current = el)} />
    </Layout>
  )
}
