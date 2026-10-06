package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Synthetic Matroska / MP4 headers, built byte by byte. */
internal object ContainerFixtures {

    // region EBML

    fun id(value: Long): ByteArray {
        val length = when {
            value > 0xFFFFFF -> 4
            value > 0xFFFF -> 3
            value > 0xFF -> 2
            else -> 1
        }
        return ByteArray(length) { index -> (value shr (8 * (length - 1 - index))).toByte() }
    }

    /** 8-byte size vint (what mkvmerge writes for big masters); [unknown] = all ones. */
    fun size(value: Long, unknown: Boolean = false): ByteArray {
        if (unknown) return byteArrayOf(0x01, -1, -1, -1, -1, -1, -1, -1)
        val bytes = ByteArray(8)
        bytes[0] = 0x01
        for (index in 1..7) bytes[index] = (value shr (8 * (7 - index))).toByte()
        return bytes
    }

    fun element(id: Long, vararg children: ByteArray): ByteArray {
        val data = children.fold(ByteArray(0)) { acc, part -> acc + part }
        return id(id) + size(data.size.toLong()) + data
    }

    fun uint(id: Long, value: Long): ByteArray {
        val bytes = if (value == 0L) byteArrayOf(0) else {
            var length = 0
            var rest = value
            while (rest != 0L) { length++; rest = rest shr 8 }
            ByteArray(length) { index -> (value shr (8 * (length - 1 - index))).toByte() }
        }
        return id(id) + byteArrayOf((0x80 or bytes.size).toByte()) + bytes
    }

    fun text(id: Long, value: String): ByteArray {
        val bytes = value.encodeToByteArray()
        return id(id) + size(bytes.size.toLong()) + bytes
    }

    fun ebmlHeader(): ByteArray = element(0x1A45DFA3, text(0x4282, "matroska"))

    fun audioTrack(number: Long, language: String?, name: String? = null, bcp47: String? = null, channels: Long = 6, default: Boolean = true): ByteArray {
        val parts = mutableListOf(uint(0xD7, number), uint(0x83, 2), text(0x86, "A_EAC3"))
        if (language != null) parts += text(0x22B59C, language)
        if (bcp47 != null) parts += text(0x22B59D, bcp47)
        if (name != null) parts += text(0x536E, name)
        if (!default) parts += uint(0x88, 0)
        parts += element(0xE1, uint(0x9F, channels))
        return element(0xAE, *parts.toTypedArray())
    }

    fun subtitleTrack(number: Long, language: String, name: String? = null, forced: Boolean = false): ByteArray {
        val parts = mutableListOf(uint(0xD7, number), uint(0x83, 17), text(0x86, "S_TEXT/UTF8"), text(0x22B59C, language))
        if (name != null) parts += text(0x536E, name)
        if (forced) parts += uint(0x55AA, 1)
        return element(0xAE, *parts.toTypedArray())
    }

    fun videoTrack(): ByteArray = element(0xAE, uint(0xD7, 1), uint(0x83, 1), text(0x86, "V_MPEGH/ISO/HEVC"))

    /** EBML header + Segment(unknown size) { [before] , Tracks, Cluster(unknown size) }. */
    fun matroska(vararg tracks: ByteArray, before: ByteArray = ByteArray(0)): ByteArray {
        val tracksElement = element(0x1654AE6B, *tracks)
        val cluster = id(0x1F43B675) + size(0, unknown = true) + ByteArray(64)
        return ebmlHeader() + id(0x18538067) + size(0, unknown = true) + before + tracksElement + cluster
    }

    /**
     * Tracks after a big Void and the first Cluster, found only through the SeekHead — the file is
     * [padding] bytes of nothing between the head and the Tracks element.
     */
    fun matroskaWithSeekHead(padding: Int, vararg tracks: ByteArray): ByteArray {
        val tracksElement = element(0x1654AE6B, *tracks)
        // SeekHead with a fixed-size position (8 bytes) so its length doesn't depend on the value.
        fun seekHead(position: Long): ByteArray {
            val positionBytes = ByteArray(8) { index -> (position shr (8 * (7 - index))).toByte() }
            val seek = element(0x4DBB, id(0x53AB) + size(4) + id(0x1654AE6B), id(0x53AC) + size(8) + positionBytes)
            return element(0x114D9B74, seek)
        }
        val info = element(0x1549A966, uint(0x2AD7B1, 1_000_000))
        val cluster = element(0x1F43B675, ByteArray(padding))
        val seekLength = seekHead(0).size
        val tracksPosition = (seekLength + info.size + cluster.size).toLong()
        val segmentData = seekHead(tracksPosition) + info + cluster + tracksElement
        return ebmlHeader() + id(0x18538067) + size(segmentData.size.toLong()) + segmentData
    }

    // endregion

    // region MP4

    fun box(type: String, vararg children: ByteArray): ByteArray {
        val data = children.fold(ByteArray(0)) { acc, part -> acc + part }
        return be32(8 + data.size) + type.encodeToByteArray() + data
    }

    fun be32(value: Int): ByteArray = byteArrayOf((value shr 24).toByte(), (value shr 16).toByte(), (value shr 8).toByte(), value.toByte())
    fun be16(value: Int): ByteArray = byteArrayOf((value shr 8).toByte(), value.toByte())

    fun packedLanguage(code: String): Int =
        ((code[0].code - 0x60) shl 10) or ((code[1].code - 0x60) shl 5) or (code[2].code - 0x60)

    fun mdhd(language: String): ByteArray =
        box("mdhd", ByteArray(4) + ByteArray(4) + ByteArray(4) + be32(48_000) + ByteArray(4) + be16(packedLanguage(language)) + ByteArray(2))

    fun hdlr(handler: String): ByteArray = box("hdlr", ByteArray(4) + ByteArray(4) + handler.encodeToByteArray() + ByteArray(12) + byteArrayOf(0))

    fun audioSampleEntry(codec: String, channels: Int): ByteArray =
        box(codec, ByteArray(6) + be16(1) + ByteArray(8) + be16(channels) + be16(16) + ByteArray(4) + be32(48_000 shl 16))

    fun trak(handler: String, language: String, name: String? = null, elng: String? = null, codec: String = "ec-3", channels: Int = 6): ByteArray {
        val stsd = box("stsd", ByteArray(4) + be32(1) + (if (handler == "soun") audioSampleEntry(codec, channels) else box("tx3g", ByteArray(8))))
        val minf = box("minf", box("stbl", stsd, box("stts", ByteArray(8))))
        val mediaParts = mutableListOf(mdhd(language), hdlr(handler))
        if (elng != null) mediaParts += box("elng", ByteArray(4) + elng.encodeToByteArray() + byteArrayOf(0))
        mediaParts += minf
        val parts = mutableListOf(box("tkhd", byteArrayOf(0, 0, 0, 3) + ByteArray(80)), box("mdia", *mediaParts.toTypedArray()))
        if (name != null) parts += box("udta", box("name", name.encodeToByteArray()))
        return box("trak", *parts.toTypedArray())
    }

    /** ftyp, then [mdatBytes] of media, then moov (the "moov at the end" layout). */
    fun mp4MoovAtEnd(mdatBytes: Int, vararg traks: ByteArray): ByteArray =
        box("ftyp", "isom".encodeToByteArray() + be32(512)) +
            box("mdat", ByteArray(mdatBytes)) +
            box("moov", box("mvhd", ByteArray(100)), *traks)

    // endregion

    /** Serves [file] by ranges like an HTTP server that honours Range; records the requests. */
    class RangeServer(private val file: ByteArray) {
        val requests = mutableListOf<Pair<Long, Int>>()
        var bytesServed = 0L

        fun fetch(offset: Long, length: Int): FetchedRange? {
            requests += offset to length
            if (offset >= file.size) return null
            val end = minOf(file.size.toLong(), offset + length).toInt()
            val bytes = file.copyOfRange(offset.toInt(), end)
            bytesServed += bytes.size
            return FetchedRange(offset, bytes, file.size.toLong())
        }
    }
}

class ContainerTrackParserTest {

    private fun probe(file: ByteArray): Pair<List<ContainerTrack>?, ContainerFixtures.RangeServer> {
        val server = ContainerFixtures.RangeServer(file)
        return TrackProbe.readTracks { offset, length -> server.fetch(offset, length) } to server
    }

    @Test
    fun matroskaListsAudioAndSubtitleTracksWithLanguagesAndNames() {
        val file = ContainerFixtures.matroska(
            ContainerFixtures.videoTrack(),
            ContainerFixtures.audioTrack(2, "fre", name = "VFF", channels = 6),
            ContainerFixtures.audioTrack(3, "fre", name = "VFQ", bcp47 = "fr-CA", default = false),
            ContainerFixtures.audioTrack(4, "eng", name = "English", channels = 8, default = false),
            ContainerFixtures.subtitleTrack(5, "fre", name = "Forced", forced = true),
            ContainerFixtures.subtitleTrack(6, "eng"),
        )
        val tracks = assertNotNull(ContainerTrackParser.parse(file))
        assertEquals(5, tracks.size, "the video track is left out")
        val audio = tracks.filter { it.kind == ContainerTrackKind.AUDIO }
        assertEquals(listOf("fre", "fre", "eng"), audio.map { it.language })
        assertEquals(listOf("VFF", "VFQ", "English"), audio.map { it.name })
        assertEquals("fr-CA", audio[1].languageTag)
        assertEquals(listOf(6, 6, 8), audio.map { it.channels })
        assertEquals(listOf(true, false, false), audio.map { it.isDefault })
        assertEquals("A_EAC3", audio[0].codec)
        val subtitles = tracks.filter { it.kind == ContainerTrackKind.SUBTITLE }
        assertEquals(listOf(true, false), subtitles.map { it.isForced })
    }

    @Test
    fun matroskaWithoutLanguageElementIsEnglishPerSpec() {
        val file = ContainerFixtures.matroska(ContainerFixtures.audioTrack(1, language = null))
        assertEquals("eng", ContainerTrackParser.parse(file)?.single()?.language)
    }

    @Test
    fun matroskaTracksAfterTheFirstClusterAreFoundThroughSeekHeadWithFewBytes() {
        val file = ContainerFixtures.matroskaWithSeekHead(
            padding = 8 * 1024 * 1024,
            ContainerFixtures.audioTrack(1, "fre", name = "TrueFrench"),
            ContainerFixtures.audioTrack(2, "eng"),
        )
        val (tracks, server) = probe(file)
        assertEquals(listOf("fre", "eng"), assertNotNull(tracks).map { it.language })
        assertTrue(server.bytesServed <= TrackProbe.MAX_BYTES, "read ${server.bytesServed} bytes of ${file.size}")
        assertEquals(2, server.requests.size, "the head, then the Tracks block: ${server.requests}")
    }

    @Test
    fun matroskaUnknownSizeClusterBeforeTracksWithoutSeekHeadGivesUp() {
        val ebml = ContainerFixtures.ebmlHeader()
        val cluster = ContainerFixtures.id(0x1F43B675) + ContainerFixtures.size(0, unknown = true) + ByteArray(1024)
        val file = ebml + ContainerFixtures.id(0x18538067) + ContainerFixtures.size(0, unknown = true) + cluster
        assertNull(ContainerTrackParser.parse(file))
    }

    @Test
    fun mp4ReadsHandlerLanguageElngAndTrackNames() {
        val file = ContainerFixtures.mp4MoovAtEnd(
            mdatBytes = 1024,
            ContainerFixtures.trak("vide", "und"),
            ContainerFixtures.trak("soun", "fra", name = "VFQ"),
            ContainerFixtures.trak("soun", "eng", elng = "en-US", codec = "mp4a", channels = 2),
            ContainerFixtures.trak("sbtl", "fra"),
        )
        val tracks = assertNotNull(ContainerTrackParser.parse(file))
        assertEquals(3, tracks.size)
        assertEquals(listOf("fra", "eng", "fra"), tracks.map { it.language })
        assertEquals("VFQ", tracks[0].name)
        assertEquals("en-US", tracks[1].languageTag)
        assertEquals(listOf("ec-3", "mp4a"), tracks.take(2).map { it.codec })
        assertEquals(listOf(6, 2), tracks.take(2).map { it.channels })
        assertEquals(ContainerTrackKind.SUBTITLE, tracks[2].kind)
    }

    @Test
    fun mp4WithMoovAtTheEndOfABigFileIsReadWithRangeRequests() {
        val file = ContainerFixtures.mp4MoovAtEnd(
            mdatBytes = 6 * 1024 * 1024,
            ContainerFixtures.trak("soun", "fra"),
            ContainerFixtures.trak("soun", "eng"),
        )
        val (tracks, server) = probe(file)
        assertEquals(listOf("fra", "eng"), assertNotNull(tracks).map { it.language })
        assertTrue(server.bytesServed < 512 * 1024, "read ${server.bytesServed} bytes")
    }

    @Test
    fun undeterminedMp4LanguageIsNull() {
        val file = ContainerFixtures.mp4MoovAtEnd(16, ContainerFixtures.trak("soun", "und"))
        assertNull(ContainerTrackParser.parse(file)?.single()?.language)
    }

    @Test
    fun aServerIgnoringRangeOnlyGivesTheHead() {
        val file = ContainerFixtures.mp4MoovAtEnd(1024 * 1024, ContainerFixtures.trak("soun", "fra"))
        val tracks = TrackProbe.readTracks { offset, length ->
            if (offset != 0L) error("must not ask again without range support")
            FetchedRange(0, file.copyOfRange(0, minOf(length, file.size)), file.size.toLong(), rangeHonored = false)
        }
        assertNull(tracks)
    }

    @Test
    fun otherFormatsAreNotParsed() {
        assertNull(ContainerTrackParser.parse("<html><body>Downloading</body></html>".encodeToByteArray()))
        assertNull(TrackProbe.readTracks { _, _ -> FetchedRange(0, ByteArray(4096) { 0x47 }, 4096) })
    }
}
