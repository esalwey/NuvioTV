#!/usr/bin/env python3
"""Generate iosApp/NuvioTV/Shared.xcstrings from the phone app's Android
string resources.

The tvOS shared module resolves user-facing strings through the
`StringKey` enum in `shared/src/commonMain/kotlin/com/nuvio/app/core/i18n/
StringProvider.kt`. Each entry name mirrors a Compose Resources string id
1:1. This script walks that enum, looks up a matching `<string name="...">`
entry in the phone app's `composeApp/src/commonMain/composeResources/
values*/strings.xml` files (en + fr/es/de/it), converts Android string
syntax to iOS String Catalog syntax, and emits an Xcode `.xcstrings` file.

Run as: python3 scripts/generate-shared-xcstrings.py
Python 3 stdlib only.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRING_PROVIDER_KT = (
    ROOT / "shared/src/commonMain/kotlin/com/nuvio/app/core/i18n/StringProvider.kt"
)
STRINGS_XML_DIR = ROOT / "composeApp/src/commonMain/composeResources"
OUTPUT_PATH = ROOT / "iosApp/NuvioTV/Shared.xcstrings"

# Fork-local translations for StringKey entries that upstream's values-<lang>
# strings.xml doesn't (yet) cover. Regenerating this file from upstream wipes
# any hand-edits made directly to Shared.xcstrings, so gaps get patched here
# instead: one `<lang>.json` per locale, `{StringKey name: translated value}`
# in FINAL iOS placeholder syntax (%1$@, not Android's %1$s). Applied only
# where the harvest produced no value for that key/lang -- harvest always
# wins on conflict, so an override becomes a no-op (and gets flagged as
# "superseded") the moment upstream catches up.
OVERRIDES_DIR = ROOT / "scripts/shared-xcstrings-overrides"

# locale code -> composeResources values directory name. "en" is the
# source language (plain `values/`); the rest are `values-<lang>/`.
LOCALES = {
    "en": "values",
    "fr": "values-fr",
    "es": "values-es",
    "de": "values-de",
    "it": "values-it",
    "vi": "values-vi",
}

SPOT_CHECK_KEYS = ["debrid_missing_api_key", "date_month_january", "media_movie"]


# --------------------------------------------------------------------------
# StringKey enum parsing
# --------------------------------------------------------------------------


def parse_string_keys(path: Path) -> list[str]:
    """Parse the bare identifier entries of `enum class StringKey { ... }`.

    Does brace-depth matching to find the enum body robustly (rather than a
    single fragile regex), then strips comments and splits on commas.
    """
    text = path.read_text(encoding="utf-8")
    m = re.search(r"enum\s+class\s+StringKey\b[^{]*\{", text)
    if not m:
        raise SystemExit(f"Could not locate `enum class StringKey {{` in {path}")

    start = m.end() - 1  # index of the opening brace
    depth = 0
    end = None
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        raise SystemExit(f"Unbalanced braces parsing StringKey enum body in {path}")

    body = text[start + 1 : end]
    # Strip line and block comments defensively (there aren't any today, but
    # don't assume).
    body = re.sub(r"//.*", "", body)
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)

    keys: list[str] = []
    for chunk in body.split(","):
        name = chunk.strip()
        if not name:
            continue
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise SystemExit(f"Unexpected StringKey enum entry token: {name!r}")
        keys.append(name)

    seen = set()
    dupes = sorted({k for k in keys if k in seen or seen.add(k)})
    if dupes:
        raise SystemExit(f"Duplicate StringKey entries found: {dupes}")

    return keys


# --------------------------------------------------------------------------
# Android string.xml -> iOS string conversion
# --------------------------------------------------------------------------

# Android string resources allow backslash-escaping arbitrary characters;
# the ones that actually occur in this codebase are \' \" \n \@ \? and a
# literal \\. Anything else just drops the backslash (matches Android's own
# lenient behavior for stray escapes).
ANDROID_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "'": "'",
    '"': '"',
    "\\": "\\",
    "@": "@",
    "?": "?",
}


def unescape_android(s: str) -> str:
    return re.sub(r"\\(.)", lambda m: ANDROID_ESCAPES.get(m.group(1), m.group(1)), s)


# Matches, in priority order:
#   %%                  -> literal percent escape
#   %<digits>$<letter>  -> explicit positional specifier (e.g. %1$s, %2$d)
#   %<letter>           -> bare specifier (e.g. %s, %d)
# Deliberately does NOT support width/flags/precision: none exist anywhere
# in these locale files, and a permissive flag class (e.g. allowing ',' or
# ' ') produces false positives on ordinary text like "100%, additional...".
PLACEHOLDER_RE = re.compile(r"%%|%(\d+)\$([a-zA-Z])|%([a-zA-Z])")


def convert_placeholders(s: str, key: str, mixed_report: list[str]) -> str:
    matches = list(PLACEHOLDER_RE.finditer(s))
    explicit_indices = [int(m.group(1)) for m in matches if m.group(1)]
    has_bare = any(m.group(3) is not None for m in matches)
    has_explicit = bool(explicit_indices)
    if has_bare and has_explicit:
        mixed_report.append(key)

    counter = max(explicit_indices) if explicit_indices else 0
    out = []
    last = 0
    for m in matches:
        out.append(s[last : m.start()])
        if m.group(0) == "%%":
            out.append("%%")
        elif m.group(1):
            out.append(f"%{int(m.group(1))}$@")
        else:
            counter += 1
            out.append(f"%{counter}$@")
        last = m.end()
    out.append(s[last:])
    return "".join(out)


def convert_value(raw_text: str | None, key: str, mixed_report: list[str]) -> str:
    if raw_text is None:
        return ""
    text = unescape_android(raw_text)
    text = convert_placeholders(text, key, mixed_report)
    return text


# --------------------------------------------------------------------------
# strings.xml loading
# --------------------------------------------------------------------------


def load_strings_xml(path: Path) -> tuple[dict[str, str], set[str]]:
    """Returns (name -> raw text for <string> entries, set of <plurals> names).

    ElementTree already resolves XML entities (&amp; etc.) and transparently
    folds CDATA sections into `.text`, so no extra handling is needed for
    either.
    """
    tree = ET.parse(path)
    root = tree.getroot()
    strings: dict[str, str] = {}
    plurals: set[str] = set()
    for child in root:
        name = child.get("name")
        if name is None:
            continue
        if child.tag == "string":
            strings[name] = child.text or ""
        elif child.tag == "plurals":
            plurals.add(name)
    return strings, plurals


# --------------------------------------------------------------------------
# Fork-local overlay merging
# --------------------------------------------------------------------------

# Same specifier-matching approach as
# scripts/merge-translations-into-xcstrings.py (lines 21-26): used to check
# an override's placeholders line up with the English source's before
# trusting it.
SPEC_RE = re.compile(r"%(?:\d+\$)?[@a-zA-Z]|%\.\d+f|%%")


def specifiers(text: str) -> Counter:
    return Counter(SPEC_RE.findall(text))


def load_overrides() -> dict[str, dict[str, str]]:
    """Load scripts/shared-xcstrings-overrides/<lang>.json overlay files.

    Each file is a flat `{StringKey name: translated value}` object; the
    filename stem is the language code and must be one of LOCALES. Returns
    `{lang: {key: value}}` for every overlay file found (today just `de`).
    """
    overrides: dict[str, dict[str, str]] = {}
    if not OVERRIDES_DIR.exists():
        return overrides
    for path in sorted(OVERRIDES_DIR.glob("*.json")):
        lang = path.stem
        if lang not in LOCALES:
            raise SystemExit(
                f"Overlay file {path} has language code {lang!r}, which is "
                f"not one of the supported LOCALES: {sorted(LOCALES)}"
            )
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in data.items()
        ):
            raise SystemExit(f"Overlay file {path} must be a flat {{str: str}} JSON object")
        overrides[lang] = data
    return overrides


def apply_overrides(
    result_strings: dict[str, dict],
    overrides: dict[str, dict[str, str]],
) -> dict[str, dict[str, list[str]]]:
    """Merge overlay translations into result_strings, in place.

    Harvest always wins: an overlay entry is applied only when the harvest
    produced no localization for that key/lang. Format specifiers in the
    override value must match the EN value's specifiers exactly, or this
    raises SystemExit.

    Returns `{lang: {"applied": [...], "superseded": [...], "stale": [...]}}`.
    `superseded` entries are overlay keys the harvest already covers for that
    language (the override is a no-op); `stale` entries are overlay keys that
    no longer name a StringKey entry at all. Both are candidates for deletion
    from the overlay file as upstream catches up.
    """
    report: dict[str, dict[str, list[str]]] = {}
    for lang, translations in overrides.items():
        applied: list[str] = []
        superseded: list[str] = []
        stale: list[str] = []
        for key, value in translations.items():
            entry = result_strings.get(key)
            if entry is None:
                stale.append(key)
                continue

            locs = entry["localizations"]
            if lang in locs:
                superseded.append(key)
                continue

            en_value = locs.get("en", {}).get("stringUnit", {}).get("value")
            if en_value is not None and specifiers(en_value) != specifiers(value):
                raise SystemExit(
                    f"Overlay format-specifier mismatch for {key!r} ({lang}): "
                    f"en specifiers={specifiers(en_value)} vs override "
                    f"specifiers={specifiers(value)} (override value: {value!r})"
                )

            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
            applied.append(key)

        report[lang] = {
            "applied": sorted(applied),
            "superseded": sorted(superseded),
            "stale": sorted(stale),
        }
    return report


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------


def validate_output(path: Path) -> tuple[list[str], list[str]]:
    """Returns (errors, notes). Errors fail the run; notes are informational."""
    errors: list[str] = []
    notes: list[str] = []

    try:
        with path.open("r", encoding="utf-8") as f:
            json.load(f)
    except json.JSONDecodeError as e:
        errors.append(f"python -m json.tool: {e}")

    try:
        lint = subprocess.run(
            ["plutil", "-lint", str(path)],
            capture_output=True,
            text=True,
        )
        if lint.returncode == 0:
            pass  # plutil -lint passed outright
        else:
            # On some plutil builds `-lint` chokes on JSON-format property
            # lists specifically (reproducible even on the pre-existing,
            # git-committed empty .xcstrings skeletons in this repo), while
            # `-convert` still parses the same file correctly. Treat a
            # successful round-trip convert as an equivalent structural
            # validity check rather than hard-failing on a tooling quirk.
            convert = subprocess.run(
                ["plutil", "-convert", "json", "-o", "-", str(path)],
                capture_output=True,
                text=True,
            )
            if convert.returncode == 0:
                notes.append(
                    "plutil -lint reported an error on this plutil build "
                    f"({lint.stdout.strip()} {lint.stderr.strip()}), but "
                    "`plutil -convert json -o -` parsed the file successfully, "
                    "so it is treated as valid (python json.tool also passed)."
                )
            else:
                errors.append(f"plutil -lint: {lint.stdout.strip()} {lint.stderr.strip()}")
                errors.append(f"plutil -convert: {convert.stdout.strip()} {convert.stderr.strip()}")
    except FileNotFoundError:
        notes.append("plutil not found on PATH; skipped that validation step")

    return errors, notes


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main() -> None:
    keys = parse_string_keys(STRING_PROVIDER_KT)

    per_locale_strings: dict[str, dict[str, str]] = {}
    per_locale_plurals: dict[str, set[str]] = {}
    for lang, dirname in LOCALES.items():
        xml_path = STRINGS_XML_DIR / dirname / "strings.xml"
        if not xml_path.exists():
            raise SystemExit(f"Missing strings.xml for locale {lang!r}: {xml_path}")
        strings_map, plurals_set = load_strings_xml(xml_path)
        per_locale_strings[lang] = strings_map
        per_locale_plurals[lang] = plurals_set

    hit_counts = {lang: 0 for lang in LOCALES}
    miss_counts = {lang: 0 for lang in LOCALES}
    missing_from_en: list[str] = []
    plural_keys: set[str] = set()
    mixed_placeholder_keys: list[str] = []

    result_strings: dict[str, dict] = {}

    for key in keys:
        localizations: dict[str, dict] = {}
        for lang in LOCALES:
            strings_map = per_locale_strings[lang]
            plurals_set = per_locale_plurals[lang]

            if key in plurals_set:
                plural_keys.add(key)
                miss_counts[lang] += 1
                continue

            if key in strings_map:
                value = convert_value(strings_map[key], f"{key}[{lang}]", mixed_placeholder_keys)
                localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}
                hit_counts[lang] += 1
            else:
                miss_counts[lang] += 1
                if lang == "en":
                    missing_from_en.append(key)

        result_strings[key] = {
            "extractionState": "manual",
            "localizations": localizations,
        }

    # ---- fork-local overlay merge ---------------------------------------
    overrides = load_overrides()
    overlay_report = apply_overrides(result_strings, overrides)

    output = {
        "sourceLanguage": "en",
        "strings": result_strings,
        "version": "1.0",
    }

    # sort_keys=True gives us alphabetical StringKey ordering AND alphabetical
    # field ordering (extractionState before localizations, state before
    # value, etc.) at every nesting level in one shot, so regeneration diffs
    # stay clean.
    serialized = json.dumps(output, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    OUTPUT_PATH.write_text(serialized, encoding="utf-8")

    # ---- validation -----------------------------------------------------
    errors, notes = validate_output(OUTPUT_PATH)

    # ---- report -----------------------------------------------------------
    print("=" * 72)
    print("Shared.xcstrings generation report")
    print("=" * 72)
    print(f"StringProvider.kt : {STRING_PROVIDER_KT.relative_to(ROOT)}")
    print(f"Output             : {OUTPUT_PATH.relative_to(ROOT)}")
    print(f"Total StringKey entries parsed: {len(keys)}")
    print()

    print("Per-locale hit/miss counts:")
    for lang in LOCALES:
        print(f"  {lang}: {hit_counts[lang]} hit, {miss_counts[lang]} miss")
    print()

    if missing_from_en:
        print(f"StringKey names missing from English source XML ({len(missing_from_en)}):")
        for k in sorted(missing_from_en):
            print(f"  - {k}")
    else:
        print("No StringKey names missing from the English source XML.")
    print()

    if plural_keys:
        print(f"StringKey ids that exist as <plurals> rather than <string> ({len(plural_keys)}):")
        print("(not converted -- listed only)")
        for k in sorted(plural_keys):
            print(f"  - {k}")
    else:
        print("No StringKey ids found as <plurals> in any locale.")
    print()

    if mixed_placeholder_keys:
        print(
            f"Entries mixing bare and explicit-index placeholders ({len(mixed_placeholder_keys)}); "
            "bare ones were numbered after the highest explicit index:"
        )
        for k in sorted(set(mixed_placeholder_keys)):
            print(f"  - {k}")
    else:
        print("No entries mixed bare and explicit-index placeholders.")
    print()

    print(f"Overlay report ({OVERRIDES_DIR.relative_to(ROOT)}/<lang>.json):")
    if overlay_report:
        for lang in sorted(overlay_report):
            r = overlay_report[lang]
            print(
                f"  {lang}: {len(r['applied'])} applied, "
                f"{len(r['superseded'])} superseded by harvest, "
                f"{len(r['stale'])} stale"
            )
            if r["superseded"]:
                print(
                    "    superseded (harvest now covers these; overlay entry "
                    "is a no-op -- candidate for deletion):"
                )
                for k in r["superseded"]:
                    print(f"      - {k}")
            if r["stale"]:
                print(
                    "    stale (not a StringKey entry -- candidate for deletion):"
                )
                for k in r["stale"]:
                    print(f"      - {k}")
    else:
        print("  No overlay files found.")
    print()

    print("Spot-check:")
    for k in SPOT_CHECK_KEYS:
        entry = result_strings.get(k)
        if entry is None:
            print(f"  {k}: NOT a StringKey entry")
            continue
        loc = entry["localizations"]
        en_val = loc.get("en", {}).get("stringUnit", {}).get("value")
        fr_val = loc.get("fr", {}).get("stringUnit", {}).get("value")
        print(f"  {k}:")
        print(f"    en = {en_val!r}")
        print(f"    fr = {fr_val!r}")
        if en_val is None or fr_val is None:
            raise SystemExit(f"Spot-check failed: {k} missing en or fr localization")
        if en_val == fr_val:
            raise SystemExit(f"Spot-check failed: {k} fr value is identical to en (suspicious)")
    print()

    if notes:
        print("Validation notes:")
        for n in notes:
            print(f"  - {n}")
        print()

    if errors:
        print("VALIDATION ERRORS:")
        for e in errors:
            print(f"  - {e}")
        raise SystemExit(1)
    else:
        print("Validation OK.")


if __name__ == "__main__":
    main()
