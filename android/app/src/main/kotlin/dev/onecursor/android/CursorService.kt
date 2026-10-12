package dev.onecursor.android

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Choreographer
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.ImageView
import dev.onecursor.protocol.ClipboardContent
import dev.onecursor.protocol.MouseButtons

/**
 * The accessibility service that makes the phone controllable: it draws the
 * mouse cursor as an overlay, injects taps/drags/scrolls as gestures and types
 * text. It also keeps the app process alive while enabled.
 */
class CursorService : AccessibilityService(), InputSink {
    private lateinit var app: OneCursorApp
    private lateinit var windowManager: WindowManager
    private lateinit var gestures: GestureController
    private lateinit var keyboard: KeyboardController
    private var cursorView: View? = null
    private var cursorParams: WindowManager.LayoutParams? = null

    @Volatile private var size = 0 to 0
    private var cursorX = 0f
    private var cursorY = 0f
    private var framePending = false
    private var lastSentClipboard: String? = null

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY) return
            val old = size
            updateSize()
            if (size != old) app.controller.screenChanged()
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        app = OneCursorApp.of(this)
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        updateSize()
        gestures = GestureController(this) { size }
        keyboard = KeyboardController(this)
        applySettings()
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(displayListener, null)
        app.controller.attachSink(this)
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        teardown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun teardown() {
        if (instance !== this) return
        instance = null
        runCatching {
            (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayListener)
        }
        app.controller.detachSink(this)
        removeCursor()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // A new window means a new text field context for Telex.
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) keyboard.resetComposition()
    }

    override fun onInterrupt() = Unit

    /** Re-reads the settings that affect input handling. */
    fun applySettings() {
        val s = app.settings
        gestures.scrollSpeed = s.scrollSpeed
        gestures.invertScroll = s.invertScroll
        keyboard.telexEnabled = s.vietnameseTelex
    }

    // ---- InputSink ------------------------------------------------------------------------

    override fun screenSize(): Pair<Int, Int> = size

    override fun onEnter(x: Float, y: Float) {
        showCursor()
        moveCursor(x, y)
        keyboard.resetComposition()
    }

    override fun onLeave() {
        if (gestures.isDragging) gestures.release()
        hideCursor()
        if (app.settings.syncClipboardOnLeave) {
            // Reading the clipboard needs a focused window on Android 10+.
            startActivity(
                Intent(this, ClipboardSyncActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        }
    }

    override fun onMove(x: Float, y: Float) {
        moveCursor(x, y)
        gestures.move(cursorX, cursorY)
    }

    override fun onButton(button: Int, down: Boolean) {
        keyboard.resetComposition()
        when (button) {
            MouseButtons.LEFT -> if (down) gestures.press(cursorX, cursorY) else gestures.release()
            MouseButtons.RIGHT -> if (down) buttonAction(app.settings.rightButton)
            MouseButtons.MIDDLE -> if (down) buttonAction(app.settings.middleButton)
            MouseButtons.EXTRA0 -> if (down) performGlobalAction(GLOBAL_ACTION_BACK)
            MouseButtons.EXTRA1 -> if (down) performGlobalAction(GLOBAL_ACTION_RECENTS)
        }
    }

    override fun onWheel(xDelta: Int, yDelta: Int) = gestures.wheel(xDelta, yDelta, cursorX, cursorY)

    override fun onKey(keyId: Int, modifiers: Int, down: Boolean, repeat: Int) =
        keyboard.onKey(keyId, modifiers, down, repeat)

    override fun onClipboard(content: ClipboardContent) {
        val text = content.text ?: return
        lastSentClipboard = text
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("One Cursor", text))
    }

    private fun buttonAction(action: ButtonAction) {
        when (action) {
            ButtonAction.BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            ButtonAction.HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            ButtonAction.RECENTS -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            ButtonAction.NOTIFICATIONS -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            ButtonAction.LONG_PRESS -> gestures.longPress(cursorX, cursorY)
            ButtonAction.NONE -> Unit
        }
    }

    // ---- cursor overlay -------------------------------------------------------------------

    private fun updateSize() {
        size = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = windowManager.maximumWindowMetrics.bounds
            b.width() to b.height()
        } else {
            val p = Point()
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealSize(p)
            p.x to p.y
        }
    }

    private fun showCursor() {
        if (cursorView == null) {
            val px = (CURSOR_DP * resources.displayMetrics.density).toInt()
            val view = ImageView(this).apply { setImageResource(R.drawable.ic_cursor) }
            val params = WindowManager.LayoutParams(
                px, px,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    } else {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setFitInsetsTypes(0)
                title = "One Cursor pointer"
            }
            runCatching { windowManager.addView(view, params) }.onFailure { return }
            cursorView = view
            cursorParams = params
        }
        cursorView?.visibility = View.VISIBLE
    }

    private fun hideCursor() {
        cursorView?.visibility = View.GONE
    }

    private fun removeCursor() {
        cursorView?.let { runCatching { windowManager.removeView(it) } }
        cursorView = null
        cursorParams = null
    }

    private fun moveCursor(x: Float, y: Float) {
        val (w, h) = size
        cursorX = x.coerceIn(0f, (w - 1).toFloat().coerceAtLeast(0f))
        cursorY = y.coerceIn(0f, (h - 1).toFloat().coerceAtLeast(0f))
        // Window updates are batched to one per frame.
        if (!framePending) {
            framePending = true
            Choreographer.getInstance().postFrameCallback {
                framePending = false
                val view = cursorView ?: return@postFrameCallback
                val params = cursorParams ?: return@postFrameCallback
                // The arrow's tip sits slightly inside the drawable (2/24 of its size).
                val inset = (params.width * 2 / 24)
                params.x = cursorX.toInt() - inset
                params.y = cursorY.toInt() - inset
                runCatching { windowManager.updateViewLayout(view, params) }
            }
        }
    }

    /** Text from this phone's clipboard, sent by [ClipboardSyncActivity]. */
    fun clipboardRead(text: String) {
        if (text == lastSentClipboard) return
        lastSentClipboard = text
        app.controller.sendClipboard(text)
    }

    companion object {
        private const val CURSOR_DP = 26f

        @Volatile var instance: CursorService? = null
            private set
    }
}
