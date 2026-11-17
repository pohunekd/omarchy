.pragma library

// Pure decisions for the pohunek bar widget, following the pohunek
// companions (desktop and Android): the owner state of a session, the
// "Needs you" section, groups shared through the `companion.group` metadata
// key, Work-link badges, filters, and the bar badge. No I/O here; the
// Service feeds snapshots from fetch.py in and the Panel renders what comes
// out. Everything from the daemon is untrusted and is rendered as plain text.

var GROUP_KEY = "companion.group"
var INBOX = "Inbox"
var NEEDS_YOU = "needs-you"
var GROUP_NAME_MAX = 64
var ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
var HOST_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/

// Owner states, as the companions name them.
var STATES = ["needs", "working", "idle", "problem", "nostate", "ended"]
var STATE_ORDER = { needs: 0, problem: 1, working: 2, nostate: 3, idle: 4, ended: 5 }

function clip(value, limit) {
  if (value === undefined || value === null) return ""
  var text = String(value)
    .replace(/[\u0000-\u001f\u007f-\u009f؜​-‏‪-‮⁠-⁩﻿]+/g, " ")
    .replace(/\s+/g, " ").trim()
  var max = limit || 200
  return text.length > max ? text.slice(0, max - 1) + "…" : text
}

function validSessionId(id) { return typeof id === "string" && ID_RE.test(id) }
function validHost(host) { return typeof host === "string" && HOST_RE.test(host) }

function validTarget(target) {
  var t = String(target || "")
  var slash = t.indexOf("/")
  if (slash < 0) return validSessionId(t)
  return validHost(t.slice(0, slash)) && validSessionId(t.slice(slash + 1))
}

function targetOf(host, id) { return !host || host === "local" ? id : host + "/" + id }
function keyOf(host, id) { return (host || "local") + "/" + id }

function parseTime(value) {
  if (typeof value === "number" && isFinite(value)) return value
  var ms = Date.parse(String(value || ""))
  return isFinite(ms) ? ms : 0
}

function baseName(path) {
  var text = clip(path, 400).replace(/\/+$/, "")
  var slash = text.lastIndexOf("/")
  return slash >= 0 ? text.slice(slash + 1) : text
}

// --- Owner state (pohunek-companion core/owner_state.rs) -------------------

function isEnded(s) {
  return s.state === "stopped" || s.state === "done" || s.state === "failed" || s.runtimeState === "lost"
}

function hasRuntimeProblem(s) {
  return s.runtimeState === "conflict" || s.runtimeState === "incompatible"
}

function hasRunningWork(s) {
  return (s.subagentsRunning || 0) > 0 || (s.backgroundRunning || 0) > 0
}

function isIdleWithoutWork(s) {
  return s.activity === "idle" && !hasRunningWork(s) && !isEnded(s) && !hasRuntimeProblem(s)
}

// An idle session counts as Idle only once it has been idle, with no
// subagent or background work, for the threshold; before that it reads as
// Working, like the companions.
function ownerState(s, openAttention, idleSince, now, thresholdMs) {
  if (isEnded(s)) return "ended"
  if (hasRuntimeProblem(s)) return "problem"
  if (openAttention || s.activity === "blocked") return "needs"
  if (s.activity === "working") return "working"
  if (s.activity === "idle") {
    var long = !hasRunningWork(s) && idleSince > 0 && now - idleSince >= thresholdMs
    return long ? "idle" : "working"
  }
  return "nostate"
}

// Carries the idle-since and needs-since clocks from one snapshot to the
// next. A session seen for the first time in a state starts its clock at its
// last update (not at the poll), so a widget restart does not reset hours of
// idling to "Working".
function trackClocks(previous, sessions, now) {
  var prev = previous || { idle: {}, needs: {} }
  var next = { idle: {}, needs: {} }
  for (var i = 0; i < sessions.length; i++) {
    var s = sessions[i]
    var key = keyOf(s.host, s.id)
    var since = Math.min(now, parseTime(s.updatedAt) || now)
    if (isIdleWithoutWork(s)) next.idle[key] = prev.idle[key] || since
    if (s.activity === "blocked" && !isEnded(s)) next.needs[key] = prev.needs[key] || since
  }
  return next
}

// --- Work link badge (pohunek-companion core/badge.rs) ---------------------

function abbreviateProvider(p) {
  switch (String(p).toLowerCase()) {
  case "github": return "GH"
  case "gitlab": return "GL"
  case "linear": return "Linear"
  case "jira": return "Jira"
  default: return p
  }
}

function abbreviateKind(k) {
  switch (String(k).toLowerCase()) {
  case "issue": return ""
  case "pr": case "pull_request": case "pull-request": case "pullrequest": return "PR"
  case "mr": case "merge_request": case "merge-request": case "mergerequest": return "MR"
  default: return k
  }
}

function workBadge(work) {
  if (!work || !work.id) return ""
  var id = /^[0-9]+$/.test(work.id) ? "#" + work.id : work.id
  return [work.provider ? abbreviateProvider(work.provider) : "", work.kind ? abbreviateKind(work.kind) : "", id]
    .filter(function(p) { return p !== "" }).join(" ")
}

function safeUrl(url) {
  var u = String(url || "")
  return u.length <= 2048 && /^https?:\/\/[^\s]+$/.test(u) ? u : ""
}

// --- Groups ----------------------------------------------------------------

function checkGroupName(raw) {
  var name = String(raw || "").trim()
  if (name === "") return { ok: false, problem: "empty" }
  if (/[\u0000-\u001f\u007f-\u009f؜​-‏‪-‮⁠-⁩﻿]/.test(name))
    return { ok: false, problem: "control" }
  if (name.length > GROUP_NAME_MAX) return { ok: false, problem: "too_long" }
  return { ok: true, name: name }
}

function groupOf(s) {
  if (s.group === null || s.group === undefined) return INBOX
  var checked = checkGroupName(s.group)
  return checked.ok ? clip(checked.name, GROUP_NAME_MAX) : INBOX
}

function sameGroup(a, b) { return String(a).toLowerCase() === String(b).toLowerCase() }

// The manager a row folds under: `spawned_by` names the spawning session id,
// either as the daemon's {session_id, daemon_id} object or as a bare id. The
// daemon id is not compared: a session id is unique on its own, and a
// cross-host origin is a reference, not a session this panel resolves.
function parentIdOf(s) {
  var sb = s.spawnedBy === undefined ? s.spawned_by : s.spawnedBy
  var id = typeof sb === "string" ? sb : (sb && typeof sb === "object" ? sb.session_id : null)
  return validSessionId(id) ? id : ""
}

function subCollapseId(row) { return "sub:" + row.key }
// A group fold and a sub-session fold share the stored map, but under
// different prefixes: group or state section ids never start with `sub:`.
// Folded parents hide their count of sub-sessions under one row; the
// stored layout state is the ground truth (a folded id lists `true`,
// a missing id lists the default, open here), so an explicit `false`
// is the way an opener stays open.
function pruneFoldState(saved, liveKeys, keepStale) {
  var out = {}
  for (var id in saved) {
    if (Object.prototype.hasOwnProperty.call(saved, id)) {
      if (id.indexOf("sub:") !== 0) { out[id] = saved[id]; continue }
      if (liveKeys[id] || keepStale) out[id] = saved[id]
    }
  }
  return out
}
function liveSubKeys(treeTop) {
  var live = {}
  function walk(row) {
    live[subCollapseId(row)] = true
    for (var i = 0; i < row.children.length; i++) walk(row.children[i])
  }
  for (var t = 0; t < treeTop.length; t++) walk(treeTop[t])
  return live
}
function subOpenMap(collapsed, row, open, liveKeys) {
  var c = Object.assign({}, collapsed || {})
  var id = subCollapseId(row)
  if (open) { if (c[id] !== false) c[id] = false }
  else if (c[id] !== true) c[id] = true
  // Fold state only grows while managers spawn workers daily: forget the
  // `sub:` entries of rows that are gone from the snapshot, so the layout
  // file stays bounded.
  if (liveKeys) return pruneFoldState(c, liveKeys, false)
  return c
}
// --- Snapshot → rows -------------------------------------------------------

// snapshot: { hosts: [{target,label,reachable,sessions,notifications,...}] }
// stale: { hostTarget: [sessions…] } rows kept from the last good answer of a
// host that is unreachable now.
function buildRows(hosts, clocks, now, thresholdMs) {
  var attention = {}
  var waitingSince = {}
  var all = []
  var labels = {}
  for (var h = 0; h < hosts.length; h++) {
    var host = hosts[h]
    labels[host.target] = host.label || host.target
    var notes = host.notifications || []
    for (var n = 0; n < notes.length; n++) {
      if (!notes[n].sessionId) continue
      var nk = keyOf(host.target, notes[n].sessionId)
      attention[nk] = true
      var t = parseTime(notes[n].createdAt)
      if (t && (!waitingSince[nk] || t < waitingSince[nk])) waitingSince[nk] = t
    }
  }
  for (var i = 0; i < hosts.length; i++) {
    var hh = hosts[i]
    var sessions = hh.sessions || []
    for (var j = 0; j < sessions.length; j++) {
      var s = sessions[j]
      if (!validSessionId(s.id)) continue
      var key = keyOf(hh.target, s.id)
      var state = ownerState(s, !!attention[key], clocks.idle[key] || 0, now, thresholdMs)
      var project = clip(s.project, 80)
      all.push({
        key: key,
        id: s.id,
        host: hh.target,
        hostLabel: labels[hh.target],
        target: targetOf(hh.target, s.id),
        title: clip(s.name, 120) || project || baseName(s.cwd) || s.id,
        name: clip(s.name, 120),
        agent: clip(s.agent, 60),
        profile: clip(s.profile, 80),
        ownerState: state,
        state: clip(s.state, 20),
        activity: clip(s.activity, 20),
        runtimeState: clip(s.runtimeState, 20),
        project: project,
        branch: clip(s.branch, 120),
        cwd: clip(s.cwd, 400),
        worktree: clip(s.worktree, 400),
        parentId: parentIdOf(s),
        badge: workBadge(s.work),
        workUrl: safeUrl(s.work && s.work.url),
        role: clip(s.work && s.work.role, 60),
        group: groupOf(s),
        subagentsRunning: s.subagentsRunning || 0,
        backgroundRunning: s.backgroundRunning || 0,
        resumable: !!s.resumable && state === "ended",
        external: !!s.external,
        lossCause: clip(s.lossCause, 200),
        createdAt: parseTime(s.createdAt),
        updatedAt: parseTime(s.updatedAt),
        waitingSince: state === "needs" ? (waitingSince[key] || clocks.needs[key] || 0) : 0,
        stale: !hh.reachable,
        onboardMode: clip(s.onboardMode, 20),
        onboardState: clip(s.onboardState, 20)
      })
    }
  }
  return all
}

// --- Filters (search, State, Project, Host chips) ---------------------------

function matchesQuery(row, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return true
  var hay = [row.title, row.name, row.project, row.branch, row.id, row.agent, row.profile, row.hostLabel, row.badge, row.group]
    .join("\n").toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) < 0) return false
  return true
}

// Ended sessions stay hidden until the Ended state is picked.
function applyFilters(rows, filters) {
  var f = filters || {}
  var states = f.states || []
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (states.length > 0 ? states.indexOf(r.ownerState) < 0 : r.ownerState === "ended") continue
    if (f.project && r.project !== f.project) continue
    if (f.host && r.host !== f.host) continue
    if (!matchesQuery(r, f.query)) continue
    out.push(r)
  }
  return out
}

function filterCount(filters) {
  var f = filters || {}
  return (f.states && f.states.length ? 1 : 0) + (f.project ? 1 : 0) + (f.host ? 1 : 0) + (f.query ? 1 : 0)
}

// --- Sections --------------------------------------------------------------

function needsOrder(a, b) {
  var wa = a.waitingSince || 0, wb = b.waitingSince || 0
  if (wa && wb && wa !== wb) return wa - wb
  if (wa && !wb) return -1
  if (!wa && wb) return 1
  if (a.title !== b.title) return a.title < b.title ? -1 : 1
  return a.key < b.key ? -1 : 1
}

function rowOrder(a, b) {
  var oa = STATE_ORDER[a.ownerState], ob = STATE_ORDER[b.ownerState]
  if (oa !== ob) return oa - ob
  if (a.updatedAt !== b.updatedAt) return b.updatedAt - a.updatedAt
  return a.key < b.key ? -1 : 1
}

// Group names in display order: Inbox, then the stored order, then any other
// group a session carries, alphabetically. `layout.groups` also keeps empty
// groups the owner created here.
function groupNames(rows, layout) {
  var names = [INBOX]
  var stored = (layout && layout.groups) || []
  function has(name) {
    for (var i = 0; i < names.length; i++) if (sameGroup(names[i], name)) return true
    return false
  }
  for (var i = 0; i < stored.length; i++) {
    var c = checkGroupName(stored[i])
    if (c.ok && !has(c.name)) names.push(c.name)
  }
  var extra = []
  for (var j = 0; j < rows.length; j++) {
    if (!has(rows[j].group)) { names.push(rows[j].group); extra.push(rows[j].group) }
  }
  var head = names.slice(0, names.length - extra.length)
  extra.sort(function(a, b) { return a.toLowerCase() < b.toLowerCase() ? -1 : 1 })
  return head.concat(extra)
}

// Sub-session trees. A row whose `spawned_by` names a row that is present
// folds under it. The manager resolves on the same host first: an identical
// session id can reach on two targets, and each copy then folds under its
// own manager instead of vanishing. A parent on another host still counts
// (sessions are merged across hosts), a self-parent and an unknown parent
// (an orphan) stay top-level rows. A chain that loops back on itself can
// never anchor: the loop detection walks the row's own chain and cuts only
// the links of that loop, so a tail into a cycle still attaches normally.
// The fold is closed by default and opens in place; explicit folds live in
// layout.collapsed under the sub id. The top-level sort follows the calling
// section (`needsOrder` keeps the oldest wait first in Needs you).
function buildTrees(rows, collapsed, order) {
  var cmp = typeof order === "function" ? order : rowOrder
  var snap = rows.slice(), byId = {}, byHostId = {}, top = []
  for (var i = 0; i < snap.length; i++) {
    // Copy the snapshot: one section listing only children still names the
    // parent, and copying keeps one section from rewriting another.
    var src = snap[i]
    var r = {}
    for (var f in src) r[f] = src[f]
    if (r.parentId === undefined) r.parentId = parentIdOf(r)
    r.children = []
    r.descendants = 0
    // Pending counts read the hidden rows only: a folded title shows how
    // many of its sub-sessions need the owner or broke, not itself.
    r.needsDown = 0
    r.problemDown = 0
    r.worstDown = r.ownerState
    r.parentRow = null
    if (r.flatSearch === undefined) r.flatSearch = false
    snap[i] = r
    if (!byId[r.id]) byId[r.id] = r
    byHostId[r.host + "\0" + r.id] = r
  }
  rows = snap
  // The manager for a row: same host first, then the first match. The
  // copy map is keyed by row key, so a duplicated session id on two
  // targets lists both copies instead of dropping one.
  function findParent(r) {
    if (!r.parentId || r.parentId === r.id) return null
    return byHostId[r.host + "\0" + r.parentId] || byId[r.parentId] || null
  }
  // Attach rows to their parents. A row joins only once its parent is
  // placed, so the parent chain anchors head-first. Unknown parents
  // (orphans) and self-parents stay top-level; a chain that loops back
  // on itself cuts only the links of that loop, so every row of it stays
  // top-level while a tail into the loop attaches normally.
  var placed = {}
  function attach(r) {
    if (placed[r.key]) return
    var p = findParent(r)
    if (!p || p === r) { r.parentId = ""; placed[r.key] = true; top.push(r); return }
    // Loop back: the parent chain returns to this row (or repeats a row),
    // so the links of that loop cannot nest. Cut exactly the loop links:
    // the rows from the first index of the repeated row onward. Rows the
    // walk passed before reaching the loop are a tail into the cycle and
    // attach normally once the loop links are top-level.
    var seen = {}
    seen[r.key] = 0
    var chain = [r]
    var badAt = -1
    for (var q = p; q; q = q.parentRow || findParent(q)) {
      if (q === r) { badAt = 0; break }
      if (seen[q.key] !== undefined) { badAt = seen[q.key]; break }
      seen[q.key] = chain.length
      chain.push(q)
      if (q.parentRow) continue
      if (!findParent(q)) break
    }
    if (badAt >= 0) {
      for (var m = badAt; m < chain.length; m++)
        if (!placed[chain[m].key]) {
          chain[m].parentId = ""
          placed[chain[m].key] = true
          top.push(chain[m])
        }
      if (!placed[r.key]) attach(r)
      return
    }
    if (!placed[p.key]) attach(p)
    if (!placed[p.key]) { r.parentId = ""; placed[r.key] = true; top.push(r); return }
    for (var a = p; a; a = a.parentRow) {
      a.descendants++
      if (r.ownerState === "needs") a.needsDown++
      if (r.ownerState === "problem") a.problemDown++
    }
    r.parentRow = p
    p.children.push(r)
    placed[r.key] = true
  }
  for (var j = 0; j < rows.length; j++) attach(rows[j])
  // A search hit must never sit behind a closed parent, so it lists every
  // row in its own place (Needs you renders flat rows by itself). A stored
  // `false` opens only the row whose key names it: children settle first
  // so an open manager shows their own folds, then this row reads its own
  // stored key.
  function settle(n) {
    n.children.sort(rowOrder)
    for (var w = 0; w < n.children.length; w++) settle(n.children[w])
    if (n.flatSearch) n.treeCollapsed = false
    else {
      var c = collapsed[subCollapseId(n)]
      n.treeCollapsed = c === undefined ? n.children.length > 0 : c === true
    }
    var worst = n.ownerState
    for (var w = 0; w < n.children.length; w++) {
      if (STATE_ORDER[n.children[w].worstDown] < STATE_ORDER[worst]) worst = n.children[w].worstDown
    }
    n.worstDown = worst
  }
  for (var k = 0; k < top.length; k++) settle(top[k])
  top.sort(cmp)
  return top
}

// A visible tree item: the parent row, then its open children recursively.
// A collapsed parent still lists its row, with the folded count. `tree`
// marks a section that holds a tree: only those rows reserve the fold
// marker slot, so a flat section keeps the rows where they were on main.
function treeItems(top) {
  var items = []
  var tree = top.some(function(row) { return row.children.length > 0 })
  function walk(row, depth) {
    var kids = row.children.filter(function(c) { return c.parentRow === row })
    var shut = kids.length > 0 && row.treeCollapsed
    items.push({ row: row, depth: depth, collapsed: shut, tree: tree })
    if (shut) return
    for (var i = 0; i < kids.length; i++) walk(kids[i], depth + 1)
  }
  for (var t = 0; t < top.length; t++) walk(top[t], 0)
  return items
}

function sectionNodes(list, collapsed, order, expand) {
  var rows = (list || []).map(function(r) {
    var c = {}
    for (var f in r) c[f] = r[f]
    if (expand === "search") c.flatSearch = true
    return c
  })
  return treeItems(buildTrees(rows, collapsed || {}, order))
}

function sections(rows, view, layout) {
  var collapsed = (layout && layout.collapsed) || {}
  // A query opens every fold, like the Android companion lists every
  // match in its own place when the query is not blank: a hit never
  // sits behind a closed parent.
  var flatSearch = !!((layout && layout.searchOpen) || (layout && layout.query))
  var expand = flatSearch ? "search" : ""
  var needing = [], rest = []
  for (var i = 0; i < rows.length; i++) (rows[i].ownerState === "needs" ? needing : rest).push(rows[i])
  needing.sort(needsOrder)
  var out = []
  // Needs you never folds (Android folds group sections only): every
  // waiting session is its own depth-0 row in waiting order, with its
  // sub-session count as an annotation from the full tree.
  if (needing.length > 0) {
    var needCounts = {}
    var needTree = buildTrees(rows.slice(), collapsed, needsOrder)
    // Every waiting row annotates its count, like Android reads
    // tree.children(key): a waiting worker with its own waiting child
    // counts it too, not only top-level managers.
    for (var t = 0; t < needTree.length; t++) {
      var stack = [needTree[t]]
      while (stack.length > 0) {
        var n = stack.pop()
        needCounts[n.key] = n.descendants
        for (var k = 0; k < n.children.length; k++) stack.push(n.children[k])
      }
    }
    var needNodes = needing.map(function(r) {
      var c = {}
      for (var f in r) c[f] = r[f]
      c.descendants = needCounts[r.key] || 0
      return { row: c, depth: 0, open: true, collapsed: false, tree: false }
    })
    out.push({ id: NEEDS_YOU, kind: "needs", name: "", rows: needing, nodes: needNodes,
               count: needing.length, collapsed: false })
  }

  if (view === "state") {
    var order = ["working", "idle", "problem", "nostate", "ended"]
    for (var s = 0; s < order.length; s++) {
      var list = rest.filter(function(r) { return r.ownerState === order[s] }).sort(rowOrder)
      if (list.length === 0) continue
      var sid = "state:" + order[s]
      out.push({ id: sid, kind: "state", state: order[s], name: "", rows: list, nodes: sectionNodes(list, collapsed, rowOrder, expand),
                 count: list.length, collapsed: !!collapsed[sid] })
    }
    return out
  }

  var names = groupNames(rows, layout)
  for (var g = 0; g < names.length; g++) {
    var members = rest.filter(function(r) { return sameGroup(r.group, names[g]) }).sort(rowOrder)
    var gid = "group:" + names[g].toLowerCase()
    var isInbox = sameGroup(names[g], INBOX)
    // Inbox and the owner's own groups show even when empty, so a session
    // can be moved into them.
    out.push({ id: gid, kind: "group", name: names[g], inbox: isInbox, rows: members, nodes: sectionNodes(members, collapsed, rowOrder, expand),
               count: members.length, collapsed: !!collapsed[gid] })
  }
  return out
}

// Header and row entries in display order, for keyboard navigation.
function flatten(sectionList) {
  var items = []
  for (var i = 0; i < sectionList.length; i++) {
    var sec = sectionList[i]
    items.push({ type: "header", section: sec, key: "h:" + sec.id })
    if (sec.collapsed) continue
    var nodes = sec.nodes || (sec.rows || []).map(function(r) { return { row: r, depth: 0, open: true, collapsed: false } })
    for (var j = 0; j < nodes.length; j++) {
      var n = nodes[j]
      n.row.treeHere = !!n.tree
      items.push({ type: "row", row: n.row, depth: n.depth, node: n, section: sec, key: "r:" + n.row.key })
    }
  }
  return items
}

// --- Bar badge (pohunek-companion core/tray_summary.rs) --------------------

function summary(rows, installed, reachableHosts) {
  var c = { needs: 0, working: 0, idle: 0, problem: 0, nostate: 0, ended: 0, live: 0 }
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].stale) continue
    c[rows[i].ownerState]++
    if (rows[i].ownerState !== "ended") c.live++
  }
  var state
  if (!installed) state = "missing"
  else if (reachableHosts === 0) state = "offline"
  else if (c.needs > 0) state = "needs"
  else if (c.problem > 0) state = "problem"
  else if (c.working > 0) state = "working"
  else if (c.live > 0) state = "idle"
  else state = "empty"
  c.state = state
  return c
}

// Sessions that turned "needs you" (or a runtime problem) since the last
// snapshot. The first snapshot is a baseline, not news.
function newAttention(previous, rows) {
  if (!previous) return []
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r.stale || (r.ownerState !== "needs" && r.ownerState !== "problem")) continue
    if (previous[r.key] === r.ownerState) continue
    out.push(r)
  }
  return out
}

function stateIndex(rows) {
  var map = {}
  for (var i = 0; i < rows.length; i++) if (!rows[i].stale) map[rows[i].key] = rows[i].ownerState
  return map
}

// --- Get started card -----------------------------------------------------

// The assistant's own preference order (pohunek assistant/src/launch.rs).
var ASSISTANT_RANK = ["pohunek-assistant", "codex", "claude", "hermes"]

// Agents that can run the onboard session, from `host inspect local --json`:
// available, not refused by the version policy and not shell-based, the rule
// of pohunek's assistant/src/host.rs, in the assistant's preference order.
// pohunek-onboard is the profile tools/onboard writes for automatic mode, so
// it is never offered as the agent that runs onboarding.
var ONBOARD_PROFILE = "pohunek-onboard"
function onboardAgents(inspect) {
  var runtimes = inspect && Array.isArray(inspect.runtimes) ? inspect.runtimes : []
  var out = []
  for (var i = 0; i < runtimes.length && out.length < 50; i++) {
    var r = runtimes[i]
    if (!r || !validSessionId(r.agent) || r.available !== true || r.supported === false) continue
    if (r.agent === "shell" || r.agent_base === "shell" || r.agent === ONBOARD_PROFILE || out.indexOf(r.agent) >= 0) continue
    out.push(r.agent)
  }
  function rank(a) { var k = ASSISTANT_RANK.indexOf(a); return k < 0 ? ASSISTANT_RANK.length : k }
  return out.sort(function(a, b) { return rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0) })
}

// Whether the onboarding record tools/onboard wrote names the session it
// started and Undo onboarding has not completed. A record without a session is
// a run whose session never started; an undone run counts as no run.
function onboardingRecordLaunched(text) {
  var doc = null
  try { doc = JSON.parse(String(text || "")) } catch (e) { return false }
  return !!doc && typeof doc === "object" && doc.schema === 1 && validSessionId(doc.session_id)
    && (doc.undone_at === undefined || doc.undone_at === null)
}

// State of the Get started card. facts: { installed, recordPresent (an
// onboarding record that names its session, see onboardingRecordLaunched),
// dismissed (Not now), again (Run onboarding again), rows }. An onboard session is a live row of this machine whose
// `onboard.mode` is set and whose agent has not set `onboard.state=done`;
// it wins over every other fact except a missing pohunek.
function onboardingCard(facts) {
  var f = facts || {}
  if (!f.installed) return { state: "missing", target: "" }
  var rows = f.rows || [], running = null
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r.host !== "local" || r.stale || r.ownerState === "ended" || !r.onboardMode || r.onboardState === "done") continue
    if (!running || r.updatedAt > running.updatedAt) running = r
  }
  if (running) return { state: "running", target: running.target }
  if (f.again) return { state: "ready", target: "" }
  if (f.dismissed) return { state: "dismissed", target: "" }
  if (f.recordPresent) return { state: "done", target: "" }
  return { state: "ready", target: "" }
}

// --- Pickers ---------------------------------------------------------------

function projects(rows, recent) {
  var seen = {}, list = []
  for (var i = 0; i < rows.length; i++) {
    var p = rows[i].project
    if (p && !seen[p]) { seen[p] = true; list.push(p) }
  }
  list.sort(function(a, b) { return a.toLowerCase() < b.toLowerCase() ? -1 : 1 })
  var rec = (recent || []).filter(function(p) { return seen[p] }).slice(0, 3)
  return { recent: rec, all: list }
}

function ageParts(nowMs, thenMs) {
  if (!thenMs) return { key: "", count: 0 }
  var sec = Math.max(0, Math.floor((nowMs - thenMs) / 1000))
  if (sec < 45) return { key: "age.now", count: 0 }
  var min = Math.round(sec / 60)
  if (min < 60) return { key: "age.minutes", count: min }
  var hours = Math.round(min / 60)
  if (hours < 48) return { key: "age.hours", count: hours }
  return { key: "age.days", count: Math.round(hours / 24) }
}

function pushRecent(list, value, limit) {
  var out = [value]
  for (var i = 0; i < (list || []).length && out.length < (limit || 8); i++) if (list[i] !== value) out.push(list[i])
  return out
}

// --- Fuzzy search ----------------------------------------------------------

// Lists longer than this get a fuzzy search field instead of a plain list.
var FUZZY_THRESHOLD = 8

function isWordStart(t, i) {
  if (i === 0) return true
  var before = t[i - 1]
  return /[\s_\-.\/:]/.test(before) || (before === before.toLowerCase() && t[i] !== t[i].toLowerCase())
}

// Subsequence match of `query` in `text`, scored like fzf-lite: consecutive
// characters, word starts and an early first match score higher. -1 when the
// query is not a subsequence.
function fuzzyScore(query, text) {
  var q = String(query || "").toLowerCase().replace(/\s+/g, "")
  var t = String(text || "")
  var lower = t.toLowerCase()
  if (q === "") return 0
  var score = 0, ti = 0, prev = -2, first = -1
  for (var qi = 0; qi < q.length; qi++) {
    var found = lower.indexOf(q[qi], ti)
    if (found < 0) return -1
    // Prefer a later occurrence that starts a word, unless this one continues
    // the previous match.
    if (found !== prev + 1) {
      for (var w = found; w >= 0 && w < lower.length; w = lower.indexOf(q[qi], w + 1)) {
        if (isWordStart(t, w)) { found = w; break }
      }
    }
    if (first < 0) first = found
    var bonus = 1
    if (found === prev + 1) bonus += 5
    if (isWordStart(t, found)) bonus += 4
    score += bonus
    prev = found
    ti = found + 1
  }
  if (lower.indexOf(q) >= 0) score += 10
  if (lower === q) score += 20
  return score - Math.min(first, 10) * 0.5 - lower.length * 0.01
}

// items: [{ label, ... }] → best matches first (stable for equal scores).
function fuzzyFilter(items, query, limit) {
  var q = String(query || "").trim()
  var list = items || []
  if (q === "") return list.slice(0, limit || list.length)
  var scored = []
  for (var i = 0; i < list.length; i++) {
    var hay = list[i].label + (list[i].detail ? " " + list[i].detail : "")
    var sc = fuzzyScore(q, hay)
    if (sc >= 0) scored.push({ item: list[i], score: sc, index: i })
  }
  scored.sort(function(a, b) { return b.score - a.score || a.index - b.index })
  return scored.slice(0, limit || scored.length).map(function(s) { return s.item })
}

if (typeof module !== "undefined") {
  module.exports = {
    clip: clip, validSessionId: validSessionId, validHost: validHost, validTarget: validTarget,
    ownerState: ownerState, trackClocks: trackClocks, workBadge: workBadge, checkGroupName: checkGroupName,
    groupOf: groupOf, buildRows: buildRows, applyFilters: applyFilters, sections: sections, flatten: flatten,
    summary: summary, newAttention: newAttention, stateIndex: stateIndex, projects: projects,
    groupNames: groupNames, ageParts: ageParts, pushRecent: pushRecent, filterCount: filterCount,
    fuzzyScore: fuzzyScore, fuzzyFilter: fuzzyFilter, FUZZY_THRESHOLD: FUZZY_THRESHOLD,
    onboardAgents: onboardAgents, onboardingCard: onboardingCard, onboardingRecordLaunched: onboardingRecordLaunched,
    parentIdOf: parentIdOf, subCollapseId: subCollapseId, subOpenMap: subOpenMap, pruneFoldState: pruneFoldState, liveSubKeys: liveSubKeys, buildTrees: buildTrees, sectionNodes: sectionNodes,
    INBOX: INBOX, NEEDS_YOU: NEEDS_YOU
  }
}
