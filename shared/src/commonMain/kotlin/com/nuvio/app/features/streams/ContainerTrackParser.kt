package com.nuvio.app.features.streams

/*
 * Fork (VERIFIED-LANGUAGES): the audio and subtitle tracks a media file really carries, read from
 * its container header — Matroska/WebM (EBML `Tracks`) and MP4/MOV (`moov/trak`). Pure byte
 * parsing, no I/O: the parser reads through a [ContainerByteSource] that throws
 * [ContainerNeedsBytes] for a range it does not hold yet, and [TrackProbe] fetches that range
 * (HTTP Range) and parses again. Parsing is cheap; the network is not — so the parser only ever
 * touches element headers and the few small values it needs.
 */

enum class ContainerTrackKind { AUDIO, SUBTITLE }

data class ContainerTrack(
    val kind: ContainerTrackKind,
    /** Container language: ISO 639-2 ("fre", "eng", "und") — Matroska `Language`, MP4 `mdhd`. */
    val language: String? = null,
    /** BCP 47 tag when the container has one ("fr-CA") — Matroska `LanguageBCP47`, MP4 `elng`. */
    val languageTag: String? = null,
    /** Track title ("VFF", "French (Canada)", "Commentary"). */
    val name: String? = null,
    val codec: String? = null,
    val channels: Int? = null,
    val isDefault: Boolean = false,
    val isForced: Boolean = false,
)

/** Thrown by a [ContainerByteSource] for bytes it does not hold: fetch them and parse again. */
class ContainerNeedsBytes(val offset: Long, val length: Int) : RuntimeException("need $length bytes at $offset")

/** Random access to the bytes of a remote file, as far as they were fetched. */
class ContainerByteSource(
    /** Whole file size when known (Content-Range / Content-Length). */
    var totalSize: Long? = null,
) {
    private val segments = mutableListOf<Pair<Long, ByteArray>>()

    val bufferedBytes: Long get() = segments.sumOf { it.second.size.toLong() }

    fun add(offset: Long, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        segments += offset to bytes
        segments.sortBy { it.first }
    }

    fun contains(offset: Long, length: Int): Boolean = segments.any { (start, bytes) ->
        offset >= start && offset + length <= start + bytes.size
    }

    /** Bytes [offset, offset + length): throws [ContainerNeedsBytes] when not held, null past the end. */
    fun read(offset: Long, length: Int): ByteArray? {
        if (length <= 0) return ByteArray(0)
        val total = totalSize
        if (total != null && offset + length > total) return null
        for ((start, bytes) in segments) {
            if (offset >= start && offset + length <= start + bytes.size) {
                val from = (offset - start).toInt()
                return bytes.copyOfRange(from, from + length)
            }
        }
        throw ContainerNeedsBytes(offset, length)
    }

    fun byte(offset: Long): Int? = read(offset, 1)?.let { it[0].toInt() and 0xFF }

    companion object {
        /** A source holding a whole file (tests, local data). */
        fun of(bytes: ByteArray): ContainerByteSource = ContainerByteSource(bytes.size.toLong()).also { it.add(0, bytes) }
    }
}

enum class ContainerFormat { MATROSKA, MP4, UNKNOWN }

object ContainerTrackParser {

    fun detect(head: ByteArray): ContainerFormat {
        if (head.size >= 4 && (head[0].toInt() and 0xFF) == 0x1A && (head[1].toInt() and 0xFF) == 0x45 &&
            (head[2].toInt() and 0xFF) == 0xDF && (head[3].toInt() and 0xFF) == 0xA3
        ) {
            return ContainerFormat.MATROSKA
        }
        if (head.size >= 8) {
            val type = head.copyOfRange(4, 8).decodeToString()
            if (type in MP4_TOP_LEVEL) return ContainerFormat.MP4
        }
        return ContainerFormat.UNKNOWN
    }

    /**
     * The tracks of the file behind [source] (audio and subtitles only), or null when the
     * container is not one this parser reads or its header is malformed. Throws
     * [ContainerNeedsBytes] when more of the file is needed.
     */
    fun parse(source: ContainerByteSource): List<ContainerTrack>? {
        val head = source.read(0, 8) ?: return null
        return when (detect(head)) {
            ContainerFormat.MATROSKA -> Matroska.parse(source)
            ContainerFormat.MP4 -> Mp4.parse(source)
            ContainerFormat.UNKNOWN -> null
        }
    }

    fun parse(bytes: ByteArray): List<ContainerTrack>? = try {
        parse(ContainerByteSource.of(bytes))
    } catch (_: ContainerNeedsBytes) {
        null
    }

    private val MP4_TOP_LEVEL = setOf("ftyp", "moov", "free", "skip", "wide", "mdat", "pnot", "styp")

    // region Matroska

    private object Matroska {
        const val EBML = 0x1A45DFA3L
        const val SEGMENT = 0x18538067L
        const val SEEK_HEAD = 0x114D9B74L
        const val SEEK = 0x4DBBL
        const val SEEK_ID = 0x53ABL
        const val SEEK_POSITION = 0x53ACL
        const val TRACKS = 0x1654AE6BL
        const val CLUSTER = 0x1F43B675L
        const val TRACK_ENTRY = 0xAEL
        const val TRACK_TYPE = 0x83L
        const val FLAG_DEFAULT = 0x88L
        const val FLAG_FORCED = 0x55AAL
        const val NAME = 0x536EL
        const val LANGUAGE = 0x22B59CL
        const val LANGUAGE_BCP47 = 0x22B59DL
        const val CODEC_ID = 0x86L
        const val AUDIO = 0xE1L
        const val CHANNELS = 0x9FL

        /** An element header: id, data start, data size (null = unknown size). */
        class Header(val id: Long, val start: Long, val dataStart: Long, val size: Long?) {
            val end: Long? get() = size?.let { dataStart + it }
        }

        fun parse(source: ContainerByteSource): List<ContainerTrack>? {
            val ebml = header(source, 0) ?: return null
            if (ebml.id != EBML) return null
            val segment = header(source, ebml.end ?: return null) ?: return null
            if (segment.id != SEGMENT) return null
            val segmentEnd = segment.end ?: source.totalSize ?: Long.MAX_VALUE
            var position = segment.dataStart
            var tracksPosition: Long? = null
            var steps = 0
            while (position < segmentEnd && steps < 48) {
                steps++
                val element = header(source, position) ?: break
                when (element.id) {
                    TRACKS -> return tracks(source, element)
                    SEEK_HEAD -> tracksPosition = tracksPosition ?: seekTracks(source, element, segment.dataStart)
                    CLUSTER -> break
                }
                position = element.end ?: break
            }
            val seekTarget = tracksPosition ?: return null
            val element = header(source, seekTarget) ?: return null
            return if (element.id == TRACKS) tracks(source, element) else null
        }

        private fun seekTracks(source: ContainerByteSource, seekHead: Header, segmentDataStart: Long): Long? {
            val end = seekHead.end ?: return null
            var position = seekHead.dataStart
            while (position < end) {
                val seek = header(source, position) ?: return null
                val seekEnd = seek.end ?: return null
                if (seek.id == SEEK) {
                    var id: Long? = null
                    var target: Long? = null
                    var child = seek.dataStart
                    while (child < seekEnd) {
                        val field = header(source, child) ?: return null
                        val size = field.size ?: return null
                        when (field.id) {
                            SEEK_ID -> id = unsigned(source, field.dataStart, size.toInt())
                            SEEK_POSITION -> target = unsigned(source, field.dataStart, size.toInt())
                        }
                        child = field.dataStart + size
                    }
                    if (id == TRACKS && target != null) return segmentDataStart + target
                }
                position = seekEnd
            }
            return null
        }

        private fun tracks(source: ContainerByteSource, tracks: Header): List<ContainerTrack> {
            val end = tracks.end ?: return emptyList()
            val result = mutableListOf<ContainerTrack>()
            var position = tracks.dataStart
            while (position < end) {
                val entry = header(source, position) ?: break
                val entryEnd = entry.end ?: break
                if (entry.id == TRACK_ENTRY) trackEntry(source, entry)?.let(result::add)
                position = entryEnd
            }
            return result
        }

        private fun trackEntry(source: ContainerByteSource, entry: Header): ContainerTrack? {
            val end = entry.end ?: return null
            var type: Long? = null
            var language: String? = null
            var languageTag: String? = null
            var name: String? = null
            var codec: String? = null
            var channels: Int? = null
            var isDefault = true
            var isForced = false
            var position = entry.dataStart
            while (position < end) {
                val field = header(source, position) ?: break
                val size = field.size ?: break
                val small = size in 0..512
                when (field.id) {
                    TRACK_TYPE -> if (small) type = unsigned(source, field.dataStart, size.toInt())
                    LANGUAGE -> if (small) language = string(source, field.dataStart, size.toInt())
                    LANGUAGE_BCP47 -> if (small) languageTag = string(source, field.dataStart, size.toInt())
                    NAME -> if (small) name = string(source, field.dataStart, size.toInt())
                    CODEC_ID -> if (small) codec = string(source, field.dataStart, size.toInt())
                    FLAG_DEFAULT -> if (small) isDefault = unsigned(source, field.dataStart, size.toInt()) != 0L
                    FLAG_FORCED -> if (small) isForced = unsigned(source, field.dataStart, size.toInt()) != 0L
                    AUDIO -> channels = audioChannels(source, field)
                }
                position = field.dataStart + size
            }
            val kind = when (type) {
                2L -> ContainerTrackKind.AUDIO
                17L -> ContainerTrackKind.SUBTITLE
                else -> return null
            }
            return ContainerTrack(
                kind = kind,
                // Matroska's default Language is "eng" (an absent element means English).
                language = language?.takeIf { it.isNotBlank() } ?: "eng",
                languageTag = languageTag?.takeIf { it.isNotBlank() },
                name = name?.takeIf { it.isNotBlank() },
                codec = codec?.takeIf { it.isNotBlank() },
                channels = if (kind == ContainerTrackKind.AUDIO) channels ?: 1 else null,
                isDefault = isDefault,
                isForced = isForced,
            )
        }

        private fun audioChannels(source: ContainerByteSource, audio: Header): Int? {
            val end = audio.end ?: return null
            var position = audio.dataStart
            while (position < end) {
                val field = header(source, position) ?: return null
                val size = field.size ?: return null
                if (field.id == CHANNELS && size in 1..8) return unsigned(source, field.dataStart, size.toInt()).toInt()
                position = field.dataStart + size
            }
            return null
        }

        /** Reads the element header at [offset]; null at the end of the file or on a malformed id. */
        fun header(source: ContainerByteSource, offset: Long): Header? {
            val first = source.byte(offset) ?: return null
            val idLength = vintLength(first)
            if (idLength !in 1..4) return null
            val idBytes = source.read(offset, idLength) ?: return null
            var id = 0L
            idBytes.forEach { id = (id shl 8) or (it.toLong() and 0xFF) }
            val sizeFirst = source.byte(offset + idLength) ?: return null
            val sizeLength = vintLength(sizeFirst)
            if (sizeLength !in 1..8) return null
            val sizeBytes = source.read(offset + idLength, sizeLength) ?: return null
            var size = (sizeBytes[0].toLong() and 0xFF) and ((1L shl (8 - sizeLength)) - 1)
            var allOnes = size == (1L shl (8 - sizeLength)) - 1
            for (index in 1 until sizeLength) {
                val value = sizeBytes[index].toLong() and 0xFF
                if (value != 0xFFL) allOnes = false
                size = (size shl 8) or value
            }
            val dataStart = offset + idLength + sizeLength
            return Header(id, offset, dataStart, if (allOnes) null else size)
        }

        private fun vintLength(first: Int): Int {
            if (first == 0) return 9
            var mask = 0x80
            var length = 1
            while (first and mask == 0) {
                mask = mask shr 1
                length++
            }
            return length
        }

        private fun unsigned(source: ContainerByteSource, offset: Long, size: Int): Long {
            if (size !in 1..8) return 0
            val bytes = source.read(offset, size) ?: return 0
            var value = 0L
            bytes.forEach { value = (value shl 8) or (it.toLong() and 0xFF) }
            return value
        }

        private fun string(source: ContainerByteSource, offset: Long, size: Int): String? {
            if (size <= 0) return null
            val bytes = source.read(offset, size) ?: return null
            val end = bytes.indexOfFirst { it.toInt() == 0 }.let { if (it < 0) bytes.size else it }
            return bytes.copyOfRange(0, end).decodeToString().trim()
        }
    }

    // endregion

    // region MP4 / MOV

    private object Mp4 {
        class Box(val type: String, val start: Long, val dataStart: Long, val end: Long?)

        fun parse(source: ContainerByteSource): List<ContainerTrack>? {
            var position = 0L
            var steps = 0
            while (steps < 32) {
                steps++
                val box = box(source, position) ?: return null
                if (box.type == "moov") return moov(source, box)
                position = box.end ?: return null
            }
            return null
        }

        private fun moov(source: ContainerByteSource, moov: Box): List<ContainerTrack> {
            val result = mutableListOf<ContainerTrack>()
            children(source, moov) { child ->
                if (child.type == "trak") trak(source, child)?.let(result::add)
            }
            return result
        }

        private fun trak(source: ContainerByteSource, trak: Box): ContainerTrack? {
            var handler: String? = null
            var language: String? = null
            var languageTag: String? = null
            var name: String? = null
            var codec: String? = null
            var channels: Int? = null
            var enabled = true
            children(source, trak) { child ->
                when (child.type) {
                    "tkhd" -> source.read(child.dataStart, 4)?.let { enabled = (it[3].toInt() and 0x1) != 0 }
                    "mdia" -> children(source, child) { media ->
                        when (media.type) {
                            "mdhd" -> language = mdhdLanguage(source, media)
                            "hdlr" -> handler = source.read(media.dataStart + 8, 4)?.decodeToString()
                            "elng" -> languageTag = fullBoxString(source, media)
                            "minf" -> children(source, media) { info ->
                                if (info.type == "stbl") children(source, info) { table ->
                                    if (table.type == "stsd") {
                                        val entry = box(source, table.dataStart + 8)
                                        if (entry != null) {
                                            codec = entry.type
                                            // AudioSampleEntry: 6 reserved, 2 data ref, 8 reserved, 2 channel count.
                                            source.read(entry.dataStart + 16, 2)?.let {
                                                channels = ((it[0].toInt() and 0xFF) shl 8) or (it[1].toInt() and 0xFF)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    "udta" -> children(source, child) { data ->
                        if (data.type == "name") name = plainString(source, data)
                    }
                }
            }
            val kind = when (handler) {
                "soun" -> ContainerTrackKind.AUDIO
                "subt", "text", "sbtl", "clcp" -> ContainerTrackKind.SUBTITLE
                else -> return null
            }
            return ContainerTrack(
                kind = kind,
                language = language,
                languageTag = languageTag?.takeIf { it.isNotBlank() && !it.equals("und", ignoreCase = true) },
                name = name?.takeIf { it.isNotBlank() },
                codec = codec,
                channels = if (kind == ContainerTrackKind.AUDIO) channels?.takeIf { it > 0 } else null,
                isDefault = enabled,
            )
        }

        /** ISO 639-2/T packed in 15 bits ("und" → null); a QuickTime Macintosh code (< 0x400) → null. */
        private fun mdhdLanguage(source: ContainerByteSource, mdhd: Box): String? {
            val version = source.byte(mdhd.dataStart) ?: return null
            val offset = mdhd.dataStart + if (version == 1) 4 + 8 + 8 + 4 + 8 else 4 + 4 + 4 + 4 + 4
            val bytes = source.read(offset, 2) ?: return null
            val packed = ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
            if (packed < 0x400) return null
            val code = buildString {
                append((((packed shr 10) and 0x1F) + 0x60).toChar())
                append((((packed shr 5) and 0x1F) + 0x60).toChar())
                append(((packed and 0x1F) + 0x60).toChar())
            }
            return code.takeIf { it.all { char -> char in 'a'..'z' } && it != "und" }
        }

        private fun fullBoxString(source: ContainerByteSource, box: Box): String? {
            val end = box.end ?: return null
            val length = (end - box.dataStart - 4).toInt()
            if (length !in 1..64) return null
            val bytes = source.read(box.dataStart + 4, length) ?: return null
            return bytes.takeWhile { it.toInt() != 0 }.toByteArray().decodeToString().trim()
        }

        private fun plainString(source: ContainerByteSource, box: Box): String? {
            val end = box.end ?: return null
            val length = (end - box.dataStart).toInt()
            if (length !in 1..256) return null
            val bytes = source.read(box.dataStart, length) ?: return null
            return bytes.filter { it.toInt() != 0 }.toByteArray().decodeToString().trim()
        }

        private inline fun children(source: ContainerByteSource, parent: Box, visit: (Box) -> Unit) {
            val end = parent.end ?: return
            var position = parent.dataStart
            var steps = 0
            while (position + 8 <= end && steps < 64) {
                steps++
                val child = box(source, position) ?: return
                val childEnd = child.end ?: return
                if (childEnd > end) return
                visit(child)
                position = childEnd
            }
        }

        /** The box header at [offset]; null past the end of the file or on a malformed size. */
        fun box(source: ContainerByteSource, offset: Long): Box? {
            val header = source.read(offset, 8) ?: return null
            val size32 = readUInt32(header, 0)
            val type = header.copyOfRange(4, 8).decodeToString()
            return when (size32) {
                1L -> {
                    val large = source.read(offset + 8, 8) ?: return null
                    var size = 0L
                    large.forEach { size = (size shl 8) or (it.toLong() and 0xFF) }
                    if (size < 16) null else Box(type, offset, offset + 16, offset + size)
                }
                0L -> Box(type, offset, offset + 8, source.totalSize)
                else -> if (size32 < 8) null else Box(type, offset, offset + 8, offset + size32)
            }
        }

        private fun readUInt32(bytes: ByteArray, at: Int): Long =
            ((bytes[at].toLong() and 0xFF) shl 24) or ((bytes[at + 1].toLong() and 0xFF) shl 16) or
                ((bytes[at + 2].toLong() and 0xFF) shl 8) or (bytes[at + 3].toLong() and 0xFF)
    }

    // endregion
}
