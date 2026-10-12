package dev.onecursor.android

import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.onecursor.protocol.BarrierClient
import dev.onecursor.protocol.CertFingerprint
import dev.onecursor.protocol.ClientConfig
import dev.onecursor.protocol.ClientListener
import dev.onecursor.protocol.ClientScreen
import dev.onecursor.protocol.ClientState
import dev.onecursor.protocol.ClipboardContent
import dev.onecursor.protocol.ScreenShape
import dev.onecursor.protocol.ServerTrust
import dev.onecursor.protocol.UntrustedServerException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Connection status shown in the UI. */
data class UiState(
    val status: Status = Status.IDLE,
    val detail: String? = null,
    val server: String? = null,
    /** True while the computer's cursor is on this phone. */
    val active: Boolean = false,
    val serviceRunning: Boolean = false,
    /** Set when a TLS server presented a certificate that is not pinned yet. */
    val pendingTrust: PendingTrust? = null,
) {
    enum class Status { IDLE, CONNECTING, CONNECTED, RETRYING, ERROR }
}

data class PendingTrust(val host: String, val fingerprint: CertFingerprint)

/**
 * The input side of the app, implemented by [CursorService]. Except for
 * [screenSize], all calls happen on the main thread.
 */
interface InputSink {
    /** Physical screen size in pixels. May be called from any thread. */
    fun screenSize(): Pair<Int, Int>
    fun onEnter(x: Float, y: Float)
    fun onLeave()
    fun onMove(x: Float, y: Float)
    fun onButton(button: Int, down: Boolean)
    fun onWheel(xDelta: Int, yDelta: Int)
    fun onKey(keyId: Int, modifiers: Int, down: Boolean, repeat: Int)
    fun onClipboard(content: ClipboardContent)
}

/**
 * Owns the network connection, reconnects when it drops and forwards server
 * events to the [InputSink] on the main thread.
 */
class ClientController(private val settings: Settings) {
    private val main = Handler(Looper.getMainLooper())
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    @Volatile private var sink: InputSink? = null
    @Volatile private var client: BarrierClient? = null
    @Volatile private var generation = 0
    @Volatile private var scale = 1f

    // Cursor position in the server's (scaled) coordinates.
    @Volatile private var cursorX = 0
    @Volatile private var cursorY = 0

    fun attachSink(s: InputSink) {
        sink = s
        _state.update { it.copy(serviceRunning = true) }
        if (settings.autoConnect && settings.wantConnected && settings.host.isNotEmpty() && client == null) connect()
    }

    fun detachSink(s: InputSink) {
        if (sink === s) sink = null
        _state.update { it.copy(serviceRunning = false, active = false) }
    }

    fun connect() {
        val host = settings.host
        if (host.isEmpty()) {
            _state.update { it.copy(status = UiState.Status.ERROR, detail = "no server address") }
            return
        }
        settings.wantConnected = true
        disconnectInternal()
        val gen = ++generation
        _state.update { it.copy(status = UiState.Status.CONNECTING, detail = null, server = host, pendingTrust = null) }
        Thread({ connectLoop(gen) }, "one-cursor-connect").apply { isDaemon = true }.start()
    }

    fun disconnect() {
        settings.wantConnected = false
        disconnectInternal()
        _state.update { it.copy(status = UiState.Status.IDLE, detail = null, active = false) }
    }

    /** User accepted the certificate shown in [UiState.pendingTrust]. */
    fun acceptPendingTrust() {
        val p = _state.value.pendingTrust ?: return
        settings.trust(p.host, p.fingerprint)
        connect()
    }

    fun rejectPendingTrust() {
        _state.update { it.copy(pendingTrust = null) }
        disconnect()
    }

    /** Call after the screen rotated or the pointer speed changed. */
    fun screenChanged() {
        client?.updateShape()
    }

    fun sendClipboard(text: String): Boolean {
        val c = client ?: return false
        Thread { runCatching { c.sendClipboard(ClipboardContent(text = text)) } }.start()
        return true
    }

    val isConnected: Boolean get() = _state.value.status == UiState.Status.CONNECTED

    private fun disconnectInternal() {
        generation++
        client?.close()
        client = null
    }

    private fun connectLoop(gen: Int) {
        var attempt = 0
        while (gen == generation) {
            val host = settings.host
            val tls = if (settings.useTls) ServerTrust { h, fp -> settings.isTrusted(h, fp) } else null
            val config = ClientConfig(host, settings.port, settings.screenName, tls)
            val c = BarrierClient(config, screen, Listener(gen))
            client = c
            lastDisconnect = null
            reachedConnected = false
            c.run()
            if (gen != generation) return
            client = null
            val outcome = lastDisconnect
            val err = outcome?.error
            val reason = outcome?.reason

            if (err is UntrustedServerException) {
                _state.update {
                    it.copy(
                        status = UiState.Status.ERROR, detail = reason, active = false,
                        pendingTrust = PendingTrust(err.host, err.fingerprint),
                    )
                }
                return
            }
            if (reason != null && (reason.contains("refused client name") || reason.contains("already has a connected client"))) {
                _state.update { it.copy(status = UiState.Status.ERROR, detail = reason, active = false) }
                return
            }
            // A connection that worked for a while starts the back-off from scratch.
            attempt = if (reachedConnected) 1 else attempt + 1
            val delayMs = minOf(1000L * (1 shl minOf(attempt, 4)), 15_000L)
            _state.update { it.copy(status = UiState.Status.RETRYING, detail = reason, active = false) }
            Thread.sleep(delayMs)
            if (gen == generation) _state.update { it.copy(status = UiState.Status.CONNECTING) }
        }
    }

    @Volatile private var reachedConnected = false
    @Volatile private var lastDisconnect: ClientState.Disconnected? = null

    private val screen = object : ClientScreen {
        override fun shape(): ScreenShape {
            val (w, h) = physicalSize()
            scale = settings.pointerSpeed
            return ScreenShape(0, 0, (w / scale).toInt(), (h / scale).toInt())
        }

        override fun cursorPosition() = cursorX to cursorY
    }

    private fun physicalSize(): Pair<Int, Int> = sink?.screenSize() ?: (1080 to 1920)

    private inner class Listener(private val gen: Int) : ClientListener {
        private fun ui(block: (InputSink) -> Unit) {
            if (gen != generation) return
            main.post { if (gen == generation) sink?.let(block) }
        }

        override fun onStateChanged(state: ClientState) {
            if (gen != generation) return
            when (state) {
                ClientState.Connecting, ClientState.Handshaking -> Unit
                is ClientState.Connected -> {
                    reachedConnected = true
                    _state.update {
                        it.copy(status = UiState.Status.CONNECTED, detail = "${state.serverProtocol} ${state.major}.${state.minor}")
                    }
                }
                is ClientState.Disconnected -> {
                    lastDisconnect = state
                    Log.i(TAG, "disconnected: ${state.reason}", state.error)
                }
            }
        }

        override fun onEnter(x: Int, y: Int, modifiers: Int) {
            cursorX = x
            cursorY = y
            _state.update { it.copy(active = true) }
            val s = scale
            ui { it.onEnter(x * s, y * s) }
        }

        override fun onLeave() {
            _state.update { it.copy(active = false) }
            ui { it.onLeave() }
        }

        override fun onMouseMove(x: Int, y: Int) {
            cursorX = x
            cursorY = y
            val s = scale
            ui { it.onMove(x * s, y * s) }
        }

        override fun onMouseRelativeMove(dx: Int, dy: Int) {
            val shape = screen.shape()
            cursorX = (cursorX + dx).coerceIn(0, shape.width - 1)
            cursorY = (cursorY + dy).coerceIn(0, shape.height - 1)
            val s = scale
            val x = cursorX
            val y = cursorY
            ui { it.onMove(x * s, y * s) }
        }

        override fun onMouseDown(button: Int) = ui { it.onButton(button, true) }
        override fun onMouseUp(button: Int) = ui { it.onButton(button, false) }
        override fun onMouseWheel(xDelta: Int, yDelta: Int) = ui { it.onWheel(xDelta, yDelta) }
        override fun onKeyDown(keyId: Int, modifiers: Int, button: Int) = ui { it.onKey(keyId, modifiers, true, 1) }
        override fun onKeyRepeat(keyId: Int, modifiers: Int, count: Int, button: Int) =
            ui { it.onKey(keyId, modifiers, true, count) }
        override fun onKeyUp(keyId: Int, modifiers: Int, button: Int) = ui { it.onKey(keyId, modifiers, false, 0) }
        override fun onClipboard(id: Int, content: ClipboardContent) {
            if (id == 0) ui { it.onClipboard(content) }
        }
    }

    companion object {
        private const val TAG = "OneCursor"
    }
}
