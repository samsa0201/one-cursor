package dev.onecursor.android

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle

/**
 * Invisible activity that exists only to read the clipboard: since Android 10
 * only the focused app (or the keyboard) may read it. It finishes as soon as
 * it has window focus.
 */
class ClipboardSyncActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        readClipboard(this)?.let { text ->
            CursorService.instance?.clipboardRead(text) ?: OneCursorApp.of(this).controller.sendClipboard(text)
        }
        finish()
        overridePendingTransition(0, 0)
    }

    companion object {
        fun readClipboard(context: Context): String? {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip ?: return null
            if (clip.itemCount == 0) return null
            return clip.getItemAt(0).coerceToText(context)?.toString()?.takeIf { it.isNotEmpty() }
        }
    }
}
