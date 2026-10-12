package dev.onecursor.protocol

import java.net.ServerSocket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class BarrierClientTest {
    private class Recorder : ClientListener {
        val events = LinkedBlockingQueue<String>()
        override fun onStateChanged(state: ClientState) { events += "state:${state.javaClass.simpleName}" }
        override fun onEnter(x: Int, y: Int, modifiers: Int) { events += "enter:$x,$y,$modifiers" }
        override fun onLeave() { events += "leave" }
        override fun onMouseMove(x: Int, y: Int) { events += "move:$x,$y" }
        override fun onMouseDown(button: Int) { events += "down:$button" }
        override fun onMouseUp(button: Int) { events += "up:$button" }
        override fun onMouseWheel(xDelta: Int, yDelta: Int) { events += "wheel:$xDelta,$yDelta" }
        override fun onKeyDown(keyId: Int, modifiers: Int, button: Int) { events += "key:${keyId.toString(16)},$modifiers" }
        override fun onClipboard(id: Int, content: ClipboardContent) { events += "clip:${content.text}" }

        fun next(): String = events.poll(5, TimeUnit.SECONDS) ?: error("timed out waiting for event")
    }

    private val screen = object : ClientScreen {
        override fun shape() = ScreenShape(0, 0, 1080, 2400)
        override fun cursorPosition() = 540 to 1200
    }

    @Test
    fun fullSessionAgainstFakeServer() {
        val server = ServerSocket(0)
        val serverLog = LinkedBlockingQueue<Message>()
        val serverThread = thread {
            server.accept().use { s ->
                val out = s.getOutputStream()
                val reader = FrameReader(s.getInputStream())
                fun send(m: Message) { Framing.write(out, m); out.flush() }
                send(Message.Hello("Barrier", 1, 6))
                serverLog += reader.readMessage()!!
                send(Message.QueryInfo)
                serverLog += reader.readMessage()!!
                send(Message.InfoAck)
                send(Message.ResetOptions)
                send(Message.SetOptions(intArrayOf(Options.MODIFIER_MAP_FOR_SUPER, KeyModifierIds.CONTROL)))
                send(Message.KeepAlive)
                serverLog += reader.readMessage()!!
                send(Message.Enter(0, 100, 5, 0))
                send(Message.MouseMove(10, 110))
                send(Message.MouseDown(1))
                send(Message.MouseUp(1))
                send(Message.MouseWheel(0, 120))
                send(Message.KeyDown('c'.code, KeyModifiers.SUPER, 9))
                for (c in ClipboardChunks.split(0, 0, ClipboardContent(text = "xin chào").marshal())) send(c)
                send(Message.Leave)
                // the client publishes its clipboard with the sequence number from the last enter
                serverLog += reader.readMessage()!!
                serverLog += reader.readMessage()!!
                send(Message.Close)
                Thread.sleep(200)
            }
        }

        val rec = Recorder()
        val client = BarrierClient(ClientConfig("127.0.0.1", server.localPort, "phone"), screen, rec)
        client.start()

        assertEquals("state:Connecting", rec.next())
        assertEquals("state:Handshaking", rec.next())
        assertEquals("state:Connected", rec.next())
        assertEquals(Message.HelloBack("Barrier", 1, 6, "phone"), serverLog.poll(5, TimeUnit.SECONDS))
        assertEquals(Message.Info(0, 0, 1080, 2400, 0, 540, 1200), serverLog.poll(5, TimeUnit.SECONDS))
        assertEquals(Message.KeepAlive, serverLog.poll(5, TimeUnit.SECONDS))
        assertEquals("enter:0,100,0", rec.next())
        assertEquals("move:10,110", rec.next())
        assertEquals("down:1", rec.next())
        assertEquals("up:1", rec.next())
        assertEquals("wheel:0,120", rec.next())
        // super was remapped to control by the server's options
        assertEquals("key:63,${KeyModifiers.CONTROL}", rec.next())
        assertEquals("clip:xin chào", rec.next())
        assertEquals("leave", rec.next())

        client.sendClipboard(ClipboardContent(text = "from phone"))
        assertEquals(Message.GrabClipboard(0, 5), serverLog.poll(5, TimeUnit.SECONDS))
        val start = serverLog.poll(5, TimeUnit.SECONDS)
        assertIs<Message.ClipboardChunk>(start)
        assertEquals(5, start.sequence)

        val last = rec.next()
        assertTrue(last.startsWith("state:Disconnected"), last)
        serverThread.join(5000)
        server.close()
    }

    @Test
    fun unknownClientNameIsReported() {
        val server = ServerSocket(0)
        thread {
            server.accept().use { s ->
                val out = s.getOutputStream()
                Framing.write(out, Message.Hello("Barrier", 1, 6)); out.flush()
                FrameReader(s.getInputStream()).readMessage()
                Framing.write(out, Message.UnknownClient); out.flush()
                Thread.sleep(200)
            }
        }
        var final: ClientState? = null
        val client = BarrierClient(ClientConfig("127.0.0.1", server.localPort, "nobody"), screen, object : ClientListener {
            override fun onStateChanged(state: ClientState) { final = state }
        })
        client.run()
        val state = assertIs<ClientState.Disconnected>(final)
        assertTrue(state.reason!!.contains("refused"), state.reason)
        server.close()
    }
}
