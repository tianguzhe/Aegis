#!/bin/bash
set -euo pipefail
platform="${1:-macos}"
configuration="${2:-Debug}"
if [[ "$#" -gt 2 || ! "$configuration" =~ ^(Debug|Release)$ ]]; then
    printf 'Usage: %s [macos|ios-simulator|ios] [Debug|Release]\n' "$0" >&2
    exit 2
fi
case "$platform" in
    macos) scheme=Aegis-macOS; destination='generic/platform=macOS'; product_folder="$configuration" ;;
    ios-simulator) scheme=Aegis-iOS; destination='generic/platform=iOS Simulator'; product_folder="$configuration-iphonesimulator" ;;
    ios) scheme=Aegis-iOS; destination='generic/platform=iOS'; product_folder="$configuration-iphoneos" ;;
    *) printf 'Unsupported platform: %s\n' "$platform" >&2; exit 2 ;;
esac
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
lane="$platform-$(printf '%s' "$configuration" | tr '[:upper:]' '[:lower:]')"
build_root="${AEGIS_BUILD_DIR:-$artifact_root/xcode/$lane}"
settings=(CODE_SIGNING_ALLOWED=NO)
if [[ "$platform" == macos && "$configuration" == Release ]]; then
    settings+=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi
python3 "$isolation_script" exec --root "$project_root" --lane "$lane" -- \
    xcodebuild -project Aegis.xcodeproj -scheme "$scheme" -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$build_root" "${settings[@]}" build
python3 Scripts/verify_app.py "$build_root/Build/Products/$product_folder/Aegis.app" --platform "$platform"
printf '\nBuild product: %s/Build/Products/%s/Aegis.app\n' "$build_root" "$product_folder"
