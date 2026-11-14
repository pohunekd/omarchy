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
