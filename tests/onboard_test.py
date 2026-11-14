#!/usr/bin/env python3
"""Scenarios of tools/onboard and the shared verified download, run against
tools/demo-pohunek with a private HOME. GitHub is replaced by a local fixture
directory (POHUNEK_ONBOARD_TEST_FIXTURES); the child environment is built from
scratch, so no `gh`, no Omarchy launcher and no real pohunek is reachable.
Run: python3 -I tests/onboard_test.py"""
import hashlib
import io
import json
import os
import platform
import pty
import select
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ONBOARD = ROOT / "tools" / "onboard"
INSTALL = ROOT / "tools" / "install-pohunek"
DEMO = ROOT / "tools" / "demo-pohunek"
VERSION = "0.42.0"
ASSISTANT = f"pohunek.context.assistant-{VERSION}.tar.zst"
CORE = f"pohunek-daemon-{VERSION}-x86_64-unknown-linux-gnu"
# The only programs the tools may find on PATH.
TOOLS = ["bash", "env", "python3", "jq", "curl", "mktemp", "od", "tr", "sed", "grep", "awk", "cut", "sort",
         "head", "tar", "gzip", "sha256sum", "cp", "rm", "mkdir", "mv", "chmod", "cat", "date", "sync",
         "uname", "dirname", "sleep"]
HOMES = ["claude", "claude:work", "codex"]


def is_read_only(argv):
    """Commands that change nothing; everything else is a write."""
    return (argv[:1] == ["--version"]
            or (argv[:1] == ["setup"] and "--dry-run" in argv)
            or argv[:2] in (["service", "check"], ["plugin", "list"]))


class Scenario(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="onboard-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.bin = self.root / "bin"
        self.home = self.root / "home"
        self.tmp = self.root / "tmp"
        self.fixtures = self.root / "fixtures"
        for d in (self.bin, self.home, self.tmp, self.fixtures):
            d.mkdir()
        for name in TOOLS:
            found = shutil.which(name)
            self.assertIsNotNone(found, f"{name} is needed by the scenario")
            (self.bin / name).symlink_to(found)
        self.log = self.tmp / "calls.jsonl"
        self.state = self.tmp / "state"
        self.record = self.home / ".local" / "state" / "omarchy" / "pohunek-onboarding.json"
        self.archive = os.urandom(4096)
        self.digest = hashlib.sha256(self.archive).hexdigest()
        self.publish_assistant()

    # ---------------------------------------------------------------- fixtures
    def put(self, url_path, data):
        path = self.fixtures / url_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())

    def publish_assistant(self, sums_digest=None, notes_digest=None, notes=True):
        base = f"github.com/pohunekd/plugin-assistant/releases/download/v{VERSION}"
        self.put(f"{base}/{ASSISTANT}", self.archive)
        self.put(f"{base}/SHA256SUMS", f"{sums_digest or self.digest}  {ASSISTANT}\n")
        body = "## Changes\r\n\r\nSomething.\r\n"
        if notes:
            body += f"\r\nAssistant package pohunek.context.assistant {VERSION} sha256: {notes_digest or self.digest}\r\n"
        self.put(f"api.github.com/repos/zajca/pohunek/releases/tags/v{VERSION}", json.dumps({"tag_name": f"v{VERSION}", "body": body}))

    def publish_core(self, corrupt=False):
        """A core release archive whose `pohunek` is tools/demo-pohunek."""
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, data, mode in ((f"{CORE}/pohunek", DEMO.read_bytes(), 0o755),
                                     (f"{CORE}/packaging/install-daemon.sh", b"#!/bin/sh\nexit 0\n", 0o755)):
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), mode
                tar.addfile(info, io.BytesIO(data))
        data = buf.getvalue()
        digest = hashlib.sha256(b"other" if corrupt else data).hexdigest()
        base = f"github.com/zajca/pohunek/releases/download/v{VERSION}"
        self.put(f"{base}/{CORE}.tar.gz", data)
        self.put(f"{base}/{CORE}.tar.gz.sha256", f"{digest}  {CORE}.tar.gz\n")
        self.put("api.github.com/repos/zajca/pohunek/releases/latest", json.dumps({"tag_name": f"v{VERSION}"}))

    # ------------------------------------------------------------------ running
    def env(self, extra=None):
        env = {"PATH": str(self.bin), "HOME": str(self.home), "TMPDIR": str(self.tmp), "LANG": "C.UTF-8",
               "TERM": "dumb", "XDG_STATE_HOME": str(self.home / ".local" / "state"),
               "XDG_CONFIG_HOME": str(self.home / ".config"), "XDG_RUNTIME_DIR": str(self.root / "run"),
               "DEMO_POHUNEK_LOG": str(self.log), "DEMO_POHUNEK_STATE": str(self.state),
               "POHUNEK_ONBOARD_TEST_FIXTURES": str(self.fixtures)}
        env.update(extra or {})
        return env

    def run_tool(self, args, extra=None, tool=ONBOARD):
        return subprocess.run([str(tool), *args], env=self.env(extra), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=120)

    def run_tty(self, args, answers, extra=None, tool=ONBOARD):
        """Runs the tool on a pseudo-terminal and types the answers."""
        master, slave = pty.openpty()
        proc = subprocess.Popen([str(tool), *args], env=self.env(extra), stdin=slave, stdout=slave,
                                stderr=slave, start_new_session=True)
        os.close(slave)
        os.write(master, "".join(a + "\n" for a in answers).encode())
        out = b""
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            elif proc.poll() is not None:
                break
        else:
            proc.kill()
        os.close(master)
        code = proc.wait(timeout=10)
        return code, out.decode(errors="replace")

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def argvs(self):
        return [c["argv"] for c in self.calls()]

    def writes(self):
        return [a for a in self.argvs() if not is_read_only(a)]

    def find(self, prefix):
        return [a for a in self.argvs() if a[:len(prefix)] == prefix]

    def home_tree(self):
        return {str(p.relative_to(self.home)): (p.read_bytes() if p.is_file() else None)
                for p in sorted(self.home.rglob("*"))}

    def assert_no_record(self):
        self.assertFalse(self.record.exists(), "no onboarding record")
        self.assertEqual(list(self.record.parent.glob(".pohunek-onboarding.json.*")) if self.record.parent.exists() else [], [])

    def read_record(self):
        self.assertEqual(self.record.stat().st_mode & 0o777, 0o600, "record mode 0600")
        return json.loads(self.record.read_text())

    def demo(self):
        return ["--command", str(DEMO)]

    # ---------------------------------------------------------------- scenarios
    def test_declining_at_the_one_yes_writes_nothing(self):
        before = self.home_tree()
        code, out = self.run_tty(self.demo(), ["y", "n", "y", "y", "n"])
        self.assertEqual(code, 1, out)
        self.assertIn("installed by this tool because pohunek setup cannot", out)
        self.assertIn("Cancelled; nothing was changed.", out)
        self.assertTrue(self.find(["setup", "--dry-run"]), "the plan was read")
        self.assertEqual(self.writes(), [], "no write command before the yes")
        self.assertEqual(self.home_tree(), before, "HOME is unchanged")
        self.assert_no_record()

    def test_yes_without_hooks_installs_none_and_starts_the_session(self):
        r = self.run_tool(["--yes", *self.demo()])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        setup = self.find(["setup", "--yes"])
        self.assertEqual(len(setup), 1)
        self.assertEqual(setup[0][setup[0].index("--hooks") + 1], "none")
        order = [a[:2] for a in self.writes()]
        self.assertEqual(order, [["setup", "--yes"], ["plugin", "install"], ["assistant", "help"],
                                 ["project", "list"], ["plugin", "profile"], ["plugin", "profile"],
                                 ["integration", "status"],
                                 ["assistant", "setup"], ["attach", order[-1][1]]], order)
        install = self.find(["plugin", "install"])[0]
        self.assertEqual(install[install.index("--sha256") + 1], self.digest)
        profile_lists = self.find(["plugin", "profile", "list"])
        self.assertEqual(profile_lists, [["plugin", "profile", "list", "--all", "--json"],
                                         ["plugin", "profile", "list", "--json"]], "v0.42.0 refuses --all")
        launch = self.find(["assistant", "setup"])[0]
        self.assertIn("--request-stdin", launch)
        self.assertIn("--all-profiles", self.find(["integration", "status"])[0])
        rec = self.read_record()
        self.assertEqual(rec["schema"], 1)
        self.assertRegex(rec["run_id"], r"^[0-9a-f]{32}$")
        self.assertEqual((rec["mode"], rec["history"], rec["agent"], rec["core_version"]), ("guided", "no", None, VERSION))
        self.assertEqual(rec["hooks_selected"], [])
        self.assertEqual(rec["setup_result"]["err"]["code"], "setup_incomplete")
        self.assertEqual(rec["assistant"], {"source": "tool", "version": VERSION, "digest": "sha256:" + self.digest})
        self.assertEqual(sorted(rec["snapshot"]), ["integrations", "profiles", "projects"])
        self.assertEqual(rec["snapshot"]["profiles"], [{"name": "work", "file_digest": "sha256:" + "ef" * 32}])
        self.assertIn(f"onboard.run={rec['run_id']}", launch)
        self.assertIn("onboard.mode=guided", launch)
        self.assertIn("onboard.history=no", launch)
        self.assertFalse(any(a.startswith("onboard.grant") for a in launch), "guided mode passes no grant")
        self.assertEqual(rec["session_id"], json.loads((self.state / "sessions.json").read_text())[0]["id"])
        self.assertIn("do not read agent history", (self.state / "request.txt").read_text())

    def test_only_ticked_homes_get_hooks(self):
        code, out = self.run_tty(self.demo(), ["y", "n", "y", "y", "y"])
        self.assertEqual(code, 0, out)
        setup = self.find(["setup", "--yes"])[0]
        self.assertEqual(setup[setup.index("--hooks") + 1], "claude,codex")
        rec = self.read_record()
        self.assertEqual(rec["hooks_selected"], ["claude", "codex"])
        self.assertEqual(rec["history"], "yes")
        self.assertIn("onboard.history=yes", self.find(["assistant", "setup"])[0])
        self.assertIn("--sources pohunek --sources history --json", (self.state / "request.txt").read_text())

    def test_yes_with_hooks_selects_those_homes(self):
        r = self.run_tool(["--yes", "--hooks", "claude:work", *self.demo()])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        setup = self.find(["setup", "--yes"])[0]
        self.assertEqual(setup[setup.index("--hooks") + 1], "claude:work")
        r = self.run_tool(["--yes", "--hooks", "hermes", *self.demo()])
        self.assertEqual(r.returncode, 1)
        self.assertIn("not an agent home here", r.stderr)

    def test_an_old_core_is_refused_and_nothing_is_written(self):
        r = self.run_tool(["--yes", *self.demo()], {"DEMO_POHUNEK_VERSION": "0.41.0"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("pohunek 0.42.0 or newer is needed", r.stderr)
        self.assertEqual(self.argvs(), [["--version"]])
        self.assert_no_record()

    def test_a_core_that_refuses_hooks_is_refused_without_a_fallback(self):
        r = self.run_tool(["--yes", *self.demo()], {"DEMO_POHUNEK_NO_HOOKS": "1"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("refuses `setup --hooks`", r.stderr)
        self.assertEqual(self.writes(), [], "never falls back to bare setup --yes")
        self.assert_no_record()

    def test_without_a_terminal_and_without_yes_it_refuses(self):
        r = self.run_tool(self.demo())
        self.assertEqual(r.returncode, 2)
        self.assertIn("No terminal", r.stderr)
        self.assertEqual(self.argvs(), [])
        self.assert_no_record()

    def test_a_checksum_mismatch_stops_before_any_install(self):
        for broken in ({"sums_digest": "0" * 64}, {"notes_digest": "1" * 64}, {"notes": False}):
            with self.subTest(broken=broken):
                self.log.unlink(missing_ok=True)
                shutil.rmtree(self.state, ignore_errors=True)
                self.publish_assistant(**broken)
                r = self.run_tool(["--yes", *self.demo()])
                self.assertEqual(r.returncode, 1)
                self.assertIn("failed verification", r.stderr)
                self.assertEqual(self.writes(), [], "stopped before setup and plugin install")
                self.assert_no_record()

    def test_a_missing_assistant_release_starts_no_session(self):
        shutil.rmtree(self.fixtures / "github.com" / "pohunekd")
        r = self.run_tool(["--yes", *self.demo()])
        self.assertEqual(r.returncode, 1)
        self.assertIn("No assistant package was released for pohunek 0.42.0", r.stderr)
        self.assertEqual(self.find(["assistant", "setup"]), [])
        self.assertEqual(self.writes(), [])
        self.assert_no_record()

    def test_a_present_assistant_package_is_not_installed_again(self):
        shutil.rmtree(self.fixtures)
        self.fixtures.mkdir()
        r = self.run_tool(["--yes", *self.demo()], {"DEMO_POHUNEK_ASSISTANT": "present"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.find(["plugin", "install"]) + self.find(["plugin", "update"]), [])
        self.assertEqual(self.read_record()["assistant"]["source"], "present")

    def test_another_setup_problem_stops_before_the_tool_install(self):
        r = self.run_tool(["--yes", *self.demo()], {"DEMO_POHUNEK_EXTRA_PROBLEM": "1"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("doctor reports a failed check", r.stderr)
        self.assertEqual(self.find(["plugin", "install"]), [])
        self.assertEqual(self.find(["assistant", "setup"]), [])
        self.assert_no_record()

    def test_launch_only_skips_setup_and_asks_for_history(self):
        shutil.rmtree(self.fixtures)
        self.fixtures.mkdir()
        code, out = self.run_tty(["--launch-only", "--agent", "claude", *self.demo()], ["y", "y"],
                                 {"DEMO_POHUNEK_ASSISTANT": "present"})
        self.assertEqual(code, 0, out)
        self.assertEqual(self.find(["setup"]), [])
        rec = self.read_record()
        self.assertEqual((rec["agent"], rec["history"], rec["setup_result"], rec["assistant"], rec["hooks_selected"]),
                         ("claude", "yes", None, None, []))
        launch = self.find(["assistant", "setup"])[0]
        self.assertEqual(launch[launch.index("--agent") + 1], "claude")

    def test_launch_only_declined_writes_nothing(self):
        code, out = self.run_tty(["--launch-only", *self.demo()], ["n", "n"], {"DEMO_POHUNEK_ASSISTANT": "present"})
        self.assertEqual(code, 1, out)
        self.assertEqual(self.writes(), [])
        self.assert_no_record()

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "release archives are Linux x86_64")
    def test_a_fresh_machine_runs_setup_from_the_verified_archive(self):
        self.publish_core()
        r = self.run_tool(["--yes", "--command", str(self.root / "absent" / "pohunek")],
                          {"DEMO_POHUNEK_SERVICE": "install"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        setup = [c for c in calls if c["argv"][:1] == ["setup"]]
        self.assertTrue(setup and all(f"/{CORE}/pohunek" in c["bin"] for c in setup), "setup ran from the archive")
        later = [c for c in calls if c["argv"][:2] in (["plugin", "install"], ["assistant", "setup"])]
        installed = str(self.state / "prefix" / "bin" / "pohunek")
        self.assertTrue(later and all(c["bin"] == installed for c in later), "then the installed CLI")
        first_apply = next(i for i, c in enumerate(calls) if c["argv"][:2] == ["setup", "--yes"])
        self.assertFalse(any(c["argv"][:2] == ["plugin", "list"] for c in calls[:first_apply]),
                         "no daemon is asked before setup installed it")
        self.assertEqual(self.read_record()["assistant"]["source"], "tool")

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "release archives are Linux x86_64")
    def test_install_pohunek_uses_the_shared_verified_download(self):
        self.publish_core()
        code, out = self.run_tty([], ["n"], {"DEMO_POHUNEK_SERVICE": "install"}, tool=INSTALL)
        self.assertEqual(code, 1, out)
        self.assertIn("SHA-256: verified", out)
        self.assertIn("What the installer will do", out)
        self.assertIn("Cancelled; nothing was changed.", out)
        self.publish_core(corrupt=True)
        code, out = self.run_tty([], ["n"], {"DEMO_POHUNEK_SERVICE": "install"}, tool=INSTALL)
        self.assertEqual(code, 1, out)
        self.assertIn("Checksum mismatch", out)
        self.assertNotIn("What the installer will do", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
