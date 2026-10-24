#!/usr/bin/env python3
"""Checks that every user-facing string in the app has a German translation.

Finds localizable literals in Sources/Plugboard (Text("…"), Button("…"), String(localized: "…")
and the other SwiftUI initializers that take a LocalizedStringKey), converts interpolations to
the format specifiers Foundation uses as keys (%lld for integers, %@ for everything else) and
compares them with Resources/de.lproj. Exits non-zero when a key is missing.

Usage: Scripts/check-localization.py [--list]
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Plugboard"
GERMAN = ROOT / "Resources" / "de.lproj"

# Initializers whose first string argument is a LocalizedStringKey.
CALLS = [
    "Text", "Button", "Label", "Toggle", "Section", "LabeledContent", "Picker", "Menu",
    "TableColumn", "ProgressView", "CommandMenu", "confirmationDialog", "Window",
    "navigationTitle", "accessibilityLabel", "accessibilityHint", "help",
    "ContentUnavailableView",
]
CALL_PATTERN = re.compile(r'\b(?:' + "|".join(CALLS) + r')\(\s*"((?:[^"\\]|\\.)*)"')
LOCALIZED_PATTERN = re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"')
TEXT_IN_ACCESSIBILITY = re.compile(r'\b(?:accessibilityLabel|accessibilityHint)\(Text\("((?:[^"\\]|\\.)*)"')

# Interpolated expressions that are integers. Anything else becomes %@.
INTEGER_HINTS = re.compile(r'(count|done|total|major|\bn\b)', re.I)

# Literals that are never shown translated.
IGNORED = {"Plugboard", "—", "VST3", "VST", "CLAP", "AAX", "MAS", "Waves WPAPI", "Apple", "Shell", ""}


def interpolation_to_specifier(literal: str) -> str:
    result = []
    i = 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth = 1
            j = i + 2
            while j < len(literal) and depth:
                if literal[j] == "(":
                    depth += 1
                elif literal[j] == ")":
                    depth -= 1
                j += 1
            expression = literal[i + 2:j - 1]
            result.append("%lld" if INTEGER_HINTS.search(expression) and "Formatters" not in expression and "title" not in expression else "%@")
            i = j
        elif literal.startswith('\\"', i):
            result.append('"')
            i += 2
        else:
            result.append(literal[i])
            i += 1
    return "".join(result)


def source_keys() -> dict:
    keys = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if "verbatim:" in line:
                continue
            for pattern in (CALL_PATTERN, LOCALIZED_PATTERN, TEXT_IN_ACCESSIBILITY):
                for match in pattern.finditer(line):
                    key = interpolation_to_specifier(match.group(1))
                    if key not in IGNORED:
                        keys.setdefault(key, f"{path.relative_to(ROOT)}:{number}")
    return keys


def strings_keys(path: Path) -> set:
    if not path.exists():
        return set()
    text = path.read_text(encoding="utf-8")
    return set(m.group(1).replace('\\"', '"') for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M))


def stringsdict_keys(path: Path) -> set:
    if not path.exists():
        return set()
    with path.open("rb") as handle:
        return set(plistlib.load(handle).keys())


def main() -> int:
    keys = source_keys()
    if "--list" in sys.argv:
        for key, where in sorted(keys.items()):
            print(f"{key}\t{where}")
        return 0

    translated = strings_keys(GERMAN / "Localizable.strings") | stringsdict_keys(GERMAN / "Localizable.stringsdict")
    missing = {k: v for k, v in keys.items() if k not in translated}
    unused = sorted(translated - set(keys))

    for key, where in sorted(missing.items(), key=lambda kv: kv[1]):
        print(f"missing German: \"{key}\"  ({where})")
    for key in unused:
        print(f"unused German key: \"{key}\"")

    english_plurals = stringsdict_keys(ROOT / "Resources" / "en.lproj" / "Localizable.stringsdict")
    german_plurals = stringsdict_keys(GERMAN / "Localizable.stringsdict")
    for key in sorted(english_plurals ^ german_plurals):
        print(f"plural rule in only one language: \"{key}\"")

    print(f"{len(keys)} keys, {len(missing)} missing, {len(unused)} unused")
    return 1 if missing or (english_plurals ^ german_plurals) else 0


if __name__ == "__main__":
    sys.exit(main())
