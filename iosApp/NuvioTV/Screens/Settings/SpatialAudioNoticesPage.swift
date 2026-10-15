import Foundation
import SpatialAudioBridge
import SwiftUI

/// Settings > About > Licenses & Attributions > SpatialAudioBridge Notices: the license texts that
/// SpatialAudioBridge asks apps to show (`SpatialAudioBridgeNotices.text`): its own Apache License 2.0,
/// the licenses of the Rust components compiled into its core (the TrueHD and DTS decoders and their
/// dependencies) and the Rust standard library's notices, each text listed once. About 330 KB of text,
/// so it is cut into chunks of a couple of dozen lines, each focusable so the Siri Remote can scroll
/// through the list, and prepared off the main thread.
struct SpatialAudioNoticesPage: View {
    @State private var chunks: [NoticeChunk] = []
    @State private var loaded = false

    var body: some View {
        List {
            if chunks.isEmpty {
                Text(loaded
                     ? String(localized: "The notices are not available.")
                     : String(localized: "Loading\u{2026}"))
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.secondary)
                    .focusable()
            } else {
                ForEach(chunks) { chunk in
                    Text(verbatim: chunk.text)
                        .font(.system(size: 22, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusable()
                }
            }
        }
        .navigationTitle(String(localized: "SpatialAudioBridge Notices"))
        .task {
            guard !loaded else { return }
            chunks = await Task.detached(priority: .utility) {
                NoticeChunk.split(SpatialAudioBridgeNotices.text)
            }.value
            loaded = true
        }
    }
}

/// One focusable block of the notices text.
nonisolated struct NoticeChunk: Identifiable, Sendable, Equatable {
    let id: Int
    let text: String

    /// Cuts `text` into blocks of about `linesPerChunk` lines, at a blank line when one comes in
    /// time (paragraphs stay whole) and at twice that length when none does.
    static func split(_ text: String, linesPerChunk: Int = 24) -> [NoticeChunk] {
        var chunks: [NoticeChunk] = []
        var current: [Substring] = []
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { chunks.append(NoticeChunk(id: chunks.count, text: joined)) }
            current.removeAll(keepingCapacity: true)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            current.append(line)
            if current.count >= linesPerChunk * 2 {
                flush()
            } else if current.count >= linesPerChunk, line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            }
        }
        flush()
        return chunks
    }
}
