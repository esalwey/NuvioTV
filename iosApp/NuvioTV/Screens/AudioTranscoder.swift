import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

// Phase 4 v2 of the hybrid player: the TrueHD / DTS audio transcode. AVPlayer cannot decode either
// codec and the MPVKit FFmpeg build ships no AC3/EAC3 encoder, so files whose only audio is
// TrueHD/DTS used to route to mpv wholesale — losing the native path's Dolby Vision output. This
// type decodes the source track, downmixes/resamples through swresample, and re-encodes with the
// native `aac` encoder (AAC-LC 5.1 for 6+ source channels, stereo/mono below), muxed alongside the
// stream-copied video. Lossless/Atmos is necessarily lost — the trade documented in
// docs/tvos-hybrid-player-plan.md ("v2 audio"): true DV picture + AAC 5.1 beats mpv's software
// video path for these files.
//
// Lifecycle: ONE TRANSCODER PER REMUX RUN (see RemuxSession's seek-anywhere runs). A reposition
// discards the whole object, so decoder/resampler/fifo state can never leak across a seek, and the
// run's fresh muxer context takes its audio codecpar from this encoder. Timestamps: the run's audio
// timeline re-anchors at the FIRST decoded frame's source pts (mapped onto the playlist origin) and
// advances by pure output-sample counting from there — TrueHD/DTS packets are contiguous in
// practice, and every seek re-anchors, so counting cannot drift far. All methods run on the remux
// worker thread; no locking.

/// AV_CODEC_FLAG_GLOBAL_HEADER — the C macro doesn't import into Swift. mp4 needs the
/// AudioSpecificConfig in codecpar extradata (the esds box), not inband.
private let codecFlagGlobalHeader: Int32 = 1 << 22
/// AVERROR(EAGAIN) on Darwin — send/receive flow control, not an error.
private let avErrorEAGAIN: Int32 = -EAGAIN
/// AVERROR_INPUT_CHANGED — swr_convert_frame's mid-stream layout/rate-change signal.
private let avErrorInputChanged: Int32 = -0x636e6701

nonisolated final class AudioTranscoder {
    /// Codec ids worth transcoding (decoders verified present in the MPVKit FFmpeg build; MLP is not).
    /// Opus and Vorbis (2026-10, one player UI for every format): FFmpeg's own native decoders, the
    /// ones mpv plays these tracks with — files whose only audio is Opus/Vorbis (common in MKV web
    /// releases) now keep the native AVPlayer path instead of going to mpv wholesale. A decoder that
    /// turned out missing fails `init` before the first segment, and the coordinator falls back to
    /// mpv exactly as for any other pre-playback remux failure.
    static func isTranscodable(_ id: AVCodecID) -> Bool {
        id == AV_CODEC_ID_TRUEHD || id == AV_CODEC_ID_DTS
            || id == AV_CODEC_ID_OPUS || id == AV_CODEC_ID_VORBIS
    }

    /// Target AAC-LC bitrate for the layout the source downmixes to.
    static func targetBitrate(sourceChannels: Int32) -> Int {
        sourceChannels >= 6 ? 384_000 : (sourceChannels >= 2 ? 192_000 : 96_000)
    }

    // MARK: - Format visibility (PLY-A14)

    /// What reaches the TV or receiver for a source audio track on the native path, for the
    /// player's Stream Info tab: the track as is when it is stream-copied ("Dolby Digital Plus
    /// 5.1"), or the AAC layout this transcoder produces with its source ("AAC 5.1 · converted from
    /// Dolby TrueHD 7.1"). `codec` is the canonical FFmpeg name (`RemuxAudioTrack.codec`).
    static func deliveredFormatDescription(codec: String, channels: Int, transcodes: Bool) -> String {
        let source = "\(codecDisplayName(codec)) \(layoutName(channels: channels))"
        guard transcodes else { return source }
        // Same layout rule as `init`: 6+ channels → 5.1, 2–5 → stereo, 1 → mono.
        let outputChannels = channels >= 6 ? 6 : (channels >= 2 ? 2 : 1)
        let delivered = "AAC \(layoutName(channels: outputChannels))"
        return String(localized: "player.audio.delivered.converted",
                      defaultValue: "\(delivered) · converted from \(source)",
                      comment: "Native player Stream Info: the AAC format sent to the TV, then the source format it was converted from (TrueHD/DTS).")
    }

    /// Consumer names of the codecs a file can carry ("truehd" → "Dolby TrueHD").
    static func codecDisplayName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "truehd": return "Dolby TrueHD"
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "dts": return "DTS"
        case "aac": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case let name where name.hasPrefix("pcm"): return "PCM"
        default: return codec.uppercased()
        }
    }

    /// "Mono", "Stereo", "5.1", "7.1", else the channel count.
    static func layoutName(channels: Int) -> String {
        switch channels {
        case 1: return String(localized: "player.audio.layout.mono", defaultValue: "Mono",
                              comment: "Audio channel layout name: one channel.")
        case 2: return String(localized: "player.audio.layout.stereo", defaultValue: "Stereo",
                              comment: "Audio channel layout name: two channels.")
        case 6: return "5.1"
        case 8: return "7.1"
        default:
            return String(localized: "player.audio.layout.channels", defaultValue: "\(channels) ch",
                          comment: "Audio channel layout fallback: the number of channels, e.g. '4 ch'.")
        }
    }

    /// Opened AAC encoder — the run's muxer copies its codecpar (incl. AudioSpecificConfig extradata)
    /// into the output stream before avformat_write_header.
    let encoderCtx: UnsafeMutablePointer<AVCodecContext>
    let outputSampleRate: Int32

    private let decoderCtx: UnsafeMutablePointer<AVCodecContext>
    private let sourceTimeBase: AVRational
    private var swr: OpaquePointer?
    private let fifo: OpaquePointer
    private let decFrame: UnsafeMutablePointer<AVFrame>
    private let outPkt: UnsafeMutablePointer<AVPacket>
    private let frameSize: Int32

    // Run timeline state, set by beginRun after avformat_write_header (post-header time_bases only —
    // see the timescale-trap note in RemuxSession.makeRun).
    private var outStreamIndex: Int32 = 0
    private var outTimeBase = AVRational(num: 1, den: 48_000)
    private var originEnc: Int64 = 0            // playlist origin in the encoder time_base (1/rate)
    private var fallbackAnchorEnc: Int64 = 0    // run-start floor, used when the first frame has no pts
    private var anchorEnc: Int64?               // set at the first decoded frame
    private var samplesOut: Int64 = 0
    private var prevDTS: Int64?
    private var decodeErrors = 0

    /// nil when the decoder/encoder can't be set up (missing codec, bad parameters) — the remux then
    /// fails and the coordinator falls back to mpv, matching pre-v2 behavior.
    init?(sourcePar: UnsafeMutablePointer<AVCodecParameters>, sourceTimeBase: AVRational) {
        var dec: UnsafeMutablePointer<AVCodecContext>?
        var enc: UnsafeMutablePointer<AVCodecContext>?
        var fifoTmp: OpaquePointer?
        var frame: UnsafeMutablePointer<AVFrame>?
        var pkt: UnsafeMutablePointer<AVPacket>?
        var swrTmp: OpaquePointer?
        func cleanup() {
            avcodec_free_context(&dec)
            avcodec_free_context(&enc)
            if let f = fifoTmp { av_audio_fifo_free(f) }
            av_frame_free(&frame)
            av_packet_free(&pkt)
            swr_free(&swrTmp)
        }

        guard let decCodec = avcodec_find_decoder(sourcePar.pointee.codec_id) else { return nil }
        dec = avcodec_alloc_context3(decCodec)
        guard let decCtx = dec,
              avcodec_parameters_to_context(decCtx, sourcePar) >= 0 else { cleanup(); return nil }
        decCtx.pointee.pkt_timebase = sourceTimeBase
        guard avcodec_open2(decCtx, decCodec, nil) >= 0 else { cleanup(); return nil }

        // Encoder target: >=6 source channels → 5.1 (BACK pair — the only 6ch layout the native aac
        // encoder accepts), 2-5 → stereo, 1 → mono. Rates above 48 kHz halve to an AAC/AVPlayer-safe
        // rate (96k→48k, 88.2k→44.1k).
        let srcChannels = sourcePar.pointee.ch_layout.nb_channels
        let srcRate = sourcePar.pointee.sample_rate
        let rate: Int32 = srcRate > 48_000 ? (srcRate % 44_100 == 0 ? 44_100 : 48_000)
                                           : (srcRate > 0 ? srcRate : 48_000)
        let mask: UInt64 = srcChannels >= 6 ? 0x3F : (srcChannels == 1 ? 0x4 : 0x3)
        guard let encCodec = avcodec_find_encoder(AV_CODEC_ID_AAC) else { cleanup(); return nil }
        enc = avcodec_alloc_context3(encCodec)
        guard let encCtx = enc,
              av_channel_layout_from_mask(&encCtx.pointee.ch_layout, mask) >= 0 else { cleanup(); return nil }
        encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        encCtx.pointee.sample_rate = rate
        encCtx.pointee.bit_rate = Int64(Self.targetBitrate(sourceChannels: srcChannels))
        encCtx.pointee.time_base = AVRational(num: 1, den: rate)
        encCtx.pointee.flags |= codecFlagGlobalHeader
        guard avcodec_open2(encCtx, encCodec, nil) >= 0 else { cleanup(); return nil }

        // Unconfigured resampler: swr_convert_frame configures + inits it from the first frame pair
        // (the decoder's real layout/format isn't authoritative until a frame is decoded).
        swrTmp = swr_alloc()
        fifoTmp = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, encCtx.pointee.ch_layout.nb_channels, 8192)
        frame = av_frame_alloc()
        pkt = av_packet_alloc()
        guard let swrCtx = swrTmp, let fifoCtx = fifoTmp,
              let decFrame = frame, let outPkt = pkt else { cleanup(); return nil }

        self.decoderCtx = decCtx
        self.encoderCtx = encCtx
        self.sourceTimeBase = sourceTimeBase
        self.swr = swrCtx
        self.fifo = fifoCtx
        self.decFrame = decFrame
        self.outPkt = outPkt
        self.outputSampleRate = rate
        self.frameSize = encCtx.pointee.frame_size > 0 ? encCtx.pointee.frame_size : 1024
        print("[AudioTx] \(String(cString: decCodec.pointee.name)) \(srcChannels)ch@\(srcRate) → aac "
              + "\(encCtx.pointee.ch_layout.nb_channels)ch@\(rate) \(encCtx.pointee.bit_rate / 1000)kbps")
    }

    deinit {
        var d: UnsafeMutablePointer<AVCodecContext>? = decoderCtx
        avcodec_free_context(&d)
        var e: UnsafeMutablePointer<AVCodecContext>? = encoderCtx
        avcodec_free_context(&e)
        swr_free(&swr)
        av_audio_fifo_free(fifo)
        var f: UnsafeMutablePointer<AVFrame>? = decFrame
        av_frame_free(&f)
        var p: UnsafeMutablePointer<AVPacket>? = outPkt
        av_packet_free(&p)
    }

    /// Bind this transcoder to the run's muxer output. All values are POST-avformat_write_header
    /// (movenc rewrites stream time_bases); `originOut`/`fallbackAnchorOut` are in `outTimeBase`.
    func beginRun(outStreamIndex: Int32, outTimeBase: AVRational, originOut: Int64, fallbackAnchorOut: Int64) {
        self.outStreamIndex = outStreamIndex
        self.outTimeBase = outTimeBase
        let encTB = AVRational(num: 1, den: outputSampleRate)
        originEnc = av_rescale_q(originOut, outTimeBase, encTB)
        fallbackAnchorEnc = max(0, av_rescale_q(fallbackAnchorOut, outTimeBase, encTB))
        anchorEnc = nil
        samplesOut = 0
        prevDTS = nil
    }

    /// Decode one source packet (source time_base timestamps) and emit any finished AAC packets via
    /// `write`. A decode error skips the packet — an audible glitch beats killing the session — up to
    /// a cap that catches a track the decoder cannot handle at all. Write failures are fatal.
    func process(_ pkt: UnsafeMutablePointer<AVPacket>, write: (UnsafeMutablePointer<AVPacket>) -> Bool) -> Bool {
        while true {
            let r = avcodec_send_packet(decoderCtx, pkt)
            if r >= 0 { break }
            if r == avErrorEAGAIN {
                guard receiveDecoded(write: write) else { return false }
                continue
            }
            decodeErrors += 1
            if decodeErrors == 1 { print("[AudioTx] decode error \(r) — skipping packet (further errors silenced)") }
            return decodeErrors < 2000
        }
        return receiveDecoded(write: write)
    }

    /// EOF: flush decoder + resampler tail, encode the fifo remainder (the aac encoder accepts a
    /// short last frame), and drain the encoder.
    func drain(write: (UnsafeMutablePointer<AVPacket>) -> Bool) -> Bool {
        _ = avcodec_send_packet(decoderCtx, nil)
        guard receiveDecoded(write: write) else { return false }
        if swr_is_initialized(swr) > 0 {
            guard withConvertFrame({ cvt in
                swr_convert_frame(swr, cvt, nil) >= 0 ? fifoWrite(cvt) : true
            }) else { return false }
        }
        return encodeBuffered(final: true, write: write)
    }

    // MARK: - Decode → resample → fifo

    private func receiveDecoded(write: (UnsafeMutablePointer<AVPacket>) -> Bool) -> Bool {
        while true {
            let r = avcodec_receive_frame(decoderCtx, decFrame)
            if r == avErrorEAGAIN || r == avErrorEOF { return true }
            guard r >= 0 else {
                decodeErrors += 1
                return decodeErrors < 2000
            }
            decodeErrors = 0
            let ok = convertAndBuffer(decFrame) && encodeBuffered(final: false, write: write)
            av_frame_unref(decFrame)
            guard ok else { return false }
        }
    }

    private func convertAndBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if anchorEnc == nil {
            let encTB = AVRational(num: 1, den: outputSampleRate)
            anchorEnc = frame.pointee.pts != Int64.min
                ? max(0, av_rescale_q(frame.pointee.pts, sourceTimeBase, encTB) - originEnc)
                : fallbackAnchorEnc
        }
        return withConvertFrame { cvt in
            var r = swr_convert_frame(swr, cvt, frame)
            if r == avErrorInputChanged {
                // Mid-stream layout/rate change (rare): drop the resampler state and reconfigure
                // from this frame pair. Sub-frame delay samples are lost; timing re-syncs via counting.
                swr_close(swr)
                r = swr_convert_frame(swr, cvt, frame)
            }
            guard r >= 0 else {
                print("[AudioTx] resample failed (\(r))")
                return false
            }
            return fifoWrite(cvt)
        }
    }

    /// Run `body` with a fresh frame pre-set to the ENCODER's layout/format/rate (the shape both the
    /// resampler output and the fifo use), freeing it afterwards.
    private func withConvertFrame(_ body: (UnsafeMutablePointer<AVFrame>) -> Bool) -> Bool {
        guard let cvt = av_frame_alloc() else { return false }
        var tmp: UnsafeMutablePointer<AVFrame>? = cvt
        defer { av_frame_free(&tmp) }
        guard av_channel_layout_copy(&cvt.pointee.ch_layout, &encoderCtx.pointee.ch_layout) >= 0 else { return false }
        cvt.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        cvt.pointee.sample_rate = Int32(outputSampleRate)
        return body(cvt)
    }

    private func fifoWrite(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let n = frame.pointee.nb_samples
        guard n > 0 else { return true }
        guard let data = frame.pointee.extended_data else { return false }
        let raw = UnsafeMutableRawPointer(data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return av_audio_fifo_write(fifo, raw, n) >= n
    }

    // MARK: - Fifo → encode → emit

    /// Feed complete `frameSize`-sample frames (plus the remainder when `final`) to the encoder.
    /// Frame pts = run anchor + output samples emitted so far, in 1/sample_rate ticks.
    private func encodeBuffered(final: Bool, write: (UnsafeMutablePointer<AVPacket>) -> Bool) -> Bool {
        while true {
            let available = av_audio_fifo_size(fifo)
            let n = available >= frameSize ? frameSize : (final && available > 0 ? available : 0)
            guard n > 0 else { break }
            let ok = withConvertFrame { frame in
                frame.pointee.nb_samples = n
                guard av_frame_get_buffer(frame, 0) >= 0, let data = frame.pointee.extended_data else { return false }
                let raw = UnsafeMutableRawPointer(data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                guard av_audio_fifo_read(fifo, raw, n) >= n else { return false }
                frame.pointee.pts = (anchorEnc ?? fallbackAnchorEnc) + samplesOut
                samplesOut += Int64(n)
                var r = avcodec_send_frame(encoderCtx, frame)
                if r == avErrorEAGAIN {
                    guard drainEncoder(write: write) else { return false }
                    r = avcodec_send_frame(encoderCtx, frame)
                }
                return r >= 0 && drainEncoder(write: write)
            }
            guard ok else { return false }
        }
        if final {
            _ = avcodec_send_frame(encoderCtx, nil)
            return drainEncoder(write: write)
        }
        return true
    }

    private func drainEncoder(write: (UnsafeMutablePointer<AVPacket>) -> Bool) -> Bool {
        while true {
            let r = avcodec_receive_packet(encoderCtx, outPkt)
            if r == avErrorEAGAIN || r == avErrorEOF { return true }
            guard r >= 0 else { return false }
            outPkt.pointee.stream_index = outStreamIndex
            av_packet_rescale_ts(outPkt, AVRational(num: 1, den: outputSampleRate), outTimeBase)
            // Floor + monotonic clamp: encoder priming can pull the first packet's dts slightly
            // negative, and movenc (avoid_negative_ts disabled) needs nonnegative increasing dts.
            if outPkt.pointee.dts == Int64.min { outPkt.pointee.dts = outPkt.pointee.pts }
            if outPkt.pointee.dts < 0 { outPkt.pointee.dts = 0 }
            if let prev = prevDTS, outPkt.pointee.dts <= prev { outPkt.pointee.dts = prev + 1 }
            prevDTS = outPkt.pointee.dts
            if outPkt.pointee.pts == Int64.min || outPkt.pointee.pts < outPkt.pointee.dts {
                outPkt.pointee.pts = outPkt.pointee.dts
            }
            let ok = write(outPkt)
            av_packet_unref(outPkt)
            guard ok else { return false }
        }
    }
}
