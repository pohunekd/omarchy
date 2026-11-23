import Quickshell
import QtQuick
import qs.Commons as Commons

// Drives the real Panel.qml, Service.qml and Model.js offscreen: it must load,
// turn a fetch.py snapshot into the Needs-you / groups list, and walk its
// sheets and pages without a QML error. No daemon is contacted: the command
// is `false` and the snapshot is handed in directly.
ShellRoot {
  Item {
    id: harness
    width: 600; height: 800
    property int failures: 0
    function check(name, got, want) {
      if (String(got) === String(want)) console.log("  ok   " + name)
      else { failures++; console.log("  FAIL " + name + ": got " + JSON.stringify(got) + ", wanted " + JSON.stringify(want)) }
    }

    BarPanel {
      id: barPanel
      bar: null
      settings: ({ command: "false", discover: false, refreshIntervalSec: 600, desktopNotifications: false })
    }

    function iso(secondsAgo) { return new Date(Date.now() - secondsAgo * 1000).toISOString() }
    function session(id, extra) {
      var s = { id: id, name: id, agent: "claude", profile: "cc", state: "running", activity: "working",
                runtimeState: "live", subagentsRunning: 0, backgroundRunning: 0, cwd: "/w/" + id, project: "app",
                branch: "", group: null, work: {}, resumable: false, updatedAt: iso(30), createdAt: iso(600) }
      for (var k in extra) s[k] = extra[k]
      return s
    }

    Timer {
      interval: 1500; running: true
      onTriggered: harness.run()
    }

    function run() {
      var svc = barPanel.service
      svc.applySnapshot(JSON.stringify({ installed: true, hosts: [
        { target: "local", label: "workstation", local: true, reachable: true, notifications: [], sessions: [
          session("s-a1", { group: "Deps", work: { provider: "github", kind: "pr", id: "12", url: "https://github.com/a/b/pull/12" } }),
          session("s-a1w", { group: "Inbox", activity: "working", spawned_by: { session_id: "s-a1", daemon_id: "d-1" }, updatedAt: iso(20) }),
          session("s-a1o", { group: "Deps", activity: "working", spawned_by: "s-gone", updatedAt: iso(10) }),
          session("s-a1x", { activity: "working", spawned_by: "s-gone", updatedAt: iso(5) }),
          session("s-a2", { activity: "idle", updatedAt: iso(4000) }),
          session("s-a3", { state: "stopped", runtimeState: "terminal", resumable: true }) ] },
        { target: "laptop", label: "laptop", reachable: true, sessions: [
          session("s-b1", { activity: "blocked", name: "<b>bold</b>" }) ],
          notifications: [{ id: "n1", sessionId: "s-b1", kind: "approval_required", createdAt: iso(120) }] },
        { target: "gone", label: "gone", reachable: false, error: "timeout", sessions: [], notifications: [] } ] }), 0)

      console.log("snapshot")
      check("rows built", svc.rows.length, 7)
      check("bar state", svc.counts.state, "needs")
      check("needs count", svc.counts.needs, 1)
      check("first section is Needs you", barPanel.sectionList[0].kind, "needs")
      check("needs row is the blocked one", barPanel.sectionList[0].rows[0].id, "s-b1")
      check("groups view lists Inbox and Deps", barPanel.sectionList.slice(1).map(function(s) { return s.name }).join(","), "Inbox,Deps")
      var inbox = null
      for (var bi = 0; bi < barPanel.sectionList.length; bi++) if (barPanel.sectionList[bi].name === "Inbox") inbox = barPanel.sectionList[bi]
      check("group-less session stays in Inbox", inbox ? inbox.nodes.map(function(n) { return n.row.id }).join(",") : "", "s-a1x,s-a2")
      check("group-less session is top-level", inbox ? inbox.nodes.map(function(n) { return n.depth }).join(",") : "", "0,0")
      check("group-less orphan folds at depth 0", inbox ? inbox.nodes.some(function(n) { return n.row.id === "s-a1x" && n.depth === 0 }) : false, true)
      check("ended hidden by default", barPanel.visibleRows.some(function(r) { return r.ownerState === "ended" }), false)
      check("worker folds under its manager", barPanel.visibleRows.filter(function(r) { return r.id === "s-a1w" }).length, 1)
      // A sub-session folds under its manager wherever the manager is
      // listed: s-a1w sits in Inbox but its manager s-a1 sits in Deps,
      // so the worker shows under Deps and Inbox holds the orphans.
      var deps = null
      for (var si = 0; si < barPanel.sectionList.length; si++) if (barPanel.sectionList[si].name === "Deps") deps = barPanel.sectionList[si]
      check("Deps section found", deps !== null, true)
      check("cross-group worker folds under its manager", deps.nodes.map(function(n) { return n.row.id }).join(","), "s-a1o,s-a1")
      check("Deps depths", deps.nodes.map(function(n) { return n.depth }).join(","), "0,0")
      var depsManager = null
      for (var di = 0; di < deps.nodes.length; di++) if (deps.nodes[di].row.id === "s-a1") depsManager = deps.nodes[di]
      check("Deps manager found", depsManager !== null, true)
      check("folded manager carries the fold", depsManager ? depsManager.collapsed : false, true)
      // M1: Deps lists s-a1o and the s-a1 manager, while `members`
      // counts only the section's own rows (the Inbox worker is the
      // manager's section-mate here), so right-click removal must
      // still refuse the group.
      check("Deps owns its shown rows", deps ? deps.members : -1, 2)
      check("Deps shows its shown rows", deps ? deps.count : -1, 2)
      check("flat list hides the worker", barPanel.items.filter(function(i) { return i.type === "row" }).map(function(i) { return i.row.id }).join(","), "s-b1,s-a1x,s-a2,s-a1o,s-a1")
      svc.toggleSub(depsManager.row)
      // Top-level roots sort newest-first (rowOrder): the orphan s-a1o
      // (iso(10)) stays ahead of the manager s-a1 (iso(30)) even when the
      // manager is open; parent-before-child still holds inside the fold.
      check("opened manager lists parent before child", barPanel.items.filter(function(i) { return i.type === "row" }).map(function(i) { return i.row.id }).join(","), "s-b1,s-a1x,s-a2,s-a1o,s-a1,s-a1w")
      var workerItem = null
      for (var wi = 0; wi < barPanel.items.length; wi++) if (barPanel.items[wi].type === "row" && barPanel.items[wi].row.id === "s-a1w") workerItem = barPanel.items[wi]
      check("child depth", workerItem ? workerItem.depth : -1, 1)
      var opened = null
      for (var oi = 0; oi < barPanel.sectionList.length; oi++) if (barPanel.sectionList[oi].name === "Deps") opened = barPanel.sectionList[oi]
      // nodes[0] is the newer orphan, not the manager: address it by id.
      var openedManager = null
      for (var om = 0; om < opened.nodes.length; om++) if (opened.nodes[om].row.id === "s-a1") openedManager = opened.nodes[om]
      check("Deps manager still listed", openedManager !== null, true)
      svc.toggleSub(openedManager.row)
      check("toggled back, worker hidden again", barPanel.items.filter(function(i) { return i.type === "row" }).map(function(i) { return i.row.id }).join(","), "s-b1,s-a1x,s-a2,s-a1o,s-a1")
      check("multi host", barPanel.multiHost, true)
      check("unreachable host listed", barPanel.unreachableHosts.length, 1)

      console.log("open panel")
      barPanel.open()
      check("content loaded", barPanel.panelContent !== null, true)

      console.log("filters")
      barPanel.toggleState("ended")
      check("ended chip shows ended only", barPanel.visibleRows.map(function(r) { return r.id }).join(","), "s-a3")
      barPanel.clearFilters()
      barPanel.setFilter("host", "laptop")
      check("host filter", barPanel.visibleRows.map(function(r) { return r.id }).join(","), "s-b1")
      barPanel.clearFilters()
      barPanel.setFilter("query", "GH PR")
      check("search matches work badge", barPanel.visibleRows.map(function(r) { return r.id }).join(","), "s-a1")
      barPanel.clearFilters()

      console.log("view")
      svc.setView("state")
      check("state view sections", barPanel.sectionList.map(function(s) { return s.id }).join(","), "needs-you,state:working,state:idle")
      // Same newest-first order as the Deps section: the orphan s-a1o
      // (iso(10)) sorts ahead of the folded manager s-a1 (iso(30)).
      check("state view folds too", barPanel.sectionList[1].nodes.map(function(n) { return n.row.id }).join(","), "s-a1x,s-a1o,s-a1")
      svc.setView("groups")

      console.log("sheets")
      var row = barPanel.sectionList[0].rows[0]
      barPanel.openSheet("actions", row)
      var sheet = barPanel.panelContent ? findSheet(barPanel.panelContent) : null
      check("action sheet built", sheet !== null && sheet.options.length > 5, true)
      check("first action opens the terminal", sheet ? sheet.options[0].label : "", barPanel.t("action.openTerminal"))
      barPanel.openSheet("group", row)
      check("group sheet offers Inbox, Deps, new", sheet ? sheet.options.map(function(o) { return o.label }).join(",") : "",
            [barPanel.t("group.inbox"), "Deps", barPanel.t("menu.newGroup")].join(","))
      barPanel.openSheet("state")
      check("state sheet has six states", sheet ? sheet.options.length : 0, 6)
      barPanel.openSheet("project")
      check("project sheet", sheet ? sheet.options.length : 0, 2)
      check("list stays put under a sheet", barPanel.panelContent.listFlick.interactive, false)
      check("short picker has no search field", sheet.searchable, false)
      for (var g = 0; g < 12; g++) svc.addGroup("group-" + g)
      barPanel.openSheet("group", row)
      check("long picker gets fuzzy search", sheet.searchable, true)
      barPanel.pickerQuery = "gp11"
      check("fuzzy ranks the match first", sheet.options.length > 0 ? sheet.options[0].label : "", "group-11")
      barPanel.closeSheet()
      for (var g2 = 0; g2 < 12; g2++) svc.removeGroup("group-" + g2)

      console.log("new session pickers")
      barPanel.newSessionFrom(null)
      svc.form = { host: "local", loading: false, error: "",
                   agents: ["claude", "codex", "shell"],
                   projects: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "pohunek-companion-android"]
                     .map(function(l, i) { return { id: "p-" + i, label: l } }) }
      var pickers = findAll(barPanel.panelContent.newForm, function(i) { try { return i.fuzzy !== undefined && i.matches !== undefined } catch (e) { return false } })
      check("three pickers", pickers.length, 3)
      var projectPicker = pickers.filter(function(p) { return p.emptyLabel !== "" })[0]
      check("11 projects → fuzzy select", projectPicker ? projectPicker.fuzzy : "", true)
      check("3 agents → chips", pickers.filter(function(p) { return p.emptyLabel === "" && p.options.length === 3 })[0].fuzzy, false)
      projectPicker.open()
      projectPicker.query = "pca"
      check("fuzzy project match", projectPicker.matches[0].label, "pohunek-companion-android")
      projectPicker.choose(projectPicker.matches[0].value)
      check("picked project", barPanel.panelContent.newForm.project, "pohunek-companion-android")
      barPanel.back()

      console.log("icon")
      check("bar icon is the prompt plate", findAll(barPanel, function(i) { try { return i.cursorColor !== undefined && i.plate !== undefined } catch (e) { return false } }).length, 1)

      console.log("machines")
      svc.machines = [{ label: "laptop", target: "me@laptop", enabled: true },
                      { label: "newbox", target: "me@newbox.lan", enabled: true }]
      check("herdr machine without pohunek", svc.machinesWithoutPohunek.map(function(m) { return m.label }).join(","), "newbox")
      check("ssh target validation", [svc.validSshTarget("me@box"), svc.validSshTarget("-oProxyCommand=x"), svc.validSshTarget("a b")].join(","), "true,false,false")
      svc.machines = []

      console.log("help")
      barPanel.page = "help"
      var helpPage = findAll(barPanel.panelContent, function(i) { try { return i.sections !== undefined && i.visible } catch (e) { return false } })[0]
      check("help page shows", helpPage !== undefined, true)
      check("help explains Ctrl+\\", helpPage ? helpPage.sections[0].keys[1].keys.join("+") : "", "Ctrl+\\")
      barPanel.back()

      console.log("pages")
      barPanel.showDetails(row)
      check("details page", barPanel.page, "details")
      barPanel.back()
      barPanel.page = "hosts"
      check("hosts page", barPanel.page, "hosts")
      barPanel.back()
      barPanel.newSessionFrom(row)
      check("new session page", barPanel.page, "new")
      barPanel.back()
      check("back to list", barPanel.page, "list")

      console.log("keyboard")
      barPanel.cursorActive = true
      barPanel.cursor = 0
      barPanel.moveCursor(1)
      check("cursor on the needs row", barPanel.currentRow() ? barPanel.currentRow().id : "", "s-b1")
      // Drive to the Inbox header by section id, not by a hardcoded index.
      var inboxHeader = -1
      for (var hi = 0; hi < barPanel.items.length; hi++)
        if (barPanel.items[hi].type === "header" && barPanel.items[hi].section.id === "group:inbox") inboxHeader = hi
      check("Inbox header found", inboxHeader >= 0, true)
      var inboxSec = null
      for (var ib = 0; ib < barPanel.sectionList.length; ib++) if (barPanel.sectionList[ib].name === "Inbox") inboxSec = barPanel.sectionList[ib]
      var collapsedBefore = inboxSec.collapsed
      barPanel.cursor = inboxHeader
      barPanel.activate()
      var inboxAfter = null
      for (var ia = 0; ia < barPanel.sectionList.length; ia++) if (barPanel.sectionList[ia].name === "Inbox") inboxAfter = barPanel.sectionList[ia]
      check("Enter on a group header collapses it", inboxAfter ? inboxAfter.collapsed : collapsedBefore, !collapsedBefore)
      svc.toggleCollapsed(inboxAfter.id)
      // The folded Deps manager: Enter opens it in place.
      var managerIdx = -1
      for (var mj = 0; mj < barPanel.items.length; mj++)
        if (barPanel.items[mj].type === "row" && barPanel.items[mj].row.id === "s-a1") managerIdx = mj
      check("Deps manager row found", managerIdx >= 0, true)
      barPanel.cursor = managerIdx
      var openedBefore = barPanel.items.length
      barPanel.activate()
      check("Enter opens a folded manager", barPanel.items.length, openedBefore + 1)
      check("Enter lands on the manager row", barPanel.currentRow() ? barPanel.currentRow().id : "", "s-a1")
      // The left key helper folds a sub-session back under its manager and
      // lands the cursor on the manager; on an open parent it folds itself.
      var workerIdx = -1
      for (var wj = 0; wj < barPanel.items.length; wj++)
        if (barPanel.items[wj].type === "row" && barPanel.items[wj].row.id === "s-a1w") workerIdx = wj
      barPanel.cursor = workerIdx
      var workerRow = barPanel.currentRow()
      check("cursor on the worker", workerRow ? workerRow.id : "", "s-a1w")
      var workerEntry = null
      for (var ei = 0; ei < barPanel.items.length; ei++)
        if (barPanel.items[ei].type === "row" && barPanel.items[ei].row.id === "s-a1w") workerEntry = barPanel.items[ei]
      check("worker can fold back", workerEntry !== null && (workerEntry.depth || 0) > 0, true)
      check("foldBack folds to the manager", barPanel.foldBack(workerEntry), true)
      check("foldBack lands on the manager", barPanel.currentRow() ? barPanel.currentRow().id : "", "s-a1")
      check("folded back, worker hidden again", barPanel.items.length, openedBefore)
      var managerEntry = null
      for (var mi = 0; mi < barPanel.items.length; mi++)
        if (barPanel.items[mi].type === "row" && barPanel.items[mi].row.id === "s-a1") managerEntry = barPanel.items[mi]
      check("foldBack on a folded manager does nothing", barPanel.foldBack(managerEntry), false)
      barPanel.activate()
      var managerEntryOpen = null
      for (var mo = 0; mo < barPanel.items.length; mo++)
        if (barPanel.items[mo].type === "row" && barPanel.items[mo].row.id === "s-a1") managerEntryOpen = barPanel.items[mo]
      check("foldBack closes the open manager", barPanel.foldBack(managerEntryOpen), true)
      check("foldBack leaves the cursor on the parent", barPanel.currentRow() ? barPanel.currentRow().id : "", "s-a1")
      check("parent folded again", barPanel.items.length, openedBefore)

      console.log("get started card")
      var card = findAll(barPanel.panelContent, function(i) { try { return i.isOnboardCard === true } catch (e) { return false } })[0]
      check("card exists", card !== undefined, true)
      svc.onboardingRecordPresent = false
      check("card ready without a record", svc.onboarding.state, "ready")
      check("ready card shows", card ? card.visible : false, true)
      svc.onboardAgents = ["codex", "claude"]
      check("picker preselects the first agent", card ? card.pickedAgent : "", "codex")
      svc.dismissOnboarding()
      check("Not now dismisses", svc.onboarding.state, "dismissed")
      check("dismissed card hides", card ? card.visible : true, false)
      svc.onboardAgain()
      check("Run onboarding again shows it", svc.onboarding.state, "ready")
      svc.onboardingAgain = false
      svc.onboardingRecordPresent = true
      svc.saveLayout(Object.assign({}, svc.layout, { onboardingDismissed: false }))
      check("record and no session: done", svc.onboarding.state, "done")
      check("done card hides", card ? card.visible : true, false)
      svc.applySnapshot(JSON.stringify({ installed: true, hosts: [
        { target: "local", label: "workstation", local: true, reachable: true, notifications: [], sessions: [
          session("s-on", { onboardMode: "guided" }) ] } ] }), 0)
      check("onboard session: running", svc.onboarding.state, "running")
      check("running card shows", card ? card.visible : false, true)
      check("Open targets the onboard session", svc.onboarding.target, "s-on")
      check("onboard tool arguments are validated",
            [svc.toolArgsValid("onboard", ["--launch-only", "--agent", "claude"]),
             svc.toolArgsValid("onboard", ["--agent", "x'; rm -rf ~"]),
             svc.toolArgsValid("onboard", ["--yes"])].join(","), "true,false,false")
      svc.applySnapshot("", 127)
      svc.onboardingRecordPresent = true
      svc.onboardAutoVersion = "0.43.0"
      svc.applySnapshot(JSON.stringify({ installed: true, hosts: [
        { target: "local", label: "workstation", local: true, reachable: true, notifications: [], sessions: [
          session("s-lost", { onboardMode: "guided", runtimeState: "lost", resumable: true, activity: "idle" }) ] } ] }), 0)
      check("lost onboard session: interrupted", svc.onboarding.state, "interrupted")
      check("interrupted card shows", card ? card.visible : false, true)
      check("interrupted card resumes the lost session", svc.onboarding.target + "/" + svc.onboarding.resumable, "s-lost/true")
      svc.onboardingRecordPresent = false
      check("interrupted needs the record", svc.onboarding.state, "ready")
      card.mode = "automatic"
      check("automatic text names the requirement", card.modeText.indexOf("needs pohunek 0.43.0 or newer") >= 0, true)
      check("automatic text has no stale version", card.modeText.indexOf("(pohunek 0.43.0") < 0, true)
      svc.onboardAutoVersion = ""
      check("no versions file: the text names no version", card.modeText.indexOf("0.4") < 0, true)
      card.mode = "guided"
      svc.onboardingRecordPresent = true
      svc.applySnapshot("", 127)
      check("no pohunek: missing", svc.onboarding.state, "missing")
      check("missing card shows", card ? card.visible : false, true)

      console.log("blocked dialog on new session")
      var offer = findAll(barPanel.panelContent, function(i) { try { return i.isBlockedOffer === true } catch (e) { return false } })[0]
      check("offer exists", offer !== undefined, true)
      check("no offer without a failure", offer ? offer.visible : true, false)
      svc.blockedStart = { spec: { host: "local", agent: "claude", prompt: "fix the bug" } }
      check("blocked failure shows the offer", offer ? offer.visible : false, true)
      svc.dismissBlockedStart()
      check("Dismiss hides the offer", offer ? offer.visible : true, false)
      svc.heldPrompt = { target: "s-held", text: "fix the bug" }
      check("held prompt belongs to its session", svc.hasHeldPrompt({ target: "s-held" }) + "/" + svc.hasHeldPrompt({ target: "s-other" }), "true/false")
      svc.heldPrompt = null

      console.log("group removal")
      // A Deps worker folds under its manager in Inbox, so Deps shows
      // 0 rows but still owns its worker: the header is kept and a
      // right-click must refuse removal (Panel.qml gates on members).
      svc.applySnapshot(JSON.stringify({ installed: true, hosts: [
        { target: "local", label: "workstation", local: true, reachable: true, notifications: [], sessions: [
          session("s-g1", { group: "Inbox", activity: "working" }),
          session("s-g2", { group: "Deps", activity: "working", spawned_by: { session_id: "s-g1", daemon_id: "d-1" } }) ] } ] }), 0)
      svc.saveLayout(Object.assign({}, svc.layout, { groups: ["Deps"] }))
      var keptDeps = null
      for (var kd = 0; kd < barPanel.sectionList.length; kd++) if (barPanel.sectionList[kd].id === "group:deps") keptDeps = barPanel.sectionList[kd]
      check("emptied Deps is kept", keptDeps !== null, true)
      check("kept Deps shows 0", keptDeps ? keptDeps.count : -1, 0)
      check("kept Deps still owns its worker", keptDeps ? keptDeps.members : -1, 1)
      var depsHeader = findAll(barPanel.panelContent, function(i) { try { return i.sec !== undefined && i.sec && i.sec.id === "group:deps" } catch (e) { return false } })[0]
      check("Deps header declares its section", depsHeader !== undefined, true)
      check("Deps header delegates the kept section", depsHeader ? depsHeader.sec.members : -1, 1)
      depsHeader.rightClicked()
      check("right-click refuses a group with members", (svc.layout.groups || []).indexOf("Deps") >= 0, true)
      var keptStill = null
      for (var ks = 0; ks < barPanel.sectionList.length; ks++) if (barPanel.sectionList[ks].id === "group:deps") keptStill = barPanel.sectionList[ks]
      check("refused click keeps the Deps header", keptStill !== null, true)
      svc.removeGroup("Deps")
      var keptAfter = null
      for (var ka = 0; ka < barPanel.sectionList.length; ka++) if (barPanel.sectionList[ka].id === "group:deps") keptAfter = barPanel.sectionList[ka]
      check("direct removal still drops an owned group", keptAfter === null, true)

      console.log(failures === 0 ? "ALL OK" : failures + " FAILED")
    }

    function findAll(item, pred) {
      var out = []
      if (!item) return out
      if (pred(item)) out.push(item)
      var kids = []
      try { var list = item.children || []; for (var k = 0; k < list.length; k++) kids.push(list[k]) } catch (e) { return out }
      for (var i = 0; i < kids.length; i++) out = out.concat(findAll(kids[i], pred))
      var content = null
      try { content = item.contentItem } catch (e2) { }
      if (content && content !== item && kids.indexOf(content) < 0) out = out.concat(findAll(content, pred))
      return out
    }

    function findSheet(item) {
      if (!item) return null
      if (item.options !== undefined && item.buildOptions !== undefined) return item
      for (var i = 0; i < item.children.length; i++) {
        var found = findSheet(item.children[i])
        if (found) return found
      }
      return null
    }
  }
}
