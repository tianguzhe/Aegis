"""Unit tests for the release checks in Scripts/packaging/artifact_utils.py."""
from pathlib import Path
import io
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "packaging"))
from artifact_utils import check_ipa_entries, check_tag, checksum, project_version, restricted_entitlements


def ipa(entries):
    """entries: (name, data, unix mode or None)."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name)
            if mode is not None:
                info.external_attr = mode << 16
            archive.writestr(info, data)
    buffer.seek(0)
    return zipfile.ZipFile(buffer)


VALID = [("Payload/", b"", None), ("Payload/Aegis.app/", b"", None), ("Payload/Aegis.app/Aegis", b"x", 0o100755),
         ("Payload/Aegis.app/PlugIns/AegisAutoFill.appex/Info.plist", b"x", 0o100644)]


class PackagingTests(unittest.TestCase):
    def project(self, text):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "project.yml"
        path.write_text(text)
        return path

    def test_tag_must_equal_project_version(self):
        project = self.project("settings:\n  base:\n    MARKETING_VERSION: 0.2.0\n    CURRENT_PROJECT_VERSION: 2\n")
        self.assertEqual(project_version(project), "0.2.0")
        check_tag("v0.2.0", project)
        for tag in ("0.2.0", "v0.2.1", "v0.2.0-rc1", "V0.2.0"):
            with self.assertRaises(ValueError):
                check_tag(tag, project)

    def test_missing_project_version_is_rejected(self):
        with self.assertRaises(ValueError):
            project_version(self.project("settings:\n  base:\n    CURRENT_PROJECT_VERSION: 2\n"))

    def test_valid_ipa_layout_passes(self):
        check_ipa_entries(ipa(VALID))

    def test_ipa_rejects_unexpected_or_dangerous_entries(self):
        cases = {
            "outside payload": [("Other/Aegis.app/Aegis", b"x", 0o100755)],
            "wrong app name": [("Payload/Evil.app/Evil", b"x", 0o100755)],
            "path traversal": [("Payload/Aegis.app/../../escape", b"x", 0o100644)],
            "symbolic link": [("Payload/Aegis.app/link", b"/etc/passwd", stat.S_IFLNK | 0o777)],
            "code signature": [("Payload/Aegis.app/_CodeSignature/CodeResources", b"x", 0o100644)],
            "provisioning profile": [("Payload/Aegis.app/embedded.mobileprovision", b"x", 0o100644)],
        }
        for label, extra in cases.items():
            with self.subTest(label), self.assertRaises(ValueError):
                check_ipa_entries(ipa(VALID + extra))
        with self.assertRaises(ValueError):
            check_ipa_entries(ipa([]))

    def test_restricted_entitlements_are_detected(self):
        granted = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.application-groups": ["group.example"],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.authentication-services.autofill-credential-provider": True,
        }
        self.assertEqual(restricted_entitlements(granted), [
            "com.apple.developer.authentication-services.autofill-credential-provider",
            "com.apple.developer.icloud-services",
            "com.apple.security.application-groups",
        ])

    def test_shipped_adhoc_entitlements_contain_no_restricted_keys(self):
        import plistlib
        for path in (Path(__file__).resolve().parents[1] / "packaging").glob("*.entitlements"):
            with self.subTest(path.name):
                values = plistlib.loads(path.read_bytes())
                self.assertEqual(restricted_entitlements(values), [])
                self.assertIs(values.get("com.apple.security.app-sandbox"), True)

    def test_checksum_matches_shasum_format(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "Aegis-0.2.0-macOS-universal.dmg"
            package.write_bytes(b"abc")
            checksum(package)
            self.assertEqual((Path(directory) / "Aegis-0.2.0-macOS-universal.dmg.sha256").read_text(),
                             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  "
                             "Aegis-0.2.0-macOS-universal.dmg\n")


if __name__ == "__main__":
    unittest.main()
