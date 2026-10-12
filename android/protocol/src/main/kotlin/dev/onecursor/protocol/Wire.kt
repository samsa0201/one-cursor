package dev.onecursor.protocol

import java.io.ByteArrayOutputStream

/** Thrown when a peer sends bytes that do not form a valid message. */
class ProtocolException(message: String) : Exception(message)

/**
 * Big-endian writer matching Barrier's `ProtocolUtil::writef` encoding:
 * `%1i`/`%2i`/`%4i` are 1/2/4 byte integers, `%s` is a 4 byte length followed
 * by raw bytes and `%4I` is a 4 byte element count followed by 4 byte integers.
 */
class ByteWriter(initialCapacity: Int = 32) {
    private val out = ByteArrayOutputStream(initialCapacity)

    fun u8(v: Int) = apply { out.write(v and 0xff) }

    fun u16(v: Int) = apply {
        out.write((v ushr 8) and 0xff)
        out.write(v and 0xff)
    }

    fun u32(v: Int) = apply {
        out.write((v ushr 24) and 0xff)
        out.write((v ushr 16) and 0xff)
        out.write((v ushr 8) and 0xff)
        out.write(v and 0xff)
    }

    fun raw(bytes: ByteArray) = apply { out.write(bytes) }

    fun ascii(s: String) = raw(s.toByteArray(Charsets.US_ASCII))

    fun string(bytes: ByteArray) = apply {
        u32(bytes.size)
        out.write(bytes)
    }

    fun string(s: String) = string(s.toByteArray(Charsets.UTF_8))

    fun intList(values: IntArray) = apply {
        u32(values.size)
        values.forEach { u32(it) }
    }

    fun toByteArray(): ByteArray = out.toByteArray()
}

/** Big-endian reader, the inverse of [ByteWriter]. */
class ByteReader(private val buf: ByteArray, private var pos: Int = 0) {
    val remaining: Int get() = buf.size - pos

    private fun need(n: Int) {
        if (remaining < n) throw ProtocolException("message truncated: need $n bytes, have $remaining")
    }

    fun u8(): Int {
        need(1)
        return buf[pos++].toInt() and 0xff
    }

    fun u16(): Int {
        need(2)
        val v = ((buf[pos].toInt() and 0xff) shl 8) or (buf[pos + 1].toInt() and 0xff)
        pos += 2
        return v
    }

    /** Signed 16 bit value (positions, sizes and deltas). */
    fun s16(): Int = u16().toShort().toInt()

    fun u32(): Int {
        need(4)
        val v = ((buf[pos].toInt() and 0xff) shl 24) or
            ((buf[pos + 1].toInt() and 0xff) shl 16) or
            ((buf[pos + 2].toInt() and 0xff) shl 8) or
            (buf[pos + 3].toInt() and 0xff)
        pos += 4
        return v
    }

    fun raw(n: Int): ByteArray {
        need(n)
        val r = buf.copyOfRange(pos, pos + n)
        pos += n
        return r
    }

    fun string(): ByteArray {
        val len = u32()
        if (len < 0 || len > MAX_STRING_LENGTH) throw ProtocolException("string too long: $len")
        return raw(len)
    }

    fun intList(): IntArray {
        val n = u32()
        if (n < 0 || n > MAX_LIST_LENGTH) throw ProtocolException("list too long: $n")
        return IntArray(n) { u32() }
    }

    companion object {
        const val MAX_STRING_LENGTH = 1024 * 1024
        const val MAX_LIST_LENGTH = 1024 * 1024
    }
}
