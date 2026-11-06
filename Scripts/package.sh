#!/bin/bash
# Build Aegis distribution packages without an Apple Developer account.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash Scripts/package.sh [all|dmg|ipa] [options]

  all                 Build the universal macOS DMG and the unsigned iOS IPA (default).
  dmg                 Universal macOS DMG; the app is ad-hoc signed and not notarized.
  ipa                 Unsigned arm64 iPhone/iPad IPA, ready for re-signing.
  --build-number N    CFBundleVersion for this build (default: project.yml).
  --output-dir PATH   Artifact directory (default: <project>/dist).
  -h, --help          Show this help.

The marketing version always comes from project.yml. Packages keep iCloud sync and AutoFill
disabled: both need restricted entitlements that only a provisioning profile can grant.
Requires macOS, Xcode 26+ and uv (DMG only).
USAGE
}

fail() { printf '[Aegis] %s\n' "$*" >&2; exit 1; }

package_target=all
target_set=0
build_number=""
output_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        all|dmg|ipa)
            [[ "$target_set" -eq 0 ]] || fail "Specify only one package target."
            package_target="$1"; target_set=1; shift ;;
        --build-number) [[ $# -ge 2 && -n "$2" ]] || fail "--build-number requires a value."; build_number="$2"; shift 2 ;;
        --output-dir) [[ $# -ge 2 && -n "$2" ]] || fail "--output-dir requires a value."; output_dir="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -z "$build_number" || "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "Build number must be a positive integer."
[[ "$(uname -s)" == Darwin ]] || fail "Run this script on macOS."
for tool in xcodebuild xcrun hdiutil codesign ditto lipo; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing required tool: $tool"
done
if [[ "$package_target" != ipa ]]; then
    command -v uv >/dev/null 2>&1 || fail "DMG packaging needs uv (https://docs.astral.sh/uv/)."
fi
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, version, "."); print version[1]}')"
[[ "$xcode_major" =~ ^[0-9]+$ && "$xcode_major" -ge 26 ]] || fail "Select Xcode 26+ using DEVELOPER_DIR or xcode-select."

# common.sh prepares the isolated artifact area, cds to the project root and owns the EXIT trap.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
output_dir="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "${output_dir:-$project_root/dist}")"
work="$artifact_root/package"
utils="$project_root/Scripts/packaging/artifact_utils.py"
mkdir -p "$work/logs" "$output_dir"
stage="$(mktemp -d "$work/stage.XXXXXX")"
package_cleanup() {
    local code=$?
    rm -rf -- "$stage"
    [[ "$code" -eq 0 ]] || printf '[Aegis] Packaging failed. Logs: %s/logs\n' "$work" >&2
    # aegis_cleanup (common.sh) reads $? and exits with it. Recreate the original status inside an
    # `if` condition, where errexit cannot end the trap before the registrations are cleaned.
    if (exit "$code"); then aegis_cleanup; else aegis_cleanup; fi
}
trap package_cleanup EXIT

# Command-line settings override Config/Local.xcconfig, so a developer's team, bundle prefix,
# App Group or iCloud container can never leak into a distribution package.
build_settings=(
    -project Aegis.xcodeproj -configuration Release
    ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
    ENABLE_DEBUG_DYLIB=NO AEGIS_BUNDLE_PREFIX=app.aegis AEGIS_APP_GROUP= AEGIS_CLOUD_ENABLED=NO
)
[[ -z "$build_number" ]] || build_settings+=("CURRENT_PROJECT_VERSION=$build_number")

build_with_log() {
    local lane="$1" log="$2"
    shift 2
    if ! python3 "$isolation_script" exec --root "$project_root" --lane "$lane" -- "$@" > "$log" 2>&1; then
        tail -n 80 "$log" >&2
        fail "xcodebuild failed. Full log: $log"
    fi
}

app_version() {
    local value
    value="$(python3 "$utils" metadata "$1" --platform "$2" --field CFBundleShortVersionString)"
    [[ -z "$build_number" || "$(python3 "$utils" metadata "$1" --platform "$2" --field CFBundleVersion)" == "$build_number" ]] \
        || fail "Built app does not carry build number $build_number."
    printf '%s\n' "$value"
}

package_dmg() {
    local products="$artifact_root/xcode/package-macos/Build/Products/Release"
    local app="$stage/macos/Aegis.app" version filename extension
    printf '[Aegis] Building universal macOS Release…\n'
    build_with_log package-macos "$work/logs/macos-build.log" xcodebuild "${build_settings[@]}" \
        -scheme Aegis-macOS -destination 'generic/platform=macOS' -sdk macosx 'ARCHS=arm64 x86_64' build
    mkdir -p "$stage/macos"
    /usr/bin/ditto "$products/Aegis.app" "$app"
    # Sign inside-out: the embedded credential provider first, then the host that seals it.
    for extension in "$app"/Contents/PlugIns/*.appex; do
        /usr/bin/codesign --force --sign - --timestamp=none \
            --entitlements Scripts/packaging/adhoc-autofill-macOS.entitlements "$extension"
    done
    /usr/bin/codesign --force --sign - --timestamp=none --entitlements Scripts/packaging/adhoc-host-macOS.entitlements "$app"
    version="$(app_version "$app" macos)"
    python3 "$utils" verify-app "$app" --platform macos

    printf '[Aegis] Rendering installer artwork…\n'
    mkdir -p "$work/tools"
    xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$work/ModuleCache" \
        Scripts/packaging/GenerateDMGArtwork.swift -o "$work/tools/GenerateDMGArtwork"
    "$work/tools/GenerateDMGArtwork" "$stage/artwork" "$version" Brand/Aegis-Icon.png

    filename="Aegis-$version-macOS-universal.dmg"
    printf '[Aegis] Creating %s…\n' "$filename"
    # Pinned packaging tools run through uv only; they never ship inside the app.
    uv tool run --quiet --from 'dmgbuild==1.6.7' --with 'ds-store==1.3.3' --with 'mac-alias==2.2.3' \
        dmgbuild -s Scripts/packaging/dmg-settings.py -D "app=$app" \
        -D "icon=$app/Contents/Resources/AppIcon.icns" -D "background=$stage/artwork/background.tiff" \
        Aegis "$stage/$filename" > "$work/logs/dmg-build.log" 2>&1 \
        || { tail -n 60 "$work/logs/dmg-build.log" >&2; fail "DMG creation failed."; }
    python3 "$utils" verify-dmg "$stage/$filename"
    mv -f -- "$stage/$filename" "$output_dir/$filename"
    python3 "$utils" checksum "$output_dir/$filename"
    printf '[Aegis] Ready: %s\n' "$output_dir/$filename"
}

package_ipa() {
    local archive="$work/ios/Aegis.xcarchive" app="$stage/Payload/Aegis.app" version filename
    printf '[Aegis] Archiving unsigned iPhone/iPad Release…\n'
    rm -rf -- "$archive"
    mkdir -p "$work/ios" "$stage/Payload"
    build_with_log package-ios "$work/logs/ios-archive.log" xcodebuild "${build_settings[@]}" \
        -scheme Aegis-iOS -destination 'generic/platform=iOS' -sdk iphoneos -archivePath "$archive" \
        ARCHS=arm64 CODE_SIGN_ENTITLEMENTS= archive
    /usr/bin/ditto "$archive/Products/Applications/Aegis.app" "$app"
    version="$(app_version "$app" ios)"
    python3 "$utils" strip-ios-signatures "$app"
    filename="Aegis-$version-iOS-unsigned.ipa"
    /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$stage/Payload" "$stage/$filename"
    python3 "$utils" verify-ipa "$stage/$filename"
    mv -f -- "$stage/$filename" "$output_dir/$filename"
    python3 "$utils" checksum "$output_dir/$filename"
    printf '[Aegis] Ready: %s\n' "$output_dir/$filename"
}

case "$package_target" in
    all) package_dmg; package_ipa ;;
    dmg) package_dmg ;;
    ipa) package_ipa ;;
esac
printf '[Aegis] SHA-256 checksums are next to the packages.\n'
