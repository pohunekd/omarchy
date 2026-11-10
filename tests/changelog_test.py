#!/usr/bin/env python3
"""Contract tests of scripts/changelog.py: fold, notes and check rules, byte
for byte against the ecosystem fixtures. Run: python3 -I tests/changelog_test.py"""
import importlib.util
import io
import os
import shutil
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "changelog"

loader = SourceFileLoader("changelog_tool", str(ROOT / "scripts" / "changelog.py"))
spec = importlib.util.spec_from_loader("changelog_tool", loader)
tool = importlib.util.module_from_spec(spec)
loader.exec_module(tool)


def single_config():
    return tool.Config("example/app", changelog=Path("CHANGELOG.md"))


def multi_config():
    return tool.Config(
        "example/work",
        surfaces={"plugin": Path("plugin/CHANGELOG.md"), "web": Path("web/CHANGELOG.md")},
    )


def read(path):
    return Path(path).read_text(encoding="utf-8")


class Scratch(unittest.TestCase):
    def scratch(self, source=None):
        directory = Path(tempfile.mkdtemp(prefix="changelog-test-"))
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        if source is not None:
            shutil.copytree(source, directory, dirs_exist_ok=True)
        return directory

    def fragment_repo(self, name, content, config=None):
        root = self.scratch()
        (root / "changelog.d").mkdir()
        (root / "changelog.d" / name).write_bytes(content.encode("utf-8"))
        return root, config or single_config()

    def accepts(self, name, content, config=None):
        root, config = self.fragment_repo(name, content, config)
        try:
            tool.check(root, config)
            return True
        except tool.ChangelogError:
            return False


class FoldAndNotes(Scratch):
    def test_single_product_fold_and_notes_match_fixtures(self):
        root = self.scratch(FIXTURES / "single" / "input")
        config = single_config()
        tool.fold(root, config, "0.37.0", "2026-10-24")
        self.assertEqual(read(root / "CHANGELOG.md"), read(FIXTURES / "single/expected-0.37.0/CHANGELOG.md"))
        self.assertEqual(os.listdir(root / "changelog.d"), [])
        self.assertEqual(tool.notes(root, config, "0.37.0"), read(FIXTURES / "single/expected-0.37.0/notes.md"))
        tool.fold(root, config, "0.37.1", "2026-10-25")
        self.assertEqual(read(root / "CHANGELOG.md"), read(FIXTURES / "single/expected-0.37.1/CHANGELOG.md"))
        self.assertEqual(tool.notes(root, config, "0.37.1"), read(FIXTURES / "single/expected-0.37.1/notes.md"))

    def test_surface_fold_removes_only_the_released_surface(self):
        root = self.scratch(FIXTURES / "multi" / "input")
        tool.fold(root, multi_config(), "0.8.0", "2026-10-24", "plugin")
        expected = FIXTURES / "multi" / "expected-plugin-0.8.0"
        self.assertEqual(read(root / "plugin/CHANGELOG.md"), read(expected / "plugin/CHANGELOG.md"))
        self.assertEqual(read(root / "web/CHANGELOG.md"), read(FIXTURES / "multi/input/web/CHANGELOG.md"))
        names = sorted(os.listdir(expected / "changelog.d"))
        self.assertEqual(sorted(os.listdir(root / "changelog.d")), names)
        for name in names:
            self.assertEqual(read(root / "changelog.d" / name), read(expected / "changelog.d" / name), name)

    def test_surface_notes_ignore_fragments_of_other_surfaces(self):
        root = self.scratch(FIXTURES / "multi" / "input")
        tool.fold(root, multi_config(), "0.8.0", "2026-10-24", "plugin")
        # 31-shared-hosts and 32-web-dark-mode still name web.
        with self.assertRaisesRegex(tool.ChangelogError, "not folded"):
            tool.notes(root, multi_config(), "0.8.0", "web")
        self.assertIn("### Changed", tool.notes(root, multi_config(), "0.8.0", "plugin"))

    def test_notes_refuse_unfolded_fragments(self):
        root = self.scratch(FIXTURES / "single" / "input")
        with self.assertRaisesRegex(tool.ChangelogError, "not folded"):
            tool.notes(root, single_config(), "0.37.0")

    def test_fold_refuses_an_existing_version(self):
        root = self.scratch(FIXTURES / "single" / "input")
        tool.fold(root, single_config(), "0.37.0", "2026-10-24")
        with self.assertRaisesRegex(tool.ChangelogError, "already has a section"):
            tool.fold(root, single_config(), "0.37.0", "2026-10-24")

    def test_fold_writes_nothing_when_a_fragment_is_invalid(self):
        root = self.scratch(FIXTURES / "single" / "input")
        (root / "changelog.d" / "99-bad.md").write_text("no header\n")
        before = read(root / "CHANGELOG.md")
        with self.assertRaises(tool.ChangelogError):
            tool.fold(root, single_config(), "0.37.0", "2026-10-24")
        self.assertEqual(read(root / "CHANGELOG.md"), before)
        self.assertEqual(len(os.listdir(root / "changelog.d")), 6)

    def test_fold_without_fragments_writes_the_no_changes_sentence(self):
        root = self.scratch(FIXTURES / "single" / "input")
        for name in os.listdir(root / "changelog.d"):
            (root / "changelog.d" / name).unlink()
        tool.fold(root, single_config(), "0.37.0", "2026-10-24")
        self.assertIn("## 0.37.0 - 2026-10-24\n\nNo user-facing changes.\n\n## 0.36.0", read(root / "CHANGELOG.md"))

    def test_fold_inserts_after_the_intro_when_no_version_exists(self):
        root = self.scratch()
        (root / "CHANGELOG.md").write_text("# Changelog\n\nIntro.\n\n\n")
        tool.fold(root, single_config(), "0.1.0", "2026-01-01")
        self.assertEqual(read(root / "CHANGELOG.md"), "# Changelog\n\nIntro.\n\n## 0.1.0 - 2026-01-01\n\nNo user-facing changes.\n")

    def test_changelog_must_start_with_the_title(self):
        root = self.scratch()
        (root / "CHANGELOG.md").write_text("Changes\n")
        with self.assertRaisesRegex(tool.ChangelogError, "must start with"):
            tool.fold(root, single_config(), "0.1.0", "2026-01-01")
        with self.assertRaisesRegex(tool.ChangelogError, "must start with"):
            tool.notes(root, single_config(), "0.1.0")

    def test_notes_need_the_blank_line_after_the_heading(self):
        root = self.scratch()
        (root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.1.0 - 2026-01-01\nText.\n")
        with self.assertRaisesRegex(tool.ChangelogError, "no section for 0.1.0"):
            tool.notes(root, single_config(), "0.1.0")

    def test_notes_find_only_the_exact_version(self):
        root = self.scratch()
        (root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.10.0 - 2026-01-01\n\nTen.\n")
        with self.assertRaisesRegex(tool.ChangelogError, "no section"):
            tool.notes(root, single_config(), "0.1.0")
        self.assertIn("Ten.", tool.notes(root, single_config(), "0.10.0"))

    def test_section_that_predates_the_process_has_no_links_and_still_publishes(self):
        root = self.scratch()
        (root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.3.0 - 2026-11-10\n\n### Added\n\n- First release.\n\n## 0.2.0 - 2026-10-01\n\nOld.\n")
        self.assertEqual(
            tool.notes(root, single_config(), "0.3.0"),
            f"{tool.START_MARKER}\n### Added\n\n- First release.\n{tool.END_MARKER}\n",
        )

    def test_a_missing_fragment_directory_is_no_fragments(self):
        root = self.scratch()
        self.assertEqual(tool.check(root, single_config()), 0)


VALID = "---\nkind: added\n---\nA change.\n"

# One case per invalid input of the contract, for a single-product repository.
INVALID_SINGLE = [
    ("1-a.md", "kind: added\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\nBody.\n"),
    ("1-a.md", "---\nkind: added\ncolour: red\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\nkind: fixed\n---\nBody.\n"),
    ("1-a.md", "---\nbreaking: true\n---\nBody.\n"),
    ("1-a.md", "---\nkind: improved\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\nbreaking: yes\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\n---\n\n\n"),
    ("1-a.md", "---\nkind: added\n---\nFirst.\n\nSecond.\n"),
    ("1-a.md", "---\nkind: added\n---\n# Title\n"),
    ("x-foo.md", VALID),
    ("012-foo.md", VALID),
    ("12-Foo.md", VALID),
    ("12_foo.md", VALID),
    ("1-a.md", "---\nkind: added\nsurfaces: plugin\n---\nBody.\n"),
    ("1-a.md", "---\r\nkind: added\r\n---\r\nBody.\r\n"),
    ("1-a.md", "---\nkind:  added\n---\nBody.\n"),
    # Traps of a port: forms that int() or isdigit() would accept.
    ("1_0-a.md", VALID),
    ("١٢-a.md", VALID),
    (" 12-a.md", VALID),
    ("+12-a.md", VALID),
    ("18446744073709551616-a.md", VALID),
    ("0-a.md", VALID),
    ("-a.md", VALID),
    ("12-.md", VALID),
    ("12-a--b.md", VALID),
    ("12-a.txt", VALID),
    ("12.md", VALID),
    # Header grammar.
    ("1-a.md", ""),
    ("1-a.md", "---\n"),
    ("1-a.md", "---\nkind: added\n"),
    ("1-a.md", "---\nKind: added\n---\nBody.\n"),
    ("1-a.md", "---\nkind-x: added\n---\nBody.\n"),
    ("1-a.md", "---\nkind:added\n---\nBody.\n"),
    ("1-a.md", "---\nkind: \n---\nBody.\n"),
    ("1-a.md", "---\nkind: added \n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\nbreaking: True\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\n---\nBody.\n\x0c\nMore.\n"),
    ("1-a.md", "---\nkind: added\n---\n  # Indented is fine\n#Not\n"),
    ("1-a.md", " ---\nkind: added\n---\nBody.\n"),
]

INVALID_MULTI = [
    ("1-a.md", VALID),
    ("1-a.md", "---\nkind: added\nsurfaces: cli\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\nsurfaces: plugin, plugin\n---\nBody.\n"),
    ("1-a.md", "---\nkind: added\nsurfaces: plugin,web\n---\nBody.\n"),
]


class Check(Scratch):
    def test_every_invalid_single_product_input_is_rejected(self):
        for name, content in INVALID_SINGLE:
            with self.subTest(name=name, content=content):
                self.assertFalse(self.accepts(name, content))
        self.assertTrue(self.accepts("1-a.md", VALID))

    def test_every_invalid_multi_surface_input_is_rejected(self):
        for name, content in INVALID_MULTI:
            with self.subTest(name=name, content=content):
                self.assertFalse(self.accepts(name, content, multi_config()))
        self.assertTrue(
            self.accepts("1-a.md", "---\nkind: added\nsurfaces: plugin, web\n---\nBody.\n", multi_config())
        )

    def test_accepted_edge_forms(self):
        for name, content in [
            ("18446744073709551615-a.md", VALID),
            ("1-a1-b2.md", VALID),
            ("1-a.md", VALID.replace("A change.", "\n\nA change.\n\n\n")),
            ("1-a.md", "---\nbreaking: true\nkind: security\n---\nBody.\n"),
            ("1-a.md", "---\nkind: added\n---\nTwo\nlines.\n"),
            ("1-a.md", "---\nkind: added\n---\nBody.\n\x1c"),
        ]:
            with self.subTest(name=name):
                self.assertTrue(self.accepts(name, content))

    def test_dotfiles_are_not_fragments(self):
        root, config = self.fragment_repo(".gitkeep", "")
        self.assertEqual(tool.check(root, config), 0)

    def test_a_directory_in_changelog_d_is_invalid(self):
        root = self.scratch()
        (root / "changelog.d" / "1-a.md").mkdir(parents=True)
        with self.assertRaises(tool.ChangelogError):
            tool.check(root, single_config())

    def test_all_problems_are_reported_with_their_path(self):
        root, config = self.fragment_repo("1-a.md", "bad\n")
        (root / "changelog.d" / "2-b.md").write_text("bad\n")
        with self.assertRaises(tool.ChangelogError) as caught:
            tool.check(root, config)
        lines = str(caught.exception).split("\n")
        self.assertEqual(
            lines,
            ["changelog.d/1-a.md: no opening ---", "changelog.d/2-b.md: no opening ---"],
        )

    def test_text_joins_trimmed_lines_with_a_space(self):
        root, config = self.fragment_repo("7-x.md", "---\nkind: added\n---\n  One \n\ttwo\n")
        self.assertEqual(tool.load_fragments(root, config)[0].text, "One two")

    def test_breaking_entries_sort_first_then_number_then_slug(self):
        root = self.scratch((FIXTURES / "single" / "input"))
        fragments = {f.file_name: f for f in tool.load_fragments(root, single_config())}
        section = tool.render_section(list(fragments.values()), "example/app")
        changed = section.split("### Changed")[1].split("###")[0]
        self.assertLess(changed.index("Breaking"), changed.index("faster"))


class Validation(unittest.TestCase):
    def test_versions_are_release_or_pre_release(self):
        for good in ("0.37.0", "0.1.0-pre.3"):
            tool.validate_version(good)
        for bad in ("0.1.0-rc1", "0.1.0-rc.1", "0.1.0-pre", "0.1.0-pre.", "0.1", "v0.1.0", "1.2.3.4", "1..3", "", "1.2.x"):
            with self.subTest(bad=bad), self.assertRaises(tool.ArgumentError):
                tool.validate_version(bad)

    def test_calendar_dates_are_checked(self):
        for good in ("2026-10-24", "2024-02-29", "2000-02-29"):
            tool.validate_date(good)
        for bad in ("2026-02-29", "1900-02-29", "2026-13-01", "2026-00-10", "2026-04-31", "2026-1-01", "2026-10-24 ", "٢026-10-24", ""):
            with self.subTest(bad=bad), self.assertRaises(tool.ArgumentError):
                tool.validate_date(bad)

    def test_today_is_a_valid_date(self):
        tool.validate_date(tool.today_utc())

    def test_trim_follows_rust_whitespace(self):
        self.assertEqual(tool.trim("　x\x85"), "x")
        self.assertEqual(tool.trim("\x1cx\x1c"), "\x1cx\x1c")

    def test_lines_follow_rust_lines(self):
        self.assertEqual(tool.split_lines("a\r\nb\n\nc\x0cd\n"), ["a", "b", "", "c\x0cd"])
        self.assertEqual(tool.split_lines(""), [])
        self.assertEqual(tool.split_lines("a"), ["a"])


class ConfigRules(Scratch):
    def load(self, text):
        root = self.scratch()
        (root / "changelog.toml").write_text(text)
        return tool.Config.load(root / "changelog.toml")

    def test_single_and_surface_layouts_load(self):
        self.assertEqual(self.load('repository = "a/b"\nchangelog = "CHANGELOG.md"\n'), tool.Config("a/b", changelog=Path("CHANGELOG.md")))
        config = self.load('repository = "a/b"\n[surfaces]\nplugin = "p/C.md"\n')
        self.assertEqual(config.surfaces, {"plugin": Path("p/C.md")})

    def test_invalid_configs_are_rejected(self):
        for text in (
            'repository = "a"\nchangelog = "C.md"\n',
            'repository = "a/b/c"\nchangelog = "C.md"\n',
            'repository = "a/ b"\nchangelog = "C.md"\n',
            'repository = "ä/b"\nchangelog = "C.md"\n',
            'repository = "a/b"\n',
            'repository = "a/b"\nchangelog = "C.md"\n[surfaces]\nx = "y.md"\n',
            'repository = "a/b"\n[surfaces]\n',
            'repository = "a/b"\n[surfaces]\nBad = "y.md"\n',
            'repository = "a/b"\nchangelog = "C.md"\nextra = 1\n',
            'repository = "a/b"\nchangelog = 3\n',
            'repository = "a/b"\n[surfaces]\nx = 3\n',
            'repository = 3\nchangelog = "C.md"\n',
            'changelog = "C.md"\n',
            "not toml [",
        ):
            with self.subTest(text=text), self.assertRaises(tool.ChangelogError):
                self.load(text)

    def test_a_missing_config_file_is_an_error(self):
        with self.assertRaises(tool.ChangelogError):
            tool.Config.load(self.scratch() / "changelog.toml")

    def test_surface_arguments_follow_the_layout(self):
        with self.assertRaisesRegex(tool.ArgumentError, "does not apply"):
            single_config().changelog_path("plugin")
        with self.assertRaisesRegex(tool.ArgumentError, "pass --surface"):
            multi_config().changelog_path(None)
        with self.assertRaisesRegex(tool.ArgumentError, "unknown surface: cli"):
            multi_config().changelog_path("cli")

    def test_the_repository_config_and_fragments_are_valid(self):
        config = tool.Config.load(ROOT / "changelog.toml")
        self.assertEqual(config, tool.Config("pohunekd/omarchy", changelog=Path("CHANGELOG.md")))
        tool.check(ROOT, config)


class CommandLine(Scratch):
    def run_main(self, args, root):
        out, err = io.StringIO(), io.StringIO()
        code = tool.main(args, root, out, err)
        return code, out.getvalue(), err.getvalue()

    def repo(self):
        root = self.scratch(FIXTURES / "single" / "input")
        (root / "changelog.toml").write_text('repository = "example/app"\nchangelog = "CHANGELOG.md"\n')
        return root

    def test_check_reports_the_fragment_count(self):
        self.assertEqual(self.run_main(["check"], self.repo()), (0, "changelog: 5 fragment(s) valid\n", ""))

    def test_fold_and_notes_print_their_contract_output(self):
        root = self.repo()
        self.assertEqual(self.run_main(["fold", "0.37.0", "--date", "2026-10-24"], root), (0, "changelog: folded 0.37.0 (2026-10-24)\n", ""))
        code, out, _ = self.run_main(["notes", "0.37.0"], root)
        self.assertEqual((code, out), (0, read(FIXTURES / "single/expected-0.37.0/notes.md")))

    def test_usage_errors_exit_2(self):
        root = self.repo()
        for args in ([], ["frobnicate"], ["check", "x"], ["fold"], ["notes"], ["fold", "0.1.0", "--date"],
                     ["notes", "0.1.0", "--date", "2026-01-01"], ["fold", "0.1.0", "--bogus", "x"]):
            with self.subTest(args=args):
                code, out, err = self.run_main(args, root)
                self.assertEqual((code, out), (2, ""))
                self.assertTrue(err.startswith("changelog: ") and "usage:" in err)

    def test_runtime_errors_exit_1(self):
        root = self.repo()
        for args in (["fold", "v1", "--date", "2026-01-01"], ["fold", "0.1.0", "--date", "2026-02-30"],
                     ["notes", "0.37.0"], ["fold", "0.1.0", "--surface", "x"]):
            with self.subTest(args=args):
                code, out, err = self.run_main(args, root)
                self.assertEqual((code, out), (1, ""))
                self.assertTrue(err.startswith("changelog: "))

    def test_the_wrapper_runs_the_tool_from_any_directory(self):
        result = subprocess.run([str(ROOT / "scripts" / "changelog"), "check"], cwd=self.scratch(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^changelog: \d+ fragment\(s\) valid\n$")


def git(cwd, *args):
    subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", *args],
        cwd=cwd, check=True, capture_output=True,
    )


class ReleaseBody(Scratch):
    """scripts/release-body renders the changelog block of a release body."""

    SECTION = "# Changelog\n\n## 0.3.0 - 2026-11-10\n\n### Added\n\n- First.\n"

    def repo(self, changelog, fragment=None):
        root = self.scratch()
        (root / "scripts").mkdir()
        for name in ("release-body", "changelog.py"):
            shutil.copy(ROOT / "scripts" / name, root / "scripts" / name)
        (root / "changelog.toml").write_text('repository = "example/app"\nchangelog = "CHANGELOG.md"\n')
        (root / "CHANGELOG.md").write_text(changelog)
        (root / "changelog.d").mkdir()
        (root / "changelog.d" / ".gitkeep").write_text("")
        if fragment:
            (root / "changelog.d" / "12-fix.md").write_text(VALID)
        return root

    def run_body(self, root, mode, version="0.3.0"):
        return subprocess.run([str(root / "scripts" / "release-body"), version, mode], cwd=self.scratch(), capture_output=True, text=True)

    def test_dry_run_with_section_and_fragment_previews_the_next_patch(self):
        root = self.repo(self.SECTION, fragment=True)
        result = self.run_body(root, "dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("- A change. ([#12](https://github.com/example/app/issues/12))", result.stdout)
        self.assertIn("preview folded as 0.3.1", result.stderr)
        self.assertEqual(read(root / "CHANGELOG.md"), self.SECTION)
        self.assertTrue((root / "changelog.d" / "12-fix.md").exists())

    def test_dry_run_with_section_and_no_fragment_prints_the_section(self):
        result = self.run_body(self.repo(self.SECTION), "dry-run")
        self.assertEqual((result.returncode, result.stdout), (0, f"{tool.START_MARKER}\n### Added\n\n- First.\n{tool.END_MARKER}\n"))

    def test_dry_run_without_section_folds_under_the_manifest_version(self):
        root = self.repo("# Changelog\n", fragment=True)
        result = self.run_body(root, "dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### Added", result.stdout)
        self.assertNotIn("preview folded", result.stderr)
        self.assertEqual(read(root / "CHANGELOG.md"), "# Changelog\n")

    def test_push_refuses_unfolded_fragments_and_a_missing_section(self):
        result = self.run_body(self.repo(self.SECTION, fragment=True), "push")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not folded", result.stderr)
        result = self.run_body(self.repo("# Changelog\n"), "push")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no section for 0.3.0", result.stderr)
        self.assertEqual(self.run_body(self.repo(self.SECTION), "push").returncode, 0)

    def test_bad_arguments_exit_2(self):
        root = self.repo(self.SECTION)
        self.assertEqual(self.run_body(root, "bogus").returncode, 2)
        self.assertEqual(self.run_body(root, "push", "v1").returncode, 2)


class RequireFragment(Scratch):
    """scripts/require-fragment is the pull request check CI runs."""

    def run_script(self, root, base, label):
        env = {"PATH": os.environ["PATH"], "BASE_SHA": base, "NO_CHANGELOG": label}
        return subprocess.run([str(ROOT / "scripts" / "require-fragment")], cwd=root, env=env, capture_output=True, text=True)

    def pull_request(self, files):
        root = self.scratch()
        git(root, "init", "-q", "-b", "main")
        (root / "README.md").write_text("x\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "base")
        base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
        for name, content in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(content)
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "change")
        return root, base

    def test_a_pull_request_without_fragment_or_label_fails(self):
        root, base = self.pull_request({"Panel.qml": "x\n"})
        result = self.run_script(root, base, "false")
        self.assertEqual(result.returncode, 1)
        self.assertIn("add a changelog fragment", result.stdout)

    def test_the_label_waives_the_fragment(self):
        root, base = self.pull_request({"Panel.qml": "x\n"})
        self.assertEqual(self.run_script(root, base, "true").returncode, 0)

    def test_a_valid_fragment_passes(self):
        root, base = self.pull_request({"changelog.d/12-fix.md": VALID})
        result = self.run_script(root, base, "false")
        self.assertEqual((result.returncode, result.stdout), (0, "changelog.d/12-fix.md\n"))

    def test_hidden_and_misnamed_files_do_not_count(self):
        for name in ("changelog.d/01-x.md", "changelog.d/.x.md", "changelog.d/x.md", "changelog.d/1-X.md", "changelog.d/sub/1-x.md", "changelog.d/1-x.txt"):
            with self.subTest(name=name):
                root, base = self.pull_request({name: VALID})
                self.assertEqual(self.run_script(root, base, "false").returncode, 1)

    def test_missing_inputs_fail(self):
        root, base = self.pull_request({"Panel.qml": "x\n"})
        env = {"PATH": os.environ["PATH"]}
        result = subprocess.run([str(ROOT / "scripts" / "require-fragment")], cwd=root, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
