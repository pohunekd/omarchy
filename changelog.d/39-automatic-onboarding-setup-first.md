---
kind: fixed
---
Automatic onboarding no longer refuses `--agent claude` on a host whose runtime packages are not installed yet: when the setup plan installs the runtime, it runs `pohunek setup` first and then picks the agent. It still refuses before any change when neither the host nor the plan provides the agent.
