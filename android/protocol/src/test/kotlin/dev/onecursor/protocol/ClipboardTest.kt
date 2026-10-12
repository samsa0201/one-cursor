package dev.onecursor.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class ClipboardTest {
    @Test
    fun marshalRoundTrip() {
        val c = ClipboardContent(text = "Xin chào\r\nthế giới", html = "<b>hi</b>")
        val back = ClipboardContent.unmarshal(c.marshal())
        assertEquals("Xin chào\nthế giới", back.text)
        assertEquals("<b>hi</b>", back.html)
    }

    @Test
    fun marshalLayout() {
        val bytes = ClipboardContent(text = "hi").marshal()
        assertContentEquals(byteArrayOf(0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 'h'.code.toByte(), 'i'.code.toByte()), bytes)
    }

    @Test
    fun chunkingAndAssembly() {
        val data = ByteArray(ClipboardChunks.CHUNK_SIZE * 2 + 100) { (it % 251).toByte() }
        val chunks = ClipboardChunks.split(0, 9, data)
        assertEquals(5, chunks.size)
        assertEquals("${data.size}", String(chunks.first().data))
        val asm = ClipboardAssembler()
        for (c in chunks.dropLast(1)) assertNull(asm.add(c))
        assertContentEquals(data, asm.add(chunks.last()))
    }

    @Test
    fun emptyClipboard() {
        val chunks = ClipboardChunks.split(0, 0, ByteArray(0))
        assertEquals(2, chunks.size)
        val asm = ClipboardAssembler()
        asm.add(chunks[0])
        assertContentEquals(ByteArray(0), asm.add(chunks[1]))
    }

    @Test
    fun sizeMismatchIsRejected() {
        val asm = ClipboardAssembler()
        asm.add(Message.ClipboardChunk(0, 0, ClipboardChunks.MARK_START, "10".toByteArray()))
        asm.add(Message.ClipboardChunk(0, 0, ClipboardChunks.MARK_CHUNK, ByteArray(4)))
        assertFailsWith<ProtocolException> { asm.add(Message.ClipboardChunk(0, 0, ClipboardChunks.MARK_END, ByteArray(0))) }
    }
}
