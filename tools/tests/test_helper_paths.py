"""Exercise installer path checks without installing or running a root helper."""
import pathlib
import subprocess
import tempfile
import unittest

HELPER = pathlib.Path(__file__).resolve().parents[1] / 'helper-paths.sh'

class HelperPathTests(unittest.TestCase):
    def check(self, directory):
        return subprocess.run([
            '/bin/bash', '-c',
            'set -euo pipefail; die() { echo "$*" >&2; exit 1; }; '
            'source "$1"; assert_secure_directory "$2"',
            'path-test', str(HELPER), str(directory)
        ], capture_output=True, text=True)

    def test_root_owned_protected_directory_is_accepted(self):
        self.assertEqual(self.check('/Library').returncode, 0)

    def test_writable_root_owned_directory_is_rejected(self):
        result = self.check('/private/tmp')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('writable', result.stderr)

    def test_user_owned_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.check(directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not root-owned', result.stderr)

    def test_symlink_to_protected_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            link = pathlib.Path(directory) / 'helper'
            link.symlink_to('/Library', target_is_directory=True)
            result = self.check(link)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unsafe helper directory', result.stderr)

if __name__ == '__main__':
    unittest.main()
