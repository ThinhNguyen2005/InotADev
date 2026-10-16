package com.inotadev.adbtoggler

import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import java.io.DataOutputStream

class AdbTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        try {
            val wasOn = Settings.Global.getInt(contentResolver, Constants.SETTING_ADB_ENABLED, 0) == 1
            val targetMode = if (wasOn) DaemonMode.OFF.key else DaemonMode.AUTO.key
            val cmd = "sed -i 's/^MODE=.*/MODE=$targetMode/' ${Constants.PATH_CONFIG_CONF} 2>/dev/null || echo 'MODE=$targetMode' >> ${Constants.PATH_CONFIG_CONF}; " +
                "sed -i 's/^MODE=.*/MODE=$targetMode/' ${Constants.PATH_CONFIG_SH} 2>/dev/null || echo 'MODE=$targetMode' >> ${Constants.PATH_CONFIG_SH}"
            if (runRoot(cmd)) {
                Thread.sleep(250)
                updateTile()
                val msg = if (!wasOn) getString(R.string.adb_enabled_msg) else getString(R.string.adb_disabled_msg)
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, getString(R.string.toggle_failed), Toast.LENGTH_LONG).show()
            }
        } catch (e: Exception) {
            Toast.makeText(this, getString(R.string.error_format, e.message ?: ""), Toast.LENGTH_LONG).show()
        }
    }

    private fun updateTile() {
        val tile: Tile = qsTile ?: return
        val adbOn = try {
            Settings.Global.getInt(contentResolver, Constants.SETTING_ADB_ENABLED, 0) == 1
        } catch (_: Exception) {
            false
        }

        tile.state = if (adbOn) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        // Standard app launcher icon for Quick Settings Tile
        tile.icon = Icon.createWithResource(this, R.drawable.ic_launcher)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (adbOn) getString(R.string.tile_subtitle_on) else getString(R.string.tile_subtitle_off)
        }
        tile.updateTile()
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
