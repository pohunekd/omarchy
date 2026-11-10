# Coding rules

## Boundaries

- The widget is an external client of the Pohunek daemon. The `pohunek` CLI
  (the `command` setting, default `pohunek`) is the only boundary: `fetch.py`
  calls it and parses its JSON, `Service.qml` calls it for row actions. Never
  read the daemon's socket, state directory, or database directly.
- The daemon owns session, herd, and notification state. The widget reads it
  and calls public CLI commands; it never infers or caches authority.
- The one shared fact the widget writes is a session's group, the
  `companion.group` metadata key, the same key the desktop and Android
  companions use.
- No network calls other than through the `pohunek` CLI and hosts it reaches,
  with one exception: the Install pohunek action downloads the release of
  pohunek, verifies it, shows what it will write, and runs only after the user
  confirmed.

## Layout of the code

- `Model.js` holds the pure logic (owner state, Needs you, groups, badges,
  filters, the bar badge) with no QML or I/O, so `tests/model.test.js` runs it
  in Node. Keep new rules there, not in QML.
- `fetch.py` is Python standard library only, runs as `python3 -I`, and prints
  one JSON snapshot. Add no third-party module.
- `Service.qml` owns processes and state refresh; `Panel.qml` is the view.
  Keep views thin.
- User-visible strings live in `i18n/en.json` and `i18n/cs.json` with identical
  key sets (`tests/manifest_check.py` enforces it).
- `manifest.json` is validated by `omarchy plugin validate`; the version there
  is the release version (see [changelog.md](changelog.md) and
  [../../docs/releasing.md](../../docs/releasing.md)).

## Files and symlinks

- Never add a symlink anywhere in the repository. `omarchy plugin add` clones
  the default branch and `omarchy plugin validate` refuses a plugin folder
  that contains any symlink. Pointer files (such as `.claude/skills/*/SKILL.md`)
  are regular files.
- `.gitattributes` keeps `.github/`, `.agents/`, `.claude/`, `changelog.d/`,
  `site/`, and `tests/` out of the release archive; a new directory that is not
  part of the widget joins that list.

## Shell

- Bash with `set -euo pipefail`, quoted expansions, `shellcheck` clean
  (`scripts/gates`). Scripts under `tools/` are held to errors; scripts under
  `scripts/` to the default severity.
- Never put a secret on a command line or in a file the repository tracks.

## Python

- Standard library only, run as `python3 -I`. Python 3.12 is the floor (the CI
  runner), so do not use newer language or library features.

## Configuration

- Tunables are manifest settings (`manifest.json` `barWidget.defaults` and
  `schema`), never constants scattered in QML or Python. A missing required
  value fails with a visible message; never invent a default for it.

## Security

- Session names, paths, and metadata are untrusted input: pass them to the
  `pohunek` CLI as separate arguments, never through a shell string.
- Never log or display secrets. Never read `.env*`, key, or credential files.
- Published screenshots, logs, and issue text come only from
  `tools/demo-pohunek`; never from the owner's real sessions.

## Comments

A comment states what the code does now or why it must be this way. Never
narrate history ("previously", "no longer", "now also", "replaces ..."); that
belongs in the PR description. One or two lines; prefer the non-obvious why.
