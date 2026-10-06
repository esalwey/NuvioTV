package com.nuvio.app.features.streams

/**
 * Fork (STREAM-INSIGHT): emoji handling for add-on stream text. Add-ons decorate names and
 * descriptions with emoji ("👤 45 💾 2.3 GB ⚙️ YggTorrent", flag emoji for languages); the parser
 * reads them as markers, and the tvOS UI must never show them (SF Symbols only).
 *
 * Pure string code (no regex on astral code points), so it behaves the same on the JVM and on
 * Kotlin/Native.
 */
object StreamInsightText {

    /**
     * [text] with every emoji, variation selector, zero-width joiner, keycap mark and flag removed,
     * runs of spaces collapsed, each line trimmed and empty lines dropped. Line breaks are kept.
     */
    fun stripEmoji(text: String?): String {
        if (text.isNullOrEmpty()) return ""
        val builder = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val char = text[index]
            if (char.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate()) {
                val codePoint = toCodePoint(char, text[index + 1])
                if (!isEmojiCodePoint(codePoint)) {
                    builder.append(char).append(text[index + 1])
                } else {
                    builder.append(' ')
                }
                index += 2
                continue
            }
            if (isEmojiCodePoint(char.code)) builder.append(' ') else builder.append(char)
            index += 1
        }
        return builder.toString()
            .split('\n')
            .map { line ->
                // "Multi Audio / 🇫🇷 / 🇬🇧" leaves "Multi Audio / / " behind: fold the orphaned
                // separators, then trim them off the ends.
                val collapsed = ORPHAN_SEPARATORS.replace(collapseSpaces(line).trim(), "$1")
                collapsed.trim().trim(*SEPARATOR_CHARS).trim()
            }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
    }

    private val SEPARATOR_CHARS = charArrayOf('|', '/', '•', '·', ',', '-', ':')
    private val ORPHAN_SEPARATORS = Regex("([/|•·])(?:\\s*[/|•·])+")

    /** One line: [stripEmoji] with the line breaks turned into " · ". */
    fun stripEmojiSingleLine(text: String?): String =
        stripEmoji(text).split('\n').joinToString(" · ")

    internal fun toCodePoint(high: Char, low: Char): Int =
        ((high.code - 0xD800) shl 10) + (low.code - 0xDC00) + 0x10000

    /** Emoji and pictographs, dingbats, arrows/technical symbols used as emoji, joiners, tags. */
    internal fun isEmojiCodePoint(codePoint: Int): Boolean = when (codePoint) {
        in 0x1F000..0x1FAFF -> true      // pictographs, emoticons, transport, flags (regional indicators)
        in 0x1FC00..0x1FFFF -> true
        in 0xE0020..0xE007F -> true      // tag sequences (subdivision flags)
        in 0x2190..0x21FF -> true        // arrows
        in 0x2300..0x23FF -> true        // misc technical (⏳ ⌛ ⏩)
        in 0x25A0..0x25FF -> true        // geometric shapes (▶ ◀ ●)
        in 0x2600..0x27BF -> true        // misc symbols + dingbats (⚙ ⚡ ✔ ❤)
        in 0x2900..0x297F -> true        // supplemental arrows (⤴)
        in 0x2B00..0x2BFF -> true        // ⬆ ⬇ ⭐
        0xFE0F, 0xFE0E, 0x200D, 0x20E3, 0x3030, 0x303D, 0x3297, 0x3299, 0x2122, 0x2139 -> true
        else -> false
    }

    internal fun collapseSpaces(value: String): String {
        val builder = StringBuilder(value.length)
        var lastWasSpace = false
        for (char in value) {
            val isSpace = char == ' ' || char == '\t' || char == ' ' || char == '\r'
            if (isSpace) {
                if (!lastWasSpace) builder.append(' ')
                lastWasSpace = true
            } else {
                builder.append(char)
                lastWasSpace = false
            }
        }
        return builder.toString()
    }
}
