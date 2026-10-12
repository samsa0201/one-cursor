package dev.onecursor.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CodecTest {
    private fun roundTrip(msg: Message) = assertEquals(msg, MessageCodec.decode(MessageCodec.encode(msg)))

    @Test
    fun allMessagesRoundTrip() {
        listOf(
            Message.Hello("Barrier", 1, 6),
            Message.Hello("Synergy", 1, 6),
            Message.HelloBack("Barrier", 1, 6, "pixel-8"),
            Message.NoOp, Message.Close, Message.Leave, Message.ResetOptions, Message.InfoAck,
            Message.KeepAlive, Message.QueryInfo, Message.Busy, Message.UnknownClient, Message.Bad,
            Message.Enter(-5, 1079, 0x7fff_ffff, KeyModifiers.CAPS_LOCK),
            Message.Enter(0, 0, -1, 0),
            Message.GrabClipboard(1, 42),
            Message.ScreenSaver(true),
            Message.KeyDown('a'.code, KeyModifiers.SHIFT, 0x0001),
            Message.KeyRepeat(KeyIds.BACKSPACE, 0, 3, 52),
            Message.KeyUp(KeyIds.SUPER_L, KeyModifiers.SUPER, 56),
            Message.MouseDown(MouseButtons.LEFT),
            Message.MouseUp(MouseButtons.RIGHT),
            Message.MouseMove(-32768, 32767),
            Message.MouseRelMove(-3, 4),
            Message.MouseWheel(0, -120),
            Message.ClipboardChunk(0, 7, ClipboardChunks.MARK_CHUNK, "xin chào".toByteArray()),
            Message.Info(0, 0, 1080, 2400, 0, 540, 1200),
            Message.SetOptions(intArrayOf(Options.HEARTBEAT, 5000, Options.MODIFIER_MAP_FOR_SUPER, 2)),
            Message.Incompatible(1, 6),
        ).forEach(::roundTrip)
    }

    @Test
    fun helloMatchesBarrierBytes() {
        val framed = Framing.frame(MessageCodec.encode(Message.Hello("Barrier", 1, 6)))
        val expected = byteArrayOf(0, 0, 0, 11) + "Barrier".toByteArray() + byteArrayOf(0, 1, 0, 6)
        assertContentEquals(expected, framed)
    }

    @Test
    fun helloBackMatchesBarrierBytes() {
        val bytes = MessageCodec.encode(Message.HelloBack("Barrier", 1, 6, "tab"))
        val expected = "Barrier".toByteArray() + byteArrayOf(0, 1, 0, 6, 0, 0, 0, 3) + "tab".toByteArray()
        assertContentEquals(expected, bytes)
    }

    @Test
    fun mouseMoveIsSignedBigEndian() {
        assertContentEquals(
            "DMMV".toByteArray() + byteArrayOf(0xff.toByte(), 0xfe.toByte(), 0x01, 0x00),
            MessageCodec.encode(Message.MouseMove(-2, 256)),
        )
    }

    @Test
    fun protocol10VariantsDecode() {
        assertEquals(Message.MouseWheel(0, 120), MessageCodec.decode("DMWM".toByteArray() + byteArrayOf(0, 120)))
        assertEquals(Message.KeyDown(0x61, 1, 0), MessageCodec.decode("DKDN".toByteArray() + byteArrayOf(0, 0x61, 0, 1)))
    }

    @Test
    fun unknownCodesArePreserved() {
        val msg = MessageCodec.decode("DFTR".toByteArray() + byteArrayOf(1, 2, 3))
        assertEquals("DFTR", (msg as Message.Unsupported).code)
    }

    @Test
    fun frameDecoderHandlesSplitInput() {
        val a = Framing.frame(MessageCodec.encode(Message.KeepAlive))
        val b = Framing.frame(MessageCodec.encode(Message.MouseMove(10, 20)))
        val all = a + b
        val dec = FrameDecoder()
        val frames = mutableListOf<ByteArray>()
        for (i in all.indices) frames += dec.feed(byteArrayOf(all[i]))
        assertEquals(listOf(Message.KeepAlive, Message.MouseMove(10, 20)), frames.map(MessageCodec::decode))
    }

    @Test
    fun frameReaderReturnsNullAtEnd() {
        val r = FrameReader(java.io.ByteArrayInputStream(ByteArray(0)))
        assertNull(r.readFrame())
    }

    @Test
    fun optionCodes() {
        assertEquals(0x48415254, Options.HEARTBEAT)
        assertEquals("MDLT", Options.name(Options.RELATIVE_MOUSE_MOVES))
    }
}
