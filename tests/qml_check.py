#!/usr/bin/env python3
"""Loads the real widget in an offscreen Quickshell and runs tests/qml/shell.qml.
Needs quickshell and Omarchy's shell modules (OMARCHY_SHELL, default
/usr/share/omarchy/shell). Fails on any QML warning from the plugin's files."""
import os, re, shutil, subprocess, sys, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = Path(os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell"))
if shutil.which("quickshell") is None:
    raise SystemExit("quickshell is not installed")
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", HOME=os.environ.get("HOME", "/tmp"))
for k in ("WAYLAND_DISPLAY", "DISPLAY", "QT_QPA_PLATFORMTHEME"):
    env.pop(k, None)

with tempfile.TemporaryDirectory(prefix="pohunek-qml-") as d:
    h = Path(d)
    shutil.copy(ROOT / "tests/qml/shell.qml", h / "shell.qml")
    for name in ("Service.qml", "Model.js", "fetch.py"):
        shutil.copy(ROOT / name, h / name)
    shutil.copytree(ROOT / "i18n", h / "i18n")
    shutil.copytree(ROOT / "assets", h / "assets")
    shutil.copy(ROOT / "Panel.qml", h / "BarPanel.qml")
    (h / "Commons").symlink_to(SHELL / "Commons")
    shutil.copytree(SHELL / "Ui", h / "Ui", symlinks=True)
    shutil.copy(ROOT / "tests/qml/KeyboardPanel.qml", h / "Ui/KeyboardPanel.qml")
    runtime = h / "runtime"; runtime.mkdir(mode=0o700)
    env["XDG_RUNTIME_DIR"] = str(runtime)
    # Layout writes go to a private state dir.
    env["HOME"] = str(h / "home"); (h / "home/.local/state/omarchy").mkdir(parents=True)
    proc = subprocess.Popen(["quickshell", "-p", str(h)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    timer = threading.Timer(40, proc.kill); timer.start()
    lines = []
    for line in proc.stdout:
        lines.append(line)
        if re.search(r"qml:\s+(ALL OK|\d+ FAILED)", re.sub(r"\x1b\[[0-9;]*m", "", line)):
            break
    timer.cancel(); proc.kill(); proc.wait()

plain = re.sub(r"\x1b\[[0-9;]*m", "", "".join(lines))
problems = [l for l in plain.splitlines()
            if re.search(r"(BarPanel|Service|Model)\.(qml|js)|shell\.qml", l) and re.search(r"WARN|ERROR|Error|error|TypeError|ReferenceError", l)]
checks = re.findall(r"qml:\s+(ok|FAIL)\s+(.*?)\s*$", plain, re.MULTILINE)
failed = [n for s, n in checks if s == "FAIL"]
if problems or failed or "ALL OK" not in plain:
    print(plain[-6000:])
    print("\nPROBLEMS:\n" + "\n".join(problems) + ("\nFAILED: " + "; ".join(failed) if failed else ""))
    sys.exit(1)
print(f"qml: {len(checks)} checks ok, no plugin warnings")
