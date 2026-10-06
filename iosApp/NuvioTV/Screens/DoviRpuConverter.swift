import Foundation
import Libavcodec
import Libavutil
import Libdovi

// Phase 5 of the hybrid player: Dolby Vision Profile 7 → 8.1 conversion, applied packet-by-packet
// during the remux. BluRay-sourced P7 MKVs carry three things inside one video track: the base layer
// (HDR10/PQ HEVC the hardware decodes), an enhancement layer AVPlayer cannot use (EL NALs — wrapped
// in UNSPEC63 by the standard single-track mux, or carried with nuh_layer_id > 0), and per-frame RPU
// dynamic metadata (UNSPEC62 NALs, dual-layer P7 flavor). tvOS plays single-layer Profile 8.1
// natively, so this converter drops every EL NAL and rewrites every RPU to the 8.1 flavor with
// libdovi — the same conversion dovi_tool --mode 2 performs. MEL sources convert visually losslessly;
// FEL sources lose the enhancement residuals (the router lets the user opt FEL files back to mpv).
// RemuxSession retags the stream's DOVI configuration (dvvC) as Profile 8.1 so movenc's boxes and the
// HLS master signaling agree with the converted bitstream.
//
// FFmpeg's own `dovi_rpu` bsf was evaluated first per the plan and can only strip or recompress RPUs
// (no profile conversion, and no EL-NAL handling either way) — libdovi, already shipped in MPVKit's
// FFmpeg bundle, is the real mechanism.
//
// Packets are ISO-BMFF style (length-prefixed NAL units, per the stream's hvcC — matroska stores
// HEVC this way), so the walker needs no start-code or emulation-prevention logic of its own:
// libdovi unescapes on parse and re-escapes on write (`dovi_write_unspec62_nalu` returns a complete
// NAL unit, 0x7C 0x01 header included).

/// Profile 7 enhancement-layer flavor, classified from the first RPU seen (probe-time packet scan).
/// (No `.none` case on purpose — it would collide with `Optional.none` in switches over the
/// optional `DolbyVisionInfo.elKind` and silently match nil.)
nonisolated enum DVELKind: String, Sendable {
    case mel            // minimal EL — conversion to 8.1 is visually lossless
    case fel            // full EL — conversion discards the enhancement residuals (Infuse tradeoff)
    case missing        // profile 7 declared but no RPU found in the scanned packets (two-track mux?)
    case unsupported    // RPU present but libdovi could not parse/classify it
}

/// One instance per remux session (state accumulates across seek-anywhere runs — the conversion is
/// stateless per packet, only the counters persist). Used on the remux worker thread only.
nonisolated final class DoviRpuConverter {
    /// NAL length-prefix size from the stream's hvcC (in practice always 4).
    private let nalLengthSize: Int
    private(set) var rpusConverted = 0
    private(set) var rpusFailed = 0
    private(set) var elNalsDropped = 0
    private(set) var abortReason: String?
    private var videoPackets = 0
    private var loggedFailure = false

    var statsDescription: String {
        "\(rpusConverted) RPUs converted, \(elNalsDropped) EL NALs dropped"
            + (rpusFailed > 0 ? ", \(rpusFailed) RPU failures (stripped)" : "")
    }

    init?(videoPar: UnsafeMutablePointer<AVCodecParameters>) {
        guard let size = Self.hvccNalLengthSize(videoPar) else { return nil }
        nalLengthSize = size
    }

    /// hvcC `lengthSizeMinusOne` (byte 21, low 2 bits) + 1. nil when the extradata isn't hvcC-shaped —
    /// the packets would then be Annex B and the length-prefix walker would misparse them.
    static func hvccNalLengthSize(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        guard par.pointee.extradata_size >= 23, let ed = par.pointee.extradata, ed[0] == 1 else { return nil }
        return Int(ed[21] & 0x3) + 1
    }

    // MARK: - Remux path

    /// Rewrite one video packet in place: EL NALs dropped, RPU NALs converted to Profile 8.1.
    /// Timestamps, flags and side data are untouched, so the segment-cut and DTS-grid logic
    /// downstream see exactly the packet they would have without conversion.
    ///
    /// Returns false only when the session should abort to mpv: structurally malformed NAL stream, a
    /// packet left with no NALs at all, a stream that turns out to carry no convertible RPUs (the
    /// two-track layout the router screens out, kept as defense here), or sustained conversion
    /// failure. A rare isolated RPU failure just strips that frame's RPU and plays on.
    func filterPacket(_ pkt: UnsafeMutablePointer<AVPacket>) -> Bool {
        videoPackets += 1
        guard let data = pkt.pointee.data else { return true }
        let size = Int(pkt.pointee.size)
        var out = [UInt8]()
        var changed = false

        /// Start diverging from the source bytes: everything before `pos` was passed through verbatim.
        func beginRewrite(upTo pos: Int) {
            guard !changed else { return }
            changed = true
            out.reserveCapacity(size)
            out.append(contentsOf: UnsafeBufferPointer(start: data, count: pos))
        }

        var pos = 0
        while pos < size {
            guard pos + nalLengthSize <= size else { return abort("length prefix past packet end") }
            var nalLen = 0
            for i in 0..<nalLengthSize { nalLen = (nalLen << 8) | Int(data[pos + i]) }
            if nalLen == 0 { pos += nalLengthSize; continue }  // tolerated: zero padding between NALs
            let nalStart = pos + nalLengthSize
            guard nalLen >= 2, nalStart + nalLen <= size else { return abort("NAL size \(nalLen) out of bounds") }
            let nalType = (data[nalStart] >> 1) & 0x3F
            let layerId = (UInt16(data[nalStart] & 0x1) << 5) | UInt16(data[nalStart + 1] >> 3)

            if nalType == 63 || layerId > 0 {
                // Enhancement layer (UNSPEC63-wrapped or genuinely layered) — drop.
                beginRewrite(upTo: pos)
                elNalsDropped += 1
            } else if nalType == 62 {
                // RPU — convert to the 8.1 flavor.
                beginRewrite(upTo: pos)
                if let converted = convertRpu(data + nalStart, nalLen), appendNal(&out, converted) {
                    rpusConverted += 1
                } else {
                    rpusFailed += 1
                    if !loggedFailure {
                        loggedFailure = true
                        print("[DoviRpu] RPU conversion failed at video packet \(videoPackets) — stripping that frame's RPU")
                    }
                }
            } else if changed {
                out.append(contentsOf: UnsafeBufferPointer(start: data + pos, count: nalLengthSize + nalLen))
            }
            pos = nalStart + nalLen
        }

        // Abort policies. A P7-tagged stream whose packets never produce a converted RPU would play
        // as DV-signaled video with no dynamic metadata — worse than mpv. 120 packets ≈ 5 s of video.
        if videoPackets >= 120, rpusConverted == 0 {
            return abort(rpusFailed == 0 ? "no RPUs in stream (two-track source?)" : "RPU conversion failing from the start")
        }
        if rpusFailed > 100, rpusFailed * 4 > rpusConverted {
            return abort("sustained RPU conversion failures (\(rpusFailed)/\(rpusFailed + rpusConverted))")
        }

        guard changed else { return true }
        guard !out.isEmpty else { return abort("packet reduced to zero NALs") }
        return replacePacketData(pkt, with: out)
    }

    /// Swap the packet's payload for `bytes` (fresh refcounted buffer, zeroed FFmpeg padding tail).
    /// Properties (pts/dts/flags/side data) stay with the packet.
    private func replacePacketData(_ pkt: UnsafeMutablePointer<AVPacket>, with bytes: [UInt8]) -> Bool {
        let padding = 64                                       // AV_INPUT_BUFFER_PADDING_SIZE
        guard let buf = av_buffer_alloc(bytes.count + padding) else { return abort("buffer alloc") }
        bytes.withUnsafeBufferPointer { src in
            memcpy(buf.pointee.data, src.baseAddress!, bytes.count)
        }
        memset(buf.pointee.data + bytes.count, 0, padding)
        av_buffer_unref(&pkt.pointee.buf)
        pkt.pointee.buf = buf
        pkt.pointee.data = buf.pointee.data
        pkt.pointee.size = Int32(bytes.count)
        return true
    }

    /// Parse → convert (mode 2: "profile 8.1 compatible", handles source profiles 5/7/8) → re-emit.
    /// Returns the complete replacement NAL unit (0x7C 0x01 header + escaped payload) or nil.
    private func convertRpu(_ nal: UnsafePointer<UInt8>, _ len: Int) -> [UInt8]? {
        guard let rpu = dovi_parse_unspec62_nalu(nal, len) else { return nil }
        defer { dovi_rpu_free(rpu) }
        // Parsing reports failure via the error slot, not a null return — check before converting.
        if dovi_rpu_get_error(rpu) != nil {
            logLibdoviError(rpu, stage: "parse")
            return nil
        }
        guard dovi_convert_rpu_with_mode(rpu, 2) == 0 else {
            logLibdoviError(rpu, stage: "convert")
            return nil
        }
        guard let written = dovi_write_unspec62_nalu(rpu) else {
            logLibdoviError(rpu, stage: "write")
            return nil
        }
        defer { dovi_data_free(written) }
        let d = written.pointee
        guard let base = d.data, d.len >= 2 else { return nil }
        return Array(UnsafeBufferPointer(start: base, count: d.len))
    }

    /// Append `nal` with its big-endian length prefix. False if the length can't be represented
    /// (only conceivable with a 1-byte prefix, which no real hvcC uses).
    private func appendNal(_ out: inout [UInt8], _ nal: [UInt8]) -> Bool {
        guard nalLengthSize >= 4 || nal.count < (1 << (8 * nalLengthSize)) else { return false }
        for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((nal.count >> shift) & 0xFF))
        }
        out.append(contentsOf: nal)
        return true
    }

    private func logLibdoviError(_ rpu: OpaquePointer?, stage: String) {
        guard !loggedFailure, let rpu, let err = dovi_rpu_get_error(rpu) else { return }
        print("[DoviRpu] libdovi \(stage) error: \(String(cString: err))")
    }

    private func abort(_ reason: String) -> Bool {
        if abortReason == nil { abortReason = reason }
        return false
    }

    // MARK: - Probe path

    /// Scan one video packet for its first UNSPEC62 NAL and classify the RPU flavor (probe-time
    /// MEL/FEL detection). nil when the packet carries no RPU — the caller keeps scanning.
    static func classifyFirstRpu(packetData data: UnsafePointer<UInt8>, size: Int, nalLengthSize: Int) -> DVELKind? {
        var pos = 0
        while pos + nalLengthSize <= size {
            var nalLen = 0
            for i in 0..<nalLengthSize { nalLen = (nalLen << 8) | Int(data[pos + i]) }
            if nalLen == 0 { pos += nalLengthSize; continue }
            let nalStart = pos + nalLengthSize
            guard nalLen >= 2, nalStart + nalLen <= size else { return nil }   // malformed — give up on this packet
            if (data[nalStart] >> 1) & 0x3F == 62 {
                return classifyRpuNal(data + nalStart, nalLen)
            }
            pos = nalStart + nalLen
        }
        return nil
    }

    private static func classifyRpuNal(_ nal: UnsafePointer<UInt8>, _ len: Int) -> DVELKind {
        guard let rpu = dovi_parse_unspec62_nalu(nal, len) else { return .unsupported }
        defer { dovi_rpu_free(rpu) }
        if let err = dovi_rpu_get_error(rpu) {
            print("[DoviRpu] probe parse error: \(String(cString: err))")
            return .unsupported
        }
        guard let header = dovi_rpu_get_header(rpu) else { return .unsupported }
        defer { dovi_rpu_free_header(header) }
        if let elType = header.pointee.el_type {
            switch String(cString: elType).uppercased() {
            case "FEL": return .fel
            case "MEL": return .mel
            default: return .unsupported
            }
        }
        // No EL flavor in the RPU header — not a dual-layer P7 RPU (e.g. 8.1 RPUs muxed alongside an
        // EL). Conversion is trivially safe, so treat like MEL: nothing real to lose.
        return .mel
    }
}
