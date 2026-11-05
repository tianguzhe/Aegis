#!/usr/bin/env python3
"""Validate production localization keys without modifying the catalogs."""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[1]
catalog = json.loads((root / "Packages/AegisKit/Sources/AegisCore/Resources/Localizable.xcstrings").read_text())
keys = catalog["strings"]
errors = []
for folder in [root / "App", root / "AutoFill", root / "Packages/AegisKit/Sources"]:
    for path in folder.rglob("*.swift"):
        source = path.read_text()
        for key in re.findall(r'L10n\.(?:text|format)\("([^"]+)"', source):
            if key not in keys:
                errors.append(f"{path.relative_to(root)}: missing {key}")
        if re.search(r'[\u3400-\u9fff]', source):
            errors.append(f"{path.relative_to(root)}: inline Chinese text")
for key, value in keys.items():
    if not value.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {}).get("value"):
        errors.append(f"{key}: missing Chinese source")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"Validated {len(keys)} localized strings; no inline Chinese in production Swift.")
