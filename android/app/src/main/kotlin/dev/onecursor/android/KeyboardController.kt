package dev.onecursor.android

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.EditorInfo
import androidx.annotation.RequiresApi
import dev.onecursor.protocol.KeyIds
import dev.onecursor.protocol.KeyModifiers
import dev.onecursor.protocol.TelexComposer

/**
 * Turns Barrier key events into text input and actions on the phone.
 *
 * Android 13+ lets an accessibility service act as an input method for the
 * focused field (`flagInputMethodEditor`), which supports real key events
 * (arrows, backspace, Ctrl shortcuts). Older versions fall back to editing the
 * focused node's text through accessibility actions. Main thread only.
 */
class KeyboardController(private val service: AccessibilityService) {
    private val audio = service.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val telex = TelexComposer()
    var telexEnabled = false
        set(v) {
            field = v
            telex.reset()
        }

    fun onKey(keyId: Int, modifiers: Int, down: Boolean, repeat: Int) {
        if (!down || KeyIds.isModifier(keyId) || keyId == KeyIds.NONE) return
        repeat(maxOf(repeat, 1)) { press(keyId, modifiers) }
    }

    /** Something other than typing happened (click, focus change); end the Telex word. */
    fun resetComposition() = telex.reset()

    private fun press(keyId: Int, modifiers: Int) {
        // Ctrl and Cmd (sent as Super by macOS servers) both act as the shortcut key.
        val shortcut = modifiers and (KeyModifiers.CONTROL or KeyModifiers.SUPER) != 0
        val shift = modifiers and KeyModifiers.SHIFT != 0

        if (globalKey(keyId, shortcut)) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val im = service.inputMethod
            val ic = im?.currentInputConnection
            if (ic != null && im.currentInputStarted) {
                imeKey(ic, im.currentInputEditorInfo, keyId, shortcut, shift)
                return
            }
            // No text field: let arrows and Enter drive focus navigation.
            dpadAction(keyId)?.let { service.performGlobalAction(it) }
            return
        }
        nodeKey(keyId, shortcut, shift)
    }

    /** Keys that work everywhere, focused text field or not. */
    private fun globalKey(keyId: Int, shortcut: Boolean): Boolean {
        val action = when (keyId) {
            KeyIds.ESCAPE, KeyIds.WWW_BACK -> AccessibilityService.GLOBAL_ACTION_BACK
            KeyIds.WWW_HOME -> AccessibilityService.GLOBAL_ACTION_HOME
            KeyIds.MISSION_CONTROL -> AccessibilityService.GLOBAL_ACTION_RECENTS
            KeyIds.LAUNCHPAD -> AccessibilityService.GLOBAL_ACTION_HOME
            else -> null
        }
        if (action != null) {
            telex.reset()
            service.performGlobalAction(action)
            return true
        }
        when (keyId) {
            KeyIds.AUDIO_UP -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
            KeyIds.AUDIO_DOWN -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
            KeyIds.AUDIO_MUTE -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_TOGGLE_MUTE, AudioManager.FLAG_SHOW_UI)
            KeyIds.AUDIO_PLAY -> mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            KeyIds.AUDIO_STOP -> mediaKey(KeyEvent.KEYCODE_MEDIA_STOP)
            KeyIds.AUDIO_NEXT -> mediaKey(KeyEvent.KEYCODE_MEDIA_NEXT)
            KeyIds.AUDIO_PREV -> mediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            else -> {
                // Cmd/Ctrl + Space shows the notification shade; handy without a touch screen.
                if (shortcut && keyId == ' '.code) {
                    service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS)
                    return true
                }
                return false
            }
        }
        return true
    }

    private fun mediaKey(code: Int) {
        val now = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
    }

    private fun dpadAction(keyId: Int): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return when (keyId) {
            KeyIds.UP, KeyIds.KP_UP -> AccessibilityService.GLOBAL_ACTION_DPAD_UP
            KeyIds.DOWN, KeyIds.KP_DOWN -> AccessibilityService.GLOBAL_ACTION_DPAD_DOWN
            KeyIds.LEFT, KeyIds.KP_LEFT -> AccessibilityService.GLOBAL_ACTION_DPAD_LEFT
            KeyIds.RIGHT, KeyIds.KP_RIGHT -> AccessibilityService.GLOBAL_ACTION_DPAD_RIGHT
            KeyIds.RETURN, KeyIds.KP_ENTER -> AccessibilityService.GLOBAL_ACTION_DPAD_CENTER
            else -> null
        }
    }

    // ---- Android 13+: the accessibility input method ----------------------------------------

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun imeKey(
        ic: android.accessibilityservice.InputMethod.AccessibilityInputConnection,
        editor: EditorInfo?,
        keyId: Int,
        shortcut: Boolean,
        shift: Boolean,
    ) {
        if (shortcut) {
            telex.reset()
            val lower = if (keyId in 'A'.code..'Z'.code) keyId + 32 else keyId
            when (lower) {
                'c'.code -> ic.performContextMenuAction(android.R.id.copy)
                'x'.code -> ic.performContextMenuAction(android.R.id.cut)
                'v'.code -> ic.performContextMenuAction(android.R.id.paste)
                'a'.code -> ic.performContextMenuAction(android.R.id.selectAll)
                else -> {
                    val code = keyCodeFor(lower) ?: return
                    var meta = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
                    if (shift) meta = meta or KeyEvent.META_SHIFT_ON
                    sendKey(ic, code, meta)
                }
            }
            return
        }
        if (KeyIds.isPrintable(keyId)) {
            val text = String(Character.toChars(keyId))
            if (telexEnabled && text.length == 1) {
                val edit = telex.type(text[0])
                if (edit.delete > 0) ic.deleteSurroundingText(edit.delete, 0)
                if (edit.insert.isNotEmpty()) ic.commitText(edit.insert, 1, null)
            } else {
                ic.commitText(text, 1, null)
            }
            return
        }
        if (keyId == KeyIds.BACKSPACE) telex.backspace() else telex.reset()

        val meta = if (shift) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0
        if (keyId == KeyIds.RETURN || keyId == KeyIds.KP_ENTER) {
            val multiLine = editor != null && (editor.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0
            val action = (editor?.imeOptions ?: 0) and EditorInfo.IME_MASK_ACTION
            if (!multiLine && !shift && action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
                ic.performEditorAction(action)
            } else {
                sendKey(ic, KeyEvent.KEYCODE_ENTER, meta)
            }
            return
        }
        val code = specialKeyCode(keyId) ?: return
        sendKey(ic, code, meta)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun sendKey(
        ic: android.accessibilityservice.InputMethod.AccessibilityInputConnection,
        code: Int,
        meta: Int,
    ) {
        val now = SystemClock.uptimeMillis()
        ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, meta))
        ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0, meta))
    }

    // ---- Android 8-12: edit the focused node through accessibility actions ------------------

    private fun nodeKey(keyId: Int, shortcut: Boolean, shift: Boolean) {
        val node = service.rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        if (!node.isEditable) return
        val text = node.text?.toString() ?: ""
        // Hint text is reported as the text of empty fields on some versions.
        val current = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && node.isShowingHintText) "" else text
        var start = node.textSelectionStart.coerceIn(0, current.length)
        var end = node.textSelectionEnd.coerceIn(0, current.length)
        if (node.textSelectionStart < 0) {
            start = current.length
            end = current.length
        }
        if (start > end) start = end.also { end = start }

        if (shortcut) {
            telex.reset()
            when (if (keyId in 'A'.code..'Z'.code) keyId + 32 else keyId) {
                'c'.code -> node.performAction(AccessibilityNodeInfo.ACTION_COPY)
                'x'.code -> node.performAction(AccessibilityNodeInfo.ACTION_CUT)
                'v'.code -> node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
                'a'.code -> setSelection(node, 0, current.length)
            }
            return
        }
        if (KeyIds.isPrintable(keyId)) {
            val typed = String(Character.toChars(keyId))
            var deleteBefore = 0
            var insert = typed
            if (telexEnabled && typed.length == 1) {
                val edit = telex.type(typed[0])
                deleteBefore = edit.delete
                insert = edit.insert
            }
            val from = (start - deleteBefore).coerceAtLeast(0)
            replace(node, current, from, end, insert)
            return
        }
        if (keyId == KeyIds.BACKSPACE) telex.backspace() else telex.reset()
        when (keyId) {
            KeyIds.BACKSPACE -> if (start != end) replace(node, current, start, end, "")
            else if (start > 0) replace(node, current, start - Character.charCount(current.codePointBefore(start)), start, "")
            KeyIds.DELETE, KeyIds.KP_DELETE -> if (start != end) replace(node, current, start, end, "")
            else if (end < current.length) replace(node, current, start, end + Character.charCount(current.codePointAt(end)), "")
            KeyIds.LEFT -> if (shift) setSelection(node, start, (end - 1).coerceAtLeast(0))
            else setSelection(node, (start - if (start == end) 1 else 0).coerceAtLeast(0))
            KeyIds.RIGHT -> if (shift) setSelection(node, start, (end + 1).coerceAtMost(current.length))
            else setSelection(node, (end + if (start == end) 1 else 0).coerceAtMost(current.length))
            KeyIds.HOME, KeyIds.UP -> setSelection(node, 0)
            KeyIds.END, KeyIds.DOWN -> setSelection(node, current.length)
            KeyIds.TAB -> node.performAction(AccessibilityNodeInfo.ACTION_NEXT_HTML_ELEMENT)
            KeyIds.RETURN, KeyIds.KP_ENTER -> {
                val multiLine = node.isMultiLine
                if (multiLine) replace(node, current, start, end, "\n")
                else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                }
            }
        }
    }

    private fun replace(node: AccessibilityNodeInfo, text: String, start: Int, end: Int, insert: String) {
        val updated = text.substring(0, start) + insert + text.substring(end)
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, updated)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        setSelection(node, start + insert.length)
    }

    private fun setSelection(node: AccessibilityNodeInfo, start: Int, end: Int = start) {
        val args = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
    }

    // ---- key tables ---------------------------------------------------------------------------

    private fun specialKeyCode(keyId: Int): Int? = when (keyId) {
        KeyIds.BACKSPACE -> KeyEvent.KEYCODE_DEL
        KeyIds.DELETE, KeyIds.KP_DELETE -> KeyEvent.KEYCODE_FORWARD_DEL
        KeyIds.TAB, KeyIds.KP_TAB -> KeyEvent.KEYCODE_TAB
        KeyIds.LEFT_TAB -> KeyEvent.KEYCODE_TAB
        KeyIds.LEFT, KeyIds.KP_LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
        KeyIds.RIGHT, KeyIds.KP_RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
        KeyIds.UP, KeyIds.KP_UP -> KeyEvent.KEYCODE_DPAD_UP
        KeyIds.DOWN, KeyIds.KP_DOWN -> KeyEvent.KEYCODE_DPAD_DOWN
        KeyIds.HOME, KeyIds.KP_HOME -> KeyEvent.KEYCODE_MOVE_HOME
        KeyIds.END, KeyIds.KP_END -> KeyEvent.KEYCODE_MOVE_END
        KeyIds.PAGE_UP, KeyIds.KP_PAGE_UP -> KeyEvent.KEYCODE_PAGE_UP
        KeyIds.PAGE_DOWN, KeyIds.KP_PAGE_DOWN -> KeyEvent.KEYCODE_PAGE_DOWN
        KeyIds.INSERT, KeyIds.KP_INSERT -> KeyEvent.KEYCODE_INSERT
        KeyIds.MENU -> KeyEvent.KEYCODE_MENU
        else -> if (KeyIds.isFunctionKey(keyId) && KeyIds.functionKeyNumber(keyId) <= 12) {
            KeyEvent.KEYCODE_F1 + KeyIds.functionKeyNumber(keyId) - 1
        } else {
            null
        }
    }

    private fun keyCodeFor(c: Int): Int? = when (c) {
        in 'a'.code..'z'.code -> KeyEvent.KEYCODE_A + (c - 'a'.code)
        in '0'.code..'9'.code -> KeyEvent.KEYCODE_0 + (c - '0'.code)
        ' '.code -> KeyEvent.KEYCODE_SPACE
        else -> specialKeyCode(c)
    }
}
