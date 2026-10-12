package dev.onecursor.protocol

/**
 * Clipboard contents in Barrier's marshalled form:
 * `u32 formatCount` then for each format `u32 format, u32 size, size bytes`.
 * Text and HTML are UTF-8 with LF line endings.
 */
data class ClipboardContent(
    val text: String? = null,
    val html: String? = null,
    /** Barrier's bitmap format (a device independent bitmap), passed through untouched. */
    val bitmap: ByteArray? = null,
) {
    val isEmpty: Boolean get() = text == null && html == null && bitmap == null

    fun marshal(): ByteArray {
        val formats = buildList {
            text?.let { add(FORMAT_TEXT to it.replace("\r\n", "\n").toByteArray(Charsets.UTF_8)) }
            html?.let { add(FORMAT_HTML to it.toByteArray(Charsets.UTF_8)) }
            bitmap?.let { add(FORMAT_BITMAP to it) }
        }
        val w = ByteWriter().u32(formats.size)
        for ((format, data) in formats) w.u32(format).u32(data.size).raw(data)
        return w.toByteArray()
    }

    override fun equals(other: Any?): Boolean = other is ClipboardContent && other.text == text &&
        other.html == html && (other.bitmap?.contentEquals(bitmap) ?: (bitmap == null))

    override fun hashCode(): Int = (text.hashCode() * 31 + html.hashCode()) * 31 + (bitmap?.contentHashCode() ?: 0)

    companion object {
        const val FORMAT_TEXT = 0
        const val FORMAT_HTML = 1
        const val FORMAT_BITMAP = 2

        fun unmarshal(data: ByteArray): ClipboardContent {
            if (data.isEmpty()) return ClipboardContent()
            val r = ByteReader(data)
            var text: String? = null
            var html: String? = null
            var bitmap: ByteArray? = null
            repeat(r.u32()) {
                val format = r.u32()
                val size = r.u32()
                if (size < 0) throw ProtocolException("invalid clipboard format size")
                val bytes = r.raw(size)
                when (format) {
                    FORMAT_TEXT -> text = String(bytes, Charsets.UTF_8)
                    FORMAT_HTML -> html = String(bytes, Charsets.UTF_8)
                    FORMAT_BITMAP -> bitmap = bytes
                    // Unknown formats from newer peers are skipped.
                }
            }
            return ClipboardContent(text, html, bitmap)
        }
    }
}

/**
 * Protocol 1.6 sends clipboard data as a sequence of DCLP messages: a start
 * mark carrying the total size as a decimal string, data chunks of at most
 * [CHUNK_SIZE] bytes and an empty end mark.
 */
object ClipboardChunks {
    const val MARK_START = 1
    const val MARK_CHUNK = 2
    const val MARK_END = 3
    const val CHUNK_SIZE = 32 * 1024

    fun split(id: Int, sequence: Int, data: ByteArray): List<Message.ClipboardChunk> = buildList {
        add(Message.ClipboardChunk(id, sequence, MARK_START, data.size.toString().toByteArray(Charsets.US_ASCII)))
        var pos = 0
        while (pos < data.size) {
            val end = minOf(pos + CHUNK_SIZE, data.size)
            add(Message.ClipboardChunk(id, sequence, MARK_CHUNK, data.copyOfRange(pos, end)))
            pos = end
        }
        add(Message.ClipboardChunk(id, sequence, MARK_END, ByteArray(0)))
    }
}

/** Reassembles DCLP chunks. Returns the complete data when the end mark arrives. */
class ClipboardAssembler {
    private val buffers = HashMap<Int, java.io.ByteArrayOutputStream>()
    private val expected = HashMap<Int, Int>()

    fun add(chunk: Message.ClipboardChunk): ByteArray? {
        when (chunk.mark) {
            ClipboardChunks.MARK_START -> {
                val size = String(chunk.data, Charsets.US_ASCII).trim { it <= ' ' || it == '\u0000' }.toIntOrNull()
                    ?: throw ProtocolException("invalid clipboard size")
                if (size < 0 || size > MAX_CLIPBOARD_SIZE) throw ProtocolException("clipboard too large: $size")
                expected[chunk.id] = size
                buffers[chunk.id] = java.io.ByteArrayOutputStream(size)
            }
            ClipboardChunks.MARK_CHUNK -> {
                val buf = buffers[chunk.id] ?: return null
                if (buf.size() + chunk.data.size > (expected[chunk.id] ?: 0)) {
                    buffers.remove(chunk.id)
                    throw ProtocolException("clipboard data exceeds announced size")
                }
                buf.write(chunk.data)
            }
            ClipboardChunks.MARK_END -> {
                val buf = buffers.remove(chunk.id) ?: return null
                val size = expected.remove(chunk.id)
                val data = buf.toByteArray()
                if (data.size != size) throw ProtocolException("corrupted clipboard data: expected $size got ${data.size}")
                return data
            }
            else -> throw ProtocolException("unknown clipboard mark ${chunk.mark}")
        }
        return null
    }

    companion object {
        const val MAX_CLIPBOARD_SIZE = 64 * 1024 * 1024
    }
}
