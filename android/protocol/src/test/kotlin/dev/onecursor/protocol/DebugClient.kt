package dev.onecursor.protocol

/**
 * Command line client that prints everything a server sends. Used to check
 * interoperability with real Barrier / Input Leap servers:
 *
 *     gradle runDebugClient --args="<host> <port> <name> [tls] [seconds]"
 */
fun main(args: Array<String>) {
    val host = args.getOrElse(0) { "127.0.0.1" }
    val port = args.getOrElse(1) { "24800" }.toInt()
    val name = args.getOrElse(2) { "android" }
    val tls = args.getOrNull(3) == "tls"
    val seconds = args.getOrElse(4) { "0" }.toLong()

    val screen = object : ClientScreen {
        override fun shape() = ScreenShape(0, 0, 1080, 2400)
        override fun cursorPosition() = 540 to 1200
    }
    val listener = object : ClientListener {
        fun log(s: String) = println("EVENT $s")
        override fun onStateChanged(state: ClientState) = log("state $state")
        override fun onEnter(x: Int, y: Int, modifiers: Int) = log("enter $x $y $modifiers")
        override fun onLeave() = log("leave")
        override fun onMouseMove(x: Int, y: Int) = log("move $x $y")
        override fun onMouseRelativeMove(dx: Int, dy: Int) = log("relmove $dx $dy")
        override fun onMouseDown(button: Int) = log("down $button")
        override fun onMouseUp(button: Int) = log("up $button")
        override fun onMouseWheel(xDelta: Int, yDelta: Int) = log("wheel $xDelta $yDelta")
        override fun onKeyDown(keyId: Int, modifiers: Int, button: Int) =
            log("keydown 0x${keyId.toString(16)} ${KeyModifiers.describe(modifiers)} $button")
        override fun onKeyUp(keyId: Int, modifiers: Int, button: Int) = log("keyup 0x${keyId.toString(16)}")
        override fun onKeyRepeat(keyId: Int, modifiers: Int, count: Int, button: Int) = log("keyrepeat 0x${keyId.toString(16)} $count")
        override fun onClipboard(id: Int, content: ClipboardContent) = log("clipboard $id ${content.text}")
        override fun onScreenSaver(on: Boolean) = log("screensaver $on")
        override fun onOptions(options: List<Pair<Int, Int>>) =
            log("options " + options.joinToString { "${Options.name(it.first)}=${it.second}" })
    }
    val trust = if (tls) ServerTrust { _, fp -> println("EVENT fingerprint ${fp.sha256}"); true } else null
    val client = BarrierClient(ClientConfig(host, port, name, trust), screen, listener)
    val t = client.start()
    if (seconds > 0) {
        Thread.sleep(seconds * 1000)
        client.close()
    }
    t.join()
}
