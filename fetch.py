#!/usr/bin/env python3
"""One snapshot of every pohunek host the bar widget follows, as one JSON line.

Hosts, in this order, without duplicates:
  1. this machine (`local`);
  2. `--hosts a,b` from the widget settings;
  3. `[[hosts]]` of the desktop companion's `~/.config/pohunek/companion.toml`
     (shared configuration, read only);
  4. with `--discover`, every overlay peer that `pohunek host discover` reports
     as `reachable_daemon` (not stored anywhere, like the Android companion).

Each host is asked concurrently for `session list --json` and
`notifications list --unread --json`. Only the fields the widget renders are
passed on, bounded and stripped of control and bidi-format characters. A host
that fails is reported with its error code and keeps no rows here; the widget
keeps its last rows dimmed.

Reads only; never changes a session. Exit 127 when the pohunek binary is
missing, so the widget can tell "not installed" from "daemon down".
"""
import argparse, concurrent.futures, json, os, re, shutil, subprocess, sys, time

try:
    import tomllib
except ImportError:  # pragma: no cover - python < 3.11
    tomllib = None

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
FORMAT_CHARS = re.compile("[\u0000-\u001f\u007f-\u009f؜​-‏‪-‮⁠-⁩﻿]+")
MAX_SESSIONS_PER_HOST = 1000
MAX_ENDED_PER_HOST = 150
MAX_NOTIFICATIONS_PER_HOST = 100
MAX_HOSTS = 32
MAX_OUTPUT = 32 * 1024 * 1024


def clean(value, limit=200):
    if value is None:
        return ""
    text = FORMAT_CHARS.sub(" ", str(value))
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def run(argv, timeout):
    try:
        out = subprocess.run(argv, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return None, "timeout", ""
    except OSError as err:
        return None, "spawn_failed", clean(err, 160)
    if len(out.stdout) > MAX_OUTPUT:
        return None, "too_large", ""
    try:
        doc = json.loads(out.stdout or b"null")
    except ValueError:
        return None, "invalid_json", clean(out.stderr.decode(errors="replace"), 240)
    if not isinstance(doc, dict):
        return None, "invalid_json", ""
    if isinstance(doc.get("err"), dict):
        return None, clean(doc["err"].get("code") or "error", 64), clean(doc["err"].get("msg"), 240)
    if "ok" not in doc:
        return None, "invalid_envelope", ""
    return doc["ok"], "", ""


def companion_config():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    path = os.path.join(base, "pohunek", "companion.toml")
    if tomllib is None or not os.path.isfile(path):
        return [], None
    try:
        with open(path, "rb") as handle:
            doc = tomllib.load(handle)
    except (OSError, ValueError):
        return [], None
    hosts = []
    for entry in doc.get("hosts", []) if isinstance(doc.get("hosts"), list) else []:
        if isinstance(entry, dict) and isinstance(entry.get("target"), str) and HOST_RE.match(entry["target"]):
            hosts.append({"target": entry["target"], "label": clean(entry.get("label") or entry["target"], 40)})
    tray = doc.get("tray") if isinstance(doc.get("tray"), dict) else {}
    idle = tray.get("idle_threshold_secs")
    return hosts, idle if isinstance(idle, int) and idle > 0 else None


def work_facts(meta):
    prefix = "work.link." if any(k.startswith("work.link.") for k in meta) else "link."
    facts = {f: clean(meta.get(prefix + f), 120) for f in ("provider", "kind", "id")}
    url = meta.get("work.link.url") or meta.get("link.url") or ""
    facts["url"] = url if isinstance(url, str) and len(url) <= 2048 and re.match(r"^https?://[^\s]+$", url) else ""
    facts["role"] = clean(meta.get("work.role"), 60)
    return facts


def slim_session(raw, host):
    if not isinstance(raw, dict) or not isinstance(raw.get("id"), str) or not ID_RE.match(raw["id"]):
        return None
    meta = raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {}
    runtime = raw.get("runtime") if isinstance(raw.get("runtime"), dict) else {}
    subagents = raw.get("subagents") if isinstance(raw.get("subagents"), list) else []
    background = raw.get("background") if isinstance(raw.get("background"), dict) else {}
    items = background.get("items") if isinstance(background.get("items"), list) else []
    return {
        "id": raw["id"],
        "host": host,
        "name": clean(raw.get("name"), 120),
        "agent": clean(raw.get("agent_base") or raw.get("agent"), 60),
        "profile": clean(raw.get("agent"), 80),
        "state": clean(raw.get("state"), 20),
        "activity": clean(raw.get("activity"), 20),
        "runtimeState": clean(runtime.get("state"), 20),
        "lossCause": clean(runtime.get("loss_cause") or runtime.get("loss_reason"), 200),
        "subagentsRunning": sum(1 for s in subagents[:256] if isinstance(s, dict) and s.get("lifecycle") == "running"),
        "backgroundRunning": sum(1 for b in items[:256] if isinstance(b, dict) and b.get("status") in ("running", "pending")),
        "cwd": clean(raw.get("cwd"), 400),
        "project": clean(raw.get("project_label") or raw.get("project_id"), 80),
        "projectId": clean(raw.get("project_id"), 120),
        "branch": clean(raw.get("branch"), 120),
        "worktree": clean(raw.get("worktree_path"), 400),
        "group": clean(meta.get("companion.group"), 120) if "companion.group" in meta else None,
        "work": work_facts(meta),
        "resumable": bool(raw.get("native_session_id") or raw.get("active_agent_session_id")),
        "external": bool(raw.get("external")),
        "createdAt": clean(raw.get("created_at"), 40),
        "updatedAt": clean(raw.get("updated_at"), 40),
        "exitCode": raw.get("exit_code") if isinstance(raw.get("exit_code"), int) else None,
    }


def slim_notification(raw, host):
    if not isinstance(raw, dict) or not isinstance(raw.get("id"), str):
        return None
    sid = raw.get("session_id")
    return {
        "id": clean(raw["id"], 128),
        "host": host,
        "kind": clean(raw.get("kind"), 40),
        "title": clean(raw.get("title"), 160),
        "body": clean(raw.get("body"), 300),
        "sessionId": sid if isinstance(sid, str) and ID_RE.match(sid) else "",
        "createdAt": clean(raw.get("created_at"), 40),
    }


def host_args(target):
    return [] if target == "local" else ["--host", target]


def fetch_host(binary, host, timeout):
    started = time.monotonic()
    target = host["target"]
    sessions, code, message = run([binary, "session", "list", "--json", *host_args(target)], timeout)
    result = dict(host, reachable=sessions is not None, error=code, message=message, sessions=[], notifications=[])
    if isinstance(sessions, list):
        live, ended = [], []
        for raw in sessions[:MAX_SESSIONS_PER_HOST]:
            slim = slim_session(raw, target)
            if slim:
                is_ended = slim["state"] in ("stopped", "done", "failed") or slim["runtimeState"] == "lost"
                (ended if is_ended else live).append(slim)
        # Ended sessions only show with the Ended chip on: keep the newest.
        ended.sort(key=lambda s: s["updatedAt"], reverse=True)
        result["sessions"] = live + ended[:MAX_ENDED_PER_HOST]
        result["endedOmitted"] = max(0, len(ended) - MAX_ENDED_PER_HOST)
        notes, _, _ = run([binary, "notifications", "list", "--unread", "--json", *host_args(target)], timeout)
        if isinstance(notes, dict) and isinstance(notes.get("notifications"), list):
            for raw in notes["notifications"][:MAX_NOTIFICATIONS_PER_HOST]:
                slim = slim_notification(raw, target)
                if slim:
                    result["notifications"].append(slim)
    elif sessions is not None:
        result.update(reachable=False, error="invalid_envelope")
    result["latencyMs"] = int((time.monotonic() - started) * 1000)
    return result


def form_data(binary, host, timeout):
    """Agents and projects a new session on `host` can use."""
    inspect, code, message = run([binary, "host", "inspect", "local" if host == "local" else host, "--json"], timeout)
    agents = []
    if isinstance(inspect, dict):
        available = {r.get("agent") for r in inspect.get("runtimes", []) if isinstance(r, dict) and r.get("available")}
        for agent in inspect.get("supported_agents", [])[:200]:
            if isinstance(agent, str) and ID_RE.match(agent) and (not available or agent in available):
                agents.append(agent)
    projects, _, _ = run([binary, "project", "list", "--json", *host_args(host)], timeout)
    out = []
    for p in projects[:500] if isinstance(projects, list) else []:
        if isinstance(p, dict) and isinstance(p.get("id"), str) and ID_RE.match(p["id"]):
            out.append({"id": p["id"], "label": clean(p.get("label") or p["id"], 80),
                        "lastUsedAt": clean(p.get("last_used_at"), 40)})
    out.sort(key=lambda p: p["lastUsedAt"], reverse=True)
    return {"host": host, "agents": agents, "projects": out, "error": code if inspect is None else "", "message": message}


def herdr_machines(timeout):
    """Machines in the herdr registry (Omarchy's multi-machine list)."""
    herdr = shutil.which("herdr")
    if not herdr:
        return None
    try:
        out = subprocess.run([herdr, "machine", "list"], capture_output=True, timeout=timeout, check=False, text=True)
    except (OSError, subprocess.TimeoutExpired):
        return None
    machines = []
    for line in out.stdout.splitlines()[:64]:
        cols = line.split("\t")
        if len(cols) < 5:
            continue
        target = cols[2].strip()
        if not re.match(r"^[A-Za-z0-9._@:-]{1,128}$", target) or target.startswith("-"):
            continue
        machines.append({"id": clean(cols[0], 64), "label": clean(cols[1], 40) or target,
                         "target": target, "enabled": cols[4].strip() == "enabled"})
    return machines


def overlay_provider():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    path = os.path.join(base, "pohunek", "overlays.toml")
    if tomllib is None or not os.path.isfile(path):
        return "netbird"
    try:
        with open(path, "rb") as handle:
            providers = tomllib.load(handle).get("providers")
    except (OSError, ValueError):
        return "unknown"
    return providers[0] if isinstance(providers, list) and providers and providers[0] in ("netbird", "tailscale") else "unknown"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", default="pohunek")
    parser.add_argument("--hosts", default="", help="comma separated extra host targets")
    parser.add_argument("--discover", action="store_true", help="add reachable pohunek peers of the overlay")
    parser.add_argument("--refresh-discovery", action="store_true", help="re-probe the overlay instead of the cache")
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--machines", action="store_true", help="include herdr machines and the overlay")
    parser.add_argument("--form", default="", help="print agents and projects of one host instead")
    args = parser.parse_args()

    binary = shutil.which(os.path.expanduser(args.bin))
    if not binary:
        print(json.dumps({"installed": False}))
        return 127

    if args.form:
        if args.form != "local" and not HOST_RE.match(args.form):
            return 2
        print(json.dumps(form_data(binary, args.form, args.timeout), separators=(",", ":")))
        return 0

    hosts = [{"target": "local", "label": "", "local": True, "source": "local"}]
    seen = {"local"}

    def add(target, label, source):
        if target in seen or not HOST_RE.match(target) or len(hosts) >= MAX_HOSTS:
            return
        seen.add(target)
        hosts.append({"target": target, "label": label or target, "local": False, "source": source})

    for target in filter(None, (t.strip() for t in args.hosts.split(","))):
        add(target, target, "settings")
    configured, idle_threshold = companion_config()
    for entry in configured:
        add(entry["target"], entry["label"], "companion")

    if args.discover:
        argv = [binary, "host", "discover", "--json"] + (["--refresh"] if args.refresh_discovery else [])
        peers, _, _ = run(argv, 60 if args.refresh_discovery else 10)
        for peer in peers if isinstance(peers, list) else []:
            if not isinstance(peer, dict) or not isinstance(peer.get("name"), str):
                continue
            if peer.get("local"):
                hosts[0]["label"] = clean(peer["name"], 40)
                seen.add(peer["name"])
            elif peer.get("classification") == "reachable_daemon":
                add(peer["name"], clean(peer["name"], 40), "discovered")
    if not hosts[0]["label"]:
        hosts[0]["label"] = clean(os.uname().nodename.split(".")[0], 40) or "local"

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(hosts))) as pool:
        results = list(pool.map(lambda h: fetch_host(binary, h, args.timeout), hosts))

    extra = {}
    if args.machines:
        extra = {"machines": herdr_machines(5), "overlay": overlay_provider()}

    print(json.dumps({
        **extra,
        "installed": True,
        "generatedAt": int(time.time() * 1000),
        "idleThresholdSecs": idle_threshold,
        "hosts": results,
    }, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
