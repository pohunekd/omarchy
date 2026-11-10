#!/usr/bin/env python3
"""Plugin folder check: the rules of `omarchy plugin validate` (manifest schema,
safe entry points that exist, no symlinks) plus this plugin's id, version
format and en/cs translation parity.

usage: python3 -I tests/manifest_check.py [plugin-folder]   (default: repository root)"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

EXPECTED_ID = "pohunek.sessions"
SECTIONS = ("left", "centerBegin", "center", "centerEnd", "tray", "right")
KIND_ENTRY_POINTS = {
    "bar": "bar",
    "bar-widget": "barWidget",
    "menu": "menu",
    "overlay": "overlay",
    "panel": "panel",
    "service": "service",
}
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def fail(message):
    print(f"manifest_check: {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        fail(f"{path}: {error}")


def check_manifest(folder):
    manifest_path = folder / "manifest.json"
    if not manifest_path.is_file():
        fail(f"missing manifest.json in {folder}")
    manifest = load_json(manifest_path)
    if not isinstance(manifest, dict):
        fail("manifest.json must be an object")
    # JSON true == 1 in Python; the shell accepts only the number 1.
    version = manifest.get("schemaVersion")
    if isinstance(version, bool) or not isinstance(version, int) or version != 1:
        fail("unsupported or missing schemaVersion (expected 1)")
    for field in ("id", "name", "version", "kinds", "entryPoints"):
        if field not in manifest:
            fail(f"manifest missing required field '{field}'")

    plugin_id = manifest["id"]
    if not isinstance(plugin_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", plugin_id) or ".." in plugin_id:
        fail(f"invalid plugin id {plugin_id!r}")
    if plugin_id.startswith("omarchy."):
        fail(f"plugin id '{plugin_id}' uses the reserved omarchy.* namespace")
    if plugin_id != EXPECTED_ID:
        fail(f"plugin id must stay {EXPECTED_ID}: {plugin_id}")
    if not isinstance(manifest["version"], str) or not SEMVER.fullmatch(manifest["version"]):
        fail(f"version must be X.Y.Z: {manifest['version']!r}")

    kinds = manifest["kinds"]
    if not isinstance(kinds, list) or not kinds:
        fail("'kinds' must be a non-empty array")
    entry_points = manifest["entryPoints"]
    if not isinstance(entry_points, dict):
        fail("'entryPoints' must be an object")

    widget = manifest.get("barWidget")
    if isinstance(widget, dict) and "defaultSection" in widget and widget["defaultSection"] not in SECTIONS:
        fail("'barWidget.defaultSection' must be " + ", ".join(SECTIONS))

    for value in entry_points.values():
        if not isinstance(value, str) or value == "":
            fail("entry point path is empty")
        if "\n" in value:
            fail("entry point may not contain a newline")
        if value.startswith("/"):
            fail(f"entry point must be a relative path: '{value}'")
        if ".." in value:
            fail(f"entry point may not contain '..': '{value}'")
        if not (folder / value).is_file():
            fail(f"entry point file not found: '{value}'")

    for kind, entry_point in KIND_ENTRY_POINTS.items():
        if kind in kinds and entry_point not in entry_points:
            fail(f"kind '{kind}' requires an 'entryPoints.{entry_point}' to load")


# Untracked dependency and build output of site/: never in a clone or the archive.
# Package managers link executables there, so it is skipped; develop site/ in a
# worktree, never inside the installed plugin folder.
SITE_UNTRACKED = ("node_modules", "dist", ".astro")


def check_no_symlinks(folder):
    for current, directories, files in os.walk(folder):
        if ".git" in directories:
            directories.remove(".git")
        if Path(current) == folder / "site":
            directories[:] = [d for d in directories if d not in SITE_UNTRACKED]
        for name in directories + files:
            path = Path(current) / name
            if path.is_symlink():
                fail(f"symlinks are not allowed inside a plugin folder: {path}")


def check_translations(folder):
    catalogs = {path: load_json(path) for path in sorted((folder / "i18n").glob("*.json"))}
    english = set(catalogs.get(folder / "i18n" / "en.json", {}))
    if not english:
        fail("i18n/en.json is missing or empty")
    for path, catalog in catalogs.items():
        if set(catalog) != english:
            missing = sorted(english - set(catalog))
            extra = sorted(set(catalog) - english)
            fail(f"{path.name} differs from en.json: missing {missing}, extra {extra}")
    return len(catalogs)


# Marketplace listing files (omacom/omarchy-plugin-marketplace SUBMISSION.md): a
# root README with install and removal instructions, a root LICENSE and at most
# one root preview that the release archive keeps.
PREVIEW_NAMES = ("preview.png", "preview.jpg", "preview.jpeg", "preview.webp", "preview.avif")
PREVIEW_MAX_BYTES = 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def check_listing(folder):
    for name in ("README.md", "LICENSE"):
        if not (folder / name).is_file():
            fail(f"marketplace listing needs a root {name}")
    readme = (folder / "README.md").read_text(encoding="utf-8")
    for needle in ("omarchy plugin add", "omarchy plugin remove"):
        if needle not in readme:
            fail(f"README.md must document `{needle}`")
    previews = [name for name in PREVIEW_NAMES if (folder / name).exists()]
    if len(previews) > 1:
        fail(f"at most one root preview is allowed: {previews}")
    for name in previews:
        path = folder / name
        if path.stat().st_size > PREVIEW_MAX_BYTES:
            fail(f"{name} is {path.stat().st_size} bytes, over the {PREVIEW_MAX_BYTES} byte budget")
        if name.endswith(".png") and not path.read_bytes().startswith(PNG_SIGNATURE):
            fail(f"{name} is not a PNG")
    # `git check-attr` applies .gitattributes exactly as `git archive` does.
    if (folder / ".git").exists():
        names = ["README.md", "LICENSE", "manifest.json"] + previews
        result = subprocess.run(
            ["git", "-C", str(folder), "check-attr", "export-ignore", "--"] + names,
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            fail(f"git check-attr failed: {result.stderr.strip()}")
        for line in result.stdout.splitlines():
            if line.endswith(": export-ignore: set"):
                fail(f".gitattributes export-ignores a listing file: {line.split(':')[0]}")
    return len(previews)


def main(argv):
    if len(argv) > 1:
        fail("usage: manifest_check.py [plugin-folder]")
    folder = Path(argv[0]) if argv else Path(__file__).resolve().parent.parent
    if not folder.is_dir():
        fail(f"plugin folder not found: {folder}")
    check_manifest(folder)
    check_no_symlinks(folder)
    catalogs = check_translations(folder)
    previews = check_listing(folder)
    print(f"manifest, {catalogs} translation catalogs and marketplace listing files ({previews} preview) ok")


if __name__ == "__main__":
    main(sys.argv[1:])
