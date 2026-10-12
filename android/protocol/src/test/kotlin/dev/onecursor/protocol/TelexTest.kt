package dev.onecursor.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

class TelexTest {
    private fun c(keys: String) = TelexComposer.compose(keys)

    @Test
    fun basicWords() {
        assertEquals("Việt", c("Vieetj"))
        assertEquals("Nam", c("Nam"))
        assertEquals("tiếng", c("tieesng"))
        assertEquals("người", c("nguwowif"))
        assertEquals("đường", c("dduwowngf"))
        assertEquals("chào", c("chaof"))
        assertEquals("xin", c("xin"))
        assertEquals("cảm", c("camr"))
        assertEquals("ơn", c("own"))
        assertEquals("quá", c("quas"))
        assertEquals("gì", c("gif"))
        assertEquals("giữa", c("giuwax"))
        assertEquals("hóa", c("hoas"))
        assertEquals("toán", c("toans"))
        assertEquals("ngoài", c("ngoaif"))
        assertEquals("khuyên", c("khuyeen"))
        assertEquals("Đ", c("DD"))
        assertEquals("ư", c("w"))
        assertEquals("thư", c("thw"))
        assertEquals("ăn", c("awn"))
    }

    @Test
    fun toneCanBeTypedAtTheEnd() {
        assertEquals("trường", c("truongwf"))
        assertEquals("được", c("dduwowcj"))
    }

    @Test
    fun undo() {
        assertEquals("as", c("ass"))
        assertEquals("aa", c("aaa"))
        assertEquals("a", c("asz"))
    }

    @Test
    fun englishPassesThrough() {
        assertEquals("class", c("class"))
        assertEquals("first", c("first"))
        assertEquals("window", c("window"))
        assertEquals("street", c("street"))
    }

    @Test
    fun incrementalEdits() {
        val t = TelexComposer()
        val out = StringBuilder()
        for (ch in "Vieetj Nam") {
            val e = t.type(ch)
            out.setLength(out.length - e.delete)
            out.append(e.insert)
        }
        assertEquals("Việt Nam", out.toString())
    }
}
