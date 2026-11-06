# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Validate the actual Aegis distribution bundles, rather than trusting a build's exit status.

Packages are built without an Apple Developer account: the Mac app is ad-hoc signed and the iOS
app is unsigned for re-signing. Restricted entitlements (iCloud, push, AutoFill provider, App
Groups) need a provisioning profile, so they must never appear in these packages.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_app import verify as verify_bundle_structure  # noqa: E402

APP_NAME = "Aegis"
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}
SIGNING_MATERIAL = {"_CodeSignature", "embedded.mobileprovision", "embedded.provisionprofile"}
# Ad-hoc signatures cannot carry these; a binary that claims them is killed at launch.
RESTRICTED_ENTITLEMENT_PREFIXES = ("com.apple.developer.", "com.apple.security.application-groups")


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()


def bundle_base(bundle, platform):
    return bundle / "Contents" if platform == "macos" else bundle


def info(bundle, platform):
    with (bundle_base(bundle, platform) / "Info.plist").open("rb") as source:
        return plistlib.load(source)


def executable(bundle, platform):
    name = info(bundle, platform).get("CFBundleExecutable", "")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name):
        raise ValueError(f"Invalid executable name in {bundle}")
    binary = bundle_base(bundle, platform) / ("MacOS" if platform == "macos" else "") / name
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"Missing executable: {binary}")
    return binary


def bundles(app, platform):
    """The host app followed by its embedded credential provider."""
    return [app, *sorted((bundle_base(app, platform) / "PlugIns").glob("*.appex"))]


def metadata(app, platform):
    values = info(app, platform)
    for key, pattern in [("CFBundleShortVersionString", r"\d+\.\d+\.\d+"), ("CFBundleVersion", r"[1-9]\d*")]:
        if not re.fullmatch(pattern, str(values.get(key, ""))):
            raise ValueError(f"Invalid {key} in {app}: {values.get(key)!r}")
    if str(values.get("AegisCloudEnabled", "")).upper() != "NO":
        raise ValueError("Distribution packages must keep CloudKit disabled (AegisCloudEnabled = NO)")
    if values.get("AegisAppGroup", "") != "":
        raise ValueError("Distribution packages must not reference an App Group")
    return values


def has_signature(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", str(path)], capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if "not signed at all" in result.stderr:
        return False
    raise ValueError(f"Could not inspect code signature for {path}: {result.stderr.strip()}")


def entitlements(bundle):
    output = subprocess.run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(bundle)],
                            capture_output=True, check=True).stdout
    return plistlib.loads(output) if output.strip() else {}


def restricted_entitlements(values):
    return sorted(key for key in values if key.startswith(RESTRICTED_ENTITLEMENT_PREFIXES))


def macho_files(root):
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as source:
                if source.read(4) in MACHO_MAGICS:
                    yield path


def verify_platform(binary, platform):
    expected_architectures = {"arm64", "x86_64"} if platform == "macos" else {"arm64"}
    architectures = set(run("/usr/bin/lipo", "-archs", str(binary)).split())
    if architectures != expected_architectures:
        raise ValueError(f"Expected {sorted(expected_architectures)}, got {sorted(architectures)}: {binary}")
    build = run("/usr/bin/xcrun", "vtool", "-show-build", str(binary))
    platforms = set(re.findall(r"^\s*platform\s+(\S+)\s*$", build, re.MULTILINE))
    expected_platform = "MACOS" if platform == "macos" else "IOS"
    if platforms != {expected_platform}:
        raise ValueError(f"Expected a {expected_platform} device binary, got {sorted(platforms)}: {binary}")


def verify_app(app, platform):
    values = metadata(app, platform)
    verify_bundle_structure(app, platform, signed=platform == "macos")
    for bundle in bundles(app, platform):
        verify_platform(executable(bundle, platform), platform)
        if platform == "macos":
            if "Signature=adhoc" not in run("/usr/bin/codesign", "--display", "--verbose=2", str(bundle)):
                raise ValueError(f"Expected an ad-hoc signature: {bundle}")
            granted = entitlements(bundle)
            if granted.get("com.apple.security.app-sandbox") is not True:
                raise ValueError(f"App Sandbox must stay enabled: {bundle}")
            if restricted := restricted_entitlements(granted):
                raise ValueError(f"Restricted entitlements in an ad-hoc package: {restricted} in {bundle}")
    if platform == "ios":
        for path in macho_files(app):
            if has_signature(path):
                raise ValueError(f"Unsigned package still contains signed code: {path}")
        for path in app.rglob("*"):
            if path.name in SIGNING_MATERIAL:
                raise ValueError(f"Unsigned package contains signing material: {path}")
    print(f"Verified {platform}: {values['CFBundleName']} {values['CFBundleShortVersionString']} "
          f"({values['CFBundleVersion']}) with {len(bundles(app, platform)) - 1} extension(s)")


def strip_ios(app):
    for bundle in bundles(app, "ios"):
        verify_platform(executable(bundle, "ios"), "ios")
    # arm64 linkers add ad-hoc Mach-O signatures even with CODE_SIGNING_ALLOWED=NO; remove inside-out.
    for path in sorted(macho_files(app), key=lambda value: len(value.parts), reverse=True):
        if has_signature(path):
            subprocess.check_call(["/usr/bin/codesign", "--remove-signature", str(path)])
    for path in sorted(app.rglob("*"), key=lambda value: len(value.parts), reverse=True):
        if path.name == "_CodeSignature" and path.is_dir():
            shutil.rmtree(path)
        elif path.name in {"embedded.mobileprovision", "embedded.provisionprofile"}:
            path.unlink()
    verify_app(app, "ios")


def check_ipa_entries(archive):
    """Reject anything but a plain Payload/Aegis.app tree before extracting it."""
    names = archive.namelist()
    prefix = f"Payload/{APP_NAME}.app/"
    if not names or any(name != "Payload/" and not name.startswith(prefix) for name in names):
        raise ValueError(f"IPA must contain only {prefix}")
    if len(set(names)) != len(names):
        raise ValueError("IPA contains duplicate entries")
    for entry in archive.infolist():
        parts = Path(entry.filename).parts
        if entry.filename.startswith("/") or ".." in parts:
            raise ValueError(f"Invalid IPA entry: {entry.filename}")
        if stat.S_ISLNK(entry.external_attr >> 16):
            raise ValueError(f"IPA must not contain symbolic links: {entry.filename}")
        if SIGNING_MATERIAL.intersection(parts):
            raise ValueError(f"IPA contains signing material: {entry.filename}")
    if (invalid := archive.testzip()) is not None:
        raise ValueError(f"Corrupt IPA entry: {invalid}")


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        check_ipa_entries(archive)
    with tempfile.TemporaryDirectory(prefix="aegis-ipa-verify-") as temporary:
        # ditto keeps the executable bits that zipfile extraction would drop.
        subprocess.check_call(["/usr/bin/ditto", "-x", "-k", str(path), temporary])
        verify_app(Path(temporary) / "Payload" / f"{APP_NAME}.app", "ios")
    print(f"Verified unsigned IPA: {path.name}")


def verify_dmg(path):
    run("/usr/bin/hdiutil", "verify", str(path))
    with tempfile.TemporaryDirectory(prefix="aegis-dmg-verify-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        attached = False
        try:
            subprocess.check_call(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount),
                                   str(path)], stdout=subprocess.DEVNULL)
            attached = True
            verify_app(mount / f"{APP_NAME}.app", "macos")
            applications = mount / "Applications"
            if not applications.is_symlink() or os.readlink(applications) != "/Applications":
                raise ValueError("DMG is missing its Applications link")
            if not (mount / ".DS_Store").is_file():
                raise ValueError("DMG is missing its Finder layout")
        finally:
            # Detach our own mount path: macOS may report /private/var for a requested /var path.
            if attached or os.path.ismount(mount):
                if subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", str(mount)], capture_output=True).returncode:
                    subprocess.check_call(["/usr/bin/hdiutil", "detach", "-force", "-quiet", str(mount)])
    print(f"Verified DMG: {path.name}")


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    path.with_name(path.name + ".sha256").write_text(f"{digest.hexdigest()}  {path.name}\n")


def project_version(project_file):
    match = re.search(r"^\s*MARKETING_VERSION:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$", project_file.read_text(), re.MULTILINE)
    if not match:
        raise ValueError(f"No MARKETING_VERSION in {project_file}")
    return match.group(1)


def check_tag(tag, project_file):
    """A release tag must be exactly v<MARKETING_VERSION>, so tag, repository and package agree."""
    version = project_version(project_file)
    if tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} does not match project.yml MARKETING_VERSION {version}; expected v{version}")
    print(f"Tag {tag} matches project version {version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["verify-app", "metadata", "strip-ios-signatures"]:
        command = commands.add_parser(name)
        command.add_argument("app", type=Path)
        if name != "strip-ios-signatures":
            command.add_argument("--platform", required=True, choices=["macos", "ios"])
        if name == "metadata":
            command.add_argument("--field", required=True)
    for name in ["verify-dmg", "verify-ipa", "checksum"]:
        commands.add_parser(name).add_argument("path", type=Path)
    tag = commands.add_parser("check-tag")
    tag.add_argument("tag")
    tag.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[2] / "project.yml")
    args = parser.parse_args()
    if args.command == "metadata":
        print(metadata(args.app, args.platform)[args.field])
    elif args.command == "verify-app":
        verify_app(args.app, args.platform)
    elif args.command == "strip-ios-signatures":
        strip_ios(args.app)
    elif args.command == "verify-dmg":
        verify_dmg(args.path)
    elif args.command == "verify-ipa":
        verify_ipa(args.path)
    elif args.command == "checksum":
        checksum(args.path)
    elif args.command == "check-tag":
        check_tag(args.tag, args.project)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        raise SystemExit(f"Artifact validation failed: {error}") from error
