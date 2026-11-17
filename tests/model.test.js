#!/usr/bin/env node
// Model.js: companion semantics (owner state, Needs you, groups, badges,
// filters, bar badge). Run: node tests/model.test.js [snapshot.json]
const fs = require("fs"), path = require("path"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const mod = { exports: {} }
new Function("module", src)(mod)
const M = mod.exports

const NOW = Date.parse("2026-11-10T12:00:00Z")
const ago = s => new Date(NOW - s * 1000).toISOString()
const T = 300 * 1000
const S = (o) => ({ state: "running", runtimeState: "live", activity: "idle", subagentsRunning: 0, backgroundRunning: 0,
  agent: "claude", profile: "cc", cwd: "/w/app", project: "app", updatedAt: ago(30), createdAt: ago(3600),
  group: null, work: {}, ...o })

// owner state
assert.strictEqual(M.ownerState(S({ state: "stopped" }), true, 0, NOW, T), "ended", "ended wins over attention")
assert.strictEqual(M.ownerState(S({ runtimeState: "lost" }), false, 0, NOW, T), "ended")
assert.strictEqual(M.ownerState(S({ runtimeState: "conflict" }), false, 0, NOW, T), "problem")
assert.strictEqual(M.ownerState(S({ activity: "working" }), true, 0, NOW, T), "needs", "open attention → needs owner")
assert.strictEqual(M.ownerState(S({ activity: "blocked" }), false, 0, NOW, T), "needs")
assert.strictEqual(M.ownerState(S({ activity: "working" }), false, 0, NOW, T), "working")
assert.strictEqual(M.ownerState(S({}), false, NOW - 60e3, NOW, T), "working", "idle under threshold reads Working")
assert.strictEqual(M.ownerState(S({}), false, NOW - 400e3, NOW, T), "idle")
assert.strictEqual(M.ownerState(S({ subagentsRunning: 1 }), false, NOW - 400e3, NOW, T), "working", "subagent work keeps it Working")
assert.strictEqual(M.ownerState(S({ activity: "" }), false, 0, NOW, T), "nostate")

// clocks start at last update on first sight and persist
let clocks = M.trackClocks(null, [S({ id: "s-1", host: "local", updatedAt: ago(3600) })], NOW)
assert.strictEqual(clocks.idle["local/s-1"], NOW - 3600e3)
clocks = M.trackClocks(clocks, [S({ id: "s-1", host: "local", updatedAt: ago(5) })], NOW)
assert.strictEqual(clocks.idle["local/s-1"], NOW - 3600e3, "kept from previous snapshot")
clocks = M.trackClocks(clocks, [S({ id: "s-1", host: "local", activity: "working" })], NOW)
assert.strictEqual(clocks.idle["local/s-1"], undefined, "reset when no longer idle")

// work badge
assert.strictEqual(M.workBadge({ provider: "github", kind: "pr", id: "1412" }), "GH PR #1412")
assert.strictEqual(M.workBadge({ provider: "linear", kind: "issue", id: "ABC-1" }), "Linear ABC-1")
assert.strictEqual(M.workBadge({ provider: "github", id: "7" }), "GH #7")
assert.strictEqual(M.workBadge({ provider: "github" }), "")

// sub-sessions fold under their manager
assert.strictEqual(M.parentIdOf({ spawnedBy: "s-1" }), "s-1")
assert.strictEqual(M.parentIdOf({ spawned_by: { session_id: "s-1", daemon_id: "d-2" } }), "s-1")
assert.strictEqual(M.parentIdOf({ spawnedBy: "bad id" }), "")
assert.strictEqual(M.parentIdOf({}), "")

const R = (o) => { const s = S(o); const parentId = M.parentIdOf({ spawnedBy: s.spawnedBy, spawned_by: s.spawned_by });
  const host = s.host || "local"
  return { ...s, group: "Inbox", ownerState: M.ownerState({ ...s, state: "running", openAttention: false }, false, 0, NOW, T),
    parentId: parentId, host: host, key: host + "/" + s.id } }
const manager = R({ id: "s-m", name: "manager", activity: "working" })
const workerA = R({ id: "s-w1", name: "worker one", activity: "working", spawnedBy: "s-m" })
const workerB = R({ id: "s-w2", name: "worker two", activity: "idle", spawnedBy: "s-m" })
const grand = R({ id: "s-g", name: "grandchild", activity: "working", spawnedBy: "s-w1" })
const orphan = R({ id: "s-o", name: "orphan", activity: "working", spawnedBy: "s-gone" })
assert.strictEqual(manager.parentId, "", "a manager has no parent")
assert.strictEqual(workerA.parentId, "s-m")
assert.strictEqual(orphan.parentId, "s-gone")
const tree = M.buildTrees([manager, workerA, workerB, grand, orphan], {})
assert.strictEqual(tree.length, 2, "manager and orphan stay top-level")
assert.deepStrictEqual(tree[0].children.map(r => r.id), ["s-w1", "s-w2"], "children sorted under the parent")
assert.strictEqual(tree[0].children[0].children[0].id, "s-g", "nesting at any depth")
assert.strictEqual(tree[0].descendants, 3)
assert.strictEqual(tree[0].treeCollapsed, true, "folded by default with a count")
const open = M.buildTrees([manager, workerA, workerB, grand, orphan], { [M.subCollapseId(manager)]: false })
assert.strictEqual(open[0].treeCollapsed, false)
assert.strictEqual(open[0].descendants, 3)
// A child's own fold stays closed while an ancestor is open.
const deeper = M.buildTrees([manager, workerA, workerB, grand, orphan],
  { [M.subCollapseId(manager)]: false, [M.subCollapseId(workerA)]: true })
assert.strictEqual(deeper[0].children[0].treeCollapsed, true)
// A loop never hides a row: every link of a cycle is cut and each row
// of it stays top-level.
const cyclic = M.buildTrees([R({ id: "s-x", spawnedBy: "s-y" }), R({ id: "s-y", spawnedBy: "s-x" })], {})
assert.strictEqual(cyclic.length, 2, "a cycle stays flat")
assert.deepStrictEqual(M.sectionNodes([R({ id: "s-x", spawnedBy: "s-y" }), R({ id: "s-y", spawnedBy: "s-x" })], {}).map(n => n.row.id), ["s-x", "s-y"])
const selfed = M.buildTrees([R({ id: "s-z", spawnedBy: "s-z" })], {})
assert.strictEqual(selfed.length, 1, "a self-parent stays top-level")
// A parent on another host folds under the same session id.
const remote = M.buildTrees([{ ...manager, host: "local", key: "local/s-m" },
  { ...workerA, host: "air", key: "air/s-w1" }], {})
assert.strictEqual(remote.length, 1, "cross-host parent merges")
// A section lists the folded rows inside the parent's group with the depth.
const treeFiltered = M.applyFilters([R({ id: "s-m", name: "manager", activity: "working" }),
  R({ id: "s-w1", name: "worker one", activity: "working", spawnedBy: "s-m" }),
  R({ id: "s-w2", name: "worker two", activity: "idle", spawnedBy: "s-m" }),
  R({ id: "s-g", name: "grandchild", activity: "working", spawnedBy: "s-w1" }),
  R({ id: "s-o", name: "orphan", activity: "working", spawnedBy: "s-gone" })], {})
let treeSecs = M.sections(treeFiltered, "groups", {})
const inbox = treeSecs.find(s => s.name === "Inbox")
assert.deepStrictEqual(inbox.nodes.map(n => n.row.id), ["s-m", "s-o"],
  "a folded group lists the parent rows only")
assert.strictEqual(inbox.nodes[0].collapsed, true, "the parent row carries the fold")
assert.deepStrictEqual(M.flatten(treeSecs).filter(i => i.type === "row").map(i => i.row.id), ["s-m", "s-o"],
  "a folded group navigates the parent rows only")
// Explicitly opened, the parent comes before its children with depths.
const openSecs = M.sections(treeFiltered, "groups",
  { collapsed: { [M.subCollapseId(manager)]: false, [M.subCollapseId(workerA)]: false } })
const openInbox = openSecs.find(s => s.name === "Inbox")
assert.deepStrictEqual(openInbox.nodes.map(n => n.row.id), ["s-m", "s-w1", "s-g", "s-w2", "s-o"], "parent before children")
assert.deepStrictEqual(openInbox.nodes.map(n => n.depth), [0, 1, 2, 1, 0])
// Needs you never folds (Android folds group sections only): every waiting
// session is its own depth-0 row in waiting order, with its sub-session
// count as an annotation. A worker that waited longest comes first even
// when its manager waits too.
const needy = R({ id: "s-n", name: "need", activity: "blocked" })
needy.waitingSince = NOW - 100 * 1000
const needyChild = R({ id: "s-nc", name: "need child", activity: "blocked", spawnedBy: "s-n" })
needyChild.waitingSince = NOW - 3000 * 1000
const needSolo = R({ id: "s-nx", name: "need solo", activity: "blocked" })
needSolo.waitingSince = NOW - 1000 * 1000
const other = R({ id: "s-r", name: "other", activity: "working" })
const needFiltered = M.applyFilters([other, needy, needyChild, needSolo], {})
const needSecs = M.sections(needFiltered, "groups", {})
assert.strictEqual(needSecs[0].id, "needs-you")
assert.deepStrictEqual(needSecs[0].nodes.map(n => n.row.id), ["s-nc", "s-nx", "s-n"],
  "Needs you lists every waiting row flat in waiting order")
assert.deepStrictEqual(needSecs[0].nodes.map(n => n.depth), [0, 0, 0], "Needs you has no nesting")
assert.deepStrictEqual(M.flatten(needSecs).filter(i => i.type === "row" && i.section.kind === "needs").map(i => i.row.id),
  ["s-nc", "s-nx", "s-n"], "flatten keeps the waiting order")
assert.strictEqual(needSecs[0].nodes[0].collapsed, false, "Needs you carries no fold")
// A waiting manager still annotates how many wait under it.
assert.strictEqual(needSecs[0].nodes.find(n => n.row.id === "s-n").row.descendants, 1)
// A grandchild's attention reaches the folded manager through the middle.
assert.strictEqual(deeper[0].worstDown, deeper[0].children[0].worstDown,
  "a middle row hands the subtree attention up")
// subOpenMap stores the explicit open; toggling back folds again.
// Stale `sub:` entries of vanished sessions are forgotten, while the
// union of the live section keys keeps a Needs-you copy's fold too: the
// same `sub:` key is live in both sections and stays stored either way.
assert.deepStrictEqual(M.subOpenMap({}, manager, true), { [M.subCollapseId(manager)]: false })
assert.deepStrictEqual(M.subOpenMap({ [M.subCollapseId(manager)]: false }, manager, false), { [M.subCollapseId(manager)]: true })
function liveUnion(lists) {
  var perSection = {}
  for (var li = 0; li < lists.length; li++) {
    var keys = M.liveSubKeys(M.buildTrees(lists[li], {}))
    for (var k in keys) perSection[k] = true
  }
  return perSection
}
const pruned = M.subOpenMap({ "group:deps": true, [M.subCollapseId(manager)]: true }, manager, false,
  liveUnion([[manager]]))
assert.deepStrictEqual(pruned, { "group:deps": true, [M.subCollapseId(manager)]: true })
const prunedGone = M.subOpenMap({ "group:deps": true, "sub:gone/s-x": true }, manager, false,
  liveUnion([[manager]]))
assert.deepStrictEqual(prunedGone, { "group:deps": true, [M.subCollapseId(manager)]: true },
  "stale sub folds of vanished sessions are forgotten")
// The top-level sort follows the section: Needs you keeps the oldest wait
// first in the nodes and the flattened rows, not in `rows` only.
const oldWait = R({ id: "s-old", name: "old", activity: "blocked", updatedAt: ago(10) })
oldWait.waitingSince = NOW - 3000 * 1000
const newWait = R({ id: "s-new", name: "new", activity: "blocked", updatedAt: ago(5000) })
newWait.waitingSince = NOW - 100 * 1000
const waitSecs = M.sections(M.applyFilters([newWait, oldWait], {}), "groups", {})
assert.deepStrictEqual(waitSecs[0].nodes.map(n => n.row.id), ["s-old", "s-new"], "nodes keep the wait order")
assert.deepStrictEqual(M.flatten(waitSecs).filter(i => i.type === "row").map(i => i.row.id), ["s-old", "s-new"])
// A row whose session id appears on two targets renders twice; each copy
// folds under its own manager.
const dupA = { ...manager, host: "local", key: "local/s-m" }
const dupB = { ...manager, host: "air", key: "air/s-m" }
const dupWa = { ...workerA, host: "local", key: "local/s-w1", parentId: "s-m" }
const dupWb = { ...workerA, host: "air", key: "air/s-w1", parentId: "s-m" }
const dupTree = M.buildTrees([dupA, dupB, dupWa, dupWb], {})
assert.strictEqual(dupTree.length, 2, "both copies of a duplicated id render")
assert.ok(dupTree.every(t => t.children.length === 1 && t.children[0].host === t.host),
  "each copy folds under its own host's manager")
// A tail into a cycle attaches normally in either input order: only the
// loop links stay flat, cut at the first index of the repeated row.
const tailRows = [R({ id: "s-a", spawnedBy: "s-c" }), R({ id: "s-b", spawnedBy: "s-c" }),
  R({ id: "s-c", spawnedBy: "s-a" }), R({ id: "s-d", spawnedBy: "s-a" })]
for (const rows of [tailRows, tailRows.slice().reverse()]) {
  const tail = M.buildTrees(rows, {})
  assert.deepStrictEqual(tail.map(r => r.id).sort(), ["s-a", "s-c"], "the cycle stays flat")
  assert.deepStrictEqual(tail.find(r => r.id === "s-a").children.map(c => c.id), ["s-d"], "a tail into the cycle attaches")
  assert.deepStrictEqual(tail.find(r => r.id === "s-c").children.map(c => c.id), ["s-b"], "a tail into the cycle attaches")
}
// A search opens every fold, so a hit never sits behind a closed parent.
const searchSecs = M.sections(treeFiltered, "groups", { searchOpen: true })
assert.deepStrictEqual(searchSecs.find(s => s.name === "Inbox").nodes.map(n => n.row.id),
  ["s-m", "s-w1", "s-g", "s-w2", "s-o"], "a query lists every match in its own place")
// A folded parent carries the attention of its subtree.
assert.strictEqual(tree[0].worstDown, "working")
const worry = M.buildTrees([R({ id: "s-p", name: "boss", activity: "working" }),
  R({ id: "s-q", name: "helper", activity: "blocked", spawnedBy: "s-p" })], {})
assert.strictEqual(worry[0].worstDown, "needs")
assert.strictEqual(worry[0].needsDown, 1)
const broke = M.buildTrees([R({ id: "s-p", name: "boss", activity: "working" }),
  R({ id: "s-u", name: "ok", activity: "working", runtimeState: "conflict", spawnedBy: "s-p" })], {})
assert.strictEqual(broke[0].worstDown, "problem")
assert.strictEqual(broke[0].problemDown, 1)

// groups
assert.strictEqual(M.groupOf(S({ group: null })), "Inbox")
assert.strictEqual(M.groupOf(S({ group: "Dependencies" })), "Dependencies")
assert.strictEqual(M.groupOf(S({ group: "  " })), "Inbox", "rejected name falls back to Inbox")
assert.ok(!M.checkGroupName("a‮b").ok)
assert.ok(!M.checkGroupName("x".repeat(65)).ok)

// rows, sections, filters
const hosts = [
  { target: "local", label: "workstation", reachable: true, notifications: [], sessions: [
    S({ id: "s-a", name: "fix-flaky", activity: "working", group: "Deps", work: { provider: "github", kind: "pr", id: "388", url: "https://github.com/x/y/pull/388" } }),
    S({ id: "s-b", name: "docs", updatedAt: ago(7200) }),
    S({ id: "s-c", name: "old", state: "stopped", runtimeState: "terminal" }),
    S({ id: "bad id", name: "x" }),
  ] },
  { target: "air", label: "laptop", reachable: true, sessions: [
    S({ id: "s-d", name: "review-pr", activity: "working", work: { url: "javascript:alert(1)" } }),
    S({ id: "s-e", name: "blocked-one", activity: "blocked", updatedAt: ago(100) }),
  ], notifications: [{ id: "n1", sessionId: "s-d", kind: "approval_required", createdAt: ago(900) }] },
  { target: "gone", label: "gone", reachable: false, sessions: [S({ id: "s-f", activity: "working" })], notifications: [] },
]
clocks = M.trackClocks(null, hosts.flatMap(h => h.sessions.map(s => ({ ...s, host: h.target }))), NOW)
const rows = M.buildRows(hosts, clocks, NOW, T)
assert.strictEqual(rows.length, 6, "invalid id dropped")
const byId = Object.fromEntries(rows.map(r => [r.id, r]))
assert.strictEqual(byId["s-a"].badge, "GH PR #388")
assert.strictEqual(byId["s-a"].workUrl, "https://github.com/x/y/pull/388")
assert.strictEqual(byId["s-d"].workUrl, "", "unsafe url dropped")
assert.strictEqual(byId["s-d"].ownerState, "needs", "unread notification → needs owner")
assert.strictEqual(byId["s-d"].target, "air/s-d")
assert.strictEqual(byId["s-a"].target, "s-a")
assert.strictEqual(byId["s-b"].ownerState, "idle")
assert.strictEqual(byId["s-f"].stale, true)

let visible = M.applyFilters(rows, {})
assert.ok(!visible.some(r => r.ownerState === "ended"), "ended hidden by default")
assert.ok(M.applyFilters(rows, { states: ["ended"] }).every(r => r.ownerState === "ended"))
assert.deepStrictEqual(M.applyFilters(rows, { host: "air" }).map(r => r.id).sort(), ["s-d", "s-e"])
assert.deepStrictEqual(M.applyFilters(rows, { query: "flaky" }).map(r => r.id), ["s-a"])
assert.deepStrictEqual(M.applyFilters(rows, { query: "GH PR" }).map(r => r.id), ["s-a"])

let secs = M.sections(visible, "groups", { groups: ["Empty one"], collapsed: { "group:deps": true } })
assert.strictEqual(secs[0].id, "needs-you")
assert.deepStrictEqual(secs[0].rows.map(r => r.id), ["s-d", "s-e"], "oldest wait first")
assert.deepStrictEqual(secs.map(s => s.name), ["", "Inbox", "Empty one", "Deps"])
assert.strictEqual(secs.find(s => s.name === "Deps").collapsed, true)
const flat = M.flatten(secs)
assert.ok(!flat.some(i => i.type === "row" && i.row.id === "s-a"), "collapsed group rows not navigable")

secs = M.sections(visible, "state", {})
assert.deepStrictEqual(secs.map(s => s.id), ["needs-you", "state:working", "state:idle"])

// bar badge
let sum = M.summary(rows, true, 2)
assert.strictEqual(sum.state, "needs"); assert.strictEqual(sum.needs, 2); assert.strictEqual(sum.working, 1, "stale rows not counted")
assert.strictEqual(M.summary([], true, 0).state, "offline")
assert.strictEqual(M.summary([], false, 0).state, "missing")
assert.strictEqual(M.summary([], true, 1).state, "empty")

// attention transitions
assert.deepStrictEqual(M.newAttention(null, rows), [])
const idx = M.stateIndex(rows)
assert.deepStrictEqual(M.newAttention(idx, rows), [])
const later = rows.map(r => r.id === "s-b" ? { ...r, ownerState: "needs" } : r)
assert.deepStrictEqual(M.newAttention(idx, later).map(r => r.id), ["s-b"])

// pickers
const pr = M.projects(rows.map((r, i) => ({ ...r, project: ["b", "a", "c", "a", "", "b"][i] })), ["c", "zzz"])
assert.deepStrictEqual(pr, { recent: ["c"], all: ["a", "b", "c"] })
assert.deepStrictEqual(M.pushRecent(["a", "b", "c"], "b", 3), ["b", "a", "c"])
assert.ok(M.validTarget("air/s-d") && !M.validTarget("a b/s-d") && !M.validTarget("-x"))

// fuzzy search
assert.strictEqual(M.fuzzyScore("xyz", "pohunek"), -1)
assert.ok(M.fuzzyScore("phk", "pohunek") >= 0, "subsequence matches")
const projs = ["means-of-compute", "pohunek-companion", "pohunek", "pohunek-companion-android", "helix", "media-manager"].map(l => ({ label: l }))
assert.strictEqual(M.fuzzyFilter(projs, "pohunek")[0].label, "pohunek", "exact match first")
assert.strictEqual(M.fuzzyFilter(projs, "pca")[0].label, "pohunek-companion-android", "word starts")
assert.strictEqual(M.fuzzyFilter(projs, "mm")[0].label, "media-manager")
assert.deepStrictEqual(M.fuzzyFilter(projs, "").map(p => p.label), projs.map(p => p.label), "empty query keeps order")
assert.strictEqual(M.fuzzyFilter(projs, "comp", 2).length, 2, "limit")
assert.strictEqual(M.fuzzyFilter(projs, "zz").length, 0)

// Get started card: missing, ready, running, done, dismissed
const card = (o) => M.onboardingCard({ installed: true, recordPresent: false, dismissed: false, again: false, rows: [], ...o })
const onboardRow = (o) => ({ host: "local", target: "s-on", stale: false, ownerState: "working", onboardMode: "guided",
  onboardState: "", updatedAt: 1, ...o })
assert.strictEqual(card({ installed: false, dismissed: true, recordPresent: true }).state, "missing", "no pohunek wins")
assert.deepStrictEqual(card({}), { state: "ready", target: "" })
assert.deepStrictEqual(card({ rows: [onboardRow()] }), { state: "running", target: "s-on" })
assert.strictEqual(card({ rows: [onboardRow()], dismissed: true, recordPresent: true }).state, "running", "running wins over dismissed and done")
assert.strictEqual(card({ recordPresent: true }).state, "done")
assert.strictEqual(card({ dismissed: true }).state, "dismissed")
assert.strictEqual(card({ dismissed: true, recordPresent: true }).state, "dismissed")
assert.strictEqual(card({ dismissed: true, recordPresent: true, again: true }).state, "ready", "Run onboarding again shows the card")
assert.strictEqual(card({ recordPresent: true, rows: [onboardRow({ ownerState: "ended" })] }).state, "done", "an ended session is not running")
assert.strictEqual(card({ rows: [onboardRow({ onboardState: "done" })] }).state, "ready", "the agent marked it done")
assert.strictEqual(card({ rows: [onboardRow({ host: "laptop", target: "laptop/s-on" })] }).state, "ready", "only this machine counts")
assert.strictEqual(card({ rows: [onboardRow({ stale: true })] }).state, "ready", "a stale row is not running")
assert.strictEqual(card({ rows: [onboardRow({ onboardMode: "" })] }).state, "ready", "no onboard.mode, no onboard session")
assert.strictEqual(card({ rows: [onboardRow({ target: "s-old" }), onboardRow({ target: "s-new", updatedAt: 9 })] }).target, "s-new", "newest wins")
const onboardRows = M.buildRows([{ target: "local", label: "w", reachable: true, notifications: [],
  sessions: [S({ id: "s-on", onboardMode: "guided", onboardState: "" })] }], { idle: {}, needs: {} }, NOW, T)
assert.deepStrictEqual(card({ rows: onboardRows }), { state: "running", target: "s-on" }, "rows carry onboard.mode from fetch.py")

// a record counts only once it names the session it started
assert.strictEqual(M.onboardingRecordLaunched('{"schema":1,"run_id":"ab","session_id":"s-01J"}'), true)
assert.strictEqual(M.onboardingRecordLaunched('{"schema":1,"run_id":"ab"}'), false, "launch failed: no session_id")
assert.strictEqual(M.onboardingRecordLaunched('{"schema":1,"session_id":"bad id"}'), false)
assert.strictEqual(M.onboardingRecordLaunched('{"schema":2,"session_id":"s-01J"}'), false, "unknown schema")
assert.strictEqual(M.onboardingRecordLaunched("not json"), false)
assert.strictEqual(M.onboardingRecordLaunched(""), false)
// Undo onboarding: an undone run brings the card back to ready.
const undone = '{"schema":1,"run_id":"ab","session_id":"s-01J","undone_at":"2026-11-15T10:00:00Z"}'
assert.strictEqual(M.onboardingRecordLaunched(undone), false, "an undone run is not done")
assert.strictEqual(card({ recordPresent: M.onboardingRecordLaunched(undone) }).state, "ready", "done -> ready after Undo")
assert.strictEqual(card({ recordPresent: M.onboardingRecordLaunched('{"schema":1,"session_id":"s-01J","undone_at":null}') }).state, "done")

// agent picker of the card
assert.deepStrictEqual(M.onboardAgents({ runtimes: [
  { agent: "claude", agent_base: "claude", available: true, supported: true },
  { agent: "codex", agent_base: "codex", available: true },
  { agent: "shell", agent_base: "shell", available: true },
  { agent: "work-sh", agent_base: "shell", available: true },
  { agent: "pi", agent_base: "pi", available: false },
  { agent: "old-claude", agent_base: "claude", available: true, supported: false },
  { agent: "bad id", available: true },
  { agent: "codex", available: true } ] }), ["codex", "claude"], "available, supported, not shell, ranked")
assert.deepStrictEqual(M.onboardAgents(null), [])
assert.deepStrictEqual(M.onboardAgents({ runtimes: [{ agent: "zed", available: true }, { agent: "hermes", available: true },
  { agent: "alpha", available: true }] }), ["hermes", "alpha", "zed"])
assert.deepStrictEqual(M.onboardAgents({ runtimes: [{ agent: "claude", agent_base: "claude", available: true },
  { agent: "pohunek-onboard", agent_base: "claude", available: true, supported: true }] }), ["claude"],
  "the automatic-mode profile never runs onboarding itself")

// Optional: a real fetch.py snapshot must build without throwing.
if (process.argv[2]) {
  const snap = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
  const now = Date.now()
  const c = M.trackClocks(null, snap.hosts.flatMap(h => h.sessions), now)
  const r = M.buildRows(snap.hosts, c, now, T)
  const s = M.sections(M.applyFilters(r, {}), "groups", {})
  console.log("snapshot:", r.length, "rows,", s.map(x => `${x.name || x.id}:${x.count}`).join(" "), JSON.stringify(M.summary(r, true, 4)))
}
console.log("model: all checks passed")
