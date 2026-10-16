import { exec, toast } from 'kernelsu-alt'
import { CONF_FILE, RUNTIME_FILE, LOG_FILE, LOCK_FILE, PROP_FILE } from '../constant'

export interface AutoToggleConfig {
  mode: 'auto' | 'on' | 'off'
  turnOffWifiAdb: boolean
  hideDevSettings: boolean
  onlyUnlocked: boolean
  notify: boolean
  debounceMs: number
}

export interface RuntimeState {
  stateOn: boolean
  mode: string
  reason: string
  isUsbPc: boolean
  pid: string
}

export class Cli {
  static async loadVersion(): Promise<string> {
    const { errno, stdout } = await exec(`grep '^version=' ${PROP_FILE} | cut -d'=' -f2`)
    if (errno === 0) return stdout.trim()
    return 'v2.1.0'
  }

  static async getAdbEnabled(): Promise<boolean> {
    const { errno, stdout } = await exec('settings get global adb_enabled')
    if (errno === 0) return stdout.trim() === '1'
    return false
  }

  static async toggleAdb(enable: boolean): Promise<boolean> {
    const targetMode = enable ? 'on' : 'off'
    const cmd = `sed -i "s/^MODE=.*/MODE=${targetMode}/" ${CONF_FILE} 2>/dev/null || echo "MODE=${targetMode}" >> ${CONF_FILE}`
    const { errno } = await exec(cmd)
    return errno === 0
  }

  static async getRuntimeState(): Promise<RuntimeState> {
    const adbOn = await this.getAdbEnabled()
    const { stdout } = await exec(`cat ${RUNTIME_FILE} 2>/dev/null`)
    
    let mode = 'auto'
    let reason = ''
    stdout.split('\n').forEach(line => {
      if (line.startsWith('MODE=')) mode = line.split('=')[1].trim()
      if (line.startsWith('REASON=')) reason = line.split('=')[1].trim()
    })

    // USB state check
    const udcRes = await exec('cat /sys/class/udc/*/state 2>/dev/null')
    const isUsbPc = udcRes.stdout.includes('configured') || udcRes.stdout.includes('addressed')

    // PID check
    const pidRes = await exec(`cat ${LOCK_FILE} 2>/dev/null`)
    const pid = pidRes.stdout.trim()

    return {
      stateOn: adbOn,
      mode,
      reason,
      isUsbPc,
      pid: pid || '--',
    }
  }

  static async loadConfig(): Promise<AutoToggleConfig> {
    const { stdout } = await exec(`cat ${CONF_FILE} 2>/dev/null`)
    const cfg: AutoToggleConfig = {
      mode: 'auto',
      turnOffWifiAdb: true,
      hideDevSettings: false,
      onlyUnlocked: false,
      notify: true,
      debounceMs: 4000,
    }

    stdout.split('\n').forEach(line => {
      const parts = line.split('=')
      if (parts.length === 2) {
        const key = parts[0].trim()
        const val = parts[1].trim().replace(/['"]/g, '')
        if (key === 'MODE') {
          if (val === 'on' || val === 'off') cfg.mode = val
          else cfg.mode = 'auto'
        }
        if (key === 'TURN_OFF_WIFI_ADB') cfg.turnOffWifiAdb = val === '1'
        if (key === 'HIDE_DEV_SETTINGS') cfg.hideDevSettings = val === '1'
        if (key === 'ONLY_UNLOCKED') cfg.onlyUnlocked = val === '1'
        if (key === 'NOTIFY') cfg.notify = val === '1'
        if (key === 'DEBOUNCE_MS') {
          const ms = parseInt(val, 10)
          if (!isNaN(ms)) cfg.debounceMs = ms
        }
      }
    })

    return cfg
  }

  static async saveConfig(cfg: AutoToggleConfig): Promise<boolean> {
    const content = [
      `MODE=${cfg.mode}`,
      `HIDE_DEV_SETTINGS=${cfg.hideDevSettings ? '1' : '0'}`,
      `TURN_OFF_WIFI_ADB=${cfg.turnOffWifiAdb ? '1' : '0'}`,
      `ONLY_UNLOCKED=${cfg.onlyUnlocked ? '1' : '0'}`,
      `NOTIFY=${cfg.notify ? '1' : '0'}`,
      `DEBOUNCE_MS=${cfg.debounceMs}`,
    ].join('\n') + '\n'

    const cmd = `printf '%s' "${content}" > ${CONF_FILE}`
    const { errno } = await exec(cmd)
    return errno === 0
  }

  static async getLogs(): Promise<string> {
    const { stdout } = await exec(`tail -n 60 ${LOG_FILE} 2>/dev/null || echo "No logs available"`)
    return stdout || 'No logs available'
  }

  static showToast(msg: string): void {
    toast(msg)
  }
}
