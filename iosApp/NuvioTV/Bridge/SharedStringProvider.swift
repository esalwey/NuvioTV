//
//  SharedStringProvider.swift
//  NuvioTV
//
//  Backs the shared module's StringKey seam (core/i18n/StringProvider.kt) with the
//  "Shared" string catalog. Keys are the StringKey enum entry names, which mirror the
//  phone app's Compose Resources ids 1:1 — Shared.xcstrings is generated from the
//  composeApp strings.xml locales by scripts/generate-shared-xcstrings.py.
//
//  Kotlin callers pass an inline English fallback and use it whenever this returns nil,
//  so a key missing from the catalog (or untranslated in the active locale) degrades to
//  English per-string rather than breaking.
//

import Foundation
import SharedCore

final class SharedStringProvider: NSObject, StringProvider {

    /// Sentinel returned by `localizedString(forKey:value:table:)` when the key has no
    /// entry — NUL bytes cannot appear in real catalog values.
    private static let missing = "\u{1}nuvio.missing\u{1}"

    func get(key: StringKey, args: KotlinArray<AnyObject>) -> String? {
        let format = Bundle.main.localizedString(forKey: key.name, value: Self.missing, table: "Shared")
        guard format != Self.missing else { return nil }
        guard args.size > 0 else { return format }

        // The generator normalizes every placeholder to positional %n$@, so all arguments
        // are formatted via their object description (String and KotlinInt/NSNumber both
        // render correctly).
        var formatArgs: [CVarArg] = []
        for i in 0..<args.size {
            switch args.get(index: i) {
            case let string as String: formatArgs.append(string)
            case let number as NSNumber: formatArgs.append(number)
            case let other?: formatArgs.append(String(describing: other))
            case nil: formatArgs.append("")
            }
        }
        return String(format: format, arguments: formatArgs)
    }
}
