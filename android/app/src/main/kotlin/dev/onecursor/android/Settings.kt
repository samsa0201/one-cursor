package dev.onecursor.android

import android.content.Context
import android.os.Build
import dev.onecursor.protocol.CertFingerprint
import dev.onecursor.protocol.Message

/** What a non-left mouse button does on the phone. */
enum class ButtonAction { BACK, HOME, RECENTS, NOTIFICATIONS, LONG_PRESS, NONE }

class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var host: String
        get() = prefs.getString("host", "") ?: ""
        set(v) = prefs.edit().putString("host", v.trim()).apply()

    var port: Int
        get() = prefs.getInt("port", Message.DEFAULT_PORT)
        set(v) = prefs.edit().putInt("port", v).apply()

    /** Screen name; must match a screen in the server's layout. */
    var screenName: String
        get() = prefs.getString("name", null) ?: defaultName()
        set(v) = prefs.edit().putString("name", v.trim()).apply()

    var useTls: Boolean
        get() = prefs.getBoolean("tls", true)
        set(v) = prefs.edit().putBoolean("tls", v).apply()

    var autoConnect: Boolean
        get() = prefs.getBoolean("autoConnect", true)
        set(v) = prefs.edit().putBoolean("autoConnect", v).apply()

    /** Remembers whether the user last asked to be connected. */
    var wantConnected: Boolean
        get() = prefs.getBoolean("wantConnected", false)
        set(v) = prefs.edit().putBoolean("wantConnected", v).apply()

    /**
     * Pointer speed. The phone reports a screen this many times smaller than
     * its pixel size, so the same mouse movement covers more of the screen.
     */
    var pointerSpeed: Float
        get() = prefs.getFloat("pointerSpeed", 1.5f)
        set(v) = prefs.edit().putFloat("pointerSpeed", v.coerceIn(0.5f, 4f)).apply()

    var scrollSpeed: Float
        get() = prefs.getFloat("scrollSpeed", 1f)
        set(v) = prefs.edit().putFloat("scrollSpeed", v.coerceIn(0.25f, 4f)).apply()

    var invertScroll: Boolean
        get() = prefs.getBoolean("invertScroll", false)
        set(v) = prefs.edit().putBoolean("invertScroll", v).apply()

    var rightButton: ButtonAction
        get() = enumPref("rightButton", ButtonAction.BACK)
        set(v) = prefs.edit().putString("rightButton", v.name).apply()

    var middleButton: ButtonAction
        get() = enumPref("middleButton", ButtonAction.HOME)
        set(v) = prefs.edit().putString("middleButton", v.name).apply()

    /** Read the phone clipboard and send it to the computer whenever the cursor leaves the phone. */
    var syncClipboardOnLeave: Boolean
        get() = prefs.getBoolean("syncClipboardOnLeave", false)
        set(v) = prefs.edit().putBoolean("syncClipboardOnLeave", v).apply()

    /** Telex input: compose Vietnamese from keys typed on the computer keyboard. */
    var vietnameseTelex: Boolean
        get() = prefs.getBoolean("telex", false)
        set(v) = prefs.edit().putBoolean("telex", v).apply()

    fun isTrusted(host: String, fp: CertFingerprint): Boolean {
        val trusted = prefs.getStringSet("trusted", emptySet()) ?: emptySet()
        val sha256 = CertFingerprint.normalize(fp.sha256)
        return trusted.any { it == "$host|$sha256" || it == "*|$sha256" }
    }

    fun trust(host: String, fp: CertFingerprint) {
        val trusted = (prefs.getStringSet("trusted", emptySet()) ?: emptySet()).toMutableSet()
        // A host gets one pinned certificate; a new one replaces the old pin.
        trusted.removeAll { it.startsWith("$host|") }
        trusted += "$host|${CertFingerprint.normalize(fp.sha256)}"
        prefs.edit().putStringSet("trusted", trusted).apply()
    }

    fun forgetTrustedServers() = prefs.edit().remove("trusted").apply()

    private inline fun <reified T : Enum<T>> enumPref(key: String, default: T): T =
        prefs.getString(key, null)?.let { name -> enumValues<T>().firstOrNull { it.name == name } } ?: default

    companion object {
        fun defaultName(): String =
            Build.MODEL.lowercase().replace(Regex("[^a-z0-9-]+"), "-").trim('-').ifEmpty { "android" }
    }
}
