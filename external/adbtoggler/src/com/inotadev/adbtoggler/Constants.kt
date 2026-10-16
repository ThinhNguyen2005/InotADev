package com.inotadev.adbtoggler

object Constants {
    const val SETTING_ADB_ENABLED = "adb_enabled"
    const val PATH_RUNTIME_STATE = "/data/adb/auto_toggle/runtime_state"
    const val PATH_CONFIG_CONF = "/data/adb/auto_toggle/config.conf"
    const val PATH_CONFIG_SH = "/data/adb/auto_toggle/config.sh"
    const val PATH_UDC = "/sys/class/udc"
    const val UDC_STATE = "state"
    const val UDC_CONFIGURED = "configured"
    const val UDC_ADDRESSED = "addressed"
    const val PREFIX_MODE = "MODE="
    const val PREFIX_REASON = "REASON="
    const val CMD_SU = "su"
    const val CMD_EXIT = "exit"
    const val VALUE_ON = "1"
    const val VALUE_OFF = "0"
}

enum class DaemonMode(val key: String) {
    AUTO("auto"),
    ON("on"),
    OFF("off");

    companion object {
        fun fromKey(key: String): DaemonMode =
            entries.firstOrNull { it.key.equals(key, ignoreCase = true) } ?: AUTO
    }
}
