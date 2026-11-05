#!/usr/bin/env python3
"""Validate both the host and embedded credential provider before using build products."""
import argparse
from pathlib import Path
import plistlib
import subprocess


def verify(app, platform, signed=False):
    mac = platform == "macos"
    base = app / "Contents" if mac else app
    info = plistlib.loads((base / "Info.plist").read_bytes())
    minimum_key = "LSMinimumSystemVersion" if mac else "MinimumOSVersion"
    expected_minimum = "14.0" if mac else "17.0"
    expected_platform = {"macos": "MacOSX", "ios": "iPhoneOS", "ios-simulator": "iPhoneSimulator"}[platform]
    if expected_platform not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError(f"Unexpected platform in {app}")
    if info.get(minimum_key) != expected_minimum:
        raise ValueError(f"Expected minimum OS {expected_minimum} in {app}")
    binary = base / "MacOS" / info["CFBundleExecutable"] if mac else base / info["CFBundleExecutable"]
    if not binary.is_file():
        raise ValueError(f"Missing executable in {app}")
    extensions = list((base / "PlugIns").glob("*.appex"))
    if len(extensions) != 1:
        raise ValueError(f"Expected one embedded credential provider in {app}")
    extension = extensions[0]
    extension_base = extension / "Contents" if mac else extension
    extension_info = plistlib.loads((extension_base / "Info.plist").read_bytes())
    if extension_info.get("CFBundleIdentifier") != info["CFBundleIdentifier"] + ".autofill":
        raise ValueError("Host and extension bundle identifiers do not match")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", minimum_key, "CFBundleSupportedPlatforms"):
        if extension_info.get(key) != info.get(key):
            raise ValueError(f"Host and extension disagree on {key}")
    extension_binary = (extension_base / "MacOS" if mac else extension_base) / extension_info["CFBundleExecutable"]
    if not extension_binary.is_file():
        raise ValueError("Missing credential provider executable")
    if extension_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.authentication-services-credential-provider-ui":
        raise ValueError("Invalid credential provider extension point")
    if signed:
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Verified {platform} host + credential provider, minimum OS {expected_minimum}, version {info['CFBundleShortVersionString']}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--platform", choices=["macos", "ios", "ios-simulator"], required=True)
    parser.add_argument("--signed", action="store_true")
    args = parser.parse_args()
    verify(args.app, args.platform, args.signed)


if __name__ == "__main__":
    main()
