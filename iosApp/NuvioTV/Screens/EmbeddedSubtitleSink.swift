import Foundation
import Libavcodec
import Libavformat
import Libavutil

// Info-panel plan W2 (docs/tvos-native-player-info-panel-plan.md §1a): embedded TEXT subtitle tracks
// on the native path. The remux worker already demuxes every packet of the source; this sink takes
// the packets of one text subtitle stream, decodes them to cues (libavcodec: subrip/ass/mov_text/
// webvtt/… → ASS dialogue lines), and — driven by the same segment boundaries the video muxer cuts
// at — writes one WebVTT file per segment (`esub-<sink>-NNNNN.vtt`, X-TIMESTAMP-MAP at the playlist
// origin, cues that span a boundary repeated in both files). `LocalHLSServer` serves them with the
// video segments' just-in-time semantics; the master lists the track as a SUBTITLES rendition, so
// AVPlayer's own Subtitles tab, styling and accessibility settings apply.
//
// Why segmented (unlike addon subtitles, which are one whole VTT): the cues only become known as the
// demux pass reaches them, so a single-file VTT can't exist before playback ends. Segment K's file is
// written when video segment K finalizes — cues that arrive later than their video (badly interleaved
// sources) miss their segment; a cue that also spans K+1 still shows there. A reposition drops the
// abandoned run's pending cues before the demuxer seeks, then keeps the cues read while scanning
// from the seek point to the target boundary (pre-roll still active in the target segment).
//
// Worker-thread only (called from RemuxSession.runRemux); no locking needed.
nonisolated final class EmbeddedSubtitleSink {
    struct Cue { let startSec: Double; let endSec: Double; let text: String }

    let sinkIndex: Int
    let streamIndex: Int
    private let codecContext: UnsafeMutablePointer<AVCodecContext>
    private let timeBase: AVRational
    private let originSec: Double
    /// Playlist-time boundaries: segment K spans [starts[K-1], starts[K]) (K 1-based); the last
    /// runs to `totalSec`.
    private let starts: [Double]
    private let totalSec: Double
    private let outputDir: URL
    /// SDH stripping, native path — the mpv path sets `sub-filter-sdh` instead. Sampled once at
    /// session start (coordinator reads the shared subtitle style); a mid-playback toggle flip
    /// applies from the next playback session, not to segments this sink already wrote.
    private let stripSdh: Bool
    private var pending: [Cue] = []
    private(set) var cuesDecoded = 0
    private(set) var segmentsWritten = 0
    private var decodeErrors = 0

    /// nil when libavcodec has no decoder for the track (then the track is simply not offered).
    init?(sinkIndex: Int, streamIndex: Int, codecpar: UnsafeMutablePointer<AVCodecParameters>,
          timeBase: AVRational, originSec: Double, segmentStartsSec: [Double], totalDurationSec: Double,
          outputDir: URL, stripSdh: Bool = false) {
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let ctx = avcodec_alloc_context3(codec) else { return nil }
        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            var p: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&p); return nil
        }
        ctx.pointee.pkt_timebase = timeBase
        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            var p: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&p); return nil
        }
        self.sinkIndex = sinkIndex
        self.streamIndex = streamIndex
        self.codecContext = ctx
        self.timeBase = timeBase
        self.originSec = originSec
        self.starts = segmentStartsSec
        self.totalSec = totalDurationSec
        self.outputDir = outputDir
        self.stripSdh = stripSdh
    }

    deinit {
        var p: UnsafeMutablePointer<AVCodecContext>? = codecContext
        avcodec_free_context(&p)
    }

    /// A reposition is about to seek: cues from the abandoned run are irrelevant to the segments
    /// about to be produced. Called BEFORE the demuxer seeks, so subtitle packets read while
    /// scanning from the seek point to the target boundary keyframe (pre-roll cues that are still
    /// active inside the target segment) are kept.
    func resetForReposition() {
        pending.removeAll(keepingCapacity: true)
        avcodec_flush_buffers(codecContext)
    }

    /// Feed one packet of this stream (source time_base). Decodes to cue text; timing comes from the
    /// packet (pts + duration), falling back to the decoder's display window, then a 3 s default.
    func ingest(_ pkt: UnsafeMutablePointer<AVPacket>) {
        guard pkt.pointee.pts != Int64.min else { return }
        var sub = AVSubtitle()
        var got: Int32 = 0
        let r = avcodec_decode_subtitle2(codecContext, &sub, &got, pkt)
        defer { if got != 0 { avsubtitle_free(&sub) } }
        guard r >= 0 else {
            decodeErrors += 1
            if decodeErrors <= 3 { print("[Remux] subtitle sink \(sinkIndex): decode error \(r)") }
            return
        }
        guard got != 0, sub.num_rects > 0, let rects = sub.rects else { return }

        var lines: [String] = []
        for i in 0..<Int(sub.num_rects) {
            guard let rect = rects[i] else { continue }
            if rect.pointee.type == SUBTITLE_ASS, let ass = rect.pointee.ass {
                let text = SubtitleVTT.vttCueText(fromASSLine: String(cString: ass), stripSdh: stripSdh)
                if !text.isEmpty { lines.append(text) }
            } else if rect.pointee.type == SUBTITLE_TEXT, let raw = rect.pointee.text {
                let text = SubtitleVTT.vttCueText(fromPlainText: String(cString: raw), stripSdh: stripSdh)
                if !text.isEmpty { lines.append(text) }
            }
        }
        guard !lines.isEmpty else { return }

        // Timing: packet pts is the cue's reference point; the decoder's display window (ms) is
        // relative to it — start_display_time shifts the start (non-zero for some codecs), and
        // end_display_time bounds the end when the packet carries no duration.
        let tb = Double(timeBase.num) / Double(timeBase.den)
        let base = Double(pkt.pointee.pts) * tb - originSec
        let startOffset = sub.start_display_time != UInt32.max ? Double(sub.start_display_time) / 1000 : 0
        let start = base + startOffset
        var end: Double
        if pkt.pointee.duration > 0 {
            end = base + Double(pkt.pointee.duration) * tb
        } else if sub.end_display_time > 0, sub.end_display_time != UInt32.max {
            end = base + Double(sub.end_display_time) / 1000
        } else {
            end = start + 3
        }
        if end <= start { end = start + 3 }
        guard end > 0, start < totalSec else { return }
        pending.append(Cue(startSec: max(0, start), endSec: min(end, totalSec), text: lines.joined(separator: "\n")))
        cuesDecoded += 1
    }

    /// Video segment `segment` (1-based) just finalized: write its VTT — every pending cue that
    /// intersects the segment window (spanning cues stay pending for the next segment; cues that end
    /// before the window are dropped). Always writes a file (header-only when empty) so the server
    /// never blocks on a segment that has no cues.
    func finalizeSegment(_ segment: Int) {
        guard segment >= 1, segment <= starts.count else { return }
        let segStart = starts[segment - 1]
        let segEnd = segment < starts.count ? starts[segment] : totalSec
        var body = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        var kept: [Cue] = []
        for cue in pending {
            if cue.endSec <= segStart { continue }              // finished before this segment
            if cue.startSec < segEnd {
                body += "\(SubtitleVTT.vttTime(cue.startSec)) --> \(SubtitleVTT.vttTime(cue.endSec))\n\(cue.text)\n\n"
            }
            if cue.endSec > segEnd { kept.append(cue) }        // spans into the next segment
        }
        pending = kept
        let name = SubtitleRendition.embeddedSegmentName(sink: sinkIndex, segment: segment)
        let url = outputDir.appendingPathComponent(name)
        let tmp = outputDir.appendingPathComponent(name + ".tmp")
        do {
            try Data(body.utf8).write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            segmentsWritten += 1
        } catch {
            print("[Remux] subtitle sink \(sinkIndex): write failed for \(name): \(error.localizedDescription)")
        }
    }
}
