"""Check shell exit cleanup without touching LaunchServices or real app data."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CleanupTests(unittest.TestCase):
    def test_preserves_original_failure_and_reports_cleanup_failure(self):
        with tempfile.TemporaryDirectory(prefix="aegis-cleanup-") as directory:
            scripts = Path(directory) / "Scripts"
            scripts.mkdir()
            shutil.copyfile(Path(__file__).resolve().parents[1] / "common.sh", scripts / "common.sh")
            (scripts / "build_isolation.py").write_text("# No registry access.\n")
            sentinel = Path(directory) / "Aegis.app/keep.txt"
            sentinel.parent.mkdir()
            sentinel.write_text("preserved")
            for original, cleanup, expected in ((0, 0, 0), (17, 0, 17), (17, 1, 17), (0, 1, 1)):
                with self.subTest(original=original, cleanup=cleanup):
                    result = subprocess.run(["bash", "-c", '''
set -euo pipefail
source "$1"
cleanup_status="$3"
python3() { return "$cleanup_status"; }
exit "$2"
''', "cleanup-test", str(scripts / "common.sh"), str(original), str(cleanup)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(sentinel.read_text(), "preserved")
