from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_app import verify


class VerifyAppTests(unittest.TestCase):
    def fixture(self, root, platform):
        mac = platform == "macos"
        app = root / "Aegis.app"
        base = app / "Contents" if mac else app
        base.mkdir(parents=True)
        minimum = "LSMinimumSystemVersion" if mac else "MinimumOSVersion"
        info = {"CFBundleIdentifier": "example.aegis", "CFBundleExecutable": "Aegis",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                minimum: "14.0" if mac else "17.0",
                "CFBundleSupportedPlatforms": [{"macos": "MacOSX", "ios": "iPhoneOS", "ios-simulator": "iPhoneSimulator"}[platform]]}
        (base / "Info.plist").write_bytes(plistlib.dumps(info))
        binary_dir = base / "MacOS" if mac else base
        binary_dir.mkdir(exist_ok=True)
        (binary_dir / "Aegis").touch()
        extension = base / "PlugIns/AegisAutoFill.appex"
        extension_base = extension / "Contents" if mac else extension
        extension_base.mkdir(parents=True)
        info.update(CFBundleIdentifier="example.aegis.autofill", CFBundleExecutable="AegisAutoFill",
                    NSExtension={"NSExtensionPointIdentifier": "com.apple.authentication-services-credential-provider-ui"})
        (extension_base / "Info.plist").write_bytes(plistlib.dumps(info))
        binary_dir = extension_base / "MacOS" if mac else extension_base
        binary_dir.mkdir(exist_ok=True)
        (binary_dir / "AegisAutoFill").touch()
        return app, extension_base / "Info.plist"

    def test_accepts_each_platform_host_and_extension(self):
        for platform in ("macos", "ios", "ios-simulator"):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                app, _ = self.fixture(Path(temporary), platform)
                verify(app, platform)

    def test_rejects_mismatched_extension_version_or_identifier(self):
        for key, value in (("CFBundleVersion", "999"), ("CFBundleIdentifier", "other.extension")):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                app, info_path = self.fixture(Path(temporary), "macos")
                info = plistlib.loads(info_path.read_bytes())
                info[key] = value
                info_path.write_bytes(plistlib.dumps(info))
                with self.assertRaises(ValueError):
                    verify(app, "macos")
