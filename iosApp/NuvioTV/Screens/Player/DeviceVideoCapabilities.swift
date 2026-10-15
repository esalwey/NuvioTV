import CoreMedia
import Foundation
import VideoToolbox

/// What this Apple TV decodes in hardware, asked of VideoToolbox rather than assumed from a model
/// name. The router sends a codec to the native player only where AVPlayer can really play it.
nonisolated enum DeviceVideoCapabilities {
    /// AV1 in hardware: the Apple TV 4K 4th generation (A19) and later. The 2nd and 3rd generation have
    /// no AV1 decoder, and VideoToolbox has no software one on tvOS (FFmpeg ticket 10642), so AV1 stays
    /// on mpv there. VP9 has no route to AVPlayer at all: Apple's HLS authoring spec (1.1) does not list
    /// it and `VTRegisterSupplementalVideoDecoderIfAvailable` is unavailable on tvOS.
    static let decodesAV1InHardware: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
}
