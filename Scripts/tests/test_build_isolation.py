"""Exercise filesystem/registry boundaries without changing LaunchServices."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_isolation as isolation


class BuildIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aegis-isolation-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "Project with spaces"
        self.root.mkdir()
        self.derived = self.base / "DerivedData"
        self.area = self.make_area()

    def make_area(self):
        return isolation.BuildArea(self.root, derived_data_home=self.derived)

    def write_plist(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def test_ownership_excludes_installed_apps_and_escaped_symlinks(self):
        self.area.prepare()
        self.assertTrue(self.area.owns(self.area.work / "xcode/Test.app"))
        self.assertTrue(self.area.owns(self.root / "build/test/Legacy.app"))
        for path in (Path("/Applications/Aegis.app"), Path.home() / "Applications/Aegis.app",
                     self.root / "Example.app", self.root / "build-other/Foo.app"):
            self.assertFalse(self.area.owns(path), path)
        (self.area.work / "Installed.app").symlink_to("/Applications/Aegis.app")
        self.assertFalse(self.area.owns(self.area.work / "Installed.app"))
        (self.area.work / "escape").symlink_to(self.base)
        self.assertFalse(self.area.owns(self.area.work / "escape/Other.app"))

    def test_legacy_release_only_accepts_aegis_bundle(self):
        app = self.root / "release/Aegis.app"
        self.assertTrue(self.area.owns(app))  # Stale registrations can outlive a bundle.
        self.write_plist(app / "Contents/Info.plist", {"CFBundleIdentifier": "another.app"})
        self.assertFalse(self.area.owns(app))
        self.write_plist(app / "Contents/Info.plist", {"CFBundleIdentifier": "app.aegis.mac"})
        self.assertTrue(self.area.owns(app))
        self.assertFalse(self.area.owns(self.root / "release/Other.app"))

    def test_legacy_release_symlink_is_not_owned(self):
        (self.root / "release").symlink_to("/Applications")
        self.assertFalse(self.area.owns(self.root / "release/Aegis.app"))

    def test_global_derived_data_requires_matching_workspace_metadata(self):
        self.write_plist(self.derived / "Owned/info.plist", {"WorkspacePath": str(self.root / "Aegis.xcodeproj")})
        self.write_plist(self.derived / "Aegis-Unrelated/info.plist", {"WorkspacePath": str(self.base / "Other/Aegis.xcodeproj")})
        self.write_plist(self.derived / "Relative/info.plist", {"WorkspacePath": "Aegis.xcodeproj"})
        area = self.make_area()
        self.assertTrue(area.owns(self.derived / "Owned/Build/Products/Debug/Aegis.app"))
        for folder in ("Aegis-Unrelated", "Relative", "NoMetadata"):
            self.assertFalse(area.owns(self.derived / folder / "Build/Products/Debug/Aegis.app"))

    def test_prepare_preserves_xcode_preferences_and_is_idempotent(self):
        username = isolation.pwd.getpwuid(isolation.os.getuid()).pw_name
        settings = self.root / f"Aegis.xcodeproj/project.xcworkspace/xcuserdata/{username}.xcuserdatad/WorkspaceSettings.xcsettings"
        self.write_plist(settings, {"CustomPreference": True})
        self.area.prepare()
        before = settings.read_bytes()
        self.area.prepare()
        self.assertEqual(settings.read_bytes(), before)
        data = plistlib.loads(before)
        self.assertTrue(data["CustomPreference"])
        self.assertEqual(data["DerivedDataCustomLocation"], str(self.area.work / "xcode/ide"))
        self.assertTrue((self.area.work / "logs").is_dir())

    def test_prepare_rejects_build_or_settings_symlinks(self):
        (self.root / "build").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.make_area()
        (self.root / "build").unlink()
        (self.root / ".build").mkdir()
        (self.root / ".build/artifacts.noindex").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.area.prepare()

    def test_command_injects_isolated_derived_data_and_preserves_arguments(self):
        arguments, env = self.area.command(["xcrun", "xcodebuild", "-scheme", "Aegis", "test"], "test")
        self.assertEqual(arguments[:4], ["xcrun", "xcodebuild", "-derivedDataPath", str(self.area.work / "xcode/test")])
        self.assertEqual(arguments[4:], ["-scheme", "Aegis", "test"])
        self.assertEqual(env["ISOLATED_BUILD_DIR"], str(self.area.work))
        with self.assertRaises(ValueError):
            self.area.command(["xcodebuild"], "../../outside")

    def test_command_rejects_output_path_escape_and_duplicate_options(self):
        for args in (["-derivedDataPath", str(self.base)], ["-archivePath", "/Applications/Test.xcarchive"],
                     ["-resultBundlePath", "../Test.xcresult"], ["SYMROOT=/tmp/products"],
                     ["-derivedDataPath"], ["-derivedDataPath=/tmp/build"],
                     ["-derivedDataPath", str(self.area.work), "-derivedDataPath", str(self.area.work)]):
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.area.command(["xcodebuild"] + args, "test")
        self.area.prepare()
        (self.area.work / "escape").symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.area.command(["xcodebuild", "-derivedDataPath", str(self.area.work / "escape")], "test")

    def test_swift_commands_confine_scratch_cache_and_manifest(self):
        for command in (["swift", "test"], ["xcrun", "swift", "build"]):
            arguments, env = self.area.command(command + ["--package-path", "Packages/AegisKit"], "core-test")
            self.assertEqual(arguments[arguments.index("--scratch-path") + 1], str(self.area.work / "swift"))
            self.assertEqual(arguments[arguments.index("--cache-path") + 1], str(self.area.work / "cache/swiftpm"))
            self.assertEqual(arguments[arguments.index("--manifest-cache") + 1], "local")
            self.assertEqual(env["CLANG_MODULE_CACHE_PATH"], str(self.area.work / "cache/clang"))
        for option in ("--scratch-path", "--cache-path"):
            for tail in ([option, "/tmp/outside"], [option], [option + "=/tmp/outside"],
                         [option, str(self.area.work), option, str(self.area.work)]):
                with self.subTest(tail=tail), self.assertRaises(ValueError):
                    self.area.command(["swift", "test"] + tail, "test")

    def test_xcode_package_paths_cannot_escape(self):
        for option in ("-clonedSourcePackagesDirPath", "-packageCachePath"):
            with self.subTest(option=option), self.assertRaises(ValueError):
                self.area.command(["xcodebuild", option, "/tmp/outside"], "macos")

    def test_execute_keeps_unique_logs_and_never_deletes_artifacts(self):
        self.area.prepare()
        sentinel = self.area.work / "Aegis.app/Contents/keep.txt"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("development app")
        with patch.object(self.area, "cleanup"):
            for _ in range(2):
                self.assertEqual(isolation.execute(self.area, [sys.executable, "-c", "print('validation log')"], "test"), 0)
        logs = list((self.area.work / "logs").glob("test.*.log"))
        self.assertEqual(len(logs), 2)
        self.assertTrue(all("validation log" in log.read_text() for log in logs))
        self.assertEqual(sentinel.read_text(), "development app")

    def test_cleanup_filters_registry_by_path_and_supports_dry_run(self):
        own = self.area.work / "xcode/Aegis.app"
        dump = f"path: {own} (0x123abc)\npath: /Applications/Aegis.app\npath: {own}\nbundle id: app.aegis.mac\n"
        with patch.object(isolation.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, dump, "")) as run:
            self.area.cleanup(dry_run=True)
            self.assertEqual(run.call_count, 1)
            self.area.cleanup()
            self.assertEqual(run.call_args.args[0], [str(isolation.LSREGISTER), "-u", str(own)])
            self.assertEqual(run.call_count, 3)

    def test_cleanup_reports_unregister_failure(self):
        with patch.object(self.area, "registered", return_value=[self.area.work / "Test.app"]), \
             patch.object(isolation.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "denied")):
            with self.assertRaisesRegex(RuntimeError, "denied"):
                self.area.cleanup()

    def test_archive_legacy_preserves_files_outside_the_index_and_is_idempotent(self):
        legacy = self.root / "build/preview/AegisPreview.app/Contents/keep.txt"
        legacy.parent.mkdir(parents=True)
        legacy.write_bytes(b"preview artifact")
        installed = self.root / "Installed.app/keep.txt"
        installed.parent.mkdir()
        installed.write_bytes(b"leave alone")
        with patch.object(self.area, "cleanup") as cleanup, patch.object(
            isolation.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "/Applications/Other.app/Contents/MacOS/Other\n", "")
        ):
            destination = self.area.archive_legacy()
            self.assertTrue(isolation.is_inside(destination, self.area.work))
            self.assertEqual((destination / "preview/AegisPreview.app/Contents/keep.txt").read_bytes(), b"preview artifact")
            self.assertFalse((self.root / "build").exists())
            self.assertEqual(installed.read_bytes(), b"leave alone")
            self.assertIsNone(self.area.archive_legacy())
            cleanup.assert_called_once()

    def test_archive_legacy_refuses_a_running_bundle_or_changed_symlink(self):
        legacy = self.root / "build"
        legacy.mkdir()
        with patch.object(self.area, "cleanup") as cleanup, patch.object(
            isolation.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, str(legacy / "mac/Aegis.app/Contents/MacOS/Aegis") + "\n", ""
            )
        ):
            with self.assertRaisesRegex(RuntimeError, "Quit the legacy"):
                self.area.archive_legacy()
            cleanup.assert_not_called()
            self.assertTrue(legacy.is_dir())
        legacy.rmdir()
        legacy.symlink_to(self.base)
        with self.assertRaises(ValueError):
            self.area.archive_legacy()

    def test_cleanup_is_idempotent_for_unavailable_registration(self):
        with patch.object(self.area, "registered", return_value=[self.area.work / "Old.app"]), \
             patch.object(isolation.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "failed to scan: -10814")):
            self.area.cleanup()

    def test_execute_preserves_failure_and_always_cleans_up(self):
        with patch.object(self.area, "cleanup") as cleanup:
            code = isolation.execute(self.area, [sys.executable, "-c", "raise SystemExit(23)"], "test")
            self.assertEqual(code, 23)
            cleanup.assert_called_once()
        with patch.object(self.area, "cleanup", side_effect=RuntimeError("cleanup failed")):
            self.assertEqual(isolation.execute(self.area, [sys.executable, "-c", "pass"], "test"), 1)
            self.assertEqual(isolation.execute(self.area, [sys.executable, "-c", "raise SystemExit(23)"], "test"), 23)

    def test_ci_logs_are_unique_and_preserve_command_failure(self):
        scripts = self.root / "Scripts"
        scripts.mkdir()
        for name in ("ci-annotate.sh", "build_isolation.py"):
            shutil.copyfile(Path(__file__).resolve().parents[1] / name, scripts / name)
        for code in (0, 17):
            result = subprocess.run(["bash", str(scripts / "ci-annotate.sh"), "Test", sys.executable,
                                     "-c", f"print('command output'); raise SystemExit({code})"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, code, result.stdout + result.stderr)
            self.assertIn("command output", result.stdout)
            self.assertEqual("::error" in result.stdout, code != 0)
        logs = list((self.area.work / "logs").glob("ci.log.*"))
        self.assertEqual(len(logs), 2)
        self.assertTrue(all("command output" in log.read_text() for log in logs))


if __name__ == "__main__":
    unittest.main()
