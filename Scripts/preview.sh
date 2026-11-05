#!/bin/bash
set -euo pipefail
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != --build-only ) ]]; then
    printf 'Usage: %s [--build-only]\n' "$0" >&2
    exit 2
fi
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
bash Scripts/build.sh macos Debug
build_root="${AEGIS_BUILD_DIR:-$artifact_root/xcode/macos-debug}"
app_path="$build_root/Build/Products/Debug/Aegis.app"
# Xcode Debug builds include injected preview/debug dylibs even without signing.
# Sign leaves first, then extension bundles and finally the host.
while IFS= read -r -d '' library; do
    /usr/bin/codesign --force --sign - "$library"
done < <(find "$app_path" -type f -name '*.dylib' -print0)
while IFS= read -r -d '' extension; do
    /usr/bin/codesign --force --sign - "$extension"
done < <(find "$app_path/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
/usr/bin/codesign --force --sign - "$app_path"
python3 Scripts/verify_app.py "$app_path" --platform macos --signed
if [[ "${1:-}" == --build-only ]]; then
    printf 'Preview ready: %s\n' "$app_path"
else
    printf 'Starting the isolated in-memory preview. Cleanup runs after the app exits.\n'
    /usr/bin/open -W -n "$app_path" --args --preview-vault
fi
