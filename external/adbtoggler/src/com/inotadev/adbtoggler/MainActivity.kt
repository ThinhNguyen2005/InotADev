package com.inotadev.adbtoggler

import android.app.Activity
import android.content.ComponentName
import android.os.Bundle
import android.provider.Settings
import android.service.quicksettings.TileService
import android.view.HapticFeedbackConstants
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import java.io.BufferedReader
import java.io.DataOutputStream
import java.io.File
import java.io.FileReader

class MainActivity : Activity() {

    private lateinit var tvStatusText: TextView
    private lateinit var tvUsbText: TextView
    private lateinit var tvDaemonDetails: TextView
    private lateinit var btnToggleAdb: Button
    private lateinit var btnModeAuto: Button
    private lateinit var btnModeOn: Button
    private lateinit var btnModeOff: Button
    private lateinit var btnRefresh: Button

    private var currentMode: DaemonMode = DaemonMode.AUTO

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        initViews()
        refreshAll()
    }

    override fun onResume() {
        super.onResume()
        refreshAll()
    }

    private fun initViews() {
        tvStatusText = findViewById(R.id.tv_status_text)
        tvUsbText = findViewById(R.id.tv_usb_text)
        tvDaemonDetails = findViewById(R.id.tv_daemon_details)
        btnToggleAdb = findViewById(R.id.btn_toggle_adb)
        btnModeAuto = findViewById(R.id.btn_mode_auto)
        btnModeOn = findViewById(R.id.btn_mode_on)
        btnModeOff = findViewById(R.id.btn_mode_off)
        btnRefresh = findViewById(R.id.btn_refresh)

        btnToggleAdb.setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            toggleAdb()
        }
        btnRefresh.setOnClickListener {
            it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            refreshAll()
        }
        btnModeAuto.setOnClickListener { setDaemonMode(DaemonMode.AUTO) }
        btnModeOn.setOnClickListener { setDaemonMode(DaemonMode.ON) }
        btnModeOff.setOnClickListener { setDaemonMode(DaemonMode.OFF) }
    }

    private fun refreshAll() {
        val adbOn = try {
            Settings.Global.getInt(contentResolver, Constants.SETTING_ADB_ENABLED, 0) == 1
        } catch (_: Exception) {
            false
        }

        if (adbOn) {
            tvStatusText.text = getString(R.string.status_on)
            tvStatusText.setTextColor(getColor(R.color.md_theme_status_active))
            btnToggleAdb.text = getString(
                R.string.toggle_adb_action,
                getString(R.string.btn_toggle),
                getString(R.string.label_off)
            )
        } else {
            tvStatusText.text = getString(R.string.status_off)
            tvStatusText.setTextColor(getColor(R.color.md_theme_status_inactive))
            btnToggleAdb.text = getString(
                R.string.toggle_adb_action,
                getString(R.string.btn_toggle),
                getString(R.string.label_on)
            )
        }

        var reason = ""
        val runtimeFile = File(Constants.PATH_RUNTIME_STATE)
        if (runtimeFile.exists() && runtimeFile.canRead()) {
            try {
                BufferedReader(FileReader(runtimeFile)).use { reader ->
                    reader.forEachLine { line ->
                        when {
                            line.startsWith(Constants.PREFIX_MODE) -> {
                                currentMode = DaemonMode.fromKey(line.substring(Constants.PREFIX_MODE.length).trim())
                            }
                            line.startsWith(Constants.PREFIX_REASON) -> {
                                reason = line.substring(Constants.PREFIX_REASON.length).trim()
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // Keep default values if reading fails
            }
        }

        if (checkUsbPc()) {
            val baseUsb = getString(R.string.usb_connected)
            tvUsbText.text = if (reason.isEmpty()) baseUsb else getString(R.string.usb_status_with_reason, baseUsb, reason)
            tvUsbText.setTextColor(getColor(R.color.md_theme_usb_connected))
        } else {
            tvUsbText.text = getString(R.string.usb_disconnected)
            tvUsbText.setTextColor(getColor(R.color.md_theme_onSurfaceVariant))
        }

        val displayReason = reason.ifEmpty { getString(R.string.status_ready) }
        tvDaemonDetails.text = getString(R.string.daemon_details_format, currentMode.name, displayReason)
        updateModeButtons(currentMode)

        try {
            TileService.requestListeningState(this, ComponentName(this, AdbTileService::class.java))
        } catch (_: Exception) {
            // Tile not added to Quick Settings yet, ignore
        }
    }

    private fun updateModeButtons(mode: DaemonMode) {
        val activeColor = getColor(R.color.md_theme_primary)
        val inactiveColor = getColor(R.color.md_theme_onSurfaceVariant)

        btnModeAuto.setTextColor(if (mode == DaemonMode.AUTO) activeColor else inactiveColor)
        btnModeOn.setTextColor(if (mode == DaemonMode.ON) activeColor else inactiveColor)
        btnModeOff.setTextColor(if (mode == DaemonMode.OFF) activeColor else inactiveColor)
    }

    private fun checkUsbPc(): Boolean {
        val entries = File(Constants.PATH_UDC).listFiles() ?: return false
        for (entry in entries) {
            val stateFile = File(entry, Constants.UDC_STATE)
            if (!stateFile.exists()) continue
            try {
                BufferedReader(FileReader(stateFile)).use { reader ->
                    val line = reader.readLine()
                    if (line != null && (line.contains(Constants.UDC_CONFIGURED) || line.contains(Constants.UDC_ADDRESSED))) {
                        return true
                    }
                }
            } catch (_: Exception) {
                // Try next entry
            }
        }
        return false
    }

    private fun toggleAdb() {
        try {
            val wasOn = Settings.Global.getInt(contentResolver, Constants.SETTING_ADB_ENABLED, 0) == 1
            val targetMode = if (wasOn) DaemonMode.OFF else DaemonMode.AUTO
            setDaemonMode(targetMode)
            val msg = if (!wasOn) getString(R.string.adb_enabled_msg) else getString(R.string.adb_disabled_msg)
            Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, getString(R.string.error_format, e.message ?: ""), Toast.LENGTH_SHORT).show()
        }
    }

    private fun setDaemonMode(mode: DaemonMode) {
        currentMode = mode
        updateModeButtons(mode)
        val modeKey = mode.key
        val cmd = "sed -i 's/^MODE=.*/MODE=$modeKey/' ${Constants.PATH_CONFIG_CONF} 2>/dev/null || echo 'MODE=$modeKey' >> ${Constants.PATH_CONFIG_CONF}; " +
            "sed -i 's/^MODE=.*/MODE=$modeKey/' ${Constants.PATH_CONFIG_SH} 2>/dev/null || echo 'MODE=$modeKey' >> ${Constants.PATH_CONFIG_SH}"
        runRoot(cmd)
        refreshAll()
    }

    private fun runRoot(command: String): Boolean {
        var process: Process? = null
        var os: DataOutputStream? = null
        return try {
            process = Runtime.getRuntime().exec(Constants.CMD_SU)
            os = DataOutputStream(process.outputStream)
            os.writeBytes("$command\n")
            os.writeBytes("${Constants.CMD_EXIT}\n")
            os.flush()
            process.waitFor() == 0
        } catch (_: Exception) {
            false
        } finally {
            try {
                os?.close()
                process?.destroy()
            } catch (_: Exception) {
                // Ignore cleanup errors
            }
        }
    }
}
