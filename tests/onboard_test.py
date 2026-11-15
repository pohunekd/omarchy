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
ONBOARD_PROFILE = "pohunek-onboard"
# The Claude rules of the pohunek-onboard profile, copied from the table
# "Allowlist and floor" of docs/knowledge/guides/onboarding.md (pohunek 0.43.0).
CLAUDE_ALLOW = [
    "Bash(pohunek --version)", "Bash(pohunek health --json)", "Bash(pohunek doctor --json)",
    "Bash(pohunek service status --json)", "Bash(pohunek host inspect local --json)", "Bash(pohunek plugin list --json)",
    "Bash(pohunek plugin doctor --json)", "Bash(pohunek plugin profile list --all --json)",
    "Bash(pohunek integration status --all-profiles --json)", "Bash(pohunek integration doctor --all-profiles --json)",
    "Bash(pohunek project list --json)", "Bash(pohunek session list --json)", "Bash(pohunek project candidates --json)",
    'Bash(pohunek session metadata "$POHUNEK_SESSION_ID" --set onboard.state=done)']
HISTORY_ALLOW = "Bash(pohunek project candidates --sources pohunek --sources history --json)"
_DENY_HEAD = [
    "Bash(sudo *)", "Bash(pohunek *--host*)", "Bash(pohunek setup *)", "Bash(pohunek service install *)",
    "Bash(pohunek service upgrade *)", "Bash(pohunek service uninstall *)", "Bash(pohunek service refresh-path *)",
    "Bash(pohunek service lock *)", "Bash(pohunek plugin install *)", "Bash(pohunek plugin link *)",
    "Bash(pohunek plugin update *)", "Bash(pohunek plugin uninstall *)", "Bash(pohunek plugin enable *)",
    "Bash(pohunek plugin disable *)", "Bash(pohunek plugin select *)"]
_DENY_TAIL = [
    "Bash(pohunek plugin profile migrate *--digest*)", "Bash(pohunek plugin profile create *--arg*)",
    "Bash(pohunek integration install *--all-profiles*)", "Bash(pohunek integration install *--skill*)",
    "Bash(pohunek integration uninstall *)", "Bash(pohunek integration update *)", "Bash(pohunek plugin profile rm *)",
    "Bash(pohunek project rm *)", "Bash(pohunek session rm *)", "Bash(pohunek session stop *)",
    "Bash(pohunek session retention sweep *--apply*)", "Bash(pohunek session metadata *--clear*)",
    "Bash(pohunek session metadata *--set*--set*)", "Bash(pohunek session metadata */*)",
    "Read(~/.claude/projects/**)", "Read(~/.claude/.credentials.json)", "Read(~/.claude/history.jsonl)",
    "Read(~/.claude.json)", "Read(~/.codex/sessions/**)", "Read(~/.codex/history.jsonl)", "Read(~/.codex/auth.json)",
    "Read(~/.config/pohunek/agents/**)"]
CLAUDE_DENY = _DENY_HEAD + _DENY_TAIL
CLAUDE_DENY_NO_HISTORY = _DENY_HEAD + ["Bash(pohunek project candidates *history*)"] + _DENY_TAIL


def is_read_only(argv):
    """Commands that change nothing; everything else is a write."""
    return (argv[:1] == ["--version"]
            or (argv[:1] == ["setup"] and "--dry-run" in argv)
            or (argv[:3] == ["plugin", "profile", "create"] and "--dry-run" in argv)
            or argv[:2] in (["service", "check"], ["plugin", "list"], ["project", "list"], ["session", "list"],
                            ["integration", "status"], ["host", "inspect"])
            or argv[:3] == ["plugin", "profile", "list"])


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

    def publish_assistant(self, sums_digest=None, notes_digest=None, notes=True, version=VERSION):
        base = f"github.com/pohunekd/plugin-assistant/releases/download/v{version}"
        archive = f"pohunek.context.assistant-{version}.tar.zst"
        self.put(f"{base}/{archive}", self.archive)
        self.put(f"{base}/SHA256SUMS", f"{sums_digest or self.digest}  {archive}\n")
        body = "## Changes\r\n\r\nSomething.\r\n"
        if notes:
            body += f"\r\nAssistant package pohunek.context.assistant {version} sha256: {notes_digest or self.digest}\r\n"
        self.put(f"api.github.com/repos/zajca/pohunek/releases/tags/v{version}", json.dumps({"tag_name": f"v{version}", "body": body}))

    def publish_core(self, corrupt=False, version=VERSION):
        """A core release archive whose `pohunek` is tools/demo-pohunek."""
        core = f"pohunek-daemon-{version}-x86_64-unknown-linux-gnu"
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, data, mode in ((f"{core}/pohunek", DEMO.read_bytes(), 0o755),
                                     (f"{core}/packaging/install-daemon.sh", b"#!/bin/sh\nexit 0\n", 0o755)):
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), mode
                tar.addfile(info, io.BytesIO(data))
        data = buf.getvalue()
        digest = hashlib.sha256(b"other" if corrupt else data).hexdigest()
        base = f"github.com/zajca/pohunek/releases/download/v{version}"
        self.put(f"{base}/{core}.tar.gz", data)
        self.put(f"{base}/{core}.tar.gz.sha256", f"{digest}  {core}.tar.gz\n")
        self.put("api.github.com/repos/zajca/pohunek/releases/latest", json.dumps({"tag_name": f"v{version}"}))

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

    def stub_gh(self, attest_rc=0):
        """A `gh` stand-in inside the fixtures: signed in, logs its argv, prints
        the core release notes, and answers `attestation verify` with attest_rc."""
        notes = json.loads((self.fixtures / f"api.github.com/repos/zajca/pohunek/releases/tags/v{VERSION}").read_text())["body"]
        (self.fixtures / "gh-notes.txt").write_text(notes)
        stub = self.fixtures / "gh"
        stub.write_text(f"""#!/usr/bin/env bash
printf '%s\\0' "$@" >>'{self.tmp}/gh-calls'
printf '\\n' >>'{self.tmp}/gh-calls'
case "$1 $2" in
"auth status") exit 0 ;;
"release view") cat '{self.fixtures}/gh-notes.txt'; exit 0 ;;
"attestation verify") exit {attest_rc} ;;
esac
exit 3
""")
        stub.chmod(0o755)
        return {"POHUNEK_ONBOARD_TEST_GH": str(stub)}

    def gh_calls(self):
        path = self.tmp / "gh-calls"
        if not path.exists():
            return []
        return [line.rstrip("\0").split("\0") for line in path.read_text().split("\n") if line]

    def seed_packages(self, *packages):
        """Installed packages the fake daemon reports (PackageInfo shape)."""
        self.state.mkdir(exist_ok=True)
        (self.state / "packages.json").write_text(json.dumps([
            {"digest": digest, "package": {"id": "pohunek.context.assistant", "version": version}, "origin": "local",
             "enabled": enabled, "selected": True, "installed_at_unix_seconds": 1, "referenced": False}
            for version, digest, enabled in packages]))

    # ---------------------------------------------------------------- scenarios
    def test_declining_at_the_one_yes_writes_nothing(self):
        before = self.home_tree()
        # claude y (skill n), claude:work n, codex y (skill n), history y, mode guided, apply n
        code, out = self.run_tty(self.demo(), ["y", "n", "n", "y", "n", "y", "n", "n"])
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
                                 ["assistant", "setup"], ["attach", order[-1][1]]], order)
        first_apply = next(i for i, a in enumerate(self.argvs()) if a[:2] == ["setup", "--yes"])
        self.assertIn(["project", "list", "--json"], self.argvs()[:first_apply], "the snapshot is read before setup")
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
        self.assertEqual(sorted(rec["snapshot"]), ["agents", "integrations", "profiles", "projects", "sessions", "taken"])
        self.assertEqual(rec["snapshot"]["taken"], "before_setup")
        self.assertEqual((rec["grant"], rec["profile"], rec["skills"]), (None, None, []))
        self.assertEqual(self.find(["plugin", "profile", "create"]), [], "guided mode writes no profile")
        self.assertEqual(rec["snapshot"]["profiles"], [{"name": "work", "file_digest": "sha256:" + "ef" * 32}])
        self.assertIn(f"onboard.run={rec['run_id']}", launch)
        self.assertIn("onboard.mode=guided", launch)
        self.assertIn("onboard.history=no", launch)
        self.assertFalse(any(a.startswith("onboard.grant") for a in launch), "guided mode passes no grant")
        self.assertEqual(rec["session_id"], json.loads((self.state / "sessions.json").read_text())[0]["id"])
        request = (self.state / "request.txt").read_text()
        self.assertIn("do not read agent history", request)
        self.assertIn("ask me in this conversation before you run it", request)
        self.assertIn("never pass --host and never a <host>/<session-id> target", request)

    def test_only_ticked_homes_get_hooks(self):
        code, out = self.run_tty(self.demo(), ["y", "n", "n", "y", "n", "y", "n", "y"])
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
        self.assertIn("refuses `setup --dry-run --json --hooks all`", r.stderr)
        self.assertIn("unexpected argument '--hooks' found", r.stderr, "the core's own message is shown")
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

    def test_the_attestation_binds_the_signer_workflow_at_the_release_tag(self):
        gh = self.stub_gh(attest_rc=0)
        shutil.rmtree(self.fixtures / "api.github.com")  # the notes come through gh
        r = self.run_tool(["--yes", *self.demo()], gh)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("GitHub build attestation: verified.", r.stdout)
        calls = self.gh_calls()
        self.assertIn(["release", "view", f"v{VERSION}", "--repo", "zajca/pohunek", "--json", "body", "--jq", ".body"], calls)
        attest = [c for c in calls if c[:2] == ["attestation", "verify"]]
        self.assertEqual(len(attest), 1, calls)
        self.assertTrue(attest[0][2].endswith("/" + ASSISTANT), attest[0])
        self.assertEqual(attest[0][3:], [
            "--repo", "pohunekd/plugin-assistant",
            "--cert-identity", f"https://github.com/zajca/pohunek/.github/workflows/plugin-release.yml@refs/tags/v{VERSION}",
            "--source-ref", f"refs/tags/v{VERSION}"])

    def test_a_failed_attestation_stops_before_any_write(self):
        r = self.run_tool(["--yes", *self.demo()], self.stub_gh(attest_rc=1))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("Attestation check failed", r.stderr)
        self.assertTrue(any(c[:2] == ["attestation", "verify"] for c in self.gh_calls()))
        self.assertEqual(self.writes(), [])
        self.assert_no_record()

    def test_a_stub_gh_outside_the_fixtures_is_refused(self):
        outside = self.tmp / "gh"
        outside.write_text("#!/usr/bin/env bash\nexit 0\n")
        outside.chmod(0o755)
        r = self.run_tool(["--yes", *self.demo()], {"POHUNEK_ONBOARD_TEST_GH": str(outside)})
        self.assertEqual(r.returncode, 1)
        self.assertIn("POHUNEK_ONBOARD_TEST_GH must name", r.stderr)
        self.assertEqual(self.argvs(), [])

    def test_an_older_installed_package_is_updated(self):
        self.seed_packages(("0.41.0", "sha256:" + "41" * 32, True))
        r = self.run_tool(["--yes", *self.demo()])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("plugin update   pohunek.context.assistant to 0.42.0", r.stdout)
        self.assertEqual(self.find(["plugin", "install"]), [])
        update = self.find(["plugin", "update"])
        self.assertEqual(len(update), 1)
        self.assertEqual(update[0][2], "pohunek.context.assistant")
        self.assertEqual(update[0][update[0].index("--sha256") + 1], self.digest)
        self.assertEqual(self.read_record()["assistant"], {"source": "tool", "version": VERSION, "digest": "sha256:" + self.digest})

    def test_a_newer_selected_package_is_kept(self):
        self.seed_packages(("0.43.0", "sha256:" + "43" * 32, True))
        r = self.run_tool(["--yes", *self.demo()])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.find(["plugin", "install"]) + self.find(["plugin", "update"]), [])
        self.assertEqual(self.read_record()["assistant"], {"source": "present", "version": "0.43.0", "digest": "sha256:" + "43" * 32})

    def test_the_same_digest_disabled_is_left_to_the_owner(self):
        self.seed_packages((VERSION, "sha256:" + self.digest, False))
        r = self.run_tool(["--yes", *self.demo()])
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"pohunek plugin enable pohunek.context.assistant --digest sha256:{self.digest}", r.stderr)
        self.assertEqual(self.writes(), [])
        self.assert_no_record()

    def test_an_installed_digest_other_than_the_verified_one_stops(self):
        r = self.run_tool(["--yes", *self.demo()], {"DEMO_POHUNEK_INSTALL_DIGEST": "sha256:" + "66" * 32})
        self.assertEqual(r.returncode, 1)
        self.assertIn("installed a package digest other than the verified one", r.stderr)
        self.assertEqual(len(self.find(["plugin", "install"])), 1)
        self.assertEqual(self.find(["assistant", "setup"]), [])
        self.assert_no_record()

    def test_an_unsafe_record_path_stops_before_the_yes(self):
        state = self.home / ".local" / "state"
        state.mkdir(parents=True)
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (state / "omarchy").symlink_to(elsewhere)
        for args in (["--yes", *self.demo()], ["--launch-only", "--yes", *self.demo()]):
            with self.subTest(args=args):
                r = self.run_tool(args, {"DEMO_POHUNEK_ASSISTANT": "present"})
                self.assertEqual(r.returncode, 1)
                self.assertIn("cannot be written safely", r.stderr)
                self.assertIn("Nothing was changed.", r.stderr)
                self.assertEqual(self.writes(), [])
                self.assertEqual(list(elsewhere.iterdir()), [])

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
        code, out = self.run_tty(["--launch-only", "--agent", "claude", *self.demo()], ["y", "n", "y"],
                                 {"DEMO_POHUNEK_ASSISTANT": "present"})
        self.assertEqual(code, 0, out)
        self.assertEqual(self.find(["setup"]), [])
        rec = self.read_record()
        self.assertEqual((rec["agent"], rec["history"], rec["setup_result"], rec["assistant"], rec["hooks_selected"]),
                         ("claude", "yes", None, None, []))
        launch = self.find(["assistant", "setup"])[0]
        self.assertEqual(launch[launch.index("--agent") + 1], "claude")

    def test_launch_only_declined_writes_nothing(self):
        code, out = self.run_tty(["--launch-only", *self.demo()], ["n", "n", "n"], {"DEMO_POHUNEK_ASSISTANT": "present"})
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

    # ------------------------------------------------- automatic mode and undo
    def pohunek(self, *argv, extra=None):
        """Calls the fake as the onboard agent or the user would, outside the tool's log."""
        env = self.env(extra)
        env.pop("DEMO_POHUNEK_LOG")
        r = subprocess.run([str(DEMO), *argv], env=env, capture_output=True, text=True, timeout=60)
        doc = json.loads(r.stdout) if r.stdout.strip().startswith("{") else None
        return r.returncode, doc

    def lists(self, extra=None):
        """What Undo must restore: projects, profiles, groups, hooks and skills per home."""
        _, projects = self.pohunek("project", "list", "--json", extra=extra)
        _, profiles = self.pohunek("plugin", "profile", "list", "--all", "--json", extra=extra)
        _, sessions = self.pohunek("session", "list", "--json", extra=extra)
        _, status = self.pohunek("integration", "status", "--all-profiles", "--json", extra=extra)
        return {
            "projects": sorted(p["id"] for p in projects["ok"]),
            "profiles": sorted((p["name"], p["file_digest"]) for p in profiles["ok"]["profiles"]),
            "groups": {r["id"]: r["metadata"].get("companion.group") for r in sessions["ok"]
                       if not r["metadata"].get("onboard.mode")},
            "homes": sorted((a["agent"], json.dumps(a["home"], sort_keys=True), a["state"], a["skill"]["state"])
                            for a in status["ok"]["agents"]),
        }

    def end_onboard_session(self):
        path = self.state / "sessions.json"
        rows = json.loads(path.read_text())
        for row in rows:
            row["state"], row["activity"] = "stopped", None
        path.write_text(json.dumps(rows))

    def auto_env(self, **more):
        return {"DEMO_POHUNEK_VERSION": "0.43.0", "DEMO_POHUNEK_ASSISTANT": "present", **more}

    def profile_create_args(self):
        create = self.find(["plugin", "profile", "create"])
        self.assertEqual(len(create), 1, create)
        argv = create[0]
        self.assertEqual(argv[3:6], [ONBOARD_PROFILE, "--base", argv[5]])
        values = [argv[i + 1] for i, a in enumerate(argv) if a == "--arg"]
        self.assertEqual(sum(1 for a in argv if a == "--arg") * 2 + 6 + (2 if "--replace" in argv else 0) + 1, len(argv),
                         f"only --arg pairs, --replace and --json follow the base: {argv}")
        for flag in ("--home", "--secret-env", "--dry-run"):
            self.assertNotIn(flag, argv)
        return argv, values

    def test_run_then_undo_restores_the_exact_pre_run_lists(self):
        auto = self.auto_env()
        before = self.lists(auto)
        r = self.run_tool(["--yes", "--mode", "automatic", "--grant", "projects,groups,profiles,profile-hooks",
                           "--hooks", "claude,codex", "--skill", "claude", *self.demo()], auto)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        rec = self.read_record()
        self.assertEqual((rec["mode"], rec["grant"]), ("automatic", ["projects", "groups", "profiles", "profile-hooks"]))
        self.assertEqual(rec["profile"]["name"], ONBOARD_PROFILE)
        self.assertEqual(rec["profile"]["replaced"], None)
        self.assertEqual(rec["skills"], [{"home": "claude", "state": "created"}])
        launch = self.find(["assistant", "setup"])[0]
        self.assertIn("onboard.grant=projects,groups,profiles,profile-hooks", launch)
        self.assertEqual(launch[launch.index("--agent") + 1], ONBOARD_PROFILE)
        self.assertIn("automatic mode", (self.state / "request.txt").read_text())

        # The onboard agent at work: a project, a group, a profile with hooks, a CLI update.
        self.pohunek("project", "add", "/home/dev/code/new-repo", "--name", "new-repo", "--json", extra=auto)
        self.pohunek("session", "metadata", "s-01JDEMO00000000000000000A1", "--set", "companion.group=Reviews", "--json", extra=auto)
        code, made = self.pohunek("plugin", "profile", "create", "side", "--base", "claude", "--home", "/home/dev/.claude-side",
                                  "--json", extra=auto)
        self.assertEqual(code, 0, made)
        self.pohunek("integration", "install", "--agent", "claude", "--profile", "side", "--json", extra=auto)
        (self.state / "cli-versions.json").write_text(json.dumps({"claude": "2.2.0"}))

        r = self.run_tool(["--undo", "--yes", *self.demo()], auto)
        self.assertEqual(r.returncode, 1, "the onboard session still runs")
        self.assertIn("is still running", r.stderr)
        self.assertEqual([a for a in self.writes() if a[:2] == ["project", "rm"] or a[:3] == ["plugin", "profile", "rm"]], [])

        self.end_onboard_session()
        self.log.unlink()
        r = self.run_tool(["--undo", "--yes", *self.demo()], auto)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        after = self.lists(auto)
        self.assertEqual(after, before, "projects, profiles, groups, hooks and skills are back to the pre-run state")
        writes = [a for a in self.writes() if a[:1] != ["--version"]]
        self.assertEqual([a[:3] for a in writes], [
            ["project", "rm", "p-" + hashlib.sha256(b"/home/dev/code/new-repo").hexdigest()[:8]],
            ["plugin", "profile", "rm"],                                           # pohunek-onboard
            ["integration", "uninstall", "--agent"], ["plugin", "profile", "rm"],  # side: its hooks, then the profile
            ["session", "metadata", "s-01JDEMO00000000000000000A1"],
            ["integration", "uninstall", "--agent"], ["integration", "uninstall", "--agent"]], writes)
        self.assertEqual(writes[1][3], ONBOARD_PROFILE)
        self.assertEqual(writes[2], ["integration", "uninstall", "--agent", "claude", "--profile", "side", "--json"])
        self.assertEqual(writes[4][3:], ["--clear", "companion.group", "--json"])
        self.assertEqual(writes[5:], [["integration", "uninstall", "--agent", "claude", "--json"],
                                      ["integration", "uninstall", "--agent", "codex", "--json"]],
                         "hooks setup installed and the skill of claude, after the profiles")
        self.assertIn("not reverted: claude was updated from 2.1.3 to 2.2.0", r.stdout)
        self.assertNotIn(["plugin", "uninstall"], [a[:2] for a in writes], "--yes never removes the assistant package")
        self.assertNotIn(["service", "uninstall"], [a[:2] for a in writes], "--yes never uninstalls the service")
        self.assertIn("pohunek service uninstall", r.stdout)
        rec = self.read_record()
        self.assertTrue(rec["undone_at"])
        self.assertEqual(rec["undo"]["failed"], [])
        self.assertEqual(rec["diff"]["agent_versions"], [{"agent": "claude", "before": "2.1.3", "after": "2.2.0"}])
        r = self.run_tool(["--undo", "--yes", *self.demo()], auto)
        self.assertEqual(r.returncode, 0)
        self.assertIn("nothing is left to undo", r.stdout)

    def test_an_edited_profile_is_kept_and_named(self):
        auto = self.auto_env()
        r = self.run_tool(["--yes", "--mode", "automatic", "--grant", "profiles", *self.demo()], auto)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        _, made = self.pohunek("plugin", "profile", "create", "side", "--base", "claude", "--home", "/home/dev/.claude-side",
                               "--json", extra=auto)
        self.end_onboard_session()
        # The next start of the tool records the diff of the ended run; this one stops at the question.
        code, out = self.run_tty(["--undo", *self.demo()], ["n"], auto)
        self.assertEqual(code, 1, out)
        diff = self.read_record()["diff"]
        self.assertEqual([p["name"] for p in diff["profiles_created"]], [ONBOARD_PROFILE, "side"])
        _, edited = self.pohunek("plugin", "profile", "create", "side", "--base", "claude", "--home", "/home/dev/.claude-side",
                                 "--secret-env", "EXTRA_TOKEN", "--replace", made["ok"]["file_digest"], "--json", extra=auto)
        r = self.run_tool(["--undo", "--yes", *self.demo()], auto)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"kept: profile side: edited after onboarding (now {edited['ok']['file_digest']})", r.stdout)
        removed = [a[3] for a in self.find(["plugin", "profile", "rm"])]
        self.assertEqual(removed, [ONBOARD_PROFILE], "only the unchanged profile is removed")
        names = [p["name"] for p in self.pohunek("plugin", "profile", "list", "--all", "--json", extra=auto)[1]["ok"]["profiles"]]
        self.assertIn("side", names)
        self.assertTrue(self.read_record()["undone_at"])

    def test_undo_asks_once_and_the_assistant_and_service_default_to_no(self):
        r = self.run_tool(["--yes", "--mode", "guided", *self.demo()])  # gap: the tool installs the assistant
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.pohunek("project", "add", "/home/dev/code/new-repo", "--name", "new-repo", "--json")
        self.end_onboard_session()
        r = self.run_tool(["--undo", *self.demo()])
        self.assertEqual(r.returncode, 2, "no terminal and no --yes")
        self.assertIn("No terminal", r.stderr)
        code, out = self.run_tty(["--undo", *self.demo()], ["n"])
        self.assertEqual(code, 1, out)
        self.assertIn("Cancelled; nothing was changed.", out)
        self.assertEqual(self.find(["project", "rm"]), [])
        # Yes to the list; Enter (no) to the assistant package; yes to the service, which refuses.
        code, out = self.run_tty(["--undo", *self.demo()], ["y", "", "y"])
        self.assertEqual(code, 0, out)
        self.assertEqual(len(self.find(["project", "rm"])), 1)
        self.assertEqual(self.find(["plugin", "uninstall"]), [], "the assistant package stays by default")
        self.assertIn("pohunek plugin uninstall pohunek.context.assistant --digest sha256:" + self.digest, out)
        self.assertEqual(len(self.find(["service", "uninstall"])), 1)
        self.assertIn("uninstall refused: live sessions remain", out, "the core's own refusal is shown")
        self.assertNotIn("--stop-sessions", self.find(["service", "uninstall"])[0])

    def test_a_stale_profile_digest_stops_the_run(self):
        auto = self.auto_env()
        self.pohunek("plugin", "profile", "create", ONBOARD_PROFILE, "--base", "claude", "--json", extra=auto)
        r = self.run_tool(["--yes", "--mode", "automatic", "--grant", "none", *self.demo()],
                          {**auto, "DEMO_POHUNEK_PROFILE_CHANGED": ONBOARD_PROFILE})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("changed while this tool was writing it", r.stderr)
        listed = self.pohunek("plugin", "profile", "list", "--all", "--json", extra=auto)[1]["ok"]["profiles"]
        digest = next(p["file_digest"] for p in listed if p["name"] == ONBOARD_PROFILE)
        self.assertIn(f"replaces the existing {ONBOARD_PROFILE} ({digest}) at that digest", r.stdout, "the preview says so")
        self.assertIn("is not the file version the request named", r.stderr, "the core's own message is shown")
        create = self.find(["plugin", "profile", "create"])[0]
        self.assertEqual(create[create.index("--replace") + 1], digest, "replaced only at the digest the preview showed")
        first_list = next(i for i, a in enumerate(self.argvs()) if a[:3] == ["plugin", "profile", "list"])
        first_apply = next(i for i, a in enumerate(self.argvs()) if a[:2] == ["setup", "--yes"])
        self.assertLess(first_list, first_apply, "the digest is read before the yes")
        self.assertEqual(self.find(["assistant", "setup"]), [], "no session starts")
        self.assert_no_record()

    def test_guided_mode_writes_no_profile(self):
        for args in (["--yes", "--mode", "guided"], ["--launch-only", "--yes"]):
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                r = self.run_tool([*args, *self.demo()], self.auto_env())
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.find(["plugin", "profile", "create"]), [])
                launch = self.find(["assistant", "setup"])[0]
                self.assertIn("onboard.mode=guided", launch)
                self.assertFalse(any(a.startswith("onboard.grant") for a in launch))
                self.assertNotIn(ONBOARD_PROFILE, launch)
                self.assertIsNone(self.read_record()["profile"])

    def test_the_profile_allows_only_the_granted_items(self):
        cases = [
            ("none", "no", CLAUDE_ALLOW, CLAUDE_DENY_NO_HISTORY),
            ("projects", "no", CLAUDE_ALLOW + ["Bash(pohunek project add *)"], CLAUDE_DENY_NO_HISTORY),
            ("groups,cli-update", "yes", CLAUDE_ALLOW + [HISTORY_ALLOW, "Bash(pohunek session metadata * --set companion.group=*)",
                                                       "Bash(claude update)", "Bash(codex update)"], CLAUDE_DENY),
            ("profiles,profile-hooks", "no", CLAUDE_ALLOW + ["Bash(pohunek plugin profile migrate * --yes)"], CLAUDE_DENY_NO_HISTORY),
        ]
        for grant, history, allow, deny in cases:
            with self.subTest(grant=grant, history=history):
                self.log.unlink(missing_ok=True)
                shutil.rmtree(self.state, ignore_errors=True)
                r = self.run_tool(["--launch-only", "--yes", "--mode", "automatic", "--grant", grant, "--history", history,
                                   "--agent", "claude", *self.demo()], self.auto_env())
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                argv, values = self.profile_create_args()
                self.assertEqual(argv[5], "claude")
                self.assertEqual(values[0], "--allowedTools")
                cut = values.index("--disallowedTools")
                self.assertEqual(values[1:cut], allow)
                self.assertEqual(values[cut + 1:-2], deny)
                self.assertEqual(values[-2:], ["--permission-mode", "default"])
                launch = self.find(["assistant", "setup"])[0]
                self.assertIn("onboard.grant=" + ("" if grant == "none" else grant), launch)

    def test_codex_gets_the_guides_approval_profile(self):
        r = self.run_tool(["--launch-only", "--yes", "--mode", "automatic", "--grant", "projects", "--agent", "codex",
                           *self.demo()], self.auto_env())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        argv, values = self.profile_create_args()
        self.assertEqual(argv[5], "codex")
        self.assertEqual(values, ["--ask-for-approval", "on-request", "--sandbox", "workspace-write",
                                  "-c", "sandbox_workspace_write.network_access=false"])

    def test_automatic_mode_refuses_what_it_cannot_enforce(self):
        r = self.run_tool(["--launch-only", "--yes", "--mode", "automatic", "--grant", "none", *self.demo()],
                          {"DEMO_POHUNEK_ASSISTANT": "present"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("Automatic mode needs pohunek 0.43.0 or newer", r.stderr)
        self.assertEqual(self.writes(), [])
        r = self.run_tool(["--launch-only", "--yes", "--mode", "automatic", "--grant", "none", "--agent", "pi",
                           *self.demo()], self.auto_env())
        self.assertEqual(r.returncode, 1)
        self.assertIn("runs under Claude or Codex", r.stderr)
        self.assertEqual(self.writes(), [])
        r = self.run_tool(["--launch-only", "--yes", "--mode", "automatic", *self.demo()], self.auto_env())
        self.assertEqual(r.returncode, 2, "no grant is implied by --yes")
        r = self.run_tool(["--launch-only", "--yes", "--mode", "automatic", "--grant", "managers", *self.demo()], self.auto_env())
        self.assertEqual(r.returncode, 2, "managers is never offered")
        self.assert_no_record()

    def test_the_grant_screen_turns_items_off(self):
        # history n, mode automatic, grant: projects y, groups n, profiles Enter (on), profile-hooks n, cli-update n, start y
        code, out = self.run_tty(["--launch-only", "--agent", "claude", *self.demo()], ["n", "y", "y", "n", "", "n", "n", "y"],
                                 self.auto_env())
        self.assertEqual(code, 0, out)
        self.assertIn("applies the items you grant without asking", out)
        self.assertEqual(self.read_record()["grant"], ["projects", "profiles"])
        self.assertIn("onboard.grant=projects,profiles", self.find(["assistant", "setup"])[0])

    def test_the_skill_is_offered_per_home_only_with_skill_support(self):
        # claude y, its skill y, claude:work n, codex n, history n, mode guided, apply y
        code, out = self.run_tty(self.demo(), ["y", "y", "n", "n", "n", "n", "y"], {"DEMO_POHUNEK_ASSISTANT": "present"})
        self.assertEqual(code, 0, out)
        self.assertEqual(self.find(["integration", "install"]),
                         [["integration", "install", "--agent", "claude", "--skill", "--json"]])
        first_apply = next(i for i, a in enumerate(self.argvs()) if a[:2] == ["setup", "--yes"])
        install = next(i for i, a in enumerate(self.argvs()) if a[:2] == ["integration", "install"])
        self.assertGreater(install, first_apply, "the skill is installed after setup")
        self.assertEqual(self.read_record()["skills"], [{"home": "claude", "state": "created"}])
        self.log.unlink()
        shutil.rmtree(self.state)
        code, out = self.run_tty(self.demo(), ["y", "n", "n", "n", "n", "y"],
                                 {"DEMO_POHUNEK_ASSISTANT": "present", "DEMO_POHUNEK_NO_SKILL": "1"})
        self.assertEqual(code, 0, out)
        self.assertNotIn("agent skill, so", out)
        self.assertIn("pohunek 0.42.0 or newer installs it", out)
        self.assertEqual(self.find(["integration", "install"]), [])
        r = self.run_tool(["--yes", "--hooks", "claude", "--skill", "claude", *self.demo()],
                          {"DEMO_POHUNEK_ASSISTANT": "present", "DEMO_POHUNEK_NO_SKILL": "1"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("offers no agent skill", r.stderr)

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "release archives are Linux x86_64")
    def test_automatic_mode_on_a_fresh_machine(self):
        self.publish_core(version="0.43.0")
        self.publish_assistant(version="0.43.0")
        fresh = {"DEMO_POHUNEK_SERVICE": "install", "DEMO_POHUNEK_VERSION": "0.43.0"}
        absent = ["--command", str(self.root / "absent" / "pohunek")]
        r = self.run_tool(["--yes", "--mode", "automatic", "--grant", "none", "--agent", "work", *absent], fresh)
        self.assertEqual(r.returncode, 1)
        self.assertIn("cannot be checked before pohunek is installed", r.stderr)
        self.assertEqual(self.writes(), [], "refused before setup")
        r = self.run_tool(["--yes", "--mode", "automatic", "--grant", "projects", *absent], fresh)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        argvs = self.argvs()
        first_apply = next(i for i, a in enumerate(argvs) if a[:2] == ["setup", "--yes"])
        create = next(i for i, a in enumerate(argvs) if a[:3] == ["plugin", "profile", "create"])
        self.assertGreater(create, first_apply, "the profile is written once the daemon runs")
        self.assertEqual(argvs[create][5], "codex", "no agent picked: the assistant's order")
        rec = self.read_record()
        self.assertEqual((rec["mode"], rec["grant"], rec["snapshot"]["taken"]), ("automatic", ["projects"], "after_setup"))

    def test_undo_passes_only_well_formed_record_values(self):
        r = self.run_tool(["--launch-only", "--yes", *self.demo()], self.auto_env())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.end_onboard_session()
        rec = self.read_record()
        rec["diff"] = {"projects_added": ["--prune-worktrees"], "groups_known": True, "agent_versions": [],
                       "profiles_created": [{"name": "../work", "file_digest": "sha256:" + "ab" * 32},
                                            {"name": "x", "file_digest": "--json"}],
                       "groups_set": [{"session_id": "-s", "group": "G"}],
                       "integrations": [{"agent": "--all-profiles", "profile": None, "hooks": True, "skill": False}]}
        self.record.write_text(json.dumps(rec))
        r = self.run_tool(["--undo", "--yes", *self.demo()], self.auto_env())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual([a for a in self.writes() if a[:1] != ["--version"] and a[:2] != ["assistant", "help"]
                          and a[:2] != ["assistant", "setup"] and a[:1] != ["attach"]], [],
                         "no malformed value reaches a command")

    def test_the_diff_is_computed_from_the_snapshot_alone(self):
        status = lambda *homes: {"agents": [{"agent": a, "state": st, "home": {"selector": sel}, "skill": {"state": sk}}
                                            for a, sel, st, sk in homes]}
        default, work = {"kind": "default"}, {"kind": "profile", "name": "work"}
        snapshot = {"projects": ["p-1"], "profiles": [{"name": "work", "file_digest": "sha256:aa"}],
                    "integrations": status(("claude", default, "not_installed", "absent"), ("codex", default, "current", "absent"),
                                           ("codex", work, "not_installed", "absent")),
                    "sessions": [{"id": "s-a", "group": None}, {"id": "s-b", "group": "Old"}],
                    "agents": [{"agent": "claude", "version": "2.1.3"}, {"agent": "codex", "version": "0.169.0"}]}
        now = {"projects": [{"id": "p-1"}, {"id": "p-2"}],
               "profiles": {"profiles": [{"name": "work", "file_digest": "sha256:bb"}, {"name": "new", "file_digest": "sha256:cc"}]},
               "integrations": status(("claude", default, "current", "current"), ("codex", default, "current", "current"),
                                      ("codex", work, "not_installed", "current"),
                                      ("claude", {"kind": "profile", "name": "new"}, "current", "absent")),
               "sessions": [{"id": "s-a", "metadata": {"companion.group": "G"}}, {"id": "s-b", "metadata": {"companion.group": "New"}},
                            {"id": "s-own", "metadata": {"companion.group": "X"}}, {"id": "s-later", "metadata": {"companion.group": "Y"}}],
               "inspect": {"runtimes": [{"agent": "claude", "agent_base": "claude", "version": "2.2.0"},
                                        {"agent": "codex", "agent_base": "codex", "version": "0.169.0"},
                                        {"agent": "work", "agent_base": "claude", "version": "9"}]}}
        out = subprocess.run(["jq", "-n", "--argjson", "snapshot", json.dumps(snapshot), "--argjson", "now", json.dumps(now),
                              "--arg", "own", "s-own", "-f", str(ROOT / "tools" / "onboard-diff.jq")],
                             capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(out.stdout), {
            "projects_added": ["p-2"],
            "profiles_created": [{"name": "new", "file_digest": "sha256:cc"}],
            "groups_known": True,
            "groups_set": [{"session_id": "s-a", "group": "G"}],
            "integrations": [{"agent": "claude", "profile": None, "hooks": True, "skill": True},
                             {"agent": "codex", "profile": None, "hooks": False, "skill": True},
                             {"agent": "codex", "profile": "work", "hooks": False, "skill": True},
                             {"agent": "claude", "profile": "new", "hooks": True, "skill": False}],
            "agent_versions": [{"agent": "claude", "before": "2.1.3", "after": "2.2.0"}]})
        del snapshot["sessions"], snapshot["agents"]
        out = subprocess.run(["jq", "-n", "--argjson", "snapshot", json.dumps(snapshot), "--argjson", "now", json.dumps(now),
                              "--arg", "own", "s-own", "-f", str(ROOT / "tools" / "onboard-diff.jq")],
                             capture_output=True, text=True, check=True)
        doc = json.loads(out.stdout)
        self.assertEqual((doc["groups_known"], doc["groups_set"], doc["agent_versions"]), (False, [], []),
                         "a record without session groups clears none")


if __name__ == "__main__":
    unittest.main(verbosity=2)
