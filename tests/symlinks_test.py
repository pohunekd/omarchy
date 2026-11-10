#!/usr/bin/env python3
"""scripts/check-symlinks judges tracked mode 120000, not paths. Run: python3 -I tests/symlinks_test.py"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check-symlinks"


# Git variables set by hooks would point git at the real repository.
CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=CLEAN_ENV)


def check(repo):
    return subprocess.run([str(CHECK), str(repo)], capture_output=True, text=True, env=CLEAN_ENV)


class SymlinkGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        (self.repo / "file").write_text("x\n")
        (self.repo / "file").chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def test_regular_files_pass(self):
        git(self.repo, "add", "file")
        self.assertEqual(check(self.repo).returncode, 0)

    def test_untracked_symlink_is_ignored(self):
        git(self.repo, "add", "file")
        (self.repo / "node_modules").mkdir()
        (self.repo / "node_modules" / "bin").symlink_to("../file")
        self.assertEqual(check(self.repo).returncode, 0)

    def test_tracked_symlink_fails_even_under_build_output_paths(self):
        for sub in ("site/node_modules", "site/dist", "site/.astro", "docs"):
            with self.subTest(sub=sub):
                (self.repo / sub).mkdir(parents=True, exist_ok=True)
                link = self.repo / sub / "link"
                link.symlink_to("../../file")
                git(self.repo, "add", "-f", str(link.relative_to(self.repo)))
                result = check(self.repo)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{sub}/link", result.stderr)
                git(self.repo, "rm", "-q", "--cached", "-f", str(link.relative_to(self.repo)))
                link.unlink()


if __name__ == "__main__":
    unittest.main()
