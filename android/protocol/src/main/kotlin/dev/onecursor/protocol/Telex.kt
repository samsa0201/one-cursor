package dev.onecursor.protocol

/**
 * A small Telex engine for typing Vietnamese with a computer keyboard on a
 * device that only receives raw key presses.
 *
 * Keys are collected per word and the whole word is recomposed on every key;
 * the caller applies the returned [Edit] (delete N characters before the
 * cursor, then insert text). Words that do not look Vietnamese are left as
 * typed, so English mostly passes through untouched.
 */
class TelexComposer {
    data class Edit(val delete: Int, val insert: String)

    private val raw = StringBuilder()
    private var output = ""

    /** Feeds one typed character and returns how to update the text field. */
    fun type(c: Char): Edit {
        if (!c.isLetter()) {
            reset()
            return Edit(0, c.toString())
        }
        raw.append(c)
        val next = compose(raw.toString())
        val common = output.commonPrefixWith(next).length
        val edit = Edit(output.length - common, next.substring(common))
        output = next
        return edit
    }

    /** Forget the current word (after a space, a click, a cursor move, ...). */
    fun reset() {
        raw.setLength(0)
        output = ""
    }

    /** Backspace removes the last typed key of the current word. */
    fun backspace() {
        if (raw.isEmpty()) return
        raw.setLength(raw.length - 1)
        // The field deleted one output character; keep our idea of it in sync.
        output = if (output.isNotEmpty()) output.dropLast(1) else output
        if (compose(raw.toString()) != output) reset()
    }

    companion object {
        private const val VOWELS = "aăâeêioôơuưy"
        private const val TONE_KEYS = "sfrxj"

        // Tone order: none, sắc, huyền, hỏi, ngã, nặng.
        private val TONED = mapOf(
            'a' to "aáàảãạ", 'ă' to "ăắằẳẵặ", 'â' to "âấầẩẫậ", 'e' to "eéèẻẽẹ", 'ê' to "êếềểễệ",
            'i' to "iíìỉĩị", 'o' to "oóòỏõọ", 'ô' to "ôốồổỗộ", 'ơ' to "ơớờởỡợ", 'u' to "uúùủũụ",
            'ư' to "ưứừửữự", 'y' to "yýỳỷỹỵ",
        )
        private val INITIALS = setOf(
            "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh", "nh",
            "p", "ph", "q", "qu", "r", "s", "t", "th", "tr", "v", "x",
        )
        private val FINALS = setOf("", "c", "ch", "m", "n", "ng", "nh", "p", "t")

        /** Composes a word from raw Telex keys. Exposed for tests. */
        fun compose(keys: String): String {
            val word = StringBuilder()
            var tone = 0
            var literal = false
            for (k in keys) {
                val lower = k.lowercaseChar()
                val upper = k.isUpperCase()
                val toneIndex = TONE_KEYS.indexOf(lower)
                when {
                    toneIndex >= 0 && hasVowel(word) && !literal -> {
                        if (tone == toneIndex + 1) {
                            tone = 0
                            word.append(k)
                            literal = true
                        } else {
                            tone = toneIndex + 1
                        }
                    }
                    lower == 'z' && tone != 0 && !literal -> tone = 0
                    (lower == 'a' || lower == 'e' || lower == 'o') && !literal && circumflex(word, lower, k) -> Unit
                    lower == 'w' && !literal && breve(word, k) -> Unit
                    lower == 'd' && !literal && word.length == 1 && word[0].lowercaseChar() == 'd' -> {
                        word.setCharAt(0, if (word[0].isUpperCase()) 'Đ' else 'đ')
                    }
                    lower == 'd' && !literal && word.length == 1 && word[0].lowercaseChar() == 'đ' -> {
                        word.setCharAt(0, if (word[0].isUpperCase()) 'D' else 'd')
                        word.append(k)
                        literal = true
                    }
                    else -> word.append(if (upper) k else lower)
                }
            }
            val base = word.toString()
            // After an undo (e.g. "ass" -> "as") the user wants exactly what is shown.
            if (!looksVietnamese(base, allowAnyFinal = literal)) return keys
            return if (tone == 0) base else applyTone(base, tone)
        }

        private fun isVowel(c: Char) = VOWELS.indexOf(c.lowercaseChar()) >= 0

        private fun hasVowel(word: CharSequence) = vowelRange(word.toString()) != null

        /** aa -> â, ee -> ê, oo -> ô (and a third press undoes it). */
        private fun circumflex(word: StringBuilder, letter: Char, key: Char): Boolean {
            val range = vowelRange(word.toString()) ?: return false
            val target = when (letter) { 'a' -> 'â'; 'e' -> 'ê'; else -> 'ô' }
            for (i in range.last downTo range.first) {
                val c = word[i].lowercaseChar()
                if (c == letter || (letter == 'a' && c == 'ă') || (letter == 'o' && c == 'ơ')) {
                    word.setCharAt(i, target.withCase(word[i]))
                    return true
                }
                if (c == target) {
                    word.setCharAt(i, letter.withCase(word[i]))
                    word.append(key)
                    return true
                }
            }
            return false
        }

        /** aw -> ă, ow -> ơ, uw -> ư, uow -> ươ, and a lone w -> ư. */
        private fun breve(word: StringBuilder, key: Char): Boolean {
            val s = word.toString().lowercase()
            val range = vowelRange(word.toString())
            if (range == null) {
                // "w" after a consonant (or at the start) types ư.
                word.append('ư'.withCase(key))
                return true
            }
            val uo = s.lastIndexOf("uo")
            if (uo >= 0 && uo >= range.first) {
                word.setCharAt(uo, 'ư'.withCase(word[uo]))
                word.setCharAt(uo + 1, 'ơ'.withCase(word[uo + 1]))
                return true
            }
            for (i in range.last downTo range.first) {
                val c = word[i].lowercaseChar()
                val replacement = when (c) {
                    'a', 'â' -> 'ă'
                    'o', 'ô' -> 'ơ'
                    'u' -> 'ư'
                    else -> null
                }
                if (replacement != null) {
                    word.setCharAt(i, replacement.withCase(word[i]))
                    return true
                }
                val undo = when (c) { 'ă' -> 'a'; 'ơ' -> 'o'; 'ư' -> 'u'; else -> null }
                if (undo != null) {
                    word.setCharAt(i, undo.withCase(word[i]))
                    word.append(key)
                    return true
                }
            }
            return false
        }

        /** The index range of the word's vowel nucleus, treating "qu" and "gi" as consonants. */
        private fun vowelRange(word: String): IntRange? {
            val lower = word.lowercase()
            var start = 0
            if (lower.startsWith("qu")) start = 2
            else if (lower.startsWith("gi") && lower.length > 2 && isVowel(lower[2])) start = 2
            while (start < lower.length && !isVowel(lower[start])) start++
            if (start >= lower.length) {
                // "gi" alone keeps i as the vowel (gì, gí).
                if (lower == "gi") return 1..1
                return null
            }
            var end = start
            while (end + 1 < lower.length && isVowel(lower[end + 1])) end++
            return start..end
        }

        private fun looksVietnamese(word: String, allowAnyFinal: Boolean = false): Boolean {
            val lower = word.lowercase()
            val range = vowelRange(lower) ?: return lower.all { it.isLetter() } && lower.length <= 3
            val initial = lower.substring(0, range.first)
            val final = lower.substring(range.last + 1)
            val nucleus = lower.substring(range.first, range.last + 1)
            return initial in INITIALS && (allowAnyFinal || final in FINALS) && nucleus.length <= 3
        }

        private fun applyTone(word: String, tone: Int): String {
            val range = vowelRange(word) ?: return word
            val lower = word.lowercase()
            val nucleus = lower.substring(range.first, range.last + 1)
            val hasFinal = range.last + 1 < word.length
            val pos = when {
                // ươ takes the tone on ơ; other marked vowels take it themselves.
                nucleus.contains("ươ") -> range.first + nucleus.indexOf("ươ") + 1
                nucleus.indexOfFirst { it in "ăâêôơư" } >= 0 -> range.first + nucleus.indexOfFirst { it in "ăâêôơư" }
                nucleus.length == 1 -> range.first
                hasFinal -> range.last
                nucleus.length == 3 -> range.first + 1
                else -> range.first
            }
            val c = word[pos]
            val toned = TONED[c.lowercaseChar()]?.get(tone) ?: return word
            return word.substring(0, pos) + toned.withCase(c) + word.substring(pos + 1)
        }

        private fun Char.withCase(model: Char) = if (model.isUpperCase()) uppercaseChar() else this
    }
}
