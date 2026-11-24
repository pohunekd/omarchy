---
kind: fixed
---
`tools/onboard` names the dialog when the onboard session waits on an answer,
such as the agent CLI's folder-trust question, and points to `pohunek session
screen` and `pohunek attach` instead of leaving only the session id. The held
request is sent once you answer. When pohunek removes the session instead
(cores before 0.44.0, or an agent it does not keep), the tool names the dialog,
how to answer it once by hand and, for a Claude agent, the upgrade to pohunek
0.44.0 or newer, and never the startup-grace hint.
