package dev.onecursor.protocol

/**
 * Barrier key ids. Printable keys use their Unicode code point; special keys
 * live in the 0xE000-0xEFFF private range (mostly X11 keysyms with 0xFF00
 * remapped to 0xEF00).
 */
object KeyIds {
    const val NONE = 0x0000
    const val BACKSPACE = 0xEF08
    const val TAB = 0xEF09
    const val LINEFEED = 0xEF0A
    const val CLEAR = 0xEF0B
    const val RETURN = 0xEF0D
    const val PAUSE = 0xEF13
    const val SCROLL_LOCK = 0xEF14
    const val SYS_REQ = 0xEF15
    const val ESCAPE = 0xEF1B
    const val DELETE = 0xEFFF

    const val HOME = 0xEF50
    const val LEFT = 0xEF51
    const val UP = 0xEF52
    const val RIGHT = 0xEF53
    const val DOWN = 0xEF54
    const val PAGE_UP = 0xEF55
    const val PAGE_DOWN = 0xEF56
    const val END = 0xEF57
    const val BEGIN = 0xEF58

    const val SELECT = 0xEF60
    const val PRINT = 0xEF61
    const val EXECUTE = 0xEF62
    const val INSERT = 0xEF63
    const val UNDO = 0xEF65
    const val REDO = 0xEF66
    const val MENU = 0xEF67
    const val FIND = 0xEF68
    const val CANCEL = 0xEF69
    const val HELP = 0xEF6A
    const val BREAK = 0xEF6B
    const val ALT_GR = 0xEF7E
    const val NUM_LOCK = 0xEF7F

    const val KP_SPACE = 0xEF80
    const val KP_TAB = 0xEF89
    const val KP_ENTER = 0xEF8D
    const val KP_HOME = 0xEF95
    const val KP_LEFT = 0xEF96
    const val KP_UP = 0xEF97
    const val KP_RIGHT = 0xEF98
    const val KP_DOWN = 0xEF99
    const val KP_PAGE_UP = 0xEF9A
    const val KP_PAGE_DOWN = 0xEF9B
    const val KP_END = 0xEF9C
    const val KP_BEGIN = 0xEF9D
    const val KP_INSERT = 0xEF9E
    const val KP_DELETE = 0xEF9F
    const val KP_MULTIPLY = 0xEFAA
    const val KP_ADD = 0xEFAB
    const val KP_SEPARATOR = 0xEFAC
    const val KP_SUBTRACT = 0xEFAD
    const val KP_DECIMAL = 0xEFAE
    const val KP_DIVIDE = 0xEFAF
    const val KP_0 = 0xEFB0
    const val KP_9 = 0xEFB9
    const val KP_EQUAL = 0xEFBD

    const val F1 = 0xEFBE
    const val F12 = 0xEFC9
    const val F35 = 0xEFE0

    const val SHIFT_L = 0xEFE1
    const val SHIFT_R = 0xEFE2
    const val CONTROL_L = 0xEFE3
    const val CONTROL_R = 0xEFE4
    const val CAPS_LOCK = 0xEFE5
    const val SHIFT_LOCK = 0xEFE6
    const val META_L = 0xEFE7
    const val META_R = 0xEFE8
    const val ALT_L = 0xEFE9
    const val ALT_R = 0xEFEA
    const val SUPER_L = 0xEFEB
    const val SUPER_R = 0xEFEC
    const val HYPER_L = 0xEFED
    const val HYPER_R = 0xEFEE

    const val LEFT_TAB = 0xEE20

    const val EJECT = 0xE001
    const val SLEEP = 0xE05F
    const val WWW_BACK = 0xE0A6
    const val WWW_FORWARD = 0xE0A7
    const val WWW_REFRESH = 0xE0A8
    const val WWW_STOP = 0xE0A9
    const val WWW_SEARCH = 0xE0AA
    const val WWW_FAVORITES = 0xE0AB
    const val WWW_HOME = 0xE0AC
    const val AUDIO_MUTE = 0xE0AD
    const val AUDIO_DOWN = 0xE0AE
    const val AUDIO_UP = 0xE0AF
    const val AUDIO_NEXT = 0xE0B0
    const val AUDIO_PREV = 0xE0B1
    const val AUDIO_STOP = 0xE0B2
    const val AUDIO_PLAY = 0xE0B3
    const val APP_MAIL = 0xE0B4
    const val APP_MEDIA = 0xE0B5
    const val BRIGHTNESS_DOWN = 0xE0B8
    const val BRIGHTNESS_UP = 0xE0B9
    const val MISSION_CONTROL = 0xE0C0
    const val LAUNCHPAD = 0xE0C1

    /** Dead (combining) keys use the Unicode combining diacritic code points. */
    val DEAD_KEYS = 0x0300..0x036F

    fun isModifier(id: Int) = id in SHIFT_L..HYPER_R || id == ALT_GR

    fun isFunctionKey(id: Int) = id in F1..F35

    fun functionKeyNumber(id: Int) = id - F1 + 1

    /** True when [id] is an ordinary character (as opposed to a special key). */
    fun isPrintable(id: Int) = id in 0x20 until 0xE000 && id != 0x7F && id !in DEAD_KEYS
}

object KeyModifiers {
    const val SHIFT = 0x0001
    const val CONTROL = 0x0002
    const val ALT = 0x0004
    const val META = 0x0008
    const val SUPER = 0x0010
    const val ALT_GR = 0x0020
    const val LEVEL5_LOCK = 0x0040
    const val CAPS_LOCK = 0x1000
    const val NUM_LOCK = 0x2000
    const val SCROLL_LOCK = 0x4000

    fun describe(mask: Int): String = buildList {
        if (mask and SHIFT != 0) add("Shift")
        if (mask and CONTROL != 0) add("Ctrl")
        if (mask and ALT != 0) add("Alt")
        if (mask and META != 0) add("Meta")
        if (mask and SUPER != 0) add("Super")
        if (mask and ALT_GR != 0) add("AltGr")
        if (mask and CAPS_LOCK != 0) add("CapsLock")
        if (mask and NUM_LOCK != 0) add("NumLock")
        if (mask and SCROLL_LOCK != 0) add("ScrollLock")
    }.joinToString("+")
}

/** Modifier ids used by the modifier-remapping options (MMFS, MMFC, ...). */
object KeyModifierIds {
    const val NULL = 0
    const val SHIFT = 1
    const val CONTROL = 2
    const val ALT = 3
    const val META = 4
    const val SUPER = 5
    const val ALT_GR = 6

    fun toMask(id: Int) = when (id) {
        SHIFT -> KeyModifiers.SHIFT
        CONTROL -> KeyModifiers.CONTROL
        ALT -> KeyModifiers.ALT
        META -> KeyModifiers.META
        SUPER -> KeyModifiers.SUPER
        ALT_GR -> KeyModifiers.ALT_GR
        else -> 0
    }
}

object MouseButtons {
    const val NONE = 0
    const val LEFT = 1
    const val MIDDLE = 2
    const val RIGHT = 3
    /** Usually the "back" side button. */
    const val EXTRA0 = 4
    /** Usually the "forward" side button. */
    const val EXTRA1 = 5
}

object ClipboardIds {
    const val CLIPBOARD = 0
    const val SELECTION = 1
}

/** Option ids are four ASCII characters packed big-endian into an Int. */
object Options {
    fun code(s: String): Int {
        require(s.length == 4)
        return (s[0].code shl 24) or (s[1].code shl 16) or (s[2].code shl 8) or s[3].code
    }

    fun name(id: Int): String = String(
        charArrayOf(
            ((id ushr 24) and 0xff).toChar(), ((id ushr 16) and 0xff).toChar(),
            ((id ushr 8) and 0xff).toChar(), (id and 0xff).toChar(),
        ),
    )

    val HALF_DUPLEX_CAPS_LOCK = code("HDCL")
    val HALF_DUPLEX_NUM_LOCK = code("HDNL")
    val HALF_DUPLEX_SCROLL_LOCK = code("HDSL")
    val MODIFIER_MAP_FOR_SHIFT = code("MMFS")
    val MODIFIER_MAP_FOR_CONTROL = code("MMFC")
    val MODIFIER_MAP_FOR_ALT = code("MMFA")
    val MODIFIER_MAP_FOR_ALT_GR = code("MMFG")
    val MODIFIER_MAP_FOR_META = code("MMFM")
    val MODIFIER_MAP_FOR_SUPER = code("MMFR")
    val HEARTBEAT = code("HART")
    val SCREEN_SWITCH_CORNERS = code("SSCM")
    val SCREEN_SWITCH_CORNER_SIZE = code("SSCS")
    val SCREEN_SWITCH_DELAY = code("SSWT")
    val SCREEN_SWITCH_TWO_TAP = code("SSTT")
    val SCREEN_SAVER_SYNC = code("SSVR")
    val RELATIVE_MOUSE_MOVES = code("MDLT")
    val CLIPBOARD_SHARING = code("CLPS")
}
