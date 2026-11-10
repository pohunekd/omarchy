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
          session("s-a2", { activity: "idle", updatedAt: iso(4000) }),
          session("s-a3", { state: "stopped", runtimeState: "terminal", resumable: true }) ] },
        { target: "laptop", label: "laptop", reachable: true, sessions: [
          session("s-b1", { activity: "blocked", name: "<b>bold</b>" }) ],
          notifications: [{ id: "n1", sessionId: "s-b1", kind: "approval_required", createdAt: iso(120) }] },
        { target: "gone", label: "gone", reachable: false, error: "timeout", sessions: [], notifications: [] } ] }), 0)

      console.log("snapshot")
      check("rows built", svc.rows.length, 4)
      check("bar state", svc.counts.state, "needs")
      check("needs count", svc.counts.needs, 1)
      check("first section is Needs you", barPanel.sectionList[0].kind, "needs")
      check("needs row is the blocked one", barPanel.sectionList[0].rows[0].id, "s-b1")
      check("groups view lists Inbox and Deps", barPanel.sectionList.slice(1).map(function(s) { return s.name }).join(","), "Inbox,Deps")
      check("ended hidden by default", barPanel.visibleRows.some(function(r) { return r.ownerState === "ended" }), false)
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
      var collapsedBefore = barPanel.sectionList[1].collapsed
      barPanel.cursor = 2
      barPanel.activate()
      check("Enter on a group header collapses it", barPanel.sectionList[1].collapsed, !collapsedBefore)
      svc.toggleCollapsed(barPanel.sectionList[1].id)

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
