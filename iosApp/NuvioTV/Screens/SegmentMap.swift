import Foundation

// Phase 4 of the hybrid player (plan decision D2/D3): the complete, up-front VOD segment map.
//
// tvOS 27 rejects EVENT / growing HLS playlists (-12927 right after the first segment) and only plays
// a VOD playlist that carries EXT-X-ENDLIST from the very first fetch. So the native path must publish
// a COMPLETE media playlist — every segment, exact EXTINF, ENDLIST — before a single segment file
// exists, then produce/serve those segments just-in-time.
//
// This type derives that map from the source video stream's KEYFRAME index (MP4 `stss` / MKV Cues,
// read at avformat open). Crucially, the D3 segmenter (`RemuxSession`) cuts its fMP4 fragments at
// exactly THESE keyframe boundaries, so the published playlist matches the produced files by
// construction: a sparse Cue list just yields longer-but-valid segments, never a desync. When the
// index is missing or too sparse to yield reasonable segments, `build` returns nil and the coordinator
// falls back to mpv (conservative routing — there is no EVENT path to fall back to on tvOS 27).
//
// Pure Swift, no libav* types — unit-testable with canned keyframe arrays (the highest-value test
// surface: an off-by-one here is an unrecoverable mid-movie stall on device).
/// One audio rendition of the master's `aud` group (info-panel W3): a playable source audio track,
/// served as its own audio-only fMP4 representation (`aud-<streamIndex>.m3u8`), produced by the remux
/// worker only while it is the active track.
nonisolated struct AudioRendition: Sendable {
    let streamIndex: Int
    let name: String
    let language: String?
    let channels: Int
    let codecToken: String?      // RFC 6381, for the variant's CODECS union
    let isDefault: Bool          // the track production starts with (DEFAULT=YES)

    var playlistName: String { "aud-\(streamIndex).m3u8" }
    var initName: String { "aud-\(streamIndex)-init.mp4" }
    var segmentPrefix: String { "aud-\(streamIndex)-" }
}

nonisolated struct SegmentMap: Sendable {
    struct Segment: Sendable, Equatable {
        let number: Int          // 1-based; the media file is `seg-{number:05d}.m4s`
        let startTicks: Int64    // segment start PTS in the source video stream time_base
        let durationSec: Double  // EXTINF
    }

    let segments: [Segment]
    let totalDurationSec: Double

    var count: Int { segments.count }

    /// The per-segment start PTS (source video time_base) that DRIVE fragment cutting. `boundaryTicks[i]`
    /// is where segment `i+1` begins; the segmenter flushes a fragment when a video keyframe reaches it.
    var boundaryTicks: [Int64] { segments.map(\.startTicks) }

    /// EXT-X-TARGETDURATION must be >= every EXTINF (HLS spec; tvOS rejects a stream that violates it).
    /// Computed from the real max segment duration, rounded up.
    var targetDurationSec: Int {
        max(1, Int((segments.map(\.durationSec).max() ?? 0).rounded(.up)))
    }

    /// Replay the segmenter's greedy cut rule over the source keyframe PTS list (sorted ascending, in
    /// the video stream's time_base): segment 1 starts at the first keyframe; a new segment begins at
    /// the first keyframe whose `pts - segmentStart >= segDur`. All comparison is integer/rational in
    /// the source time_base (never float) so a keyframe landing exactly on a boundary can't flip.
    ///
    /// Returns nil when the index is unusable: empty, non-positive time_base, unknown duration, or so
    /// sparse that the average segment would exceed `maxAvgSegSec` (route to mpv rather than serve a
    /// stream of enormous segments).
    static func build(keyframeTicks: [Int64],
                      timeBaseNum: Int32,
                      timeBaseDen: Int32,
                      totalDurationSec: Double,
                      segDurSec: Int,
                      maxAvgSegSec: Double = 30) -> SegmentMap? {
        guard timeBaseNum > 0, timeBaseDen > 0,
              segDurSec > 0, totalDurationSec > 0,
              !keyframeTicks.isEmpty else { return nil }

        // De-dupe + sort defensively; index entries are usually sorted but a stray duplicate boundary
        // would emit a zero-length segment.
        let ticks = Array(Set(keyframeTicks)).sorted()
        let tbSec = Double(timeBaseNum) / Double(timeBaseDen)

        // seg duration expressed in source ticks: segDurSec / tbSec = segDurSec * den / num.
        let segDurTicks = Int64(segDurSec) * Int64(timeBaseDen) / Int64(timeBaseNum)
        guard segDurTicks > 0 else { return nil }

        var starts: [Int64] = [ticks[0]]
        var segStart = ticks[0]
        for k in ticks.dropFirst() where k - segStart >= segDurTicks {
            starts.append(k)
            segStart = k
        }

        // The final segment runs to the true media end (from the probe duration), so the summed EXTINF
        // equals the real duration exactly — no early EOS, no phantom tail. If a keyframe lands at (or
        // just before, within rounding of) the media end, folding it into the previous segment keeps a
        // valid map instead of dropping the whole native path — the segmenter, driven by these same
        // boundaries, simply doesn't cut there either.
        let endTicks = ticks[0] + Int64((totalDurationSec / tbSec).rounded())
        while starts.count > 1, endTicks <= starts.last! { starts.removeLast() }
        guard endTicks > starts.last! else { return nil }

        var segments: [Segment] = []
        segments.reserveCapacity(starts.count)
        for (i, start) in starts.enumerated() {
            let end = (i + 1 < starts.count) ? starts[i + 1] : endTicks
            let durationSec = Double(end - start) * tbSec
            guard durationSec > 0 else { return nil }   // non-monotonic boundary → unusable
            segments.append(Segment(number: i + 1, startTicks: start, durationSec: durationSec))
        }

        let avgSegSec = totalDurationSec / Double(segments.count)
        guard avgSegSec <= maxAvgSegSec else { return nil }   // index too sparse to segment usefully

        return SegmentMap(segments: segments, totalDurationSec: totalDurationSec)
    }

    // MARK: - Resume lookup (PLY-A5)

    /// Playlist time (seconds from the playlist origin) at which segment `number` starts.
    func startSec(ofSegment number: Int) -> Double? {
        guard number >= 1, number <= segments.count else { return nil }
        return segments.prefix(number - 1).reduce(0) { $0 + $1.durationSec }
    }

    /// The 1-based segment whose span contains playlist time `timeSec` (the last segment for a time
    /// at or past the end, segment 1 for a negative time). nil only for an empty map.
    func segmentNumber(containing timeSec: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        guard timeSec.isFinite, timeSec > 0 else { return 1 }
        var elapsed = 0.0
        for seg in segments {
            elapsed += seg.durationSec
            if timeSec < elapsed { return seg.number }
        }
        return segments.count
    }

    /// `#EXT-X-START` line for a resume offset (PLY-A5): AVPlayer starts the item there instead of at
    /// zero, so it never fetches (or flashes) segment 1 before the resume seek. nil/<=0 → no tag.
    static func startTag(_ offsetSec: Double?) -> String? {
        guard let offsetSec, offsetSec.isFinite, offsetSec > 0 else { return nil }
        return String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", offsetSec)
    }

    // MARK: - Playlist synthesis

    /// The complete VOD media playlist (single muxed-A/V representation), published up front with
    /// EXT-X-ENDLIST so tvOS 27 treats it as VOD from the first fetch. `startOffsetSec` adds an
    /// `EXT-X-START` (resume at the right segment, PLY-A5).
    func mediaPlaylist(initName: String = "init.mp4", segmentPrefix: String = "seg-",
                       startOffsetSec: Double? = nil) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDurationSec)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:1",
        ]
        if let start = Self.startTag(startOffsetSec) { lines.append(start) }
        lines.append("#EXT-X-MAP:URI=\"\(initName)\"")
        for seg in segments {
            lines.append(String(format: "#EXTINF:%.6f,", seg.durationSec))
            lines.append("\(segmentPrefix)\(String(format: "%05d", seg.number)).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Media playlist for an embedded subtitle rendition (info-panel W2): the same segment grid and
    /// EXTINFs as the video playlist, one WebVTT file per segment, no init map.
    func embeddedSubtitlePlaylist(fileName: (Int) -> String) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDurationSec)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:1",
        ]
        for seg in segments {
            lines.append(String(format: "#EXTINF:%.6f,", seg.durationSec))
            lines.append(fileName(seg.number))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The master playlist: one variant pointing at `mediaName`, carrying the full RFC 6381 CODECS and
    /// (for DV) SUPPLEMENTAL-CODECS so Dolby Vision engages. Muxed A/V, so CODECS lists video + audio;
    /// the only audio EXT-X-MEDIA entry is a URI-less label for the muxed track (name/language).
    func masterPlaylist(signaling: VideoSignaling,
                        audioRenditions: [AudioRendition] = [],
                        bandwidth: Int,
                        mediaName: String = "media.m3u8",
                        subtitles: [SubtitleRendition] = [],
                        subtitleFlags: [SubtitleRenditionFlags] = []) -> String {
        // CODECS lists every codec the variant can carry — video plus the union of the audio
        // renditions' tokens (mixed groups, e.g. "hvc1…,ec-3,mp4a.40.2", are the standard form).
        var codecTokens: [String] = []
        if !signaling.codecs.isEmpty { codecTokens.append(signaling.codecs) }
        for token in audioRenditions.compactMap(\.codecToken) where !token.isEmpty && !codecTokens.contains(token) {
            codecTokens.append(token)
        }
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(max(bandwidth, 1))"
        if signaling.width > 0, signaling.height > 0 {
            streamInf += ",RESOLUTION=\(signaling.width)x\(signaling.height)"
        }
        if signaling.frameRate > 0 {
            streamInf += String(format: ",FRAME-RATE=%.3f", signaling.frameRate)
        }
        streamInf += ",CODECS=\"\(codecTokens.joined(separator: ","))\""
        if let supp = signaling.supplementalCodecs {
            streamInf += ",SUPPLEMENTAL-CODECS=\"\(supp)\""
        }
        // VIDEO-RANGE is REQUIRED for HDR on tvOS 27: PQ media behind a master that doesn't declare it
        // is rejected at media admission (-12927); declared (with full CODECS + SUPPLEMENTAL-CODECS,
        // the exact shape device-validated via the probe rig), the same media plays.
        if let range = signaling.videoRange {
            streamInf += ",VIDEO-RANGE=\(range)"
        }

        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        // Demuxed audio (info-panel W3): the variant is video-only; every playable source track is
        // its own AUDIO rendition with a URI, so the system Audio tab lists them all and switching is
        // AVPlayer's own seamless rendition change. Only the active track's segments exist at any
        // time — a request for another track's files makes the remux switch (LocalHLSServer).
        for r in audioRenditions {
            var media = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(r.name.replacingOccurrences(of: "\"", with: ""))\""
            media += ",DEFAULT=\(r.isDefault ? "YES" : "NO"),AUTOSELECT=YES"
            if let language = r.language, !language.isEmpty { media += ",LANGUAGE=\"\(language)\"" }
            if r.channels > 0 { media += ",CHANNELS=\"\(r.channels)\"" }
            media += ",URI=\"\(r.playlistName)\""
            lines.append(media)
        }
        if !audioRenditions.isEmpty { streamInf += ",AUDIO=\"aud\"" }
        // External-subtitle renditions (D5): WebVTT sidecars served by LocalHLSServer. AUTOSELECT /
        // DEFAULT follow the coordinator's language plan (Preferred Subtitle Language: "none" ⇒ no
        // rendition is auto-selectable, so captions never switch on by themselves; a preferred
        // language ⇒ matches are AUTOSELECT and the first match is DEFAULT). Legacy: AUTOSELECT only.
        if !subtitles.isEmpty {
            for (i, sub) in subtitles.enumerated() {
                let flags = i < subtitleFlags.count ? subtitleFlags[i] : .legacy
                var media = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(sub.name.replacingOccurrences(of: "\"", with: ""))\""
                // AUTOSELECT/DEFAULT come from the coordinator's language plan (which already keeps
                // forced renditions auto-selectable unless subtitles are off); SDH tracks carry the
                // accessibility characteristics tvOS lists them under.
                let autoselect = flags.autoselect || flags.isDefault
                media += ",DEFAULT=\(flags.isDefault ? "YES" : "NO"),AUTOSELECT=\(autoselect ? "YES" : "NO"),FORCED=\(sub.forced ? "YES" : "NO")"
                if sub.hearingImpaired {
                    media += ",CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\""
                }
                if let language = sub.language { media += ",LANGUAGE=\"\(language)\"" }
                media += ",URI=\"\(sub.playlistName)\""
                lines.append(media)
            }
            streamInf += ",SUBTITLES=\"subs\""
        }
        lines.append(streamInf)
        lines.append(mediaName)
        return lines.joined(separator: "\n") + "\n"
    }
}
