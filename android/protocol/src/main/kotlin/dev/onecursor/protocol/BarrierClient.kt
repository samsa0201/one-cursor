package dev.onecursor.protocol

import java.io.BufferedOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

data class ScreenShape(val x: Int, val y: Int, val width: Int, val height: Int)

/** Information the client needs from the device it runs on. */
interface ClientScreen {
    fun shape(): ScreenShape
    fun cursorPosition(): Pair<Int, Int>
}

sealed interface ClientState {
    data object Connecting : ClientState
    data object Handshaking : ClientState
    data class Connected(val serverProtocol: String, val major: Int, val minor: Int) : ClientState
    data class Disconnected(val reason: String?, val error: Throwable? = null) : ClientState
}

/** Events delivered from the server. Called on the client's network thread. */
interface ClientListener {
    fun onStateChanged(state: ClientState) {}
    fun onEnter(x: Int, y: Int, modifiers: Int) {}
    fun onLeave() {}
    fun onMouseMove(x: Int, y: Int) {}
    fun onMouseRelativeMove(dx: Int, dy: Int) {}
    fun onMouseDown(button: Int) {}
    fun onMouseUp(button: Int) {}
    fun onMouseWheel(xDelta: Int, yDelta: Int) {}
    fun onKeyDown(keyId: Int, modifiers: Int, button: Int) {}
    fun onKeyRepeat(keyId: Int, modifiers: Int, count: Int, button: Int) {}
    fun onKeyUp(keyId: Int, modifiers: Int, button: Int) {}
    fun onClipboard(id: Int, content: ClipboardContent) {}
    fun onScreenSaver(on: Boolean) {}
    fun onOptions(options: List<Pair<Int, Int>>) {}
}

data class ClientConfig(
    val host: String,
    val port: Int = Message.DEFAULT_PORT,
    val name: String,
    /** When non-null the connection uses TLS and the server certificate is checked with it. */
    val tls: ServerTrust? = null,
    val connectTimeoutMs: Int = 10_000,
)

/**
 * A Barrier/Synergy protocol 1.6 client. [run] blocks until the connection
 * ends; [start] runs it on a background thread.
 */
class BarrierClient(
    private val config: ClientConfig,
    private val screen: ClientScreen,
    private val listener: ClientListener,
) {
    private val closed = AtomicBoolean(false)
    @Volatile private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    private val writeLock = Any()

    @Volatile private var protocolName = "Barrier"
    @Volatile private var sequence = 0
    @Volatile private var ignoreMouse = false
    @Volatile private var active = false
    private var keepAliveRateMs = KEEP_ALIVE_RATE_MS
    private val modifiers = ModifierTranslator()
    private val clipboardAssembler = ClipboardAssembler()
    private var thread: Thread? = null

    val isActive: Boolean get() = active

    fun start(): Thread = Thread({ run() }, "barrier-client").also {
        it.isDaemon = true
        thread = it
        it.start()
    }

    fun run() {
        var reason: String? = null
        var error: Throwable? = null
        try {
            listener.onStateChanged(ClientState.Connecting)
            val plain = Socket()
            socket = plain
            plain.tcpNoDelay = true
            plain.connect(InetSocketAddress(config.host, config.port), config.connectTimeoutMs)
            val sock = config.tls?.let { Tls.wrap(plain, config.host, config.port, it) } ?: plain
            socket = sock
            sock.soTimeout = HANDSHAKE_TIMEOUT_MS
            out = BufferedOutputStream(sock.getOutputStream())
            val reader = FrameReader(sock.getInputStream().buffered())
            listener.onStateChanged(ClientState.Handshaking)
            handshake(reader)
            sock.soTimeout = keepAliveTimeout()
            reason = loop(reader)
        } catch (e: SocketTimeoutException) {
            reason = "server did not respond"
            error = e
        } catch (e: UntrustedServerException) {
            reason = e.message
            error = e
        } catch (e: ProtocolException) {
            reason = "protocol error: ${e.message}"
            error = e
            runCatching { send(Message.Bad) }
        } catch (e: IOException) {
            if (!closed.get()) {
                reason = e.message ?: e.javaClass.simpleName
                error = e
            }
        } finally {
            val wasActive = active
            active = false
            closeSocket()
            if (wasActive) runCatching { listener.onLeave() }
            listener.onStateChanged(ClientState.Disconnected(reason, error))
        }
    }

    /** Disconnects; safe to call from any thread. */
    fun close() {
        if (closed.getAndSet(true)) return
        closeSocket()
    }

    /** Tells the server that the screen shape changed (e.g. after a rotation). */
    fun updateShape() {
        ignoreMouse = true
        sendInfo()
    }

    /** Publishes this device's clipboard to the server. */
    fun sendClipboard(content: ClipboardContent, id: Int = ClipboardIds.CLIPBOARD) {
        val seq = sequence
        synchronized(writeLock) {
            val o = out ?: return
            Framing.write(o, Message.GrabClipboard(id, seq))
            for (chunk in ClipboardChunks.split(id, seq, content.marshal())) Framing.write(o, chunk)
            o.flush()
        }
    }

    fun send(msg: Message) {
        synchronized(writeLock) {
            val o = out ?: return
            Framing.write(o, msg)
            o.flush()
        }
    }

    private fun handshake(reader: FrameReader) {
        val hello = reader.readMessage() ?: throw IOException("server closed the connection")
        if (hello !is Message.Hello) {
            throw ProtocolException("expected hello, got $hello (check that TLS settings match the server)")
        }
        if (hello.major < Message.PROTOCOL_MAJOR ||
            (hello.major == Message.PROTOCOL_MAJOR && hello.minor < Message.PROTOCOL_MINOR)
        ) {
            throw ProtocolException("server protocol ${hello.major}.${hello.minor} is too old")
        }
        protocolName = hello.protocolName
        send(Message.HelloBack(hello.protocolName, Message.PROTOCOL_MAJOR, Message.PROTOCOL_MINOR, config.name))
        listener.onStateChanged(ClientState.Connected(hello.protocolName, hello.major, hello.minor))
    }

    /** Returns the disconnect reason. */
    private fun loop(reader: FrameReader): String? {
        while (!closed.get()) {
            val msg = reader.readMessage() ?: return "server closed the connection"
            handle(msg)?.let { return it }
        }
        return null
    }

    /** Handles one message; returns a reason string when the connection must end. */
    internal fun handle(msg: Message): String? {
        when (msg) {
            Message.QueryInfo -> sendInfo()
            Message.InfoAck -> ignoreMouse = false
            Message.ResetOptions -> resetOptions()
            is Message.SetOptions -> setOptions(msg)
            Message.KeepAlive -> send(Message.KeepAlive)
            Message.NoOp -> Unit
            is Message.Enter -> {
                sequence = msg.sequence
                active = true
                listener.onEnter(msg.x, msg.y, modifiers.translateMask(msg.modifiers))
            }
            Message.Leave -> {
                active = false
                listener.onLeave()
            }
            is Message.MouseMove -> if (!ignoreMouse) listener.onMouseMove(msg.x, msg.y)
            is Message.MouseRelMove -> if (!ignoreMouse) listener.onMouseRelativeMove(msg.dx, msg.dy)
            is Message.MouseDown -> listener.onMouseDown(msg.button)
            is Message.MouseUp -> listener.onMouseUp(msg.button)
            is Message.MouseWheel -> listener.onMouseWheel(msg.xDelta, msg.yDelta)
            is Message.KeyDown -> listener.onKeyDown(
                modifiers.translateKey(msg.keyId), modifiers.translateMask(msg.modifiers), msg.button,
            )
            is Message.KeyRepeat -> listener.onKeyRepeat(
                modifiers.translateKey(msg.keyId), modifiers.translateMask(msg.modifiers), msg.count, msg.button,
            )
            is Message.KeyUp -> listener.onKeyUp(
                modifiers.translateKey(msg.keyId), modifiers.translateMask(msg.modifiers), msg.button,
            )
            is Message.GrabClipboard -> Unit // another screen owns the clipboard now
            is Message.ClipboardChunk -> clipboardAssembler.add(msg)?.let {
                listener.onClipboard(msg.id, ClipboardContent.unmarshal(it))
            }
            is Message.ScreenSaver -> listener.onScreenSaver(msg.on)
            Message.Close -> return "server closed the connection"
            is Message.Incompatible -> return "server has incompatible version ${msg.major}.${msg.minor}"
            Message.Busy -> return "server already has a connected client named \"${config.name}\""
            Message.UnknownClient -> return "server refused client name \"${config.name}\" " +
                "(add it to the server's screen layout)"
            Message.Bad -> return "server reported a protocol error"
            is Message.Unsupported -> Unit
            is Message.Hello, is Message.HelloBack, is Message.Info -> throw ProtocolException("unexpected $msg")
        }
        return null
    }

    private fun sendInfo() {
        val s = screen.shape()
        val (mx, my) = screen.cursorPosition()
        send(Message.Info(s.x, s.y, s.width, s.height, 0, mx, my))
    }

    private fun resetOptions() {
        modifiers.reset()
        setKeepAliveRate(KEEP_ALIVE_RATE_MS)
    }

    private fun setOptions(msg: Message.SetOptions) {
        val pairs = msg.pairs()
        for ((id, value) in pairs) {
            when (id) {
                Options.MODIFIER_MAP_FOR_SHIFT -> modifiers.map(KeyModifierIds.SHIFT, value)
                Options.MODIFIER_MAP_FOR_CONTROL -> modifiers.map(KeyModifierIds.CONTROL, value)
                Options.MODIFIER_MAP_FOR_ALT -> modifiers.map(KeyModifierIds.ALT, value)
                Options.MODIFIER_MAP_FOR_ALT_GR -> modifiers.map(KeyModifierIds.ALT_GR, value)
                Options.MODIFIER_MAP_FOR_META -> modifiers.map(KeyModifierIds.META, value)
                Options.MODIFIER_MAP_FOR_SUPER -> modifiers.map(KeyModifierIds.SUPER, value)
                Options.HEARTBEAT -> setKeepAliveRate(value.toLong())
            }
        }
        listener.onOptions(pairs)
    }

    private fun setKeepAliveRate(ms: Long) {
        keepAliveRateMs = if (ms > 0) ms else KEEP_ALIVE_RATE_MS
        runCatching { socket?.soTimeout = keepAliveTimeout() }
    }

    private fun keepAliveTimeout(): Int = (keepAliveRateMs * KEEP_ALIVES_UNTIL_DEATH).toInt()

    private fun closeSocket() {
        out = null
        runCatching { socket?.close() }
    }

    companion object {
        const val KEEP_ALIVE_RATE_MS = 3_000L
        const val KEEP_ALIVES_UNTIL_DEATH = 3
        const val HANDSHAKE_TIMEOUT_MS = 30_000
    }
}

/**
 * Applies the server's modifier remapping options (e.g. "super = ctrl") to key
 * ids and masks, mirroring Barrier's ServerProxy.
 */
class ModifierTranslator {
    private val table = IntArray(7) { it }

    fun reset() {
        for (i in table.indices) table[i] = i
    }

    fun map(from: Int, to: Int) {
        if (from in 1..6 && to in 0..6) table[from] = to
    }

    fun translateKey(id: Int): Int {
        for (mod in 1..6) {
            val keys = KEYS[mod]
            val side = keys.indexOf(id)
            if (side >= 0) {
                val target = table[mod]
                return if (target == KeyModifierIds.NULL) KeyIds.NONE else KEYS[target][side]
            }
        }
        return id
    }

    fun translateMask(mask: Int): Int {
        var out = mask and MODIFIER_BITS.inv()
        for (mod in 1..6) {
            if (mask and KeyModifierIds.toMask(mod) != 0) out = out or KeyModifierIds.toMask(table[mod])
        }
        return out
    }

    private companion object {
        val KEYS = arrayOf(
            intArrayOf(KeyIds.NONE, KeyIds.NONE),
            intArrayOf(KeyIds.SHIFT_L, KeyIds.SHIFT_R),
            intArrayOf(KeyIds.CONTROL_L, KeyIds.CONTROL_R),
            intArrayOf(KeyIds.ALT_L, KeyIds.ALT_R),
            intArrayOf(KeyIds.META_L, KeyIds.META_R),
            intArrayOf(KeyIds.SUPER_L, KeyIds.SUPER_R),
            intArrayOf(KeyIds.ALT_GR, KeyIds.ALT_GR),
        )
        val MODIFIER_BITS = KeyModifiers.SHIFT or KeyModifiers.CONTROL or KeyModifiers.ALT or
            KeyModifiers.META or KeyModifiers.SUPER or KeyModifiers.ALT_GR
    }
}
