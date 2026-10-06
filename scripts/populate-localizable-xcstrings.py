#!/usr/bin/env python3
"""Populate iosApp/NuvioTV/Localizable.xcstrings from build-emitted .stringsdata.

Xcode's IDE-only catalog sync never runs for headless xcodebuild, so this script does
that job: it collects every key the compiler extracted (SWIFT_EMIT_LOC_STRINGS) from
the NuvioTV target's .stringsdata files in DerivedData, merges them into the catalog,
and pre-fills fr/es/de/it translations for any key whose English text exactly matches
a phone-app Compose string (composeApp/src/commonMain/composeResources), converting
Android placeholders to iOS ones. Idempotent; existing catalog entries are preserved.

Usage: python3 scripts/populate-localizable-xcstrings.py <NuvioTV.build dir>
Prints a summary and writes scratch report 'localizable-needs-translation.json' next
to the catalog listing keys still missing per-locale translations (input for MT).
"""

import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(REPO, "iosApp/NuvioTV/Localizable.xcstrings")
COMPOSE_RES = os.path.join(REPO, "composeApp/src/commonMain/composeResources")
LOCALES = ["fr", "es", "de", "it", "vi"]

ANDROID_ESCAPES = [("\\'", "'"), ('\\"', '"'), ("\\n", "\n"), ("\\@", "@"), ("\\?", "?")]


def unescape_android(text):
    for old, new in ANDROID_ESCAPES:
        text = text.replace(old, new)
    return text


def convert_placeholders(text):
    """%1$s/%1$d/%s/%d -> %1$@/%@ (all-object convention, matching Shared.xcstrings)."""
    out, counter = [], [0]

    def repl(m):
        tok = m.group(0)
        if tok == "%%":
            return "%%"
        idx = re.match(r"%(\d+)\$", tok)
        if idx:
            return f"%{idx.group(1)}$@"
        counter[0] += 1
        return f"%{counter[0]}$@"

    return re.sub(r"%%|%\d+\$[a-zA-Z]|%[a-zA-Z]", repl, text)


def load_compose_strings(locale_dir):
    path = os.path.join(COMPOSE_RES, locale_dir, "strings.xml")
    if not os.path.exists(path):
        return {}
    result = {}
    for node in ET.parse(path).getroot().iter("string"):
        name, value = node.get("name"), node.text or ""
        result[name] = convert_placeholders(unescape_android(value))
    return result


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: populate-localizable-xcstrings.py <NuvioTV.build dir>")
    build_dir = sys.argv[1]

    # 1. Collect extracted keys (dedupe across build variants).
    keys = set()
    for path in glob.glob(os.path.join(build_dir, "**/*.stringsdata"), recursive=True):
        with open(path) as f:
            data = json.load(f)
        # Only the Localizable table: Xcode's generated symbol file for
        # Shared.xcstrings emits stringsdata for table "Shared" too, which must
        # not leak into this catalog.
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    if not keys:
        sys.exit(f"no .stringsdata keys found under {build_dir}")

    # 2. Build English-value -> translations map from the phone app's Compose resources.
    en = load_compose_strings("values")
    locale_maps = {loc: load_compose_strings(f"values-{loc}") for loc in LOCALES}
    by_english = {}
    for sid, en_value in en.items():
        translations = {
            loc: locale_maps[loc][sid] for loc in LOCALES if sid in locale_maps[loc]
        }
        if translations:
            # First mobile id wins on duplicate English values (rare, and any choice is
            # consistent because values are identical English).
            by_english.setdefault(en_value, translations)

    # 3. Merge into the catalog.
    with open(CATALOG) as f:
        catalog = json.load(f)
    strings = catalog.setdefault("strings", {})
    added, harvested = 0, 0
    for key in sorted(keys):
        entry = strings.setdefault(key, {})
        if "localizations" not in entry:
            added += 1
        locs = entry.setdefault("localizations", {})
        match = by_english.get(key)
        if match:
            got_any = False
            for loc, value in match.items():
                if loc not in locs:
                    locs[loc] = {"stringUnit": {"state": "translated", "value": value}}
                    got_any = True
            if got_any:
                harvested += 1
        if not locs:
            del entry["localizations"]

    catalog["strings"] = dict(sorted(strings.items()))
    with open(CATALOG, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")

    # 4. Needs-translation report for the MT pass.
    needs = {
        loc: [k for k in sorted(keys) if loc not in strings[k].get("localizations", {})]
        for loc in LOCALES
    }
    report_path = os.path.join(REPO, "build", "localizable-needs-translation.json")
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w") as f:
        json.dump(needs, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"extracted keys: {len(keys)}")
    print(f"new catalog entries: {added}")
    print(f"keys with harvested mobile translations: {harvested}")
    for loc in LOCALES:
        print(f"needs MT [{loc}]: {len(needs[loc])}")
    print(f"report: {report_path}")


if __name__ == "__main__":
    main()
