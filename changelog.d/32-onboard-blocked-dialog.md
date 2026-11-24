---
kind: fixed
---
`tools/onboard` names the dialog when the onboard session waits on an answer,
such as the agent CLI's folder-trust question, and points to `pohunek session
screen` and `pohunek attach` instead of leaving only the session id. The held
request is sent once you answer. A core that refuses the dialog instead of
keeping the session gets the same guidance with the upgrade to pohunek 0.44.0
or newer, and no longer the startup-grace hint.
