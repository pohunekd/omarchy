# Changelog

User-facing changes of pohunek for Omarchy. Each version section is folded from
the fragments in `changelog.d/` when its release is prepared. Sections that
predate the fragment process carry no issue links.

## 0.4.0 - 2026-11-15

Pohunek for Omarchy 0.4 helps you get started. A new card in the panel sets pohunek up and hands you to an onboard agent that registers your projects, groups your sessions and sets up profiles and hooks with you. If you change your mind, one entry in Help takes it back.

### What's new

#### A Get started card

On a machine without pohunek, or one that has not been onboarded yet, the panel shows a Get started card. It installs pohunek from a verified release (checksum and attestation), shows every change it will make and asks once. It then starts an onboard agent in guided mode, which proposes your projects, session groups, agent profiles and hooks one at a time and asks before each change. Hooks are chosen per agent home and start unticked, and for each home you can also add the pohunek agent skill, so your own Claude or Codex can drive pohunek outside pohunek sessions.

#### Automatic mode, limited to what you grant

With pohunek 0.43.0 and Claude or Codex you can let the onboard agent work without asking at every step. Before it starts you see the items it may do (register projects, group ungrouped sessions, migrate profiles, hooks for a profile it creates, the agent CLI's own update); each can be turned off, and you confirm once. The session runs under a `pohunek-onboard` profile written for this run. Under Claude it allows the read-only pohunek commands and the commands of the items you granted, and everything else asks first; under Codex, which has no such allowlist, pohunek commands ask for your approval. Your own agent permission settings still apply on top: a command that your own Claude allow rules or Codex command rules already allow runs without a prompt.

#### Undo onboarding

**Undo onboarding** in Help lists what the run added and removes it after one yes: the projects it registered (only unregistered, no repository or worktree is deleted), the profiles it created, the session groups it set, and the hooks and agent skills it installed. It removes only what it can prove the run added. Leave the onboarding window open until the onboard session ends and it records exactly what the run changed; if you closed it earlier, Undo removes only what it can still prove. Anything that was there before, or that you changed since, is kept and listed with the command to remove it by hand. Agent CLI updates are listed, never reverted.

### Upgrading

This release is made for pohunek 0.43.0. Guided onboarding works with pohunek 0.42.0 or newer; automatic mode and removing profiles in Undo need 0.43.0. Upgrading the widget onboards nothing by itself: the card waits until you start it.

### Full changelog

#### Added

- A Get started card in the panel sets pohunek up from a verified release (or starts on a machine that has it), asks once after showing every change, and starts a guided onboard manager that is told to propose projects, groups, profiles and hooks one at a time and ask before each change. Agent hooks are chosen per agent home and start unticked; the assistant package is installed and verified by the tool while `pohunek setup` cannot install it, and onboarding needs pohunek 0.42.0 or newer. ([#9](https://github.com/pohunekd/omarchy/issues/9))
- Onboarding gets an automatic mode that applies the items you grant without asking, under a `pohunek-onboard` profile that allows those commands on top of your own agent permission settings (pohunek 0.43.0, Claude or Codex), and per agent home you can add the pohunek agent skill. **Undo onboarding** in Help removes what the recorded run provably added: with the tool's window left open until the onboard session ends, the projects, profiles, session groups, hooks and skills it added, keeping anything you changed since; otherwise only its manual projects and its own profile, listing the rest with its command. ([#14](https://github.com/pohunekd/omarchy/issues/14))

## 0.3.0 - 2026-11-10

### Added

- First public release as `pohunekd/omarchy`.
- Sessions of every host (this machine, herdr machines, NetBird / Tailscale peers), Needs you first.
- My groups / By state, shared `companion.group` groups, State / Project / Host filters, fuzzy search.
- Row actions, details, new session form, help page, hosts page.
- Bar icon: the pohunek plate with a state-coloured cursor; clickable desktop notifications that attach.
- `tools/`: install-pohunek, setup-network, distribute, add-shortcuts, demo-pohunek.
