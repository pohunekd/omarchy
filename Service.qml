import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Data and actions for the pohunek bar widget. Polls fetch.py (every host at
// once), keeps the last rows of a host that drops off (shown dimmed, like the
// companions), tracks the idle and needs-you clocks, and runs session actions
// through the pohunek CLI. Commands are argv arrays; only targets that pass
// Model.validTarget and values typed by the owner ever reach one.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false
  property var strings: null
  function t(key, fallback) { return strings ? strings.t(key, fallback) : fallback }

  // ---- settings (manifest.json schema) ----
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/+$/, "")
  readonly property string command: {
    var c = String(settings && settings.command !== undefined ? settings.command : "pohunek").trim()
    return /^[A-Za-z0-9._\/~+-]{1,256}$/.test(c) ? c.replace(/^~(?=\/)/, Quickshell.env("HOME")) : "pohunek"
  }
  readonly property string extraHosts: {
    var raw = String(settings && settings.hosts !== undefined ? settings.hosts : "")
    return raw.split(/[\s,]+/).filter(function(h) { return Model.validHost(h) && h !== "local" }).join(",")
  }
  readonly property bool discover: settings && settings.discover !== undefined ? !!settings.discover : true
  readonly property int intervalMs: {
    var n = Number(settings && settings.refreshIntervalSec !== undefined ? settings.refreshIntervalSec : 5)
    return Math.max(2, Math.min(600, isFinite(n) ? n : 5)) * 1000
  }
  readonly property int idleThresholdMs: {
    var fromCompanion = snapshotIdleSecs > 0 ? snapshotIdleSecs : 0
    var n = Number(settings && settings.idleThresholdSec !== undefined ? settings.idleThresholdSec : 300)
    return (fromCompanion || Math.max(10, isFinite(n) ? n : 300)) * 1000
  }
  readonly property bool desktopNotifications: settings && settings.desktopNotifications !== undefined
    ? !!settings.desktopNotifications : true

  // ---- snapshot ----
  property bool installed: true
  property bool loaded: false
  property var hosts: []             // [{target,label,reachable,error,message,source,latencyMs,count}]
  property var rows: []              // Model.buildRows
  property var counts: Model.summary([], true, 0)
  property int snapshotIdleSecs: 0
  property double lastUpdated: 0
  property double now: Date.now()
  property var clocks: null
  property var lastGood: ({})        // host target -> sessions of its last good answer
  property var previousStates: null
  property int pollCount: 0
  readonly property int reachableHosts: hosts.filter(function(h) { return h.reachable }).length

  // ---- owner layout (view, collapsed sections, own groups, recent projects) ----
  readonly property string layoutPath: Quickshell.env("HOME") + "/.local/state/omarchy/pohunek-layout.json"
  property var layout: ({ view: "groups", collapsed: {}, groups: [], recentProjects: [], onboardingDismissed: false })

  // ---- Get started card ----
  // tools/onboard writes the record; the widget reads only whether it names
  // the session it started (a failed launch leaves the card at ready).
  readonly property string onboardingRecordPath: Quickshell.env("HOME") + "/.local/state/omarchy/pohunek-onboarding.json"
  property bool onboardingRecordPresent: false
  property bool onboardingAgain: false   // Help → Run onboarding again, until the next start
  property var onboardAgents: []         // Model.onboardAgents of `host inspect local --json`
  readonly property var onboarding: Model.onboardingCard({
    installed: installed, recordPresent: onboardingRecordPresent, dismissed: !!layout.onboardingDismissed,
    again: onboardingAgain, rows: rows })

  // ---- action feedback ----
  property string banner: ""
  property bool bannerError: false
  property int busyActions: 0

  // ---- new-session form data ----
  property var form: ({ host: "", agents: [], projects: [], loading: false, error: "" })

  // ---- machines and network (Omarchy's herdr registry, pohunek's overlay) ----
  property var machines: []          // [{label, target, enabled}] from `herdr machine list`
  property bool machinesLoaded: false
  property string overlay: "netbird"
  // herdr machines with no pohunek host of the same name yet.
  readonly property var machinesWithoutPohunek: machines.filter(function(m) {
    var name = m.target.replace(/^.*@/, "").replace(/:.*$/, "").split(".")[0].toLowerCase()
    var label = m.label.toLowerCase()
    return !hosts.some(function(h) {
      var hl = String(h.label).toLowerCase(), ht = String(h.target).toLowerCase()
      return h.reachable && (hl === name || ht === name || hl === label || ht === label)
    })
  })

  // Whether bindings.lua already carries the widget's shortcuts.
  property bool shortcutsBound: false

  function validSshTarget(t) { return typeof t === "string" && /^[A-Za-z0-9._@:-]{1,128}$/.test(t) && t[0] !== "-" }

  // The `command` setting's own pattern.
  function validCommandPath(c) { return typeof c === "string" && /^[A-Za-z0-9._\/~+-]{1,256}$/.test(c) && c[0] !== "-" }

  // The helper scripts in tools/, each in Omarchy's floating terminal (the
  // one its own installers use). Only these names, and only arguments that
  // pass toolArgsValid, ever reach the command line.
  readonly property var tools: ["install-pohunek", "setup-network", "distribute", "add-shortcuts", "doctor", "onboard"]
  // onboard takes --launch-only, --agent <name> and --command <path>; the
  // others at most one validated SSH target. No accepted value holds a quote
  // or a space, so single quotes keep each one a single word.
  function toolArgsValid(name, args) {
    if (name !== "onboard") return args.length === 0 || (args.length === 1 && validSshTarget(args[0]))
    for (var i = 0; i < args.length; i++) {
      if (args[i] === "--launch-only") continue
      if (args[i] === "--agent" && i + 1 < args.length && Model.validSessionId(args[i + 1])) { i++; continue }
      if (args[i] === "--command" && i + 1 < args.length && validCommandPath(args[i + 1])) { i++; continue }
      return false
    }
    return true
  }
  function runTool(name, args) {
    var list = args === undefined || args === "" ? [] : (Array.isArray(args) ? args : [args])
    if (tools.indexOf(name) < 0 || !/^\/[A-Za-z0-9._\/-]+$/.test(pluginDir) || !toolArgsValid(name, list)) {
      say(t("msg.toolRefused", "%1 did not start: the plugin folder, the command setting or an argument holds characters a terminal command cannot carry").arg(name), true)
      return
    }
    var line
    if (name === "doctor") line = "'" + root.command.replace(/'/g, "") + "' doctor"
    else line = "'" + pluginDir + "/tools/" + name + "'"
    for (var i = 0; i < list.length; i++) line += " '" + list[i] + "'"
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", line])
  }

  // The card runs nothing by itself: it opens tools/onboard, which shows
  // every change and asks before it writes.
  function startOnboarding(launchOnly, agent) {
    var args = launchOnly ? ["--launch-only"] : []
    if (agent) args.push("--agent", agent)
    if (root.command !== "pohunek") args.push("--command", root.command)
    onboardingAgain = false
    runTool("onboard", args)
  }
  function dismissOnboarding() { saveLayout(Object.assign({}, layout, { onboardingDismissed: true })) }
  function onboardAgain() {
    saveLayout(Object.assign({}, layout, { onboardingDismissed: false }))
    onboardingAgain = true
    loadOnboardAgents()
  }
  // Read when the card is shown (panel open), not on the snapshot poll.
  function loadOnboardAgents() {
    if (!installed || onboardAgentsProc.running) return
    onboardAgentsProc.begin([root.command, "host", "inspect", "local", "--json"])
  }

  signal attentionNeeded(var row)

  function refresh(refreshDiscovery) {
    if (fetchProc.running) return
    var argv = ["python3", "-I", pluginDir + "/fetch.py", "--bin", root.command]
    if (extraHosts !== "") argv.push("--hosts", extraHosts)
    if (discover) argv.push("--discover")
    if (refreshDiscovery) argv.push("--refresh-discovery")
    // herdr machines and the overlay change rarely: read them with discovery.
    if (refreshDiscovery || !machinesLoaded) argv.push("--machines")
    fetchProc.begin(argv)
  }

  function applySnapshot(out, code) {
    loaded = true
    if (code === 127) { installed = false; hosts = []; rows = []; counts = Model.summary([], false, 0); return }
    var snap
    try { snap = JSON.parse(out) } catch (e) { return }
    if (!snap || !Array.isArray(snap.hosts)) return
    installed = true
    if (snap.machines !== undefined) {
      machinesLoaded = true
      machines = Array.isArray(snap.machines) ? snap.machines.filter(function(m) { return m && validSshTarget(m.target) })
        .map(function(m) { return { label: Model.clip(m.label, 40), target: m.target, enabled: !!m.enabled } }) : []
      overlay = snap.overlay === "tailscale" || snap.overlay === "netbird" ? snap.overlay : "unknown"
    }
    snapshotIdleSecs = Number(snap.idleThresholdSecs) > 0 ? Number(snap.idleThresholdSecs) : 0

    // A host that failed keeps the rows of its last good answer, dimmed.
    var good = {}
    var merged = []
    var info = []
    for (var i = 0; i < snap.hosts.length; i++) {
      var h = snap.hosts[i]
      if (!h || !(h.target === "local" || Model.validHost(h.target))) continue
      var sessions = h.reachable ? (h.sessions || []) : (lastGood[h.target] || [])
      if (h.reachable) good[h.target] = sessions
      merged.push({ target: h.target, label: Model.clip(h.label || h.target, 40), reachable: !!h.reachable,
                    sessions: sessions, notifications: h.reachable ? (h.notifications || []) : [] })
      info.push({ target: h.target, label: Model.clip(h.label || h.target, 40), reachable: !!h.reachable,
                  error: Model.clip(h.error, 64), message: Model.clip(h.message, 240), source: h.source || "",
                  latencyMs: h.latencyMs || 0, count: sessions.length, local: !!h.local,
                  endedOmitted: h.endedOmitted || 0 })
    }
    for (var t in lastGood) if (!good[t] && lastGood[t]) good[t] = lastGood[t]
    lastGood = good

    var t0 = Date.now()
    var all = []
    for (var m = 0; m < merged.length; m++)
      for (var k = 0; k < merged[m].sessions.length; k++)
        all.push(Object.assign({}, merged[m].sessions[k], { host: merged[m].target }))
    clocks = Model.trackClocks(clocks, all, t0)
    var built = Model.buildRows(merged, clocks, t0, idleThresholdMs)
    var fresh = Model.newAttention(previousStates, built)
    previousStates = Model.stateIndex(built)
    hosts = info
    rows = built
    now = t0
    counts = Model.summary(built, true, reachableHosts)
    lastUpdated = t0
    for (var f = 0; f < fresh.length && f < 5; f++) {
      notifyDesktop(fresh[f])
      attentionNeeded(fresh[f])
    }
  }

  // A click on the notification attaches to the session (Omarchy's
  // `--exec`: the argv runs on click, from the toast or the history).
  function notifyDesktop(row) {
    if (!desktopNotifications || !Model.validTarget(row.target)) return
    var title = row.ownerState === "problem" ? t("notify.problem", "pohunek: runtime problem") : t("notify.needs", "pohunek: needs you")
    var body = [row.title, row.agent, row.hostLabel].filter(function(p) { return p }).join(" · ")
    // The description slot reads a leading "-" as an option: keep the
    // session's name from ever being parsed as one.
    body = body.replace(/^-+/, function(m) { return m.replace(/-/g, "\u2010") }) || "pohunek"
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "pohunek", "-u", "critical", "-g", "󰀦",
                             title, body,
                             "--exec", "omarchy-launch-or-focus-tui", "--app-id=" + appId(row.target),
                             root.command, "attach", row.target])
  }


  // ---- layout persistence ----
  function saveLayout(next) {
    layout = next
    layoutFile.setText(JSON.stringify(next, null, 2) + "\n")
  }
  function setView(view) { saveLayout(Object.assign({}, layout, { view: view === "state" ? "state" : "groups" })) }
  function toggleCollapsed(sectionId) {
    var c = Object.assign({}, layout.collapsed || {})
    if (c[sectionId]) delete c[sectionId]; else c[sectionId] = true
    saveLayout(Object.assign({}, layout, { collapsed: c }))
  }
  function addGroup(name) {
    var checked = Model.checkGroupName(name)
    if (!checked.ok) return checked
    var groups = (layout.groups || []).slice()
    if (groups.every(function(g) { return g.toLowerCase() !== checked.name.toLowerCase() }) && checked.name.toLowerCase() !== "inbox")
      groups.push(checked.name)
    saveLayout(Object.assign({}, layout, { groups: groups }))
    return checked
  }
  function removeGroup(name) {
    var groups = (layout.groups || []).filter(function(g) { return g.toLowerCase() !== String(name).toLowerCase() })
    saveLayout(Object.assign({}, layout, { groups: groups }))
  }
  function rememberProject(project) {
    if (!project) return
    saveLayout(Object.assign({}, layout, { recentProjects: Model.pushRecent(layout.recentProjects, project, 8) }))
  }

  // ---- actions ----
  function appId(target) {
    return "org.omarchy.pohunek." + String(target).replace(/[^A-Za-z0-9]+/g, "-").slice(0, 80)
  }

  function attach(row) {
    if (!row || !Model.validTarget(row.target)) return
    Quickshell.execDetached(["omarchy-launch-or-focus-tui", "--app-id=" + appId(row.target), root.command, "attach", row.target])
  }

  function diff(row) {
    if (!row || !Model.validTarget(row.target)) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=" + appId(row.target) + "-diff",
                             "sh", "-c", '"$0" session diff "$1" | less -R', root.command, row.target])
  }

  // Only the project's own pages: the help page links to these and nothing else.
  readonly property var webLinks: ({
    site: "https://pohunek.dev/",
    docs: "https://pohunek.dev/docs/",
    surfaces: "https://pohunek.dev/surfaces/",
    source: "https://github.com/zajca/pohunek",
    remove: "https://github.com/pohunekd/omarchy#remove"
  })
  function openWeb(which) {
    var url = webLinks[which]
    if (url) Quickshell.execDetached(["xdg-open", url])
  }

  function openLink(row) {
    if (row && /^https?:\/\/[^\s]+$/.test(row.workUrl || "")) Quickshell.execDetached(["xdg-open", row.workUrl])
  }

  function assistant(host) {
    var argv = ["omarchy-launch-tui", "--app-id=org.omarchy.pohunek.assistant", root.command, "assistant"]
    if (host && host !== "local" && Model.validHost(host)) argv.push("--host", host)
    Quickshell.execDetached(argv)
  }

  function copy(text) {
    Quickshell.execDetached(["wl-copy", "--", String(text)])
    say(t("msg.copied", "Copied"), false)
  }

  function say(message, isError) {
    banner = Model.clip(message, 300)
    bannerError = !!isError
    bannerTimer.restart()
  }

  // Runs one CLI action with --json and reports its typed error, if any.
  function runAction(argv, okMessage, stdinText, onOk) {
    var proc = actionComponent.createObject(root, { okMessage: okMessage || "", stdinText: stdinText || "", onOk: onOk || null })
    busyActions++
    proc.begin([root.command].concat(argv))
  }

  function rename(row, name) {
    if (!row || !Model.validTarget(row.target)) return
    var clean = String(name || "").trim()
    if (clean.length > 120) clean = clean.slice(0, 120)
    var argv = ["session", "rename", row.target].concat(clean === "" ? ["--clear"] : [clean]).concat(["--json"])
    runAction(argv, clean === "" ? t("msg.nameCleared", "Name cleared") : t("msg.renamed", "Renamed"))
  }

  // Groups are shared with the companions through the companion.group key;
  // Inbox is the absence of the key.
  function moveToGroup(row, name) {
    if (!row || !Model.validTarget(row.target)) return
    var isInbox = String(name).toLowerCase() === "inbox"
    var argv = ["session", "metadata", row.target]
    if (isInbox) argv.push("--clear", Model.GROUP_KEY)
    else {
      var checked = Model.checkGroupName(name)
      if (!checked.ok) { say(t("group.invalid.empty", "Invalid group name"), true); return }
      argv.push("--set", Model.GROUP_KEY + "=" + checked.name)
    }
    argv.push("--json")
    runAction(argv, t("msg.moved", "Moved to %1").arg(isInbox ? "Inbox" : name))
  }

  function stop(row) {
    if (row && Model.validTarget(row.target)) runAction(["session", "stop", row.target, "--json"], t("msg.stopped", "Stopped"))
  }
  function remove(row) {
    if (row && Model.validTarget(row.target)) runAction(["session", "rm", row.target, "--json"], t("msg.removed", "Removed"))
  }
  function resume(row) {
    if (row && Model.validTarget(row.target)) runAction(["session", "resume", row.target, "--json"], t("msg.resumed", "Resumed"), "",
      function() { root.attach(row) })
  }

  // spec: { host, project, agent, name, branch, baseBranch, prompt, group }
  function newSession(spec) {
    var host = spec.host || "local"
    if (host !== "local" && !Model.validHost(host)) return
    if (!Model.validSessionId(spec.agent || "")) { say(t("msg.pickAgent", "Pick an agent"), true); return }
    var argv = ["session", "new", "--host", host, "--agent", spec.agent, "--yes", "--json"]
    if (spec.project) argv.push("--project", spec.project)
    if (spec.name) argv.push("--name", String(spec.name).slice(0, 120))
    if (spec.branch) argv.push("--branch", String(spec.branch).slice(0, 200))
    if (spec.branch && spec.baseBranch) argv.push("--base-branch", String(spec.baseBranch).slice(0, 200))
    var prompt = String(spec.prompt || "")
    if (prompt.trim() !== "") argv.push("--input-stdin")
    if (spec.project) rememberProject(spec.project)
    runAction(argv, t("msg.started", "Session started"), prompt.trim() !== "" ? prompt : "", function(ok) {
      var id = ok && ok.session && ok.session.id
      if (!Model.validSessionId(id)) return
      var created = { target: Model.validHost(host) && host !== "local" ? host + "/" + id : id }
      if (spec.group && String(spec.group).toLowerCase() !== "inbox")
        root.runAction(["session", "metadata", created.target, "--set", Model.GROUP_KEY + "=" + spec.group, "--json"], "")
      root.attach(created)
    })
  }

  function loadForm(host) {
    var h = host || "local"
    if (h !== "local" && !Model.validHost(h)) return
    form = { host: h, agents: [], projects: [], loading: true, error: "" }
    formProc.begin(["python3", "-I", pluginDir + "/fetch.py", "--bin", root.command, "--form", h])
  }

  onPanelOpenChanged: if (panelOpen) {
    refresh(false)
    onboardingRecord.reload()
    if (onboarding.state === "ready") loadOnboardAgents()
  }
  onExtraHostsChanged: refresh(false)
  onDiscoverChanged: refresh(false)
  Component.onCompleted: refresh(true)

  Timer {
    interval: root.panelOpen ? Math.min(root.intervalMs, 2000) : root.intervalMs
    running: true
    repeat: true
    onTriggered: {
      root.pollCount++
      // Re-probe the overlay for new pohunek hosts about every ten minutes.
      root.refresh(root.pollCount % Math.max(1, Math.round(600000 / root.intervalMs)) === 0)
    }
  }

  Timer { id: bannerTimer; interval: 4000; onTriggered: root.banner = "" }

  FileView {
    path: Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.shortcutsBound = String(text() || "").indexOf("pohunek.sessions") >= 0
  }

  FileView {
    id: layoutFile
    path: root.layoutPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object") root.layout = {
          view: parsed.view === "state" ? "state" : "groups",
          collapsed: parsed.collapsed && typeof parsed.collapsed === "object" ? parsed.collapsed : {},
          groups: Array.isArray(parsed.groups) ? parsed.groups.map(String).slice(0, 100) : [],
          recentProjects: Array.isArray(parsed.recentProjects) ? parsed.recentProjects.map(String).slice(0, 8) : [],
          onboardingDismissed: parsed.onboardingDismissed === true
        }
      } catch (e) { }
    }
  }

  FileView {
    id: onboardingRecord
    path: root.onboardingRecordPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.onboardingRecordPresent = Model.onboardingRecordLaunched(text())
    onLoadFailed: function(error) { root.onboardingRecordPresent = false }
  }

  // Exit and end-of-stream arrive in either order; apply once both have.
  component CliProcess: Process {
    id: proc
    property string out: ""
    property bool streamDone: false
    property int code: -1
    property string stdinText: ""
    signal finished(string out, int code)
    function begin(argv) {
      out = ""; streamDone = false; code = -1
      stdinEnabled = stdinText !== ""
      command = argv
      running = true
    }
    function settle() { if (streamDone && code !== -1) proc.finished(out, code) }
    onStarted: if (stdinText !== "") { write(stdinText); stdinEnabled = false }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { proc.out = String(text || ""); proc.streamDone = true; proc.settle() }
    }
    onExited: function(exitCode) { proc.code = exitCode; proc.settle() }
  }

  CliProcess {
    id: fetchProc
    onFinished: function(out, code) { root.applySnapshot(out, code) }
  }

  CliProcess {
    id: onboardAgentsProc
    onFinished: function(out, code) {
      var doc = null
      try { doc = JSON.parse(out) } catch (e) { }
      root.onboardAgents = code === 0 && doc && doc.ok ? Model.onboardAgents(doc.ok) : []
    }
  }

  CliProcess {
    id: formProc
    onFinished: function(out, code) {
      var parsed = null
      try { parsed = JSON.parse(out) } catch (e) { }
      if (!parsed) { root.form = Object.assign({}, root.form, { loading: false, error: "invalid" }); return }
      root.form = {
        host: root.form.host,
        agents: (parsed.agents || []).filter(Model.validSessionId).slice(0, 200),
        projects: (parsed.projects || []).filter(function(p) { return p && Model.validSessionId(p.id) })
          .map(function(p) { return { id: p.id, label: Model.clip(p.label, 80) } }).slice(0, 500),
        loading: false,
        error: Model.clip(parsed.error || "", 64)
      }
    }
  }

  Component {
    id: actionComponent
    CliProcess {
      id: action
      property string okMessage: ""
      property var onOk: null
      onFinished: function(out, code) {
        root.busyActions = Math.max(0, root.busyActions - 1)
        var doc = null
        try { doc = JSON.parse(out) } catch (e) { }
        if (code === 0 && doc && doc.ok !== undefined) {
          if (action.okMessage) root.say(action.okMessage, false)
          if (typeof action.onOk === "function") action.onOk(doc.ok)
        } else {
          var err = doc && doc.err ? (doc.err.msg || doc.err.code) : t("msg.failed", "Command failed (exit %1)").arg(code)
          root.say(err, true)
        }
        root.refresh(false)
        action.destroy()
      }
    }
  }
}
