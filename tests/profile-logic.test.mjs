import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"

const source = fs
  .readFileSync(new URL("../ProfileLogic.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/m, "")

const context = { Array, Number, String, Object, JSON, Math }
vm.createContext(context)
vm.runInContext(source, context)

const config = {
  version: 1,
  profiles: [
    {
      id: "desk",
      name: "Desk",
      match: { mode: "exact", monitors: ["Monitor B", "Monitor A"] },
      assignments: { "Monitor A": [1, 2, 2, -1], "Monitor B": [3] },
      labels: { "1": "💻" }
    },
    {
      id: "default",
      name: "Default",
      match: { mode: "default" },
      assignments: {},
      labels: {}
    }
  ]
}

assert.equal(context.signature(["Monitor B", "Monitor A"]), context.signature(["Monitor A", "Monitor B"]))
assert.equal(context.activeProfile(config, ["Monitor A", "Monitor B"]).id, "desk")
assert.equal(context.activeProfile(config, ["Monitor A"]).id, "default")
assert.deepEqual(Array.from(context.workspaceIds(config.profiles[0], "Monitor A")), [1, 2])
assert.equal(context.workspaceLabel(config.profiles[0], 1), "💻")
assert.equal(context.workspaceLabel(config.profiles[0], 2), "2")
assert.equal(context.profileName(null), "No matching profile")

const moved = context.moveWorkspace(config, "desk", 2, "Monitor B")
assert.deepEqual(Array.from(context.workspaceIds(moved.profiles[0], "Monitor A")), [1])
assert.deepEqual(Array.from(context.workspaceIds(moved.profiles[0], "Monitor B")), [3, 2])
assert.deepEqual(Array.from(context.workspaceIds(config.profiles[0], "Monitor A")), [1, 2])

const reorderedLastToMiddle = context.moveWorkspaceAt(config, "desk", 3, "Monitor A", 1)
assert.deepEqual(Array.from(context.workspaceIds(reorderedLastToMiddle.profiles[0], "Monitor A")), [1, 3, 2])

const reorderedLastToStart = context.moveWorkspaceAt(config, "desk", 3, "Monitor A", 0)
assert.deepEqual(Array.from(context.workspaceIds(reorderedLastToStart.profiles[0], "Monitor A")), [3, 1, 2])

const reorderedFirstToEnd = context.moveWorkspaceAt(config, "desk", 1, "Monitor A", 3)
assert.deepEqual(Array.from(context.workspaceIds(reorderedFirstToEnd.profiles[0], "Monitor A")), [2, 1])

const sameGroupConfig = {
  version: 1,
  profiles: [{ id: "same", match: { mode: "default" }, assignments: { "Monitor A": [1, 2, 3] } }]
}
assert.deepEqual(
  Array.from(context.workspaceIds(context.moveWorkspaceAt(sameGroupConfig, "same", 3, "Monitor A", 0).profiles[0], "Monitor A")),
  [3, 1, 2]
)
assert.deepEqual(
  Array.from(context.workspaceIds(context.moveWorkspaceAt(sameGroupConfig, "same", 3, "Monitor A", 1).profiles[0], "Monitor A")),
  [1, 3, 2]
)

const removed = context.removeWorkspace(moved, "desk", 3)
assert.deepEqual(Array.from(context.workspaceIds(removed.profiles[0], "Monitor B")), [2])

const labeled = context.setWorkspaceLabel(config, "desk", 2, "🧪")
assert.equal(context.workspaceLabel(labeled.profiles[0], 2), "🧪")
assert.equal(context.workspaceLabel(context.setWorkspaceLabel(labeled, "desk", 2, "").profiles[0], 2), "2")

assert.equal(context.nextWorkspaceId(config.profiles[0]), 4)
assert.equal(context.setDivider(config, "desk", "\\").profiles[0].divider, "\\")

const created = context.addExactProfile(config, "travel", "Travel", ["USB monitor"], { "USB monitor": [1, 2] })
assert.equal(created.profiles[0].id, "travel")
assert.equal(context.activeProfile(created, ["USB monitor"]).name, "Travel")

// --------------------------------------------------------------- apply block

const defaults = context.applySettings({})
assert.equal(defaults.enabled, false, "assignments must stay unapplied until asked for")
assert.equal(defaults.persistent, true)
assert.equal(defaults.debounceMs, 1200)
assert.equal(context.applySettings({ apply: { debounceMs: 50 } }).debounceMs, 300)
assert.equal(context.applySettings({ apply: { debounceMs: 90000 } }).debounceMs, 5000)
assert.equal(context.applySettings({ apply: { debounceMs: "not a number" } }).debounceMs, 1200)
assert.equal(context.applySettings({ apply: { enabled: "yes" } }).enabled, false, "only a real boolean enables")

// The apply block has to survive a round trip through the save path, which
// rebuilds the config from normalizedConfig().
const enabledConfig = context.withApplySettings(config, { enabled: true })
assert.equal(enabledConfig.apply.enabled, true)
assert.equal(context.normalizedConfig(enabledConfig).apply.enabled, true)
assert.equal(enabledConfig.profiles.length, config.profiles.length)
assert.equal(context.applySettings(config).enabled, false, "the source config is not mutated")

// ------------------------------------------------------------ rule rendering

assert.equal(context.luaString("plain"), '"plain"')
assert.equal(context.luaString('say "hi"'), '"say \\"hi\\""')
assert.equal(context.luaString("back\\slash"), '"back\\\\slash"')
assert.equal(context.luaString("two\nlines"), '"two\\nlines"')

const disabledRules = context.renderRules(config, {})
assert.match(disabledRules, /^return$/m, "a disabled module must bail out before claiming anything")
assert.equal(disabledRules.includes("hl.workspace_rule"), false)

const rules = context.renderRules(enabledConfig, {})
assert.match(rules, /local persistent = true/)
assert.match(rules, /local debounce_ms = 1200/)
assert.match(rules, /monitor = "desc:Monitor A", workspaces = \{ 1, 2 \}/)
assert.match(rules, /monitor = "desc:Monitor B", workspaces = \{ 3 \}/)
assert.match(rules, /hl\.on\("monitor\.added", schedule\)/)
assert.match(rules, /hl\.timer\(/)
assert.match(rules, /local fallback = \{/, "the default profile becomes the fallback")

// Descriptions are Lua string literals, so a comma or a quote in an EDID name
// is an escaping problem rather than a syntax problem.
const awkward = context.withApplySettings({
  version: 1,
  profiles: [{
    id: "awkward",
    match: { mode: "exact", monitors: ['Acme, Inc. "Wide" 34'] },
    assignments: { 'Acme, Inc. "Wide" 34': [1] }
  }]
}, { enabled: true })
const awkwardRules = context.renderRules(awkward, {})
assert.match(awkwardRules, /monitors = \{ "Acme, Inc\. \\"Wide\\" 34" \}/)
assert.match(awkwardRules, /monitor = "desc:Acme, Inc\. \\"Wide\\" 34"/)
assert.match(awkwardRules, /local fallback = nil/, "no default profile means no fallback rules")

// Entries that name no monitor, or name one with nothing on it, cannot become
// rules and must not reach the generated file.
const sparse = context.withApplySettings({
  version: 1,
  profiles: [{
    id: "sparse",
    match: { mode: "exact", monitors: ["Monitor A"] },
    assignments: { "Monitor A": [1], "*": [2], "": [3], "Monitor B": [] }
  }]
}, { enabled: true })
// Asserted on the group data rather than the rendered text: the runtime half
// of the module legitimately contains both `"desc:"` and `desc:*`-shaped
// fragments, so substring checks over the whole file would match itself.
assert.deepEqual(
  Array.from(context.rulesProfile(sparse.profiles[0]).groups).map(group => group.selector),
  ["desc:Monitor A"]
)
const sparseRules = context.renderRules(sparse, {})
assert.match(sparseRules, /monitor = "desc:Monitor A", workspaces = \{ 1 \}/)
assert.equal(sparseRules.includes("Monitor B"), false)

assert.equal(
  context.renderRules(context.withApplySettings(enabledConfig, { persistent: false }), {}).includes("local persistent = false"),
  true
)

console.log("profile logic: ok")

// ------------------------------------------------ default profile allocation
//
// This allocation is implemented twice: here in JS, which is what the bar
// draws, and in Lua inside the generated module, which is what Hyprland acts
// on. They have to agree exactly, so these assertions pin the ids themselves
// rather than the shape of the result.
//
// Values cross the vm realm boundary, so their arrays fail a strict deepEqual
// on prototype identity alone. Round-tripping through JSON compares them by
// value, the way these assertions mean to.
const plain = value => JSON.parse(JSON.stringify(value))
const allocation = (profile, descriptions) =>
  plain(context.resolveGroups(profile, descriptions)).map(group => group.workspaces)

const fallbackProfile = { id: "default", match: { mode: "default" }, assignments: {} }

// A single unknown monitor is the case that used to leave the bar empty: the
// default profile was selected, but it named no monitor, so it produced nothing.
assert.deepEqual(allocation(fallbackProfile, ["Laptop"]), [[1, 2, 3]])

// Every further unrecognised monitor gets its own block, left to right.
assert.deepEqual(allocation(fallbackProfile, ["Screen A", "Screen B"]), [[1, 2, 3], [4, 5, 6]])
assert.deepEqual(allocation(fallbackProfile, ["A", "B", "C"]), [[1, 2, 3], [4, 5, 6], [7, 8, 9]])
assert.deepEqual(allocation(fallbackProfile, []), [])
assert.deepEqual(
  plain(context.resolveGroups(fallbackProfile, ["A", "B"])).map(group => group.automatic),
  [true, true]
)

// The block size is configurable, and clamped to a range the number-key
// bindings can actually reach.
assert.equal(context.fallbackPerMonitor({}), 3)
assert.equal(context.fallbackPerMonitor({ fallback: { perMonitor: 2 } }), 2)
assert.equal(context.fallbackPerMonitor({ fallback: { perMonitor: 0 } }), 1)
assert.equal(context.fallbackPerMonitor({ fallback: { perMonitor: 99 } }), 10)
assert.deepEqual(
  allocation({ id: "d", match: { mode: "default" }, fallback: { perMonitor: 2 } }, ["A", "B"]),
  [[1, 2], [3, 4]]
)

// A monitor the default profile pins by hand keeps its ids, and those ids are
// reserved — the automatic blocks route around them instead of colliding.
const pinned = { id: "default", match: { mode: "default" }, assignments: { "Pinned": [1, 5] } }
assert.deepEqual(
  allocation(pinned, ["Unknown A", "Pinned", "Unknown B"]),
  [[2, 3, 4], [1, 5], [6, 7, 8]]
)
assert.deepEqual(
  plain(context.resolveGroups(pinned, ["Unknown A", "Pinned", "Unknown B"])).map(group => group.automatic),
  [true, false, true]
)

// An exact profile never allocates. Its assignments are the user's explicit
// statement of intent, so a monitor it does not name stays empty.
const exactProfile = {
  id: "exact",
  match: { mode: "exact", monitors: ["Known"] },
  assignments: { "Known": [1, 2] }
}
assert.deepEqual(allocation(exactProfile, ["Known", "Stranger"]), [[1, 2], []])
assert.deepEqual(
  plain(context.resolveGroups(exactProfile, ["Known", "Stranger"])).map(group => group.automatic),
  [false, false]
)

// The generated module carries the allocation rule rather than pre-computed
// groups, because the monitors it applies to are unknown until Hyprland
// reports them and a rule's monitor cannot be changed after it is created.
const fallbackConfig = context.withApplySettings({
  version: 1,
  profiles: [{
    id: "default",
    match: { mode: "default" },
    fallback: { perMonitor: 2 },
    assignments: { "Pinned Screen": [7] }
  }]
}, { enabled: true })
const fallbackRules = context.renderRules(fallbackConfig, {})
assert.match(fallbackRules, /per_monitor = 2,/)
assert.match(fallbackRules, /\{ description = "Pinned Screen", workspaces = \{ 7 \} \},/)
assert.match(fallbackRules, /local function fallback_groups\(monitors\)/)
assert.match(fallbackRules, /local function ordered_monitors\(\)/)
// Falling back twice onto different unknown screens has to rebuild, not reuse.
assert.match(fallbackRules, /fallback\.id \.\. "\\31" \.\. current/)

console.log("fallback allocation: ok")

// ------------------------------------------------- materializing the fallback
//
// Editing an automatically assigned monitor has to act on what the user sees.
// The allocation is recomputed from the stored assignments every time, so
// pinning one monitor changes the pool the others draw from; writing the whole
// visible layout down first is what keeps an edit from renumbering the rest.

const autoProfile = {
  version: 1,
  profiles: [{
    id: "default",
    name: "Default",
    match: { mode: "default" },
    assignments: {},
    labels: {}
  }]
}

const screens = ["Screen A", "Screen B"]
const materialized = context.materializeFallback(autoProfile, "default", screens)

// What was allocated is now stored, unchanged.
assert.deepEqual(plain(materialized.profiles[0].assignments), {
  "Screen A": [1, 2, 3],
  "Screen B": [4, 5, 6]
})

// And nothing is automatic any more, so the panel drops its AUTO badges.
assert.deepEqual(
  plain(context.resolveGroups(materialized.profiles[0], screens)).map(group => group.automatic),
  [false, false]
)

// The ids the profile resolves to are identical before and after — that is the
// whole point: materializing must be invisible except for pinning.
assert.deepEqual(
  allocation(materialized.profiles[0], screens),
  allocation(autoProfile.profiles[0], screens)
)

// The bug this fixes: on the unmaterialized profile the next free id is 1,
// which is already on screen, so "+" would collide and renumber every monitor.
assert.equal(context.nextWorkspaceId(autoProfile.profiles[0]), 1)
assert.equal(context.nextWorkspaceId(materialized.profiles[0]), 7)

// The source config is untouched, and materializing twice changes nothing.
assert.deepEqual(plain(autoProfile.profiles[0].assignments), {})
assert.deepEqual(
  plain(context.materializeFallback(materialized, "default", screens).profiles[0].assignments),
  plain(materialized.profiles[0].assignments)
)

// Explicit assignments survive, and only the automatic monitors are written.
const partly = {
  version: 1,
  profiles: [{ id: "default", match: { mode: "default" }, assignments: { "Pinned": [1, 5] } }]
}
assert.deepEqual(
  plain(context.materializeFallback(partly, "default", ["Unknown A", "Pinned"]).profiles[0].assignments),
  { "Pinned": [1, 5], "Unknown A": [2, 3, 4] }
)

// An exact profile allocates nothing, so this is a no-op on it — which is why
// the service can call it before every edit without checking the mode.
const exactUntouched = {
  version: 1,
  profiles: [{ id: "e", match: { mode: "exact", monitors: ["Known"] }, assignments: { "Known": [1] } }]
}
assert.deepEqual(
  plain(context.materializeFallback(exactUntouched, "e", ["Known", "Stranger"]).profiles[0].assignments),
  { "Known": [1] }
)

// ------------------------------------------- generated module is canonical
//
// Key order in config.json must not reach rules.lua: otherwise reordering keys
// by hand rewrites the file and reloads Hyprland for no semantic change.
const orderOne = context.withApplySettings({
  version: 1,
  profiles: [{
    id: "p",
    match: { mode: "exact", monitors: ["B", "A"] },
    assignments: { "B": [3], "A": [1] }
  }]
}, { enabled: true })
const orderTwo = context.withApplySettings({
  version: 1,
  profiles: [{
    id: "p",
    match: { mode: "exact", monitors: ["B", "A"] },
    assignments: { "A": [1], "B": [3] }
  }]
}, { enabled: true })
assert.equal(context.renderRules(orderOne, {}), context.renderRules(orderTwo, {}))

console.log("fallback materialization: ok")
