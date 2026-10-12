package dev.onecursor.protocol

/**
 * Messages of the Barrier/Synergy 1.6 protocol. Every message travels inside a
 * frame (see [Framing]); this file only deals with the frame payload.
 *
 * Positions and sizes are signed 16 bit, key ids/modifier masks/key buttons are
 * unsigned 16 bit and sequence numbers are unsigned 32 bit (kept as raw [Int]).
 */
sealed interface Message {
    // --- handshake -------------------------------------------------------------
    /** Server -> client greeting. [protocolName] is "Barrier" or "Synergy". */
    data class Hello(val protocolName: String, val major: Int, val minor: Int) : Message

    /** Client -> server greeting reply carrying the client's screen name. */
    data class HelloBack(val protocolName: String, val major: Int, val minor: Int, val name: String) : Message

    // --- commands --------------------------------------------------------------
    data object NoOp : Message
    data object Close : Message
    data class Enter(val x: Int, val y: Int, val sequence: Int, val modifiers: Int) : Message
    data object Leave : Message
    data class GrabClipboard(val id: Int, val sequence: Int) : Message
    data class ScreenSaver(val on: Boolean) : Message
    data object ResetOptions : Message
    data object InfoAck : Message
    data object KeepAlive : Message

    // --- data ------------------------------------------------------------------
    data class KeyDown(val keyId: Int, val modifiers: Int, val button: Int) : Message
    data class KeyRepeat(val keyId: Int, val modifiers: Int, val count: Int, val button: Int) : Message
    data class KeyUp(val keyId: Int, val modifiers: Int, val button: Int) : Message
    data class MouseDown(val button: Int) : Message
    data class MouseUp(val button: Int) : Message
    data class MouseMove(val x: Int, val y: Int) : Message
    data class MouseRelMove(val dx: Int, val dy: Int) : Message
    data class MouseWheel(val xDelta: Int, val yDelta: Int) : Message

    /** One chunk of clipboard data, see [ClipboardChunks]. */
    class ClipboardChunk(val id: Int, val sequence: Int, val mark: Int, val data: ByteArray) : Message {
        override fun equals(other: Any?) = other is ClipboardChunk && other.id == id &&
            other.sequence == sequence && other.mark == mark && other.data.contentEquals(data)

        override fun hashCode() = ((id * 31 + sequence) * 31 + mark) * 31 + data.contentHashCode()
        override fun toString() = "ClipboardChunk(id=$id, seq=$sequence, mark=$mark, ${data.size} bytes)"
    }

    data class Info(
        val x: Int, val y: Int, val width: Int, val height: Int,
        val warpSize: Int, val mouseX: Int, val mouseY: Int,
    ) : Message

    /** Flat list of option id / value pairs. */
    class SetOptions(val options: IntArray) : Message {
        fun pairs(): List<Pair<Int, Int>> = (0 until options.size / 2).map { options[2 * it] to options[2 * it + 1] }
        override fun equals(other: Any?) = other is SetOptions && other.options.contentEquals(options)
        override fun hashCode() = options.contentHashCode()
        override fun toString() = "SetOptions(${pairs().joinToString { "${Options.name(it.first)}=${it.second}" }})"
    }

    data object QueryInfo : Message

    // --- errors ----------------------------------------------------------------
    data class Incompatible(val major: Int, val minor: Int) : Message
    data object Busy : Message
    data object UnknownClient : Message
    data object Bad : Message

    /** A well-formed message this implementation does not interpret (e.g. DFTR, DDRG). */
    class Unsupported(val code: String, val payload: ByteArray) : Message {
        override fun toString() = "Unsupported($code, ${payload.size} bytes)"
    }

    companion object {
        const val PROTOCOL_MAJOR = 1
        const val PROTOCOL_MINOR = 6
        const val DEFAULT_PORT = 24800
        val PROTOCOL_NAMES = listOf("Barrier", "Synergy")
    }
}

object MessageCodec {
    fun encode(msg: Message): ByteArray {
        val w = ByteWriter()
        when (msg) {
            is Message.Hello -> w.ascii(msg.protocolName).u16(msg.major).u16(msg.minor)
            is Message.HelloBack -> w.ascii(msg.protocolName).u16(msg.major).u16(msg.minor).string(msg.name)
            Message.NoOp -> w.ascii("CNOP")
            Message.Close -> w.ascii("CBYE")
            is Message.Enter -> w.ascii("CINN").u16(msg.x).u16(msg.y).u32(msg.sequence).u16(msg.modifiers)
            Message.Leave -> w.ascii("COUT")
            is Message.GrabClipboard -> w.ascii("CCLP").u8(msg.id).u32(msg.sequence)
            is Message.ScreenSaver -> w.ascii("CSEC").u8(if (msg.on) 1 else 0)
            Message.ResetOptions -> w.ascii("CROP")
            Message.InfoAck -> w.ascii("CIAK")
            Message.KeepAlive -> w.ascii("CALV")
            is Message.KeyDown -> w.ascii("DKDN").u16(msg.keyId).u16(msg.modifiers).u16(msg.button)
            is Message.KeyRepeat -> w.ascii("DKRP").u16(msg.keyId).u16(msg.modifiers).u16(msg.count).u16(msg.button)
            is Message.KeyUp -> w.ascii("DKUP").u16(msg.keyId).u16(msg.modifiers).u16(msg.button)
            is Message.MouseDown -> w.ascii("DMDN").u8(msg.button)
            is Message.MouseUp -> w.ascii("DMUP").u8(msg.button)
            is Message.MouseMove -> w.ascii("DMMV").u16(msg.x).u16(msg.y)
            is Message.MouseRelMove -> w.ascii("DMRM").u16(msg.dx).u16(msg.dy)
            is Message.MouseWheel -> w.ascii("DMWM").u16(msg.xDelta).u16(msg.yDelta)
            is Message.ClipboardChunk -> w.ascii("DCLP").u8(msg.id).u32(msg.sequence).u8(msg.mark).string(msg.data)
            is Message.Info -> w.ascii("DINF").u16(msg.x).u16(msg.y).u16(msg.width).u16(msg.height)
                .u16(msg.warpSize).u16(msg.mouseX).u16(msg.mouseY)
            is Message.SetOptions -> w.ascii("DSOP").intList(msg.options)
            Message.QueryInfo -> w.ascii("QINF")
            is Message.Incompatible -> w.ascii("EICV").u16(msg.major).u16(msg.minor)
            Message.Busy -> w.ascii("EBSY")
            Message.UnknownClient -> w.ascii("EUNK")
            Message.Bad -> w.ascii("EBAD")
            is Message.Unsupported -> w.ascii(msg.code).raw(msg.payload)
        }
        return w.toByteArray()
    }

    fun decode(frame: ByteArray): Message {
        for (name in Message.PROTOCOL_NAMES) {
            if (frame.startsWith(name)) return decodeHello(name, ByteReader(frame, name.length))
        }
        if (frame.size < 4) throw ProtocolException("message too short (${frame.size} bytes)")
        val code = String(frame, 0, 4, Charsets.US_ASCII)
        val r = ByteReader(frame, 4)
        val payloadSize = frame.size - 4
        val msg = when (code) {
            "CNOP" -> Message.NoOp
            "CBYE" -> Message.Close
            "CINN" -> Message.Enter(r.s16(), r.s16(), r.u32(), r.u16())
            "COUT" -> Message.Leave
            "CCLP" -> Message.GrabClipboard(r.u8(), r.u32())
            "CSEC" -> Message.ScreenSaver(r.u8() != 0)
            "CROP" -> Message.ResetOptions
            "CIAK" -> Message.InfoAck
            "CALV" -> Message.KeepAlive
            // 1.0 variants of the key messages do not carry the key button.
            "DKDN" -> if (payloadSize >= 6) Message.KeyDown(r.u16(), r.u16(), r.u16())
            else Message.KeyDown(r.u16(), r.u16(), 0)
            "DKRP" -> if (payloadSize >= 8) Message.KeyRepeat(r.u16(), r.u16(), r.u16(), r.u16())
            else Message.KeyRepeat(r.u16(), r.u16(), r.u16(), 0)
            "DKUP" -> if (payloadSize >= 6) Message.KeyUp(r.u16(), r.u16(), r.u16())
            else Message.KeyUp(r.u16(), r.u16(), 0)
            "DMDN" -> Message.MouseDown(r.u8())
            "DMUP" -> Message.MouseUp(r.u8())
            "DMMV" -> Message.MouseMove(r.s16(), r.s16())
            "DMRM" -> Message.MouseRelMove(r.s16(), r.s16())
            "DMWM" -> if (payloadSize >= 4) Message.MouseWheel(r.s16(), r.s16())
            else Message.MouseWheel(0, r.s16())
            "DCLP" -> Message.ClipboardChunk(r.u8(), r.u32(), r.u8(), r.string())
            "DINF" -> Message.Info(r.s16(), r.s16(), r.s16(), r.s16(), r.s16(), r.s16(), r.s16())
            "DSOP" -> Message.SetOptions(r.intList())
            "QINF" -> Message.QueryInfo
            "EICV" -> Message.Incompatible(r.s16(), r.s16())
            "EBSY" -> Message.Busy
            "EUNK" -> Message.UnknownClient
            "EBAD" -> Message.Bad
            else -> {
                if (!code.all { it in 'A'..'Z' }) throw ProtocolException("invalid message code")
                return Message.Unsupported(code, r.raw(r.remaining))
            }
        }
        return msg
    }

    private fun decodeHello(name: String, r: ByteReader): Message {
        val major = r.s16()
        val minor = r.s16()
        if (r.remaining == 0) return Message.Hello(name, major, minor)
        return Message.HelloBack(name, major, minor, String(r.string(), Charsets.UTF_8))
    }

    private fun ByteArray.startsWith(prefix: String): Boolean {
        if (size < prefix.length) return false
        for (i in prefix.indices) if (this[i] != prefix[i].code.toByte()) return false
        return true
    }
}
