# Player spec: the system player, and how NuvioTV matches it

Written 2026-10-15 for `feature/native-first` (from `main`, release 1.0.0). It is the reference the
code is checked against: when a value in `PlayerSpec`, the router or the mpv chrome changes, this
document changes with it, and the other way round.

Updated 2026-10-16 for `feature/mpv-native-ref` (from `main`, build b150): the owner filmed the system player on an
Apple TV 4K, and the recording was measured frame by frame (section 9). Sections 3 and 4 and `PlayerSpec` now carry the
measured values, tagged `[observed: owner video 2026-10-16]`; what a recording cannot give (the finger on the remote,
the hold threshold) stays `[inferred]`, with the reason.

Why it exists. The owner tests on a real Apple TV 4K (tvOS 26 / 27) and keeps saying the mpv player is
"still not exactly like the native one" (the pause, the +10 s, "plenty of other things"). Several partial
fixes did not end that, because they were made from impressions. The strategy is now:

1. **The only perfect clone of the native player is the native player.** Apple says the system player
   cannot be reproduced in code: `AVPlayerViewController` "doesn't support subclassing" and "automatically
   adopts the new features and styling of future operating system releases"; extra gestures "will
   interfere with standard playback UI" [doc: AVPlayerViewController; WWDC21 10191; WWDC16 506]. So far more
   content goes to AVPlayer (section 2).
2. **For what must stay on mpv, the chrome and the remote reactions are rebuilt from a cited
   specification** (sections 3 and 4), not from impressions. Where nothing public gives a value, the value
   is measured on the owner's recording (section 9) or, when the recording cannot give it, a stand-in tagged
   `[inferred]` (or `[MEASURE]`), kept in one file (`PlayerSpec`), and a probe on the native engine
   measures it (section 6).

## 0. Source tags

| Tag | Meaning |
|---|---|
| **[doc]** | Apple documentation: AVKit, the HIG, the Apple TV user guide (support.apple.com) |
| **[WWDC]** | An Apple session or sample |
| **[observed]** | A third-party or user observation (URL in section 7). Includes an Apple engineer answering on the developer forums |
| **[observed: owner video 2026-10-16]** | Measured frame by frame on the owner's phone recording of the system player (section 9): times to one frame, clock readings to +/- 1 s, speeds to +/- 15 %, sizes to +/- 5 % |
| **[inferred]** | Reasoned from the above, or from what the native engine shows on a device; for a value the recording should have given but could not (the finger is never in the picture), it says why |
| **[MEASURE]** | Nothing public gives a value. It has to be measured on an Apple TV; the stand-in in the code is not a fact |
| **[app]** | An app mechanism or rule, not something the system player does |

Research finding that shapes everything below: **no public source gives pixel sizes, durations or easing
curves for the tvOS 26 / 27 transport UI.** Apple docs, the HIG, WWDC 2016-2025, the release notes, the
press and the forums were searched. Every number tagged [inferred] or [MEASURE] is a hypothesis, not a
measurement. The only source of measured values is the owner's recording of the system player (section 9):
where a value carries `[observed: owner video 2026-10-16]` it was read off that recording.

## 1. Scope and hardware

- Liquid Glass applies on Apple TV 4K 2nd and 3rd generation; older models keep the previous look
  [observed: AppleInsider forum 240713, heise 10438760; doc: HIG Materials "Apple TV 4K (2nd generation)
  and newer models support Liquid Glass effects"].
- In tvOS 26, standard buttons and controls "take on a Liquid Glass appearance when focus moves to them"
  [doc: HIG Materials].
- Linking against the tvOS 15 SDK gives the redesigned player (title view, controls on the bar, content
  tabs); older SDKs get the tvOS 14 UI [WWDC21 10191].
- The 1st-generation remote has a touch surface plus Menu. The 2nd and 3rd generation have a clickpad
  ring plus Back, TV, Mute (silver remote) [doc: support.apple.com/guide/tv/atvb7944597f/tvos].

## 2. Engine routing (strategy A)

### 2.1 The engines

| Engine | What it is | How the stream reaches it |
|---|---|---|
| **native** | `AVPlayerViewController` over `AVPlayer`: the system player itself | **remux**: the on-device MKV / MP4 / MOV / WebM to local fMP4 HLS (`RemuxSession`, `LocalHLSServer`, `SegmentMap`, `AudioTranscoder`). **direct HLS**: AVPlayer opens an `.m3u8` itself, no remux, no local server (`NativePlaybackCoordinator.launchDirect`) |
| **mpv** | libmpv with a SwiftUI re-implementation of the system chrome (`MPVPlayer*.swift`, `MPVTransportChrome.swift`) | direct, any format |

A native engine that fails before the first frame, or stalls for good, hands the same context to mpv at
the same position (`PlayerScreen`, `NativePlaybackCoordinator`): that automatic fallback is kept in every
mode.

### 2.2 Decision order

`PlayerEngineRouter.decide` (pure, unit-tested: `PlayerEngineRouterTests`, and the DEBUG
`selfCheckFailures()` at first playback). The first rule that matches wins. "Preference" is Settings >
Playback > Advanced > Player (section 2.3).

| # | Rule | Engine | Why |
|---|---|---|---|
| 0 | Dolby Vision picker is Off (`nativeDVKey` false) | mpv | The legacy kill switch for the native player |
| 1 | An `.m3u8` URL (no probe) | native, direct HLS (mpv if Prefer mpv) | AVPlayer opens HLS itself. A Jellyfin / Emby transcode is `/videos/<id>/master.m3u8` |
| 2 | No probe result | Prefer Native: native (tries it, falls back); else mpv | A source that did not answer: see 2.8 |
| 3 | Probe says container `hls` | native, direct HLS, if the video and audio codecs are AVPlayer's (H.264, HEVC, AV1 on hardware; AAC, AC-3, E-AC-3, MP3, FLAC, ALAC); else mpv | Same as 1, for an extension-less playlist URL |
| 4 | Source not seekable | mpv | The remux needs Range requests for the index and for seeking |
| 5 | Container not Matroska, WebM, MP4, MOV | mpv | No keyframe index to cut segments on (AVI, MPEG-TS / M2TS, FLV, ASF, OGM ...) |
| 6 | Video codec not H.264 / HEVC (AV1 only on a hardware decoder) | mpv | VP9, MPEG-2, VC-1, MPEG-4 Part 2, VP8, ProRes ... have no AVPlayer path |
| 7 | H.264 High 10 / 4:2:2 / 4:4:4 (profile 110, 122, 144, 244, 44) | mpv | No hardware decoder on Apple TV |
| 8 | HEVC not Main / Main 10 (RExt 4:2:2, 4:4:4, 12-bit; SCC), bit depth above 10, more than 4096 x 2304 samples (8K), level 6.0 and up | mpv | Used to start the remux and hang 45 s before the fallback. Level 5.2 and below is left to AVPlayer: a declaration it refuses fails the item at once |
| 9 | Interlaced (`field_order` TT, BB, TB, BT) | mpv (Prefer Native: native) | The HLS authoring spec wants deinterlaced input and nothing says tvOS deinterlaces. Drop the rule if a 1080i file looks fine natively |
| 10 | Dolby Vision FEL and "HDR10 for Profile 7 FEL" | mpv | A deliberate fidelity choice (section 2.4) |
| 11 | No audio track that can be copied (AAC, AC-3, E-AC-3, FLAC, ALAC) or decoded by libavcodec | mpv | Rare: WMA-only and similar |
| 12 | Prefer mpv, unless the file plays as true Dolby Vision | mpv | The viewer's choice |
| 13 | Everything else | **native, remux** | |
| 14 | After the router, Automatic only: subtitles in the viewer's language exist only as images (section 2.7) | mpv | PGS and VobSub cannot be shown by AVPlayer |

### 2.3 Settings

Settings > Playback > Advanced > **Player** (`PlayerEnginePreference`, key `player.enginePreference`):

| Choice | Meaning |
|---|---|
| **Automatic** (default) | Native first. mpv for what AVPlayer cannot play, interlaced video, and files whose subtitles in the viewer's language are images only |
| **Prefer Native** | Everything AVPlayer can open plays on it, even at the cost of image subtitles, a stream the probe could not read, or interlaced video. mpv only takes what AVPlayer cannot play |
| **Prefer mpv** | mpv for everything, except Dolby Vision files that play as true Dolby Vision on the native player |

It sits next to Settings > Playback > **Dolby Vision** and does not replace it:

| Dolby Vision picker | Effect |
|---|---|
| Automatic | Dolby Vision plays natively (Profile 7 converted to 8.1) |
| HDR10 for Profile 7 FEL | As Automatic, FEL releases go to mpv (nothing discarded) |
| HDR10 Only | Dolby Vision files play as their HDR10 base layer, **on the native player, with the Dolby Vision data stripped**. Profile 5 has no base layer and keeps playing as Dolby Vision. (It used to send these files to mpv.) |
| Off | The native player is off: everything plays on mpv. Wins over the Player choice |

### 2.4 Dolby Vision handling (`DolbyVisionHandling`)

| File | Handling |
|---|---|
| Profile 5, single-layer Profile 8 | `passthrough`: played as Dolby Vision (`dvh1` for P5, `hvc1` + SUPPLEMENTAL-CODECS for P8) |
| Profile 7, one video track, MEL or FEL (FEL unless the fidelity mode is on) | `passthrough` through the existing 8.1 conversion (EL NALs dropped, RPUs rewritten with libdovi) |
| Profile 7 FEL with "HDR10 for Profile 7 FEL" | mpv |
| "HDR10 Only", any profile but 5 | `stripToBase` |
| Profile 7 with two video tracks (BL + EL), with no RPU, with an RPU libdovi cannot parse, or not classified | `stripToBase` (these went to mpv, which plays the base layer: same picture) |
| Profile 4, 9 (AVC, SDR base), 10 and others | `stripToBase` |

`stripToBase` (`RemuxSession.Config.dolbyVisionHandling`, `DoviRpuConverter.Mode.stripToBase`): the DOVI
configuration is removed from the stream's `codecpar` before anything derives from it, so the init segment
has no `dvvC` / `dvcC` box, the sample entry is plain `hvc1` / `avc1`, and the master has no
SUPPLEMENTAL-CODECS; `VIDEO-RANGE` comes from the stream's own transfer (PQ, HLG, none = SDR). The RPU and
enhancement-layer NALs of an HEVC track are dropped too. The loading caption "Preparing Dolby Vision" is not
shown for a stripped file.

### 2.5 Direct HLS

- `NativePlaybackCoordinator.launchDirect`: `AVURLAsset(url:options:)` with the addon's request headers under
  `AVURLAssetHTTPHeaderFieldsKey` (the key AVFoundation reads for every request the asset makes; it has no
  public constant), `AVPlayerItem`, then the same player installation and observation as the remux path.
- The loading view stays up until the item is `readyToPlay`; then the resume point is applied, the player is
  shown and playback starts.
- Failure: an item that fails before ready, is not ready after 30 s, or stalls for ~60 s with the playhead
  frozen goes to mpv (`handOverToMpv`).
- Not offered on direct HLS: addon subtitle files (there is no master of ours to put them in; the stream's own
  renditions are the system menu's) and the app's Subtitle Timing. Jellyfin / Emby keep their audio and
  burned-in subtitle choices in the server menus (`ServerPlaybackLink`).
- No Dolby Atmos conversion (APAC) and no lossless FLAC on direct HLS: both are renditions the remux's local
  master lists, and a stream AVPlayer opens itself plays the audio its own playlist declares. The router never
  labels a direct HLS decision with `EngineDecision.spatialAudio`.
- Risks to check on a device: addon headers on segment requests, segments with unusual MIME types (AVPlayer is
  strict), live streams.

### 2.6 Audio

- Copied: AAC, AC-3, E-AC-3, FLAC, ALAC. **MP3 is no longer copied**: Apple's HLS authoring spec lists no MP3
  for fMP4 (2.2, 2.5); it is decoded and re-encoded to AAC like the rest.
- Transcoded to AAC (5.1 for 6+ channels, stereo, mono): TrueHD, DTS, Opus, Vorbis, and now **every codec
  libavcodec has a decoder for** (PCM including Blu-ray PCM, MP2, MP3, WMA, AMR ...), minus MLP. The probe asks
  libavcodec (`AudioStreamInfo.decodable`); the remux uses the same predicate
  (`AudioTranscoder.isTranscodable`).
- Lossless Surround Sound (Settings > Playback > Audio, on by default): TrueHD and DTS-HD MA with 3 to 8
  channels that the FLAC encoder can carry are transcoded to FLAC at their own channel count instead of AAC 5.1
  (`AudioTranscoder.losslessPlan`, master CODECS `fLaC`); every other transcoded codec stays AAC.
- Spatial Audio (same pane, on by default): a TrueHD Atmos or DTS:X track plays as Dolby Atmos, converted to
  APAC 7.1.4 by SpatialAudioBridge (`NativePlaybackCoordinator+SpatialAudio`), on the remuxed path only. It
  changes the label of a native decision (`EngineDecision.spatialAudio`), not the engine: the Player preference
  and the Dolby Vision modes still decide. A file that falls back to the standard audio keeps the FLAC / AAC
  rendition the remux produces.
- Initial audio track: the viewer's language plan first (`preferredAudioPicker`); with none, the file's own main
  track (`RemuxAudioCandidate.automaticPick`). With Spatial Audio on, an announced Atmos / DTS:X track of the
  same language replaces a stream-copied compatibility track (not E-AC-3) as the start track, unless the
  viewer's remembered pick is a named track.

### 2.7 Image subtitles (PGS, VobSub, DVB)

AVPlayer shows WebVTT, CEA-608 / 708 and IMSC1 text only [doc: HLS authoring spec 4.2]; the on-device remux
turns the file's text tracks and the addon files into WebVTT renditions, and **image tracks were silently
lost** on the native path. The router has no view of subtitles, so `PlayerScreen` applies one more rule after
it, for **Automatic only**: the file goes to mpv when

- the language plan would switch subtitles on at the start (a preferred subtitle language, not "none", not
  forced-only, not turned off for this title), and
- the file has image tracks in that language and no text track in it, and the stream came with no file in it,
  and
- no addon subtitle in that language came back (the search is started and awaited, 3 s at most).

A Jellyfin / Emby source is exempt (its subtitles are the server's business). Prefer Native skips the rule.

### 2.8 Probe

`PlayerTuning.probeTimeoutSec` is 4 s. A probe that ran into that deadline (not one that failed outright)
gets **one more try of 8 s** (`probeRetryTimeoutSec`, `MediaProbe.probeWithRetry`) while the loading view
shows. A source that still does not answer is mpv (Prefer Native: tried natively). Prefer mpv with a Dolby
Vision picker that never plays Dolby Vision natively (HDR10 Only, Off) does not probe at all.

### 2.9 What stays on mpv, and why

| Case | Why it stays |
|---|---|
| VP9, MPEG-2, VC-1, MPEG-4 Part 2, VP8, ProRes, MJPEG | No AVPlayer path; only an on-device video transcode would move them (heat, latency, quality) |
| AV1 on Apple TV 4K 2nd / 3rd generation | No hardware decoder; VideoToolbox has no software one on tvOS. `VTRegisterSupplementalVideoDecoderIfAvailable` is unavailable on tvOS; the HLS spec does not list VP9 |
| H.264 High 10 / 4:2:2 / 4:4:4, HEVC RExt | No hardware decoder |
| MPEG-TS, M2TS, MPEG-PS, AVI, FLV, ASF, OGM | No keyframe index to cut on; a pre-scan is too slow over the network and a published playlist that disagrees with the real keyframes breaks playback |
| DASH (`.mpd`) | AVPlayer has no DASH |
| Not seekable sources; MKV without Cues (average segment over 30 s) | The remux needs the index and Range |
| Interlaced video | Until AVPlayer's deinterlacing is confirmed on a device |
| Image-only subtitles in the viewer's language | Until image subtitles can be drawn over AVPlayer |

AV1 plays natively on a hardware decoder (`DeviceVideoCapabilities.decodesAV1InHardware`, i.e.
`VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)`): the Apple TV 4K 4th generation (A19) lists AV1. The
remux signals it (`av01`, `av01.<profile>.<level><tier>.<depth>`); it has not been run on a device.

### 2.10 Decided against, for now

| Item | Decision |
|---|---|
| Image subtitles over AVPlayer (decode PGS with libavcodec, draw them in `contentOverlayView`, publish an empty WebVTT rendition so the track is in the menu) | Not built. A week of work with seek, HDR brightness and aspect risks that cannot be checked off a device; the section 2.7 rule is the stop-gap |
| ALAC instead of AAC for lossless multichannel (TrueHD, DTS-HD MA, PCM) | Not built as ALAC: FFmpeg's `alac` encoder is stereo-oriented, so lossless FLAC is what ships for TrueHD and DTS-HD MA (section 2.6). These files are already native; this is audio quality, not routing. The encoder question is settled: MPVKit's FFmpeg is configured with `--disable-encoders` and then `--enable-encoder=aac`, `alac`, `flac`, `pcm*` (MPVKit `Sources/BuildScripts/XCFrameworkBuild/main.swift`, the revision the submodule pins), and FFmpeg's ALAC encoder takes mono up to 7.1 in fixed channel layouts and 16 / 24-bit planar integers. What is left is the transcoder's encoder choice and layout mapping, the `alac` CODECS signaling for a transcoded track, and a device test that AVPlayer plays ALAC 5.1 / 7.1 from fMP4 HLS (it is in the HLS authoring spec, 2.5) |
| Progressive MP4 straight to AVPlayer (no remux) | Not built. Only pays off if seek latency through the remux becomes a complaint, and it loses the addon subtitle renditions |
| MPEG-TS / M2TS remux | Not built (no index) |
| Proxying a direct HLS master to add addon subtitle renditions | Not built |
| `AVPlayerViewController.speeds` instead of the app's Playback Speed menu | Not changed; the app's menu keeps the title's remembered speed |

### 2.11 Platform facts used

- Apple TV 4K 3rd generation (tech specs): SDR AVC / HEVC (Main, Main 10) up to 2160p60; Dolby Vision Profile 5;
  HDR10+ / HDR10 / HLG with HEVC Main 10; audio HE-AAC, AAC, MP3, Apple Lossless, FLAC, AIFF, WAV, AC-3, E-AC-3
  and Atmos. AV1, VP9, Opus, DTS and TrueHD are not listed. 4th generation (A19) lists AV1, VP9, HEVC, AVC,
  MPEG-4.
- HLS authoring specification [doc]: video H.264, HEVC, Dolby Vision or AV1 (1.1; no VP9, MPEG-2, VC-1); H.264
  in fMP4 or MPEG-TS, High profile up to level 5.2 (1.2); HEVC in fMP4 only, up to Main 10, level 5.1, High tier
  (1.5, 1.6b); "All interlaced source content MUST be deinterlaced" (1.14); stereo and multichannel codecs
  include Apple Lossless, FLAC, AC-3, E-AC-3 (2.2, 2.5); FLAC and ALAC need fMP4 (2.25); captions are CEA-608 /
  708, WebVTT or IMSC1 text profile (4.2); AV1 in fMP4 (1.39); "Media data SHOULD NOT be delivered to the
  application through a local server" (10.3) - the loopback server contradicts that guidance and has worked on
  device so far.
- Opus works from iOS 17 in MP4 only and is not in the spec [observed: Apple Media Engineer, forums 759210]: the
  AAC transcode stays.

## 3. The system player (tvOS 26 / 27)

### 3.1 Layout

Measured on the owner's recording (section 9). Sizes are points of a 1920 x 1080 canvas, worked out from the
screen's own edges (the phone filmed the TV at an angle), good to about 5 %.

| Element | Spec | Tag |
|---|---|---|
| Safe area | 90 pt left / right, 60 pt top / bottom on a 1920 x 1080 pt canvas | [WWDC19 211] |
| Structure | A **title view** above the transport bar. **Controls** (subtitles, audio, PiP, custom items) on the bar's trailing side. **Content tabs** (Info, Chapters, custom) below | [doc: Customizing the tvOS playback experience; WWDC21] |
| Sides | The bar, the title and the pills start 83 pt from the left edge; the bar and the last button end 78 pt from the right edge | [observed: owner video 2026-10-16] |
| Heights, above the bottom edge | Pills' centre 79 pt (their bottom edge 47 pt), labels 150 pt, bar 178 pt, title 249 pt, buttons 258 pt, episode line 314 pt | [observed: owner video 2026-10-16] |
| Title view | The episode line (semibold, 26 pt, white at 90 %) over the title (bold, 57 pt); a soft shadow, no platter and **no scrim**: the picture is never dimmed | [observed: owner video 2026-10-16] |
| Round buttons | Seven, 65 pt across, 89 pt apart, Clear glass tinted by the picture behind: Start Over (the darker, skip-style chip), Sources, Playback Speed, Aspect Ratio, Player Engine, Subtitles, Audio (the waveform) | [observed: owner video 2026-10-16] |
| Scrubber | A capsule **15 pt thick** (21 pt while a finger or a scrub is on it); the played part white, the rest a pale lavender; elapsed time **centred under the playhead**, 29 pt under the bar's centre (38 pt with the knob); remaining time right-aligned to the bar's end; both 25 pt semibold, with a soft shadow | [observed: owner video 2026-10-16] |
| Labels | `15:43` and `-06:38` on a 22:35 file: minutes on two digits once the file is 10 min or longer; the remaining time is the whole-second length less the whole seconds elapsed (they add up) | [observed: owner video 2026-10-16] |
| Tab pills | 64 pt tall, 24 pt apart, 27 pt semibold text, 31 pt of padding; Clear glass capsules; the selected one a white capsule with dark text. No ring, no scale | [observed: owner video 2026-10-16] |
| Clock capsule | Top-trailing ("21:44 · Se termine à 21:51"); with the full chrome and with the scrub's bar, **not** with the bar a skip click brings up | [observed: owner video 2026-10-16] |
| Contextual actions (Skip Intro, Recap) | Bottom-trailing of the screen, focusable glass buttons | [doc] |
| Glass | Clear variant over video; buttons brighten and darken as the white time text passes behind them | [doc: HIG Materials; observed: AppleInsider, kodi.expert] |
| Focused button | A **pale cyan disc** (a quarter larger than the others) with a dark teal symbol; the bar and its labels drop to about 40 %; no tooltip | [observed: owner video 2026-10-16] |

The mpv bar's side inset (82 pt) and bottom inset (47 pt) are now the measured ones; the earlier 84 / 56 pt were tuned on
a device and agree to within the measure's error on the side.

### 3.2 Pause and resume

| Event | Reaction | Tag |
|---|---|---|
| Play/Pause or Select while playing, chrome away | The **picture freezes in the same frame** (1.600 s). The chrome follows **0.283 s later** (1.883 s) as a cascade of pure fades, no slide: buttons 1.883 to 2.017 s, bar, labels and the pause glyph 1.917 to 2.017 s, title and pills 2.15 to 2.283 s (the pills' glass two frames after their text) | [observed: owner video 2026-10-16] |
| Glyph | A thin ring with two bars in it, 25 pt, **18 pt to the right of the elapsed time** (not a big centred icon). It is away while a finger rests on the surface (the knob) and while the head is scrubbed, and comes back when neither is left | [observed: owner video 2026-10-16] |
| Persistence | The chrome does **not** auto-hide while paused (still up 8.4 s later, and 3 s on the second pause); the info capsule shows "Se termine à" from the committed position | [observed: owner video 2026-10-16] |
| Resume | The picture plays 0.23 s after the click. The chrome comes back as the cascade of section 3.5 if it was in the scrub's bar (167 ms), stays 5.0 s, then fades out | [observed: owner video 2026-10-16] |
| Back while paused | Hides the controls; does not exit | [doc: "Hide: press Back or Menu"] |
| Thumbnail | None. "Pausing shows elapsed and remaining time" | [doc; observed: owner video 2026-10-16] |
| Subtitles while paused | A subtitle can stay on screen above the bar | [observed: Firecore] |

### 3.3 Skip: click left / right

| Item | Spec | Tag |
|---|---|---|
| Input | A click on the left or right edge of the touch surface or ring skips 10 s; press again to skip another 10 | [doc] |
| Target | The elapsed label **jumps by 10 s in the very frame the glyph appears**; the remaining label rolls through three or four values in 100 to 130 ms. The picture follows later, **0.10 to 1.45 s** after the label (back skips are slower), and two seeks can be out at once. The play / pause state is kept | [observed: owner video 2026-10-16] |
| Glyph | A circular arrow with the 10 in it, 28 pt, **on the right of the elapsed time for a forward click, on its left for a back click**. It lives 0.25 to 0.5 s (0.35 s typical) and fades out in two or three frames. There is **no running total** ("+20") and no rate | [observed: owner video 2026-10-16] |
| Bar, full chrome up | Nothing but the label and the glyph change. The chrome's own timer is **not restarted**: it hid 0.72 s after a click | [observed: owner video 2026-10-16] |
| Bar, chrome away | The **bar alone** (bar, both labels, glyph) fades in over four or five frames (21.903 to 22.0 s). No title, no buttons, no pills, no clock capsule. It was still up 1.98 s after the last click of a series of five (21.9 to 27.54 s), each click restarting it. The upper bound is not in the recording | [observed: owner video 2026-10-16]; the bound [inferred] (the chrome's idle time) |
| Fill | The played part turns from white to a pale lavender with the first click and stays so until the bar hides | [observed: owner video 2026-10-16] |
| Back skip, third click | The third back skip of a run turns subtitles on (the picture shows them 0.23 s after the click) and "Subtitles on for 11 seconds" appears under the remaining time, right-aligned, in two frames. The text is constant (it never counts down). The subtitles went off between 36.0 and 39.2 s (25.8 + 11 = 36.8). The first two clicks of the run showed neither | [observed: owner video 2026-10-16] |
| Hint | "There's no way to disable the skipping hint" | [observed: Apple staff, forums 651514] |
| Delegate | `timeToSeekAfterUserNavigatedFrom` fires for ±10 but not for scans; `requiresLinearPlayback` is the only way to disable ±10 | [observed: Apple staff, forums 651497] |

### 3.4 Hold: left / right

Press and hold; the scan runs **only while the edge is held**. [observed: owner video 2026-10-16]

| Item | Spec | Tag |
|---|---|---|
| Start | The picture **freezes** (45.2 s, 54.0 s). The badge comes 0.13 to 0.3 s later (a ring with the way it runs in it: rewind on the **left** of the elapsed time as `digit ring time`, fast-forward on its **right** as `time ring digit`; the time stays centred under the head and the badge hangs off it) and the head starts to run 0.3 s after the freeze | [observed: owner video 2026-10-16] |
| Tiers | Three, each 2.4 s of holding: **8 s/s with no digit, 24 s/s with "2", 48 s/s with "3"** (the rewind measured 7.8, 23.5 and 48; the forward 8, 24 and 40 to 50). Bare digits, no multiplication sign; no tier above the third in a 7.4 s hold. A change of tier takes 100 to 200 ms. The speed is steady inside a tier | [observed: owner video 2026-10-16] |
| Picture | Frozen for the whole hold; no thumbnail, no preview, no sound | [observed: owner video 2026-10-16] |
| Chrome | The full chrome stays up for the whole hold | [observed: owner video 2026-10-16] |
| Release | The head stops within two frames (the forward one slows for five), the badge becomes a **spinner** that stays until the picture has changed (1.07 s after the rewind, 0.03 s after the forward), the picture cuts to the new place and plays at 1x. The seek is to the head's place | [observed: owner video 2026-10-16] |
| Hold threshold | Where a click ends and a hold begins is not in the recording (the finger is never in the picture) | [inferred] (0.45 s) |
| Older source | "Press repeatedly to cycle through 2x, 3x and 4x", "release does not stop it" | [doc; observed: 9to5Mac] describes an earlier tvOS; the recording shows what tvOS 26 does |

### 3.5 Scrub

| Item | Spec | Tag |
|---|---|---|
| Touch, paused | A finger on the surface of a paused player: the **title, the buttons, the pills and the pause glyph fade out in 100 to 130 ms** (4.567 to 4.667 s); the bar and its labels stay; within 0.1 s a **knob** grows on the playhead (200 ms): a white disc 51 pt across with an indigo ring 30 pt across in it; the labels move 9 pt down. The bar thickens to 21 pt | [observed: owner video 2026-10-16] |
| Finger lifts | The knob collapses in 130 ms and the pause glyph returns; the bar stays the bar alone | [observed: owner video 2026-10-16] |
| A swipe | The head **flicks**: 42 to 65 s in one to three frames (33 to 100 ms), then glides on, exponentially, with a time constant of 0.2 s (a tail of 15 s after +42 s; -10 s after -45 s). A flick lasts 0.3 to 0.7 s, the pause between two 0.15 to 0.6 s; twelve flicks of 25 to 80 s each in 9 s. **No knob during a flick**, no preview image, **the picture stays frozen**, a reversal is immediate | [observed: owner video 2026-10-16] |
| What the bar shows | White up to the nearer of the playhead and the target, a deeper lavender between the two, the pale track beyond, and a 2 pt tick on the farther of the two; the elapsed time is **centred under the target** and the remaining time follows it. The pause glyph stays away | [observed: owner video 2026-10-16] |
| Finger to seconds | How far a given swipe moves the head cannot be read from a recording that never shows the finger | [inferred] |
| Commit | Select (the click) seeks there and plays; the full chrome returns in 167 ms (buttons 15.618 to 15.652 s, title 15.652 to 15.718 s, pills 15.652 to 15.752 s), stays 5.0 s, then fades out. The picture blends for one frame and moves 0.23 s after the click | [observed: owner video 2026-10-16] |
| Cancel | Back cancels and returns to the original time (no seek was issued) | [doc] |
| Ring | Fine control within about a second since tvOS 12.3; the ring does not reach the app as a distinct input | [WWDC19 503] |

### 3.6 Show and hide the chrome

| Input | Reaction | Tag |
|---|---|---|
| A finger on a paused player | The bar alone with the knob (section 3.5) | [observed: owner video 2026-10-16] |
| A finger on a playing player, or Up on the ring | Shows the controls | [doc] |
| Idle time | **5.0 s** after the commit of a scrub (visible 15.633 s, gone 20.767 s); every gap between two visible events in the 26 s run from 39.6 to 66.1 s (3.9 s at most) fits it. A ±10 s click while the full chrome is up does not restart it. Paused, scrubbing or holding the chrome stays | [observed: owner video 2026-10-16] |
| Fade out | Pure opacity, 133 to 167 ms (4 or 5 frames): the pills and the bar lead by a frame, the title and the buttons follow. No slide | [observed: owner video 2026-10-16] |
| First touch while playing | Elapsed on the left, remaining on the right | [observed: iDownloadBlog] |
| Second touch | The labels become the clock time and the finishing time ("21:44" and "21:51", 41.095 to 41.66 s), then go back; the trigger is ambiguous (a tap and a click both touch the surface) and it was seen once | [observed: owner video 2026-10-16; iDownloadBlog] |
| Hide manually | Back or Menu | [doc] |

### 3.7 Other remote reactions

| Input | Playing | Paused | Scrubbing | Menus open |
|---|---|---|---|---|
| Swipe down | The tab view | same | cancels? | n/a |
| Swipe up | Focus the transport buttons | same | | Closes the tab view |
| Click center | Pause | Resume | Commit the scrub | Activate the focused item |
| Click left / right | ±10 | ±10 (stays paused) | Step the scrub | Move focus |
| Hold left / right | The hold of section 3.4 | same (stays paused) | Steps the scrub once | |
| Back / Menu | Hides the chrome if visible, exits if hidden | Hides the chrome | Cancels the scrub | Closes the tab view / menu |
| Back, long press | Home Screen | | | |
| Mute (silver remote) | If audio is muted, subtitles turn on | | | |

[doc for each; "exits when hidden" inferred]. Click center is always Pause / Play: a contextual action (Skip
Intro) is a focusable button and only reacts once focus is on it [doc: `contextualActions`]. Siri: "skip ahead 15 seconds", "What did they say?" (enables captions
and rewinds), pause [doc]. Only the system player answers these.

### 3.8 Menus, tabs, panels

- Transport bar buttons: Subtitles, Audio Options, Picture in Picture, Speed (tvOS 16+, `speeds`), plus custom
  items [doc]. Audio options: Enhance Dialogue, Reduce Loud Sounds, Audio Track [doc]. Menus are `UIMenu` popups
  with checkmarks [doc sample]. A focused button is a pale cyan disc (section 3.1); the bar dims.
- **Tab view** (a swipe down). The pills row and the panel come in **from the bottom edge in about 230 ms** with a fade
  (29.557 to 29.8 s); with the transport bar up, the bar's block of title, bar and pills goes up with them. The picture
  keeps playing and is not dimmed; the captions jump up to the top quarter of the picture while it is open. The pills
  sit with their centre 594 to 611 pt above the bottom edge, in the order **Info, Chapters, Episodes, Stream Info**,
  the selected one white; the panel's top edge is 514 pt above the bottom edge, its left edge 83 pt from the left.
  Right swipes move the white highlight in 33 to 130 ms; the panel **crossfades 0.25 to 0.33 s later** (0.1 s on the
  last), in place, no slide. **Back (or a swipe up)** closes it: the pills, with the title and the bar, slide back down
  **49 % of the screen's height in 0.3 s, ease-out**, the panel fades, the buttons fade in at 39.4 to 39.5 s [all
  observed: owner video 2026-10-16]. Info (needs metadata), Chapters (`navigationMarkerGroups`), custom
  (`customInfoViewControllers`) [doc].
  - Info: one glass card, 1726 x 251 pt, corners 40 pt: the portrait artwork (141 x 211 pt), the episode line
    (semibold), the synopsis (light, tinted), the runtime with an "HD" badge, and a glass capsule "From the Beginning"
    with a play glyph at the trailing end.
  - Chapters: four equal cards (328 x 232 pt, 43 pt apart) on a deep violet glass, each with a film-strip glyph and
    the chapter's name at its bottom leading corner; the current one says "EN COURS" over its name. No picture.
  - Episodes: 16:9 stills (421 x 237 pt) with "Épisode N" and the title under each.
  - Stream Info: three columns of white text straight over the picture, no panel.
  - No focus ring or scale was visible on any card.
- Contextual actions bottom-trailing [doc]. Up Next: the video shrinks to a window and the proposal sits lower right
  [doc, WWDC16 506].
- Stream list (the Sources button): a 300 ms crossfade to the app's own screen, no slide [observed: owner video 2026-10-16];
  Back from it left the player at once (the picker is app-level).

### 3.9 Loading, buffering, end

A spinner appears over the video, the transport bar can still be shown (style [MEASURE]). The player does not
dismiss itself at the end; the app decides [doc: HIG Playing video]. Resume automatically, without a prompt
[doc]. An interactive overlay waits a 0.5 s minimum after a pause [doc: HIG]. After a hold's release the badge turns
into a small spinner until the picture has changed (section 3.4).

### 3.10 Timings

| Item | Value | Tag |
|---|---|---|
| Chrome fade in after a pause | 0.283 s after the freeze, then 130 ms (buttons, bar), 120 to 150 ms (title, pills) 0.27 s later | [observed: owner video 2026-10-16] |
| Chrome fade in after a commit, a Play or a touch while playing | 167 ms in all (buttons 40 ms, title 70 ms, pills 100 ms, the last two 33 ms late) | [observed: owner video 2026-10-16] |
| The bar alone (a skip click) | 100 to 130 ms | [observed: owner video 2026-10-16] |
| Chrome fade out | 133 to 167 ms by idle, 100 to 130 ms on a touch | [observed: owner video 2026-10-16] |
| Auto-hide while playing | 5.0 s (a +/-10 s click does not restart it) | [observed: owner video 2026-10-16] |
| The bar alone after a skip | 1.98 s at least after the last click; 5 s assumed | [observed: owner video 2026-10-16]; the bound [inferred] |
| Skip glyph | 0.35 s, then 0.1 s of fade | [observed: owner video 2026-10-16] |
| Knob | grows in 0.2 s, collapses in 0.13 s | [observed: owner video 2026-10-16] |
| Hold | freeze, badge +0.2 s, head +0.3 s, tiers every 2.4 s, spinner until the picture | [observed: owner video 2026-10-16] |
| Tab view | in 230 ms, back down in 300 ms, content crossfade 300 ms | [observed: owner video 2026-10-16] |
| Focus lift on glass buttons | spring | [inferred] |

## 4. What the mpv chrome does (implementation)

Constants live in `Player/PlayerSpec.swift`, each with its source (the measurements of section 9, or `[inferred]` with
the reason); the behaviours in the files named. The mpv chrome is rebuilt from section 3, interaction by interaction;
section 9.5 lists, for each, what the system player does, what mpv did before and what it does now.

| Spec item | mpv chrome | Where |
|---|---|---|
| Parts | The chrome is four parts that fade **by themselves, in pure opacity, with no slide**: the bar (scrubber, both labels, the state slot, the hint), the title, the buttons, the pills. The layout never moves, so a part that is away leaves its place empty; the passive overlay and the focus layer draw the same `PlayerTransportBar` and hide the same parts the same way. No scrim: the picture is never dimmed | `PlayerTransportBar`, `PlayerBarParts`, `PlayerBarFade` (`MPVPlayerOverlays.swift`) |
| Elapsed time, state slot | The elapsed time is **centred under the playhead** (under the scrub target while scrubbing), the remaining time right-aligned at the bar's end; they add up to the length. The slot hangs off the elapsed time: the pause ring on its right, the skip glyph and the hold's badge on the side the head is going (the digit on the far side of the ring), the spinner of a hold's release in the badge's place | `PlayerScrubberRow`, `PlayerBarSlotView`, `MPVPlaybackState.slot(at:)` |
| Pause | The picture freezes at once; the chrome follows 0.3 s later in the pause cascade (buttons and bar, then title and pills); at once if the chrome was already up. The chrome stays until the viewer acts; Back hides it and the next input shows it again | `updatePauseReveal`, `MPVPlaybackState.pauseChromeRevealed`, `hideChrome` (`MPVPlayerView+Remote`) |
| ±10 s | An **exact absolute seek** to the displayed time ± 10 s (from the freshest position, so clicks in a row add up exactly): the head and the time **jump at once**, play / pause kept. Clicks less than 0.5 s apart (or while a seek is still out) go to the core as keyframe seeks and settle on one exact seek 0.25 s after the last, so a burst on a 4K stream never queues exact decodes. Siri, iPhone Remote and CEC skips take the same path | `skip(by:)`, `seekForSkipClick`, `nowPlayingSkip` |
| Skip glyph, the bar alone | The circular arrow with the 10 in it beside the elapsed time (right for forward, left for back), 0.35 s, no running total; the bar's fill goes lavender. With the chrome away the click brings up **the bar alone** (no title, buttons, pills or clock capsule), which hides 5 s after the last click, each click restarting it; with the full chrome up a click restarts nothing | `showSkipGlyph`, `revealSkim`, `MPVPlaybackState.skimVisible`, `barTinted` |
| Back skip | The third back skip of a run (clicks less than 3 s apart) turns on the subtitles the language plan would pick, when none is showing, and says "Subtitles on for 11 seconds" under the remaining time; 11 s after the last of the run they go off and the hint with them. Nothing is saved; any pick of the viewer's ends it | `registerBackSkip`, `endRewindSubtitles`, `cancelRewindSubtitles` (`MPVPlayerView+Tracks`) |
| Select and the skip chip | Select is Pause / Play, always. The chip ("Skip Intro") is a focusable action: Up (with the bar showing) moves "focus" onto it, Select then skips; any other input, the bar hiding or the segment ending takes the focus off it | `upRequested`, `selectPressed`, `MPVPlaybackState.skipChipFocused` |
| Playhead between polls | The core is polled twice a second; the bar's head and both labels follow the clock in between (`TimelineView`, 30 Hz, only while the bar is on screen and the picture is playing or a hold is running). Pause, stall and scrub stand still; a hold runs by its own clock | `MPVPlaybackState.displayPosition`, `PlayerScrubber` |
| Focus layer handover | The passive bar stays drawn under the focus layer, which appears without a dissolve when the bar was already up; the passive bar steps aside after the layer is presented and is back before it is dismissed, both without a fade | `MPVPlaybackState.chromeCovered`, `onOpenChrome`, `PlayerPanelHostController.onWillClose` |
| Click vs hold | The click acts on release; a press of `holdThresholdSec` (0.45 s, `[inferred]`) is a hold | `arrowPressBegan` |
| Hold | The picture **freezes** (the core is paused; the player still reads as playing, so nothing reacts to a pause nobody asked for); the head runs on **its own clock** in three tiers (8, 24, 48 s/s, 2.4 s each from the freeze, a ramp of 0.15 s between) with the badge after 0.2 s and a bare digit from tier 2; nothing is seeked meanwhile (no thumbnail); the full chrome stays up. The **release** (or Select, or Play/Pause) does one exact seek to the head's place, shows a spinner in the badge's place until the picture is there, and plays on if it was playing; Back goes back to the freeze point | `beginScan`, `endScan`, `settleSeekSpinner`, `MPVScan` |
| Touch while paused | After 70 ms (and only if no button went down with the finger: a click lands a finger too) the title, the buttons, the pills and the pause glyph fade out in 115 ms, the bar and labels stay; a finger that rests 0.1 s grows the **knob** (51 pt disc with an indigo ring) on the playhead in 0.2 s, and it collapses in 0.15 s when the finger lifts. Select commits, Back cancels; left alone for 5 s the bar goes back to the full chrome | `fingerTouched`, `enterScrubChrome`, `leaveScrubChrome`, `MPVPlaybackState.scrubChrome`, `knobShown` |
| Scrub | A swipe after 24 pt of travel (and not within 0.4 s of an edge press: a click's drift stays a skip) **flicks** the head: the distance is the finger's travel times a gain that grows with the swipe's speed (a share of the duration per surface width, so it scales with the file); after the finger leaves it glides on by 30 % of its last tenth of a second (at most 1.1 % of the duration), exponentially with a 0.22 s constant. The bar is white to the nearer of head and target, deeper lavender to the farther, with a tick on it; the time under the target; **the picture stays frozen**; Select commits one exact seek and plays, Back cancels (no seek was issued). **No thumbnail**: the system has none either | `handleTransportPan`, `scrubGain`, `moveScrubTarget`, `finishScrubGesture`, `startScrubTail`, `commitScrub`, `cancelScrub` |
| Show / hide | A finger on a playing player shows the chrome (not when it is a click); Up shows it, the next Up focuses the buttons; it hides **5 s** after the last interaction while playing, never while paused (the pause holds it, so a resume that did not come through the remote cannot leave it up), scrubbing, holding or under the focus layer; it fades out in 150 ms | `flashControls`, `PlayerSpec.Chrome.autoHideDelay` |
| Animation | Pure opacity per part (section 3.10): after a pause the pause cascade, after a commit / Play / touch the quick one (167 ms), the bar alone 115 ms; out in 150 ms (115 ms on a touch). No slide: `slideOffset` is gone. Reduce Motion drops the tab view's slides | `PlayerBarFade`, `MPVPlayerScreen.body` |
| Captions | Three positions: resting; **lifted above the chrome** (`sub-pos`, `chromeClearancePercent` 27 %, also under the skip's bar); **lifted above the tab view** (70 %, near the top quarter of the picture), the glide in 0.1 s. The 27 % is [inferred] from the chrome's height; the 70 % is [observed: owner video 2026-10-16] | `setSubtitleChromeLift`, `MPVSubtitleLift`, `SubtitleRenderStyle.mpvSubPosWithTabs` |
| Glass | The transport buttons and the pills wear the **Clear** variant of Liquid Glass (`PlayerChipStyle.transportGlass`) with no shade under it; the selected pill is a white capsule, a focused button a pale cyan disc. Developer > "Dark Player Glass" brings the tinted regular glass back for an A/B. The scrubber is not glass | `PlayerTransportGlyphSurface`, `PlayerPillSurface` |
| Tab view | Down (or a swipe down): the pills (Info, Chapters, Episodes, Stream Info) and the panel **slide up from the bottom edge in 230 ms**, with no transport bar, the pills' centre 592 pt above the bottom and the panel's top 514 pt above it; with the bar up, the bar's block goes up with them. Right moves the white highlight and crossfades the panel (0.3 s). Back, or Up on the pills, slides the block back down in 0.3 s and the layer lets go. The Info tab is a glass card (artwork, episode line, synopsis, runtime with HD / 4K, "From the Beginning"), the Chapters tab equal violet cards with a film-strip glyph and "Current" on the playing one | `MPVTransportFocusView`, `PlayerInfoSummaryTab`, `PlayerChaptersTab` |
| Play/Pause in the focus layer | Answered at once, wherever focus sits in the bar or a tab | `MPVTransportFocusView.onPlayPauseCommand`, `MPVPlaybackState.togglePlayPause` |
| Swipe down / up | Down: the tab view. Up with the bar showing: the transport buttons (the first one a pale cyan disc, the bar dimmed to 40 %); Up on the tab view's pills closes it | `handleSwipeDown`, `handleSwipeUp` |

Remote grammar, in the order Back closes layers: Up Next card, Stream Info, scrub (back to the original time),
hold (back to the freeze point), chrome (the bar alone included), exit.

### 4.1 The native engine's own pieces

The system transport bar is untouched. The app adds, through AVKit's hooks only: `externalMetadata` (title view,
Info), `customInfoViewControllers` (Episodes, Stream Info), `navigationMarkerGroups` (Chapters),
`transportBarCustomMenuItems` (Start Over, Sources, Playback Speed, Aspect Ratio, Subtitle Timing, Player
Engine), `contextualActions` (Skip Intro / Recap / Outro, Up Next), and the clock pill (Settings > Playback >
Player Interface), which both engines draw.

## 5. Not matched yet (open)

What is left is what the owner's recording cannot give (section 9.1) and what was not filmed.

| Item | Why |
|---|---|
| How far a swipe moves the head | The finger is never in the recording. `PlayerSpec.Scrub` gives the measured *outcome* of a quick flick (42 to 65 s in one to three frames and a glide of 10 to 15 s on a 22:35 file), as a share of the duration per width of the surface that grows with the swipe's speed; the slow end (fine control) is a guess. `[inferred]`; check by flicking on a device and comparing the head's travel with the system player's |
| The hold threshold | Where a click ends and a hold begins (0.45 s) is not readable from the picture, which only freezes once the hold is recognised. `[inferred]` |
| How long the bar alone stays up | At least 1.98 s after the last click; 5 s (the chrome's idle time) is assumed. A recording of a single click with the chrome away, on a stopwatch, settles it |
| The third back skip | Which clicks count as one run (here: less than 3 s apart) and whether the 11 depends on anything (here: constant; on a 22:35 file with the third click in a dialogue); whether the first two clicks of a run showed nothing on any file |
| The second touch | The time of day and finishing time on the labels (41.095 to 41.66 s) were seen once, with an ambiguous trigger; the clock capsule shows the finishing time instead |
| The skip arrow's turn | The glyph seems to turn once as it appears (18.2 to 18.3 s); mpv draws it still |
| Scrubbing thumbnails | None on the system player either (the recording shows no preview image) |
| Ring jog (fine scrub) | The silver remote's ring does not reach the app as a distinct input |
| Mute turns subtitles on; Siri "What did they say?" | System features; only AVPlayerViewController answers |
| The tab view opened from the full chrome | Not filmed (the owner opened it with the chrome away and closed it with Back): mpv grows it out of the bar and slides it back down, as the closing animation suggests |
| Moving inside a tab's content | No card was focused in the recording: the cards keep the focus lift the Episodes tab has |
| A hold while paused, during a scrub, or longer than 7.4 s | Not filmed. mpv scans from the head and stays paused after the release; a hold during a scrub steps it by 10 s; no tier above the third |
| The first touch while playing | Not filmed (the recording's only touch was on a paused player and on the full chrome): mpv shows the full chrome after 70 ms |
| The focused button's colour | A pale cyan disc over a red scene in the recording; it could be scene-dependent (glass), it is drawn the same on every scene |
| `AVPlayerViewController.speeds`, `nextContentProposal` on the native engine | Possible follow-ups; the app's menus and Up Next card are kept |
| Pause screen with synopsis (Apple TV app only) | Not part of `AVPlayerViewController` |

## 6. Calibrating on a device

The first calibration was done from the owner's phone recording instead (section 9): it gave the layout, every timing
and the hold's speeds. What the recording cannot give (section 5) still needs a session on a device, about an hour:

1. Developer pane (press Version in About seven times) > **System Player Probe** on, or the launch argument
   `-debug.playerSpecProbe YES`. Pick a file that plays on the native engine (an MKV, the Stream Info "Engine"
   row says Native).
2. With the console attached (Xcode), run the **remote script** and read the `[SpecProbe]` lines:
   1. Touch the surface once; wait. -> `transport bar SHOWN`, then `HIDDEN (x s after ...)`: the auto-hide delay.
   2. Click right, wait 1 s, click right, wait 6 s. -> the playhead jumps (+10, +20 from the first) and the bar
      timings after a skip.
   3. Click left three times. -> back-skip subtitles (the Subtitles tab shows them on).
   4. Hold right for 10 s; release. -> `rate` lines per tier, what a hold longer than 7.4 s does past the third
      tier, and the release (section 3.4).
   5. Pause; wait 30 s. -> the bar must not hide. Swipe to scrub; click center. -> the jump target.
   6. Pause, press Back, press Back. -> hide, then exit.
3. Sizes, fonts and the fade curve: HDMI capture at 60 fps (or screenshots at each state: playing, paused, +10,
   +20, scan 2x / 3x / 4x, scrubbing, Info, menus), then frame-step. The fade duration and curve can also be read
   from `willTransitionToVisibilityOfTransportBar`'s animation coordinator.
4. Put the numbers in `PlayerSpec` (its `Layout` holds the layout constants), the tags here from
   [MEASURE] to [observed: probe, date], and run the same remote script against an mpv file to diff.
5. The probe also prints the system player's view tree (`view tree, bar appearing / bar settled / after rate x`):
   class, frame, alpha, label text and font, image, running animations. Read the pause glyph, the skip hint and the
   fade off it when the controls are drawn in-process; an almost empty tree means they are not, and the capture in
   step 3 is the only source.

## 7. Verification, and what to check after a build

Checked without a device, with a Swift 6.2.3 toolchain on Linux and the app target's own compiler settings (Swift 5
mode, main-actor default isolation, approachable concurrency, member import visibility):

- The files that need no Apple framework compile as they are, and their 25 unit tests pass (`PlayerEngineRouterTests`,
  `PlayerSpecTests`, the Dolby Vision picker cases of `PlayerTuningTests`, the router's DEBUG self-check): the router,
  `PlayerEnginePreference`, `PlayerSpec`, `DolbyVisionMode`.
- The FFmpeg-facing files (`MediaProbe`, `AudioTranscoder`, `DoviRpuConverter`, `RemuxSession`, `SegmentMap`,
  `EmbeddedSubtitleSink`, `NativePlaybackMetrics`, `RemuxCacheJanitor`) type-check with no error against the exact FFmpeg
  headers of the MPVKit revision the submodule pins (`0.41.0-n8.1.2`, libavcodec 62.28, tvOS slice of the
  xcframeworks) and libdovi 3.3.2, so `av_packet_side_data_remove`, the `AVCodecParameters` fields and the AV1 and DOVI
  constants are the real ones. Only Linux stand-ins for Darwin-only API (Mach task info, `String(localized:)`) were
  needed.
- The FFmpeg build of that MPVKit revision (`--disable-encoders` then `aac`, `alac`, `flac`, `pcm*`; the audio decoders
  `aac* ac3* adpcm* alac* amr* ape cook dca dolby_e eac3* flac mp1* mp2* mp3* opus pcm* sonic truehd tta vorbis wma*`;
  no `mlp`) matches what `AudioTranscoder.isTranscodable` assumes.
- Every other changed file parses clean (tree-sitter); the string catalog is valid JSON in the file's own format with
  fr / de / es / it / vi for each new string.

`feature/mpv-native-ref` was written without Xcode. Every touched file parses clean with the Swift 6.4.1 compiler's own
parser on Linux (and in tree-sitter), line endings are kept (CRLF), the new strings are in the catalog with fr / de /
es / it / vi, and each symbol was checked by search. `PlayerSpec`, `MPVPlaybackState` (with stand-ins for the seven app
types it names and a `Published` / `ObservableObject` shim for Combine), `PlayerChromeFormat` and the 13 tests of
`PlayerSpecTests` were compiled there in Swift 5 mode with MainActor default isolation, as the app target is, and
all 13 pass: the hold's three tiers and clamps against the measured clock readings, the badge and digit, the state
slot's rules, the pause reveal, the label formats and the vertical stack of the rows. The CI build is the first
compile of the SwiftUI and UIKit files.

**Not compiled here** (no Xcode, no tvOS SDK): the files that import SwiftUI, AVFoundation, AVKit, UIKit, Combine,
libmpv or SharedCore - the CI build (`tvos-sim-build.yml`) is the first compile of those. Their symbols were checked
against the project's existing call sites one by one.

On the Apple TV, in this order:

1. Build and launch. Settings > Playback > Advanced > **Player** is there; Dolby Vision's "HDR10 Only" text reads
   "play as HDR10, their base layer".
2. An addon `.m3u8` stream, and a Jellyfin / Emby transcode: Stream Info says `Native · HLS direct`, the system
   player shows its own audio and subtitle menus; a stream that needs headers on its segments; a stream that
   cannot play falls back to mpv within 30 s.
3. A Dolby Vision Profile 8.1 file with HDR10 Only: no Dolby Vision badge on the TV, plain HDR10, native
   (`Native · DV P8 → HDR10`). A two-track Profile 7 file: native, HDR10.
4. An MKV whose only audio is MP3 or PCM: native, AAC in Stream Info.
5. HEVC 4:2:2 / 12-bit: mpv at once (no 45 s black). A 1080i file: mpv; with Prefer Native, native - does the picture
   comb? If not, drop the interlace rule.
6. A Blu-ray remux with PGS only, French preferred, no French addon file: mpv; with French addon subtitles
   installed: native.
7. mpv, against the owner's recording (section 9.5), one interaction at a time: pause (the picture freezes, the chrome
   follows 0.3 s later, bar and buttons first, title and pills after), a finger on the paused player (title, buttons and
   pills fade out, the knob grows), a flick (head jumps and glides, picture frozen, no knob, tick and lavender stretch, the
   label under the target), Select (the full chrome returns in a blink, hides 5 s later), +10 and -10 (arrow beside the
   centred time, the bar alone with the chrome away, nothing restarted with it up), three back skips in a row (the
   subtitles and the hint), a hold left and right (freeze, badge, head, tiers at 2.4 s and 4.8 s, digits 2 and 3, the
   spinner after the release), swipe down (the tab view slides up, order Info, Chapters, Episodes, Stream Info, a
   crossfade on each right swipe), Back (it slides back down), Up then the buttons (the pale cyan disc, the bar dims).
   Replace the `[inferred]` stand-ins that remain (the swipe's gain, the hold threshold, the bar alone's lifetime).
8. The transport buttons in Clear glass over bright and dark scenes; if illegible, Developer > Dark Player Glass is
   the previous look.
9. On an Apple TV 4K 4th generation: an AV1 file plays natively (`av01` signaling is untested).

## 8. Sources

- Apple: [AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller),
  [Customizing the tvOS playback experience](https://developer.apple.com/documentation/avkit/customizing-the-tvos-playback-experience),
  [Playing video (HIG)](https://developer.apple.com/design/human-interface-guidelines/playing-video),
  [Remotes (HIG)](https://developer.apple.com/design/human-interface-guidelines/remotes),
  [Materials (HIG)](https://developer.apple.com/design/human-interface-guidelines/materials),
  [Control video playback (tvOS 26)](https://support.apple.com/en-my/guide/tv/atvb7944597f/26/tvos/27),
  [tvOS 17 version](https://support.apple.com/en-la/guide/tv/atvb7944597f/17.0/tvos),
  [HLS authoring specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices),
  [Apple TV 4K specs](https://apple.com/uk/apple-tv-4k/specs) and
  [4th generation](https://www.apple.com/apple-tv-4k/specs/), the tvOS release notes.
- WWDC: [2016 s506 AVKit on tvOS](https://asciiwwdc.com/2016/sessions/506),
  [2017 s251](https://developer.apple.com/videos/play/wwdc2017/251/),
  [2019 s503](https://developer.apple.com/videos/play/wwdc2019/503/),
  [2021 s10191](https://developer.apple.com/videos/play/wwdc2021/10191/),
  [2025 s219 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/).
- Forums and press: developer forums threads
  [651497](https://developer.apple.com/forums/thread/651497),
  [651514](https://developer.apple.com/forums/thread/651514) (Apple staff),
  [758138](https://developer.apple.com/forums/thread/758138),
  [759210](https://developer.apple.com/forums/thread/759210) (Opus);
  [9to5Mac fast-forward guide](https://9to5mac.com/2021/05/24/how-to-fast-forward-and-rewind-on-apple-tv-remote/);
  [iDownloadBlog end-time labels](https://www.idownloadblog.com/2018/12/10/apple-tv-time-remaining-video-scrubber-howto/);
  [Cult of Mac scrubbing](https://www.cultofmac.com/420160/scrub-through-video-on-apple-tv-in-tvos-9-2/);
  [Six Colors](https://sixcolors.com/post/2025/06/tvos-26-brings-minor-additions-and-weird-priorities/);
  Firecore threads on [UI optimizations](https://community.firecore.com/t/infuse-tvos-player-ui-optimizations/21247),
  [skip with non-Siri remotes](https://community.firecore.com/t/skip-forward-back-10s-with-non-siri-remote/16861) and
  [Infuse 8.2.7](https://community.firecore.com/t/infuse-8-2-7-now-available/57570);
  [Plex time remaining](https://forums.plex.tv/t/time-remaining/711456);
  FFmpeg: [ticket 10642](https://trac.ffmpeg.org/ticket/10642) (no AV1 software decoder in VideoToolbox),
  [patchwork 67960](https://patchwork.ffmpeg.org/comment/67960/) (`VTRegisterSupplementalVideoDecoderIfAvailable`
  unavailable on tvOS); [Firecore: formats on Apple TV 4K](https://community.firecore.com/t/video-and-audio-formats-on-apple-tv-4k-2021/32482).
- The owner's recording of the system player (`IMG_5958.MOV`, 2026-10-16), measured in section 9.
- Pages that blocked the research fetch (403 / 404): AppleInsider hands-on and review, the MacRumors forum, VLC
  issue 515 (seen only through a search summary), the Plex 10-second-skip thread.

## 9. The owner's recording of the system player (2026-10-16)

### 9.1 What it is, and how it was read

The owner filmed the native engine with a phone: NuvioTV on an Apple TV 4K (tvOS 26 / 27, French interface), an SDR
episode of 22:35 ("Rick et Morty", S9 É6), `IMG_5958.MOV`, 69.26 s, 1920 x 1080, 3532 frames (33 ms apart for the first
8 s, 17 ms after). A first reading used contact sheets at 30 fps (one 33 ms tile each). Their digits are tiny, so every
number in sections 3 and 9 was read again from the video itself, at its own frame rate and at 4x to 8x on crops, frame
by frame around each event. The clock readings are good to +/- 1 s, the times to one frame, the speeds to +/- 15 %, the
sizes to +/- 5 %: the phone looked at the TV from an angle, so every size is the on-screen size divided by the screen's
own width (positions along each axis use that axis' own scale, from the screen's edges at that height).

What a recording cannot give: **the finger** (it is never in the picture: the swipe's gain, the hold threshold and the
click-versus-touch decision are unreadable), and anything not filmed (a plain Play press, Back with the chrome up while
playing, the tab view opened from the full chrome, a hold while paused, a hold longer than 7.4 s).

### 9.2 What the first reading got wrong, and what this one found

| Point | First reading | Now |
|---|---|---|
| The bar a skip click brings up | "Hides 1.8 s after the last click (27.6 s)" | The bar and its labels were still fully up at 29.52 s: the click at 25.8 s was followed by a fourth at 27.54 s, and the bar was camouflaged by a bright blue slab in the picture at the scene cut. It stays **at least 1.98 s** after the last click; its upper bound is unknown |
| After a hold's release | "The badge fades out in 3 to 4 frames" | The badge **turns into a small spinner** (51.75 s rewind, 61.47 s forward) that stays until the picture has changed: 1.05 s after the rewind, one frame after the forward |
| The pause glyph while scrubbing | "Visible right of the label on the plateau" | **Absent for the whole scrub** (twelve flicks, 6.567 to 15.6 s); it comes back with the knob's collapse (6.15 s) and with the commit's cascade |
| Bar colours while scrubbing | "The fill never moves; zones by whether the target is behind" | White up to the **nearer** of playhead and target, deeper lavender between the two, the pale track beyond, and the **tick on the farther** of the two (the fill does end at the target when it is behind the playhead) |
| Bar colour after a click | "Why does the fill turn lavender at 18.1 s?" | It does after the **first skip click** and stays until the bar hides (18.085 s); it is white again when the chrome returns |
| Elapsed label "stale" for 1.3 s | "Real native behaviour or a reading error?" | A reading error: the label is the whole second the picture is in, and a seek that lands on a whole second takes up to a second to change it. The two labels always add up to the length |
| Screen fractions | "Bar x 17.9 % to 95.2 %" and so on | Those were fractions of the phone's frame (the TV fills about 84 % of its width). Redone in points from the screen's edges: section 3.1 |
| Tab order | Info, Episodes, Chapters, Stream Info (in the code) | **Info, Chapters, Episodes, Stream Info** on the system player |
| Tab view closing | "About 22 % of the screen's height" | 49 % of the screen's height (a block of title, bar and pills, 0.3 s, ease-out) |
| The label "21:44" at 41.1 to 41.66 s, and the glyph after it | "Unknown" | A **second touch**: the labels become the time of day and the finishing time for about 0.6 s; the Play/Pause press follows (the picture froze at 41.6 s and played again at about 43.8 s) and the glyph is the pause ring |
| Focus on a button | "Filled cyan-white disc" | A pale cyan disc with a dark teal symbol, a quarter larger, the bar and labels dimmed to about 40 % |
| x1, x2, x4 | The owner expected "x1 x2 x4" | The badge shows **no digit, then "2", then "3"** (bare digits, left of the ring when rewinding and right of it when fast-forwarding): 8, 24 and 48 media seconds per second |

### 9.3 The evidence behind each constant

| `PlayerSpec` value | Measured |
|---|---|
| `Remote.scanRates` 8 / 24 / 48 | Rewind: 16:07 at 45.613 s, 15:53 at 47.415 s (7.8 s/s); 15:50 at 47.582 s to 15:03 at 49.582 s (23.5 s/s); 14:49 at 50.0 s to 13:33 at 51.6 s (48 s/s). Forward: 13:29 at 54.25 s; 14:47 at 59.0 s, 15:35 at 60.0 s, 16:40 at 61.4 s |
| `Remote.scanTierSec` 2.4 | Digit "2" at 47.53 s and 56.50 s, digit "3" at 49.93 s and 58.97 s (freeze 45.2 s and 54.0 s) |
| `Remote.scanStartDelaySec` 0.3, `scanBadgeDelaySec` 0.2 | Freeze 45.2 s, glyph 45.5 s, first label change 45.6 s; freeze 54.0 s, glyph 54.13 to 54.27 s, label 54.25 s |
| `Skip.glyphLifetimeSec` 0.35 | 18.085 to 18.468 s, 23.088 to 23.45 s, 62.825 to 63.099 s, 64.167 to 64.561 s |
| `Skip.subtitlesFromClick` 3, `subtitlesWindowSec` 11 | Clicks at 23.1, 24.5 and 25.8 s; subtitles at 26.033 s with the hint "Sous-titres activés pendant 11 secondes"; Stream Info reads "Français" at 36.0 s and "Désactivé" at 39.233 s |
| `Scrub.tailTimeConstantSec` 0.22, `tailShare`, `tailMaxShareOfDuration` | Flick at 6.5 s: 943 s at 6.485 s, 985 s at 6.618 s (+42 s in three frames), then 988, 990, 992, 994, 995, 996, 997, 998, 999 and 1000 s at one frame each up to 7.118 s (a tail of 15 s, 63 % of it in 0.2 s); flick at 8.6 s: 1094 s at 8.552 s, 1049 s at 8.652 s (-45 s in three frames), then 1047 down to 1039 s (a tail of -10 s) |
| `Scrub.touchReactionSec` 0.07, `knobDelaySec` 0.1 | First knob frame 4.450 s, parts fading from 4.517 s, gone 4.667 s; no knob in any of the twelve flicks |
| `Chrome.autoHideDelay` 5 | Commit 15.633 s, fade 20.637 to 20.770 s; click at 19.95 s did not restart it |
| `Chrome.pauseRevealDelaySec` 0.3 | Freeze 1.600 s, first chrome frame 1.883 s |
| `Layout.*` | Section 3.1; bar 12.5 px thick at rest and 16.5 px scrubbing on a 1620 px wide screen; buttons 55 px with a 75 px pitch; title cap height 33 px. The vertical stack is the capitals' centres over the screen's bottom edge, read in one frame (3.0 s) at the title's own column, 0.853 px per pt: title 212.5 px = 249 pt, episode line 266 px = 312 to 314 pt, bar 150.5 px = 177 pt, buttons 258 pt. The code stacks the pills' row (47 to 111 pt), 13 pt, the bar's row (124 to 188 pt), 37.5 pt, the buttons (bottom edge 225.5 pt), and drops the title block 10.5 pt under its bottom-aligned place so the title's capitals sit at 249 pt and the episode line's at 313.5 pt |

### 9.4 Reference timeline (condensed)

1.600 pause (freeze); 1.883 to 2.283 chrome cascade; 4.45 touch, knob; 6.1 finger lifts; 6.5 to 14.97 twelve flicks;
15.633 commit, full chrome; 18.085 +10 (glyph right, fill lavender); 20.637 chrome fades; 21.9 +10, the bar alone;
23.1, 24.5, 25.8 back skips, subtitles and hint at 26.03; 27.54 fourth back skip; 29.557 tab view in; 39.16 tab view
out; 41.1 second touch (clock labels), 41.6 pause, about 43.8 play; 45.2 to 51.7 rewind hold (tiers at 47.53 and
49.93); 51.75 spinner, 52.8 picture; 54.0 to 61.4 fast-forward hold (tiers at 56.5 and 58.97); 62.825 and 64.167 +10;
64.86 focus on the first button; 66.1 Select on the second (stream list); 67.7 Back.

### 9.5 Audit: what the system player does, what mpv did, what it does now

| Interaction | Native (measured) | mpv before | mpv after |
|---|---|---|---|
| Pause, chrome away | Picture freezes at once; chrome 0.283 s later, cascade: buttons and bar 130 ms, title and pills 0.27 s after; no slide | Chrome at once, one 0.3 s fade with a 16 pt slide, all parts together | Freeze at once, chrome after 0.3 s, the measured cascade, pure opacity |
| Pause glyph | Ring with two bars, 25 pt, 18 pt right of the centred elapsed time; away while a finger rests or a scrub runs | `pause.fill` bare, right of a left-aligned elapsed time, always while paused | Ring, same place, same rules |
| Elapsed / remaining | Elapsed centred under the head, remaining right-aligned at the bar's end, 25 pt semibold, two-digit minutes, adding up to the length | Elapsed at the bar's left end, 31 pt callout, one-digit minutes, remaining = length less the exact position | As measured |
| Bar | 15 pt capsule (21 pt active), white fill, pale lavender track, tinted fill after a click, no scrim | 6 pt capsule, white fill, 30 % white track, 4 x 22 pt head mark, black scrim under the chrome | As measured, no scrim |
| Title, buttons, pills | Title 57 pt bold, buttons 65 pt 89 pt apart, pills 64 pt glass, selected one white | Title 38 pt, buttons 66 pt 82 pt apart, pills plain text (white capsule only when focused) | As measured |
| Touch, paused | Parts fade out in 115 ms; knob (white disc, indigo ring) grows in 0.2 s on the head, labels 9 pt lower; collapses in 0.13 s | Nothing (the full chrome stayed) | As measured (after 70 ms, not on a click) |
| Swipe, paused | Head flicks 42 to 65 s in 1 to 3 frames, glides on (tau 0.2 s); picture frozen; no knob, no preview; bar zones and a tick; label under the target | Head moves at 1/8 s per point x1, x3 or x8, no glide, a time bubble above a second head | Gain by swipe speed (a share of the duration), glide tau 0.22 s, zones and tick, label under the target |
| Select after a scrub | Seek and play; chrome back in 167 ms; hides 5.0 s later | Seek and play; chrome 4 s | Seek and play; 167 ms cascade; 5 s |
| +/-10 s click | Label jumps in the frame the glyph appears; circular arrow right (forward) or left (back), 0.35 s; no total | "+10 ›" text, running total "+20", "+30", 4 s plus a 0.3 s fade | Arrow glyph, side by direction, 0.35 s, no total |
| +/-10 s, chrome away | The bar alone fades in over 115 ms; no title, buttons, pills or clock; up at least 1.98 s after the last click | The full chrome for 4 s | The bar alone, hides 5 s after the last click |
| +/-10 s, chrome up | Chrome's timer not restarted (hid 0.72 s after a click) | Timer restarted | Not restarted |
| Third back skip | Subtitles on 0.23 s later, "Subtitles on for 11 seconds" under the remaining time, off after 11 s | Subtitles on at the first back skip until the playhead was back | Third of a run, 11 s window, the hint |
| Hold | Freeze; badge at +0.2 s; head from +0.3 s; 8 / 24 / 48 s/s, tiers every 2.4 s; digit none / 2 / 3; picture frozen; chrome stays | 2x then 3x, 4x by more presses, rewind by 4 keyframe seeks a second (the picture moved), forward on mpv's speed, muted; kept going after the release | As measured; stops with the finger |
| Release of a hold | Head stops, badge becomes a spinner until the picture is back (1.07 s rewind), then 1x | No release step (it kept running) | One exact seek, spinner, resume |
| Auto-hide | 5.0 s, fade 150 ms, no slide | 4 s, 0.3 s fade with a 16 pt slide | 5 s, 150 ms, opacity |
| Tab view | Pills and panel slide up from the bottom in 230 ms, no bar; order Info, Chapters, Episodes, Stream Info; panel crossfade 0.3 s; Back slides the block down 49 % in 0.3 s; captions to the top quarter | Panel under the bar at the bottom edge, dark scrim, order Info, Episodes, Chapters, Stream Info | As measured |
| Info tab | One glass card with artwork, episode line, synopsis, runtime + HD, "From the Beginning" | Artwork, title, genres, synopsis on the bare picture | Glass card as measured |
| Chapters tab | Equal violet cards, film glyph, no picture, "EN COURS" on the current | Cards with artwork crops and start times | Cards as measured |
| Focused button | Pale cyan disc, a quarter larger, bar dims to 40 % | White disc, black symbol | Pale cyan disc, bar dims |
| Skip chip, contextual actions | System buttons, bottom-trailing | unchanged | unchanged |

### 9.6 Still unmeasured

See section 5. In short: the swipe's gain (the finger), the hold threshold, how long the bar alone stays up beyond 1.98 s,
whether the skip arrow turns once as it appears, the clock-labels toggle's trigger, the tab view opened from the full
chrome, a hold while paused or during a scrub, and a hold longer than 7.4 s.
