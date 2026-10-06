#!/usr/bin/env python3
"""Merge MT part-files (translations-<lang>-part*.json) into Localizable.xcstrings.

Companion to populate-localizable-xcstrings.py: that script fills the catalog with
extracted keys + mobile-harvested translations; this one folds in the machine
translations produced for the remainder. Re-validates that every translation
preserves its key's format specifiers before writing anything.

Usage: python3 scripts/merge-translations-into-xcstrings.py <dir-with-part-files>
"""

import glob
import json
import os
import re
import sys
from collections import Counter

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(REPO, "iosApp/NuvioTV/Localizable.xcstrings")
SPEC_RE = re.compile(r"%(?:\d+\$)?[@a-zA-Z]|%\.\d+f|%%")


def specifiers(text):
    return Counter(SPEC_RE.findall(text))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: merge-translations-into-xcstrings.py <dir-with-part-files>")
    src_dir = sys.argv[1]

    with open(CATALOG) as f:
        catalog = json.load(f)
    strings = catalog["strings"]

    merged, skipped = Counter(), []
    for path in sorted(glob.glob(os.path.join(src_dir, "translations-*-part*.json"))):
        lang = os.path.basename(path).split("-")[1]
        with open(path) as f:
            translations = json.load(f)
        for key, value in translations.items():
            if key not in strings:
                skipped.append((lang, key, "key not in catalog"))
                continue
            if specifiers(key) != specifiers(value):
                skipped.append((lang, key, f"specifier mismatch: {value!r}"))
                continue
            locs = strings[key].setdefault("localizations", {})
            if lang in locs:
                skipped.append((lang, key, "already translated (harvest wins)"))
                continue
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
            merged[lang] += 1

    with open(CATALOG, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")

    for lang, count in sorted(merged.items()):
        print(f"merged [{lang}]: {count}")
    if skipped:
        print(f"skipped: {len(skipped)}")
        for lang, key, reason in skipped[:20]:
            print(f"  [{lang}] {key!r}: {reason}")
    # Remaining gaps after merge.
    for lang in ("fr", "es", "de", "it", "vi"):
        missing = [k for k, e in strings.items() if lang not in e.get("localizations", {})]
        print(f"still missing [{lang}]: {len(missing)}")


if __name__ == "__main__":
    main()
