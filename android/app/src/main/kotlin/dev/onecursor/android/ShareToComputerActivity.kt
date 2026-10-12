package dev.onecursor.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast

/** Receives "Share" intents with text and puts the text on the computer's clipboard. */
class ShareToComputerActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent?.takeIf { it.action == Intent.ACTION_SEND }?.getStringExtra(Intent.EXTRA_TEXT)
        val sent = text != null && OneCursorApp.of(this).controller.sendClipboard(text)
        Toast.makeText(
            this,
            if (sent) R.string.share_sent else R.string.share_not_connected,
            Toast.LENGTH_SHORT,
        ).show()
        finish()
    }
}
