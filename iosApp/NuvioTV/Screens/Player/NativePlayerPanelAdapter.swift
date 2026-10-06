import AVFoundation
import Combine
import SharedCore
import SwiftUI

/// Feeds the swipe-down top panel from the native AVPlayer path: media-selection groups →
/// Subtitles/Audio rows, playback ticks → Info rows/chips, AVAudioSession → output route name.
/// Panel picks go straight back to `NativePlaybackCoordinator.select(...)`, which uses the same
/// `AVPlayerItem.select(_:in:)` path as the native transport-bar popovers, so both UIs stay in step.
@MainActor
final class NativePlayerPanelAdapter {
    private let coordinator: NativePlaybackCoordinator
    private let model: PlayerTopPanelModel
    private let context: PlaybackContext
    private let routingNote: String?
    private var cancellables: Set<AnyCancellable> = []
    private var routeObserver: NSObjectProtocol?

    init(coordinator: NativePlaybackCoordinator, model: PlayerTopPanelModel,
         context: PlaybackContext, routingNote: String?) {
        self.coordinator = coordinator
        self.model = model
        self.context = context
        self.routingNote = routingNote

        // The native engine has the system Audio button (Enhance Dialogue, Reduce Loud Sounds):
        // the Audio tab points to it (VIS-07, contract C5).
        model.showsSystemAudioHint = true
        model.onSelectSubtitle = { [weak self] option in self?.selectSubtitle(option) }
        model.onSelectAudio = { [weak self] option in self?.selectAudio(option) }
        // Subtitle delay (B3): the native engine re-times the addon WebVTT renditions it serves
        // itself. `supportsSubtitleDelay` is re-derived per selection in `rebuildSelections` — only
        // an addon rendition can be re-timed.
        model.subtitleDelayMs = coordinator.subtitleDelayMs
        model.onSubtitleDelayChange = { [weak self] ms in self?.coordinator.setSubtitleDelay(ms: ms) }
        coordinator.$subtitleDelayMs
            .receive(on: RunLoop.main)
            .sink { [weak model] ms in if model?.subtitleDelayMs != ms { model?.subtitleDelayMs = ms } }
            .store(in: &cancellables)

        Publishers.Merge5(
            coordinator.$legibleGroup.map { _ in () }.eraseToAnyPublisher(),
            coordinator.$audibleGroup.map { _ in () }.eraseToAnyPublisher(),
            coordinator.$selectionVersion.map { _ in () }.eraseToAnyPublisher(),
            coordinator.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            coordinator.$lateAddonSubtitleCount.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildSelections() }
        .store(in: &cancellables)

        refreshRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRoute() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// Called from the coordinator's tick: refresh the Info tab and re-derive the checkmarks (the
    /// media-selection notification is not reliable everywhere).
    func onTick() {
        let rows = coordinator.streamInfoRows(routingNote: routingNote)
        var dynamic = coordinator.infoChips()
        // The catalog runtime stands in until the player reports a real duration.
        if !dynamic.contains(where: { $0.isRuntime }), let runtime = context.meta?.runtime {
            dynamic.insert(PlayerPanelChip(text: runtime, isRuntime: true), at: 0)
        }
        let chips = staticLeadingChips + dynamic + staticTrailingChips
        if model.info.rows != rows { model.info.rows = rows }
        if model.info.chips != chips { model.info.chips = chips }
        rebuildSelections()
    }

    // MARK: - Selections

    private func rebuildSelections() {
        // Subtitles: Off, embedded (rendition order), addon (rendition order).
        var subtitles: [PlayerPanelOption] = []
        if let group = coordinator.legibleGroup {
            let selected = coordinator.currentSubtitleOption
            // A delay change moves the selection to a twin slot of the same rendition — compare the
            // canonical name so the checkmark stays on the row the viewer picked.
            let selectedName = selected.map {
                NativePlaybackCoordinator.canonicalSubtitleName(NativePlaybackCoordinator.renditionName(of: $0))
            }
            subtitles.append(PlayerPanelOption(id: "off", title: String(localized: "Off"), group: .off,
                                               isSelected: selected == nil))
            let options = group.options
                // The master publishes each addon rendition under several interchangeable delay
                // slots (B3 re-timing); only slot 0 is a real menu entry.
                .filter { NativePlaybackCoordinator.subtitleSlot(ofName: NativePlaybackCoordinator.renditionName(of: $0)) == 0 }
                .filter { coordinator.subtitleOptionAllowed($0) }
                .map { option -> (AVMediaSelectionOption, SubtitleRendition?) in
                    (option, coordinator.subtitleRenditionsByName[
                        NativePlaybackCoordinator.canonicalSubtitleName(NativePlaybackCoordinator.renditionName(of: option))])
                }
                .sorted { a, b in (a.1?.index ?? Int.max) < (b.1?.index ?? Int.max) }
            for (option, rendition) in options {
                let name = NativePlaybackCoordinator.canonicalSubtitleName(NativePlaybackCoordinator.renditionName(of: option))
                var details: [String] = []
                if rendition?.forced == true || option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
                    details.append(String(localized: "Forced"))
                }
                if rendition?.hearingImpaired == true || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) {
                    details.append("SDH")
                }
                subtitles.append(PlayerPanelOption(
                    id: name, title: name,
                    detail: details.isEmpty ? nil : details.joined(separator: " · "),
                    language: rendition?.language ?? option.extendedLanguageTag,
                    group: rendition?.isEmbedded == true ? .embedded : .addon,
                    isSelected: selectedName == name))
            }
        }
        if model.subtitles != subtitles { model.subtitles = subtitles }
        // The Timing row is only meaningful for a showing ADDON rendition: the whole file is ours to
        // re-serve. Embedded text tracks are per-segment VTTs the remux writes as it goes and are not
        // re-timed (B3), and with subtitles Off there is nothing to shift.
        // During the coordinator's own Off→restore refetch hop the selection is transiently nil;
        // keep the row mounted so the focused chip survives consecutive presses.
        let canRetime = subtitles.contains { $0.isSelected && $0.group == .addon }
            || (coordinator.isRefetchingSubtitles && model.supportsSubtitleDelay)
        if model.supportsSubtitleDelay != canRetime { model.supportsSubtitleDelay = canRetime }
        // The master is rendered once, at playback start: a search still running after that can't
        // add rows, so the panel never shows a spinner past it (LANG-08). Late arrivals are counted.
        let searching = !coordinator.addonSubtitlesFetched && coordinator.phase == .preparing
        if model.subtitlesSearching != searching { model.subtitlesSearching = searching }
        let late = coordinator.lateAddonSubtitleCount
        if model.lateAddonSubtitleCount != late { model.lateAddonSubtitleCount = late }

        // Audio: every audible option; the title is the rendition NAME ("English · TrueHD 7.1").
        var audio: [PlayerPanelOption] = []
        if let group = coordinator.audibleGroup {
            let selected = coordinator.currentAudioOption
            for option in group.options {
                let name = NativePlaybackCoordinator.renditionName(of: option)
                audio.append(PlayerPanelOption(id: name, title: name, group: .audio,
                                               isSelected: selected.map { $0 == option } ?? false))
            }
        }
        if model.audio != audio { model.audio = audio }
    }

    private func selectSubtitle(_ option: PlayerPanelOption?) {
        guard let option else { coordinator.select(subtitle: nil); return }
        guard let group = coordinator.legibleGroup,
              let target = group.options.first(where: {
                  let name = NativePlaybackCoordinator.renditionName(of: $0)
                  return NativePlaybackCoordinator.subtitleSlot(ofName: name) == 0
                      && NativePlaybackCoordinator.canonicalSubtitleName(name) == option.id
              })
        else { return }
        coordinator.select(subtitle: target)
    }

    private func selectAudio(_ option: PlayerPanelOption) {
        guard let group = coordinator.audibleGroup,
              let target = group.options.first(where: { NativePlaybackCoordinator.renditionName(of: $0) == option.id })
        else { return }
        coordinator.select(audio: target)
    }

    // MARK: - Route

    private func refreshRoute() {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).filter { !$0.isEmpty }
        let name = names.isEmpty ? "Apple TV" : names.joined(separator: ", ")
        if model.outputRouteName != name { model.outputRouteName = name }
    }

    // MARK: - Static chips (from the PlaybackContext)

    private var staticLeadingChips: [PlayerPanelChip] {
        var chips: [PlayerPanelChip] = []
        if let year = context.meta?.year { chips.append(PlayerPanelChip(text: year)) }
        if let rating = context.meta?.imdbRating { chips.append(PlayerPanelChip(text: rating, symbol: "star.fill")) }
        if let age = context.meta?.ageRating { chips.append(PlayerPanelChip(text: age)) }
        return chips
    }

    private var staticTrailingChips: [PlayerPanelChip] {
        var chips: [PlayerPanelChip] = []
        if let bytes = context.fileSizeBytes, bytes > 0 {
            chips.append(PlayerPanelChip(text: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let genres = context.meta?.genres, !genres.isEmpty {
            chips.append(PlayerPanelChip(text: genres.prefix(3).joined(separator: ", ")))
        }
        return chips
    }
}
