<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/nuviotv-dark.svg">
  <img alt="NuvioTV — Nuvio, made for Apple TV" src=".github/assets/nuviotv-light.svg" width="100%">
</picture>

<p align="center">
  <a href="../../releases"><img alt="Latest build" src="https://img.shields.io/github/v/release/esalwey/NuvioTV?include_prereleases&label=build&style=flat-square&color=2f6bff"></a>
  <img alt="tvOS 26+" src="https://img.shields.io/badge/tvOS-26%2B-000?style=flat-square&logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/SwiftUI-native-f05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-555?style=flat-square"></a>
</p>

Native Apple TV (tvOS 26+) version of [Nuvio](https://github.com/NuvioMedia/NuvioMobile): a media hub built on the Stremio add-on ecosystem, with a SwiftUI interface designed for the Siri Remote and a shared Kotlin Multiplatform core.

> **Unofficial community port.** This project is not affiliated with the Nuvio team. Please report NuvioTV bugs here, not upstream.

## Install

NuvioTV is not on the App Store. It is sideloaded with a free Apple ID and kept installed by **tvsign**, which signs the app and reinstalls it on your Apple TV before the 7-day free-account limit:

- **Windows:** tvsign desktop app (installer, starts with Windows).
- **NAS / Raspberry Pi / home server:** tvsign Docker image, running 24/7.

```mermaid
flowchart LR
  A["GitHub Actions<br/>builds NuvioTV.ipa"] --> B["tvsign<br/>(Windows app or Docker)"]
  B -- "free Apple ID<br/>signs" --> C["Signed IPA"]
  C -- "Wi-Fi install,<br/>renewed before day 7" --> D["Apple TV"]
```

Each release on the [Releases](../../releases) page carries an unsigned `NuvioTV.ipa` built by GitHub Actions.

Requirements: Apple TV 4K (any generation) or Apple TV HD on tvOS 26 or later, on the same local network as the machine running tvsign.

## What differs from upstream

- Native SwiftUI tvOS app (`iosApp/NuvioTV`) using the system sidebar, search, focus effects and transport bar.
- Two playback engines: AVPlayer for files tvOS plays natively (HDR, Dolby Vision, frame-rate matching) and mpv for everything else.
- Dolby Atmos from TrueHD Atmos and DTS:X tracks on the AVPlayer engine: the track is converted on the Apple TV to Apple Positional Audio Codec (APAC 7.1.4) with its height channels, and the receiver switches to Atmos. Plain TrueHD and DTS-HD MA play as lossless FLAC 5.1 / 7.1 instead of AAC 5.1. Both are switches in Settings > Playback > Audio.
- Siri Remote handling: layered Back, swipe scrubbing, ±10 s clicks, hold to fast-forward, Up Next.
- Audio and subtitle language preferences remembered per show, with readable track names.
- Full French localization.

## Building

The app builds off-Mac on GitHub Actions (`.github/workflows/tvos-device-ipa.yml`). With a Mac and Xcode 26+, open `iosApp/iosApp.xcodeproj` and build the `NuvioTV` scheme; the shared Kotlin framework is built by Gradle during the Xcode build.

## Credits and license

- [Nuvio](https://github.com/NuvioMedia/NuvioMobile) by the Nuvio team: the app, shared core and brand.
- [youngchris29-art](https://github.com/youngchris29-art/NuvioMobile): original native tvOS port this project continues.
- [MPVKit](https://github.com/mpvkit/MPVKit) and mpv for the playback engine.
- [SpatialAudioBridge](https://github.com/kristofferR/SpatialAudioBridge) by kristofferR (Apache-2.0): decodes TrueHD Atmos and DTS:X, renders their objects to 7.1.4 and encodes APAC for Dolby Atmos output. It bundles the [truehdd](https://github.com/truehdd/truehdd), [dca](https://github.com/harletty/harletty-bridge/tree/a717bae441b116485f0254603dc20a6ede65d8c6/dca) and [oamd](https://github.com/truehdd/oamd) decoders and other Rust components; their licenses are listed in the app under Settings > About > Licenses & Attributions.

Licensed under the GNU General Public License v3.0, like upstream Nuvio. See [LICENSE](LICENSE). The upstream README is kept in [README.upstream.md](README.upstream.md).
