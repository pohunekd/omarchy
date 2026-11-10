---
name: gates
description: >-
  Run the omarchy gate set (model test, fetch snapshot, manifest, symlinks,
  shell, changelog) locally and report each gate's real result. Use before any
  commit, push, or claim that a change works or is done.
---

# gates

Run `scripts/gates` from the repository root (or the worktree root). It runs
the gates below, records each exit code, prints a per-gate summary, and exits
non-zero if any gate failed:

- `model`: `node tests/model.test.js`
- `fetch`: `py_compile` of `fetch.py` and `tools/demo-pohunek`, `fetch.py`
  against `tools/demo-pohunek`, and the model test on that snapshot
- `manifest`: `tests/manifest_check.py` (plugin manifest schema, entry points,
  en/cs translation parity)
- `symlinks`: no symlink anywhere in the tree
- `shell`: `bash -n` and `shellcheck` on every bash script under `tools/` and
  `scripts/`
- `changelog` and `changelog-tests`: `scripts/changelog check` and
  `tests/changelog_test.py`
- `qml`: `tests/qml_check.py`, only when `quickshell` and the Omarchy shell
  (`OMARCHY_SHELL`, default `/usr/share/omarchy/shell`) exist

- Read the summary, not a piped tail of the output: report each gate as
  `passed`, `failed (exit N)` or `not run` exactly as printed.
- A missing `shellcheck` fails the `shell` gate (exit 127). Install it; do not
  skip the gate.
- `qml` reported as `not run` stays `not run` in the PR; it is not a pass.
- Never mark a gate passed that did not run, and never weaken a check to get
  green.
