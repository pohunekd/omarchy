---
kind: fixed
---
Automatic onboarding runs `pohunek setup` before it checks the Claude or Codex agent, so a host whose runtime packages are not installed yet no longer refuses `--agent claude`.
