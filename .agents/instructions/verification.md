# Verification

## Gate set

`scripts/gates` runs, each with its own exit code:

1. `model`: `node tests/model.test.js`
2. `fetch`: `fetch.py` against `tools/demo-pohunek`, then the model test on the
   snapshot
3. `manifest`: `tests/manifest_check.py`
4. `symlinks`: no symlink in the tree
5. `shell`: `bash -n` and `shellcheck` on the bash scripts
6. `changelog`: `scripts/changelog check`
7. `changelog-tests`: `tests/changelog_test.py`
8. `qml`: `tests/qml_check.py`, only when `quickshell` and the Omarchy shell
   exist; otherwise it is `not run`

CI runs the same set except `qml`, plus the `site` job. A change under `site/`
also needs `cd site && bun test && bun run build` locally, and screenshots of
the hero at 1440 px and 390 px in the PR (dark and light), taken with headless
Chromium against `bun run preview`. Run it on the final revision before every
push and report each gate's real result. Never report a gate as passed when it
was skipped, not run, or its output was cut off.

## Testing policy

Write the minimum set of tests that catch real regressions. A test is written
only for:

- **Non-trivial pure logic** where a bug is silent and costly: owner state,
  Needs you ordering, grouping, badges, filters (`tests/model.test.js`);
  `fetch.py` output against `tools/demo-pohunek`; the changelog tool
  (`tests/changelog_test.py`).
- **A fixed bug in such logic**, as a regression test that fails without the
  fix. No regression test for a QML glitch or a one-line fix.

Do not write:

- QML UI tests in CI;
- tests per function, getters, trivial mappings;
- mocks of the `pohunek` CLI beyond `tools/demo-pohunek`;
- coverage targets.

Delete a test that keeps breaking on intentional changes without ever having
caught a bug, and say so in the PR.

## Manual verification

`tests/qml_check.py` loads the real widget in an offscreen Quickshell and runs
`tests/qml/shell.qml`. It needs `quickshell` and Omarchy's shell modules
(`OMARCHY_SHELL`, default `/usr/share/omarchy/shell`); without them report it
as `not run`, never as passed. Panel behaviour that no automated check covers
is verified in a running Omarchy bar and recorded in the PR in words.

Agent sessions share the owner's live desktop. Never inject synthetic input
there (uinput, ydotool, wtype, xdotool): it lands in whatever window has focus.

## Published evidence

The repository is public. Screenshots, logs, and PR or issue text must not show
the owner's real sessions (names, ids, working directories, hosts). Published
screenshots come only from the panel running against `tools/demo-pohunek`.

## CI

`.github/workflows/ci.yml`:

- `gates` runs `scripts/gates` on `ubuntu-24.04` with the runner's Node,
  Python 3.12, and shellcheck (its version is printed in the log).
- `changelog` (pull requests) validates every fragment and runs
  `scripts/require-fragment`: a fragment is required unless the pull request
  carries `no-changelog`.
- `site` (always) installs the landing page dependencies, runs `bun test` and
  `bun run build` in `site/`.
- `ci` is the aggregate and the only required status check.
- A newer push cancels the previous run of the same PR; `main` runs are never
  cancelled.

Every action is pinned to a commit SHA and every job declares minimal
permissions. A slow or flaky CI is a bug: file it.

## Release

`.github/workflows/release.yml` and [docs/releasing.md](../../docs/releasing.md)
describe the tag-driven, attested release. A pull request that touches release
files runs the same build and uploads the archive and checksum as workflow
artifacts; it never tags, attests, or publishes.
