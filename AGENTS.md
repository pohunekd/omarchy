# AGENTS.md

Canonical entry point for every agent working in this repository. Keep it
short: it routes to the scoped guides instead of repeating them. When a command,
convention, or boundary changes, update the guide that owns it in the same PR.

All repository text, code, comments, commit messages, issues, and PRs are in
English. Priorities: security > correctness > simplicity > speed of delivery.

## About

pohunek for Omarchy is an Omarchy bar widget (QML for Quickshell, pure logic in
`Model.js`, a stdlib-only `fetch.py`, and bash tools) that shows every
[pohunek](https://pohunek.dev) agent session on every machine in the bar. It is
an external client of the `pohunek` CLI and owns no session state. Users
install it with `omarchy plugin add https://github.com/pohunekd/omarchy`, which
clones the default branch; releases are attested archives for pinned and
verifiable installs. See [README.md](README.md).

## Instruction routes

Read a guide when its trigger applies.

- **Every task:** [.agents/instructions/workflow.md](.agents/instructions/workflow.md)
  for autonomy, issues, branches, PRs, merge, and the rule to file problems
  instead of fixing them.
- **Any code change:** [.agents/instructions/coding.md](.agents/instructions/coding.md)
  for QML, `Model.js`, `fetch.py`, bash, translations, the no-symlink rule, the
  `pohunek` CLI boundary, security, and comment rules.
- **Any user-visible change:** [.agents/instructions/changelog.md](.agents/instructions/changelog.md)
  for the changelog fragment in `changelog.d/` and when `no-changelog` applies.
- **Before any commit or PR:** [.agents/instructions/verification.md](.agents/instructions/verification.md)
  for the gate set, the testing policy, CI, and evidence.
- **Releasing:** [docs/releasing.md](docs/releasing.md).

## Skills

Canonical skills live in `.agents/skills/`. `.claude/skills/<name>/SKILL.md`
are regular pointer files (name, description, and a link), never symlinks:
`omarchy plugin validate` rejects a plugin folder that contains any symlink.
Edit only `.agents/skills/`.

- [github-workflow](.agents/skills/github-workflow/SKILL.md): issues, epics,
  milestones, project status, and writing reproducible issues.
- [deliver-issue](.agents/skills/deliver-issue/SKILL.md): take one issue from
  intake to a merged, verified, closed result without asking.
- [plan-epic](.agents/skills/plan-epic/SKILL.md): split an epic or milestone
  into ready, well-formed issues.
- [gates](.agents/skills/gates/SKILL.md): run the local gate set and report it
  honestly.

## Commands

```bash
scripts/gates                  # model, fetch, manifest, symlinks, shell, changelog (+ qml when available)
scripts/changelog check        # validate the changelog fragments (CI runs it too)
node tests/model.test.js       # Model.js rules
python3 -I tests/qml_check.py  # offscreen Quickshell check; needs quickshell and the Omarchy shell
(cd site && bun install --frozen-lockfile && bun test && bun run build)   # landing page, see site/DESIGN.md
```

The repository is public: published screenshots, logs, and PR or issue text come
only from `tools/demo-pohunek` (synthetic sessions), never from the owner's
real sessions.

Never read `.env*`, key, or credential files, and never print a secret value.
Never call `env` or `printenv` (the owner's agent settings stop on them):
check a variable with `test -n "$VAR"` and list names with `compgen -e`.
