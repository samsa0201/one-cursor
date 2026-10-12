package dev.onecursor.protocol

import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream

/**
 * Barrier's packet stream filter: every message is preceded by its length as a
 * 4 byte big-endian integer. This applies to the hello handshake too.
 */
object Framing {
    const val MAX_MESSAGE_LENGTH = 4 * 1024 * 1024

    fun frame(payload: ByteArray): ByteArray =
        ByteWriter(payload.size + 4).u32(payload.size).raw(payload).toByteArray()

    fun write(out: OutputStream, msg: Message) {
        out.write(frame(MessageCodec.encode(msg)))
    }
}

/** Reads whole frames from a blocking stream. */
class FrameReader(input: InputStream) {
    private val input = DataInputStream(input)

    /** Returns the next frame payload, or null on a clean end of stream. */
    fun readFrame(): ByteArray? {
        val len = try {
            input.readInt()
        } catch (e: EOFException) {
            return null
        }
        if (len < 0 || len > Framing.MAX_MESSAGE_LENGTH) throw ProtocolException("invalid frame length $len")
        val buf = ByteArray(len)
        input.readFully(buf)
        return buf
    }

    fun readMessage(): Message? = readFrame()?.let { MessageCodec.decode(it) }
}

/** Incremental frame decoder for non-blocking transports. */
class FrameDecoder {
    private var buf = ByteArray(0)

    /** Appends [data] and returns all frames that are now complete. */
    fun feed(data: ByteArray): List<ByteArray> {
        buf += data
        val frames = mutableListOf<ByteArray>()
        var pos = 0
        while (buf.size - pos >= 4) {
            val len = ByteReader(buf, pos).u32()
            if (len < 0 || len > Framing.MAX_MESSAGE_LENGTH) throw ProtocolException("invalid frame length $len")
            if (buf.size - pos - 4 < len) break
            frames += buf.copyOfRange(pos + 4, pos + 4 + len)
            pos += 4 + len
        }
        buf = buf.copyOfRange(pos, buf.size)
        return frames
    }
}
