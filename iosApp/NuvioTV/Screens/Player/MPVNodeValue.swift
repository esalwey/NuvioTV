import Foundation
import Libmpv

/// A libmpv `mpv_node` tree copied into plain Swift values.
///
/// `track-list` and `chapter-list` are observed with `MPV_FORMAT_NODE`: the whole list arrives in
/// the property-change event, so reading it costs no call into the core. (Walking
/// `track-list/N/...` one property at a time was hundreds of synchronous core round trips, each one
/// parked behind whatever the core was busy with, which on a very large stream stopped the event
/// loop for as long as the core stayed busy.) The node belongs to the event and is only valid
/// inside its handler, so it is copied here before anything leaves the reader queue.
nonisolated enum MPVNodeValue {
    case null
    case string(String)
    case flag(Bool)
    case int(Int64)
    case double(Double)
    indirect case array([MPVNodeValue])
    indirect case map([String: MPVNodeValue])

    /// The payload of a property-change event observed as `MPV_FORMAT_NODE`; `.null` when the
    /// property is unavailable (no file) or carries another format.
    init(property prop: mpv_event_property) {
        guard prop.format == MPV_FORMAT_NODE, let data = prop.data else {
            self = .null
            return
        }
        self.init(data.assumingMemoryBound(to: mpv_node.self).pointee)
    }

    init(_ node: mpv_node) {
        let format = node.format
        if format == MPV_FORMAT_STRING {
            if let string = node.u.string {
                self = .string(String(cString: string))
            } else {
                self = .null
            }
        } else if format == MPV_FORMAT_FLAG {
            self = .flag(node.u.flag != 0)
        } else if format == MPV_FORMAT_INT64 {
            self = .int(node.u.int64)
        } else if format == MPV_FORMAT_DOUBLE {
            self = .double(node.u.double_)
        } else if format == MPV_FORMAT_NODE_ARRAY {
            guard let list = node.u.list else {
                self = .array([])
                return
            }
            let count = Int(list.pointee.num)
            var items: [MPVNodeValue] = []
            if count > 0, let values = list.pointee.values {
                items.reserveCapacity(count)
                for index in 0..<count { items.append(MPVNodeValue(values[index])) }
            }
            self = .array(items)
        } else if format == MPV_FORMAT_NODE_MAP {
            guard let list = node.u.list else {
                self = .map([:])
                return
            }
            let count = Int(list.pointee.num)
            var entries: [String: MPVNodeValue] = [:]
            if count > 0, let values = list.pointee.values, let keys = list.pointee.keys {
                for index in 0..<count {
                    guard let key = keys[index] else { continue }
                    entries[String(cString: key)] = MPVNodeValue(values[index])
                }
            }
            self = .map(entries)
        } else {
            self = .null
        }
    }

    // MARK: Typed access (a missing key or another type reads as nil)

    var items: [MPVNodeValue] {
        if case .array(let items) = self { return items }
        return []
    }

    subscript(key: String) -> MPVNodeValue {
        if case .map(let entries) = self { return entries[key] ?? .null }
        return .null
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return Int(truncatingIfNeeded: value)
        case .double(let value) where value.isFinite: return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool {
        switch self {
        case .flag(let value): return value
        case .int(let value): return value != 0
        case .string(let value): return value == "yes" || value == "true"
        default: return false
        }
    }
}

/// One audio or subtitle row of mpv's `track-list`, as the event carries it.
nonisolated struct MPVTrackListEntry: Sendable {
    let isAudio: Bool
    let id: Int
    let selected: Bool
    let external: Bool
    let externalFilename: String?
    let lang: String
    let title: String
    let forced: Bool
    let codec: String
    let codecProfile: String
    let channels: Int
    let isDefault: Bool
    let hearingImpaired: Bool

    /// The audio and subtitle tracks of a `track-list` value, in the file's order (video and other
    /// types are not offered to the viewer).
    static func parse(_ value: MPVNodeValue) -> [MPVTrackListEntry] {
        value.items.compactMap { node -> MPVTrackListEntry? in
            let type = node["type"].stringValue ?? ""
            guard type == "audio" || type == "sub" else { return nil }
            let isAudio = type == "audio"
            let external = node["external"].boolValue
            return MPVTrackListEntry(
                isAudio: isAudio,
                id: node["id"].intValue ?? 0,
                selected: node["selected"].boolValue,
                external: !isAudio && external,
                externalFilename: !isAudio && external ? node["external-filename"].stringValue : nil,
                lang: (node["lang"].stringValue ?? "").trimmingCharacters(in: .whitespaces),
                title: (node["title"].stringValue ?? "").trimmingCharacters(in: .whitespaces),
                forced: node["forced"].boolValue,
                codec: (node["codec"].stringValue ?? "").trimmingCharacters(in: .whitespaces),
                codecProfile: node["codec-profile"].stringValue ?? "",
                channels: isAudio ? (node["demux-channel-count"].intValue ?? 0) : 0,
                isDefault: node["default"].boolValue,
                hearingImpaired: !isAudio && node["hearing-impaired"].boolValue
            )
        }
    }
}

/// One chapter of mpv's `chapter-list`: its start in seconds and the name the file gives it.
nonisolated struct MPVChapterEntry: Sendable {
    let start: Double
    let title: String?

    /// A file with one chapter or none has nothing to jump between: empty.
    static func parse(_ value: MPVNodeValue) -> [MPVChapterEntry] {
        let nodes = value.items
        guard nodes.count > 1 else { return [] }
        return nodes.compactMap { node -> MPVChapterEntry? in
            guard let start = node["time"].doubleValue else { return nil }
            return MPVChapterEntry(start: start, title: node["title"].stringValue)
        }
    }
}
