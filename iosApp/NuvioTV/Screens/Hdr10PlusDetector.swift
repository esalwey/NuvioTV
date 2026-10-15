import Foundation

// HDR10+ in the remuxed stream.
//
// HDR10+ is HDR10 plus per-scene dynamic metadata (SMPTE ST 2094-40). In an HEVC bitstream it travels
// as an ITU-T T.35 "user data registered" SEI message (payload type 4) in a prefix SEI NAL unit
// (type 39; suffix SEI, type 40, is accepted too): country code 0xB5 (United States), terminal
// provider code 0x003C (Samsung), oriented code 0x0001, application identifier 4. There is no
// container-level flag for it in Matroska or MP4, so the only way to know a file carries HDR10+ is to
// look into its video packets.
//
// Does it survive the remux? Yes, byte for byte. `RemuxSession` stream-copies the HEVC samples (the
// Matroska blocks are already length-prefixed, as the fMP4 `hvc1` samples are) and the only rewriting it
// does, the Dolby Vision 7 to 8.1 conversion, drops enhancement-layer NAL units (type 63 or
// layer id > 0) and replaces RPU NAL units (type 62); SEI NAL units pass through. So the metadata is in
// the fMP4 samples AVPlayer decodes. What the HLS master adds is the declaration Apple specifies for
// HDR10+ variants: `VIDEO-RANGE=PQ` (already there) and a SUPPLEMENTAL-CODECS entry carrying the
// compatibility brand `cdm4` after the base HEVC codec string, e.g.
//   CODECS="hvc1.2.4.L153.B0,ec-3",SUPPLEMENTAL-CODECS="hvc1.2.4.L153.B0/cdm4",VIDEO-RANGE=PQ
// (the form of Apple's HLS update of WWDC 2024, `SUPPLEMENTAL-CODECS="hvc1.2.20000000.L123.B0/cdm4"`;
// a variant of this shape is reported to play on an Apple TV 4K 3rd generation in an Apple developer
// forums thread). `SegmentMap.masterPlaylist` writes it for HDR10+ streams that carry no Dolby Vision
// signaling; the existing signaling retry drops SUPPLEMENTAL-CODECS entirely if a strict AVPlayer
// rejects the master, which plays the stream as plain HDR10 again.
//
// What this cannot establish without a device: whether tvOS then outputs HDR10+ rather than HDR10. That
// depends on the Apple TV model (HDR10+ is an Apple TV 4K feature), the TV, and Settings > Video and
// Audio > Match Content > Match Dynamic Range. The Stream Info "Dynamic range" row says "HDR10+" when
// the stream carries it and the master declares it.

nonisolated enum Hdr10PlusDetector {
    /// ITU-T T.35 header of an ST 2094-40 message: country code, provider code, oriented code,
    /// application identifier.
    static let t35Header: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    /// SEI payload type `user_data_registered_itu_t_t35`.
    static let userDataRegisteredT35 = 4

    /// Whether a length-prefixed HEVC packet (`nalLengthSize` bytes per NAL unit, as in hvcC) carries an
    /// HDR10+ SEI message. Malformed packets answer false.
    static func containsHdr10Plus(packet data: UnsafePointer<UInt8>, size: Int, nalLengthSize: Int) -> Bool {
        guard (1...4).contains(nalLengthSize) else { return false }
        var position = 0
        while position + nalLengthSize <= size {
            var length = 0
            for offset in 0..<nalLengthSize { length = (length << 8) | Int(data[position + offset]) }
            let start = position + nalLengthSize
            guard length >= 0, start + length <= size else { return false }
            if length > 3 {
                // 39 = prefix SEI, 40 = suffix SEI; two header bytes, then the SEI messages.
                let type = Int((data[start] >> 1) & 0x3F)
                if type == 39 || type == 40,
                   firstMessageIsHdr10Plus(UnsafeBufferPointer(start: data + start + 2, count: length - 2)) {
                    return true
                }
            }
            position = start + length
        }
        return false
    }

    /// The same for a packet held in an array.
    static func containsHdr10Plus(packet bytes: [UInt8], nalLengthSize: Int) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return containsHdr10Plus(packet: base, size: buffer.count, nalLengthSize: nalLengthSize)
        }
    }

    /// Whether the first SEI message of a NAL unit body (after the two NAL header bytes) is a T.35
    /// message with the ST 2094-40 header. HDR10+ encoders write it as the first message of its own SEI
    /// NAL unit; the T.35 header contains no pair of zero bytes, so emulation-prevention bytes cannot
    /// have changed it and the escaped bytes can be compared as they are.
    static func firstMessageIsHdr10Plus(_ body: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        func variableLength() -> Int? {
            var value = 0
            while index < body.count {
                let byte = Int(body[index])
                index += 1
                value += byte
                if byte != 0xFF { return value }
            }
            return nil
        }
        guard let type = variableLength(), type == userDataRegisteredT35,
              let size = variableLength(),
              size >= t35Header.count, index + t35Header.count <= body.count else { return false }
        for (offset, expected) in t35Header.enumerated() where body[index + offset] != expected {
            return false
        }
        return true
    }
}
