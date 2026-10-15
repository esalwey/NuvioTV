# Player spec: the system player, and how NuvioTV matches it

Written 2026-10-15 for `feature/native-first` (from `main`, release 1.0.0). It is the reference the
code is checked against: when a value in `PlayerSpec`, the router or the mpv chrome changes, this
document changes with it, and the other way round.

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
   is a stand-in tagged `[MEASURE]`, kept in one file (`PlayerSpec`), and a probe on the native engine
   measures it (section 6).

## 0. Source tags

| Tag | Meaning |
|---|---|
| **[doc]** | Apple documentation: AVKit, the HIG, the Apple TV user guide (support.apple.com) |
| **[WWDC]** | An Apple session or sample |
| **[observed]** | A third-party or user observation (URL in section 7). Includes an Apple engineer answering on the developer forums |
| **[inferred]** | Reasoned from the above, or from what the native engine shows on a device |
| **[MEASURE]** | Nothing public gives a value. It has to be measured on an Apple TV; the stand-in in the code is not a fact |
| **[app]** | An app mechanism or rule, not something the system player does |

Research finding that shapes everything below: **no public source gives pixel sizes, durations or easing
curves for the tvOS 26 / 27 transport UI.** Apple docs, the HIG, WWDC 2016-2025, the release notes, the
press and the forums were searched. Every number tagged [inferred] or [MEASURE] is a hypothesis, not a
measurement.

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
- Risks to check on a device: addon headers on segment requests, segments with unusual MIME types (AVPlayer is
  strict), live streams.

### 2.6 Audio

- Copied: AAC, AC-3, E-AC-3, FLAC, ALAC. **MP3 is no longer copied**: Apple's HLS authoring spec lists no MP3
  for fMP4 (2.2, 2.5); it is decoded and re-encoded to AAC like the rest.
- Transcoded to AAC (5.1 for 6+ channels, stereo, mono): TrueHD, DTS, Opus, Vorbis, and now **every codec
  libavcodec has a decoder for** (PCM including Blu-ray PCM, MP2, MP3, WMA, AMR ...), minus MLP. The probe asks
  libavcodec (`AudioStreamInfo.decodable`); the remux uses the same predicate
  (`AudioTranscoder.isTranscodable`).

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
| ALAC instead of AAC for lossless multichannel (TrueHD, DTS-HD MA, PCM) | Not built. These files are already native; this is audio quality, not routing. The encoder question is settled: MPVKit's FFmpeg is configured with `--disable-encoders` and then `--enable-encoder=aac`, `alac`, `flac`, `pcm*` (MPVKit `Sources/BuildScripts/XCFrameworkBuild/main.swift`, the revision the submodule pins), and FFmpeg's ALAC encoder takes mono up to 7.1 in fixed channel layouts and 16 / 24-bit planar integers. What is left is the transcoder's encoder choice and layout mapping, the `alac` CODECS signaling for a transcoded track, and a device test that AVPlayer plays ALAC 5.1 / 7.1 from fMP4 HLS (it is in the HLS authoring spec, 2.5) |
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

| Element | Spec | Tag |
|---|---|---|
| Safe area | 90 pt left / right, 60 pt top / bottom on a 1920 x 1080 pt canvas | [WWDC19 211] |
| Structure | A **title view** above the transport bar. **Controls** (subtitles, audio, PiP, custom items) on the bar's trailing side. **Content tabs** (Info, Chapters, custom) below | [doc: Customizing the tvOS playback experience; WWDC21] |
| Title view | The item's title and subtitle (`commonIdentifierTitle`, `iTunesMetadataTrackSubTitle`); live streams add a state badge | [doc] |
| Scrubber row | Elapsed time on the left, remaining on the right in the negative format (`-1:12:00`). The playhead is a knob | [observed: Plex forum 711456; knob form inferred] |
| Order | Title above the controls row above the scrubber; the title large and bold on the leading edge, the buttons glass circles on the trailing edge | [inferred] |
| Contextual actions (Skip Intro, Recap) | Bottom-trailing of the screen, focusable glass buttons | [doc] |
| Glass | Clear variant over video; AVKit supplies its own dimming layer; buttons brighten and darken as the white time text passes behind them | [doc: HIG Materials; observed: AppleInsider, kodi.expert] |
| Scrubber | Not glass. Thin; the playhead reads poorly over motion | [observed: Firecore, Six Colors] |
| Sizes: scrubber thickness, knob, button diameter, spacing, title font, bottom gradient height | | [MEASURE] |

### 3.2 Pause and resume

| Event | Reaction | Tag |
|---|---|---|
| Play/Pause or center click while playing | Playback stops and the transport UI appears with elapsed time, remaining time and the other options | [doc: support.apple.com/guide/tv/atvb7944597f/26/tvos/27] |
| Persistence | The UI stays until the viewer acts. It does **not** auto-hide while paused (Infuse's "about 2 seconds" is Infuse's own) | [inferred] |
| Glyph | **No big centred pause icon.** The state is shown in the bar; a scan shows its glyph and a speed number there | [inferred; scan glyph and number: observed 9to5Mac] |
| Thumbnail | A preview thumbnail above the timeline while scrubbing; the tvOS 17 page says "Pausing shows elapsed and remaining time" | [doc] |
| Resume | Play/Pause or a center click: the UI hides after the usual delay | [doc] |
| Back while paused | Hides the controls; does not exit | [doc: "Hide: press Back or Menu"] |
| Subtitles while paused | A subtitle can stay on screen above the bar | [observed: Firecore] |

### 3.3 Skip: click left / right

| Item | Spec | Tag |
|---|---|---|
| Input | A click on the left or right edge of the touch surface or ring skips 10 s; press again to skip another 10 | [doc] |
| Quick press / long press | A quick press skips, a long press scans (tvOS 14.3 and later) | [observed: Firecore 16861] |
| Hint | A skip hint labelled "+10 ›" (chevron plus the number, mirrored for back). "There's no way to disable the skipping hint" | [observed: Apple staff, forums 651514] |
| Bar | The full transport UI appears and stays "roughly 3 to 4 seconds" on a single skip | [observed: Firecore 21247] |
| Accumulation | +10, +20, +30 on repeated clicks, each a real seek | [inferred; "skim in ten-second increments" observed: 9to5Mac] |
| Running total reset, bar timer reset | | [MEASURE] |
| Back skip | "Skipping back 10 seconds turns subtitles on automatically so you can rewatch that section"; pressing left up to three times (10 to 30 s) turns them on for that window | [doc] |
| Target | Exactly current time ± 10 s; the play / pause state is kept (a skip while paused leaves it paused) | [inferred] |
| Delegate | `timeToSeekAfterUserNavigatedFrom` fires for ±10 but not for scans; `requiresLinearPlayback` is the only way to disable ±10 | [observed: Apple staff, forums 651497] |

### 3.4 Scan: hold left / right

Press and hold starts scanning at 2x; press repeatedly to cycle 2x, 3x, 4x. Release does not stop it;
Play/Pause or a center click returns to 1x. A speed number is added to the bar with the scan glyph
[doc; observed: 9to5Mac]. Sound is muted [inferred]. What a press beyond 4x does is [MEASURE].

### 3.5 Scrub

Pause, then swipe on the clickpad or touch surface: a preview thumbnail appears above the timeline [doc]. The
ring gives finer control (fine precision within about a second since tvOS 12.3) [WWDC19 503]. Play/Pause or a
center click plays from the new position; Back or Menu cancels and returns to the original position [doc]. A
press before swiping activates scrubbing mode [doc: HIG Remotes]. The time bubble's format and whether it is
elapsed or target time are [MEASURE].

### 3.6 Show and hide the chrome

| Input | Reaction | Tag |
|---|---|---|
| Rest a finger on the touch surface, or press up on the ring | Shows the controls | [doc] |
| First touch while playing | Elapsed on the left, remaining on the right | [observed: iDownloadBlog] |
| Second touch | The right label becomes the estimated finish time, the left the clock time | [observed: iDownloadBlog; Firecore reports the reverse order: verify] |
| Auto-hide while playing | "A few seconds" after the last interaction (3 to 4 s); exact value | [observed: Firecore] / [MEASURE] |
| Hide manually | Back or Menu | [doc] |
| Animation | Fade with a slide of the bottom group; `willTransitionToVisibilityOfTransportBar` exposes the change | [doc for the callback, the rest inferred] |

### 3.7 Other remote reactions

| Input | Playing | Paused | Scrubbing | Menus open |
|---|---|---|---|---|
| Swipe down | Info (tab row) | same | cancels? | n/a |
| Swipe up | Focus the transport buttons | same | | |
| Click center | Pause | Resume | Commit the scrub | Activate the focused item |
| Click left / right | ±10 | ±10 (stays paused) | Step the scrub | Move focus |
| Back / Menu | Hides the chrome if visible, exits if hidden | Hides the chrome | Cancels the scrub | Closes the menu or panel |
| Back, long press | Home Screen | | | |
| Mute (silver remote) | If audio is muted, subtitles turn on | | | |

[doc for each; "exits when hidden" inferred]. Siri: "skip ahead 15 seconds", "What did they say?" (enables captions
and rewinds), pause [doc]. Only the system player answers these.

### 3.8 Menus, tabs, panels

- Transport bar buttons: Subtitles, Audio Options, Picture in Picture, Speed (tvOS 16+, `speeds`), plus custom
  items [doc]. Audio options: Enhance Dialogue, Reduce Loud Sounds, Audio Track [doc]. Menus are `UIMenu` popups
  with checkmarks [doc sample].
- Content tabs: Info (needs metadata), Chapters (`navigationMarkerGroups`), custom (`customInfoViewControllers`)
  [doc]. Contextual actions bottom-trailing [doc]. Up Next: the video shrinks to a window and the proposal sits
  lower right [doc, WWDC16 506].

### 3.9 Loading, buffering, end

A spinner appears over the video, the transport bar can still be shown (style [MEASURE]). The player does not
dismiss itself at the end; the app decides [doc: HIG Playing video]. Resume automatically, without a prompt
[doc]. An interactive overlay waits a 0.5 s minimum after a pause [doc: HIG].

### 3.10 Timings

| Item | Value | Tag |
|---|---|---|
| Chrome fade in / out | about 0.25 to 0.35 s | [inferred] |
| Auto-hide while playing | 3 to 5 s (3 to 4 s quoted) | [observed], [MEASURE] |
| Skip hint persistence | tied to the chrome's auto-hide | [inferred] |
| Focus lift on glass buttons | spring | [inferred] |

## 4. What the mpv chrome does (implementation)

Constants live in `Player/PlayerSpec.swift`; the behaviours in the files named. `[MEASURE]` rows are the
stand-ins to replace after section 6.

| Spec item | mpv chrome | Where |
|---|---|---|
| No centred pause or skip glyph | The old arrow-with-seconds glyph at the picture's edge (`PlayerSkipIndicator`, 120 pt, 900 ms: invented, no source) is **gone**. Pause, scan and skip are drawn in the bar's state slot only | `MPVPlayerOverlays.swift` (`stateSlot`) |
| State slot | Right after the elapsed time (so the labels do not move): skip hint, else scan glyph + `2x` / `3x` / `4x`, else `pause.fill`; nothing while playing | `PlayerTransportBar.stateSlot` |
| Pause | The bar stays until the viewer acts; Back hides it, the next Back exits; any input shows it again | `MPVPlaybackState.pauseChromeShown`, `MPVPlayerView+Remote` `menuPressed` |
| ±10 s | One **exact absolute seek** to current time ± 10 s (from the freshest position, so clicks in a row add up exactly), the head and the time **jump at once** (they used to wait for the core's position events, held back up to 2 s during a seek), play / pause state kept | `skip(by:)` |
| Skip hint | "+10 ›" / "‹ -10", the clicks in a row added (`+10`, `+20`, `+30`), up for `PlayerSpec.Chrome.skipHintLifetime` (= the auto-hide) after the last click, then the total starts over; the opposite direction starts over at once | `showSkipHint`, `SkipHint` |
| Back skip | Subtitles the language plan would pick are turned on for the replayed section when none is showing, and go off when the playhead is back at the first click's position. Nothing is saved; any pick of the viewer's ends it | `beginRewindSubtitles`, `endRewindSubtitlesIfDue` |
| Click vs hold | The click acts on release; a press of `holdThresholdSec` (0.45 s) is a hold | `arrowPressBegan` |
| Scan | 2x, then 3x, 4x on further presses of the same edge; the opposite edge, Select, Play/Pause or Back return to 1x; muted; rewind and any scan from a pause walk the head by timer (`scanStepIntervalSec`) with keyframe seeks | `startOrStepRate`, `rateStepTick` |
| Scrub | Pause, then swipe (about 1 s per 8 pt, accelerating with speed); a time label over the head; Select / Play/Pause commits one exact seek, Back cancels with no seek issued. **No thumbnail**: the native engine has none either (no I-frame playlist), and mpv would need a second decoder | `handleTransportPan`, `commitScrub`, `cancelScrub` |
| Show / hide | Resting a finger shows the bar; Up shows it, the next Up focuses the buttons; it hides `autoHideDelay` (4 s) after the last interaction while playing, never while paused, scrubbing or scanning | `flashControls`, `PlayerSpec.Chrome.autoHideDelay` |
| Animation | Fade (`fadeDuration` 0.3 s, ease in-out) with a `slideOffset` (16 pt) slide of the bar; the slide is dropped under Reduce Motion | `MPVPlayerScreen.body` |
| Captions | While the bar is up the captions glide up above it (`sub-pos`, `chromeClearancePercent` 27 %) and back down over the bar's own fade (`fadeDuration`, 8 steps), as AVPlayer lifts its captions with the system bar. The 27 % is [inferred] from the bar's height; the distance is [MEASURE] | `setSubtitleChromeLift` |
| Glass | The transport buttons wear the **Clear** variant of Liquid Glass (`PlayerChipStyle.transportGlass`) over the bar's own shade; Developer > "Dark Player Glass" brings the tinted regular glass back for an A/B. The scrubber is not glass | `PlayerTransportGlyphSurface` |
| Play/Pause in the focus layer | Answered at once, wherever focus sits in the bar or a tab (it used to depend on the press bubbling up or on a debounced Now Playing command) | `MPVTransportFocusView.onPlayPauseCommand`, `MPVPlaybackState.togglePlayPause` |
| Swipe down / up | Down: the content tabs (Info, Episodes, Chapters, Stream Info). Up with the bar showing: the transport buttons | `handleSwipeDown`, `handleSwipeUp` |

Remote grammar, in the order Back closes layers: Up Next card, Stream Info, scrub (back to the original time),
scan, chrome, exit.

### 4.1 The native engine's own pieces

The system transport bar is untouched. The app adds, through AVKit's hooks only: `externalMetadata` (title view,
Info), `customInfoViewControllers` (Episodes, Stream Info), `navigationMarkerGroups` (Chapters),
`transportBarCustomMenuItems` (Start Over, Sources, Playback Speed, Aspect Ratio, Subtitle Timing, Player
Engine), `contextualActions` (Skip Intro / Recap / Outro, Up Next), and the clock pill (Settings > Playback >
Player Interface), which both engines draw.

## 5. Not matched yet (open)

| Item | Why |
|---|---|
| Sizes, fonts, spacing, gradient height of the bar | [MEASURE]. The values in the code are from earlier tuning on a device, not a measurement |
| Where exactly the skip hint and the scan glyph sit | [MEASURE]; the state slot is the stand-in |
| Skip running-total reset, bar timer reset, scan beyond 4x, scrub time bubble | [MEASURE] |
| The second touch that turns the labels into clock time and end time | [observed] on tvOS 12 only and ambiguous (a tap and a click both touch the pad); the clock pill shows the end time instead |
| Scrubbing thumbnails | Needs a second decoder on mpv; the native engine has no trick-play playlist either |
| Ring jog (fine scrub) | The silver remote's ring does not reach the app as a distinct input |
| Mute turns subtitles on; Siri "What did they say?" | System features; only AVPlayerViewController answers |
| `AVPlayerViewController.speeds`, `nextContentProposal` on the native engine | Possible follow-ups; the app's menus and Up Next card are kept |
| Pause screen with synopsis (Apple TV app only) | Not part of `AVPlayerViewController` |

## 6. Calibrating on a device

One session, about an hour, replaces the [MEASURE] stand-ins:

1. Developer pane (press Version in About seven times) > **System Player Probe** on, or the launch argument
   `-debug.playerSpecProbe YES`. Pick a file that plays on the native engine (an MKV, the Stream Info "Engine"
   row says Native).
2. With the console attached (Xcode), run the **remote script** and read the `[SpecProbe]` lines:
   1. Touch the surface once; wait. -> `transport bar SHOWN`, then `HIDDEN (x s after ...)`: the auto-hide delay.
   2. Click right, wait 1 s, click right, wait 6 s. -> the playhead jumps (+10, +20 from the first) and the bar
      timings after a skip.
   3. Click left three times. -> back-skip subtitles (the Subtitles tab shows them on).
   4. Hold right; release; press right again twice; then the opposite edge. -> `rate` lines: 2, 3, 4, then what a
      further press does, then the return.
   5. Pause; wait 30 s. -> the bar must not hide. Swipe to scrub; click center. -> the jump target.
   6. Pause, press Back, press Back. -> hide, then exit.
3. Sizes, fonts and the fade curve: HDMI capture at 60 fps (or screenshots at each state: playing, paused, +10,
   +20, scan 2x / 3x / 4x, scrubbing, Info, menus), then frame-step. The fade duration and curve can also be read
   from `willTransitionToVisibilityOfTransportBar`'s animation coordinator.
4. Put the numbers in `PlayerSpec` (and the layout constants in `PlayerChromeLayout`), the tags here from
   [MEASURE] to [observed: probe, date], and run the same remote script against an mpv file to diff.

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
7. mpv, against the native engine with the probe on (section 6): pause (the bar stays, only the state slot
   changes), +10 (head jumps, `+10 >` then `+20 >`), back-skip subtitles, the 3 to 4 s auto-hide, scan 2x / 3x /
   4x, scrub, Back order. Replace the [MEASURE] stand-ins.
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
- Pages that blocked the research fetch (403 / 404): AppleInsider hands-on and review, the MacRumors forum, VLC
  issue 515 (seen only through a search summary), the Plex 10-second-skip thread.
