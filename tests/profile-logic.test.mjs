import assert from "node:assert/strict"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import vm from "node:vm"
import { spawnSync } from "node:child_process"

const source = fs
  .readFileSync(new URL("../ProfileLogic.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/m, "")

const context = { Array, Number, String, Object, JSON, Math }
vm.createContext(context)
vm.runInContext(source, context)

// Values cross the vm realm boundary, so their arrays/objects fail a strict
// deepEqual on prototype identity alone. Round-tripping through JSON compares
// them by value, the way these assertions mean to.
const plain = value => JSON.parse(JSON.stringify(value))

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
// Unlike activeProfile(), independent of which monitors are connected.
assert.equal(context.defaultProfile(config).id, "default")
assert.equal(context.defaultProfile({ version: 1, profiles: [config.profiles[0]] }), null)
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

assert.equal(context.nextWorkspaceId(config.profiles[0], ["Monitor A", "Monitor B"]), 4)
assert.equal(context.setDivider(config, "desk", "\\").profiles[0].divider, "\\")

const created = context.addExactProfile(config, "travel", "Travel", ["USB monitor"], { "USB monitor": [1, 2] })
assert.equal(created.profiles[0].id, "travel")
assert.equal(context.activeProfile(created, ["USB monitor"]).name, "Travel")
// No labels/divider passed: same defaults as before the parameters existed.
assert.deepEqual(plain(created.profiles[0].labels), {})
assert.equal(created.profiles[0].divider, "|")

// labels/divider carry over from the profile a layout is captured from —
// but only for ids that actually survived into the new assignments.
const capturedWithExtras = context.addExactProfile(
  config,
  "captured",
  "Captured",
  ["USB monitor"],
  { "USB monitor": [1, 2] },
  { "1": "🧪", "2": "🌐", "9": "dropped — id 9 is not in the new assignments" },
  "~"
)
assert.deepEqual(plain(capturedWithExtras.profiles[0].labels), { "1": "🧪", "2": "🌐" })
assert.equal(capturedWithExtras.profiles[0].divider, "~")

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

// A removed workspace takes its name with it: a label left behind is invisible
// until that id comes back, and then it wears a name meant for another layout.
const named = context.setWorkspaceLabel(config, "desk", 3, "chat")
assert.equal(named.profiles[0].labels["3"], "chat")
const dropped = context.removeWorkspace(named, "desk", 3)
assert.equal(dropped.profiles[0].labels["3"], undefined)
assert.equal(dropped.profiles[0].labels["1"], "💻", "the other names are left alone")

// ---------------------------------------------------------------- appearance

assert.equal(context.appearanceSettings({}).focusMark, "", "the bar keeps the number until a character is given")
assert.equal(context.defaultFocusMark(), "\u25cf")
assert.equal(
  context.appearanceSettings({ appearance: { focusMark: context.defaultFocusMark() } }).focusMark,
  context.defaultFocusMark(),
  "the panel's reset must set something that survives a save"
)
assert.equal(context.appearanceSettings({ appearance: { focusMark: "  \u25aa  " } }).focusMark, "\u25aa")
assert.equal(context.appearanceSettings({ appearance: { focusMark: "   " } }).focusMark, "", "whitespace is not a mark")
assert.equal(context.appearanceSettings({ appearance: { focusMark: "\u{1f7e2}" } }).focusMark, "\u{1f7e2}", "a mark is never cut to length, so an emoji survives whole")

// Configs from when this was a set of named styles stored a mark even while it
// was switched off. Reading one must not turn it on.
assert.equal(context.appearanceSettings({ appearance: { focusStyle: "color", focusMark: "\u25cf" } }).focusMark, "")
assert.equal(context.appearanceSettings({ appearance: { focusStyle: "replace", focusMark: "\u25cf" } }).focusMark, "\u25cf")

// Same round trip as the apply block: normalizedConfig() rewrites the config
// down to the keys it names, so a section it forgets is lost on the next save.
const marked = context.withAppearance(config, { focusMark: "\u25cf" })
assert.equal(marked.appearance.focusMark, "\u25cf")
assert.equal(context.normalizedConfig(marked).appearance.focusMark, "\u25cf")
assert.equal(context.withAppearance(marked, { focusMark: "" }).appearance.focusMark, "", "clearing the field is how it is turned off")
assert.equal(marked.profiles.length, config.profiles.length)
assert.equal(marked.apply.enabled, false)
assert.equal(context.appearanceSettings(config).focusMark, "", "the source config is not mutated")

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

// Appearance is a bar concern and must leave the generated module byte for
// byte identical. Service.writeRules() reloads Hyprland whenever the rendered
// text differs, so a display key leaking in here would make picking a focus
// mark reload the compositor.
assert.equal(
  context.renderRules(context.withAppearance(enabledConfig, { focusMark: "\u25aa" }), {}),
  rules,
  "changing how the bar looks must not touch what Hyprland is told"
)

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
assert.equal(context.nextWorkspaceId(autoProfile.profiles[0], screens), 1)
assert.equal(context.nextWorkspaceId(materialized.profiles[0], screens), 7)

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

// --------------------------------------- next id ignores disconnected monitors
//
// The default profile accumulates an assignment for every monitor it has ever
// allocated, connected or not. The bug this guards against: with four stale
// monitors filling 1-10 and one connected monitor sitting on 1-3, "+" handed
// out 11 instead of the 4 that is actually free on screen.

const staleProfile = {
  version: 1,
  profiles: [{
    id: "default",
    match: { mode: "default" },
    assignments: {
      "Gone A": [7, 8, 9],
      "Gone B": [1],
      "Gone C": [4, 5, 6],
      "Gone D": [10],
      "Connected": [1, 2, 3]
    },
    labels: {}
  }]
}
assert.equal(context.nextWorkspaceId(staleProfile.profiles[0], ["Connected"]), 4)
// With no descriptions, the whole profile is still in scope, so the old
// (buggy) behaviour is exactly what asking for it produces.
assert.equal(context.nextWorkspaceId(staleProfile.profiles[0]), 11)

console.log("next id scoped to connected monitors: ok")

// ------------------------------------------------------- forgetting a monitor

const withStale = {
  version: 1,
  profiles: [{
    id: "default",
    match: { mode: "default" },
    assignments: { "Gone": [4, 5], "Here": [1, 2] },
    labels: { "4": "old", "1": "kept" }
  }]
}

assert.deepEqual(
  plain(context.storedMonitors(withStale.profiles[0])),
  [
    { description: "Gone", workspaces: [4, 5] },
    { description: "Here", workspaces: [1, 2] }
  ]
)

const forgotten = context.forgetMonitor(withStale, "default", "Gone")
assert.deepEqual(plain(forgotten.profiles[0].assignments), { "Here": [1, 2] })
// The label that belonged only to the forgotten monitor's ids is gone with it;
// a label an id still in use elsewhere keeps.
assert.deepEqual(plain(forgotten.profiles[0].labels), { "1": "kept" })
// The source config is untouched.
assert.deepEqual(plain(withStale.profiles[0].assignments), { "Gone": [4, 5], "Here": [1, 2] })

// No matching monitor, or no matching profile: a no-op.
assert.deepEqual(
  plain(context.forgetMonitor(withStale, "default", "Nowhere").profiles[0].assignments),
  plain(withStale.profiles[0].assignments)
)
assert.deepEqual(
  plain(context.forgetMonitor(withStale, "missing", "Gone").profiles[0].assignments),
  plain(withStale.profiles[0].assignments)
)

console.log("forgetting a monitor preset: ok")

// -------------------------------------------------------- adding a monitor preset
//
// Pre-assigning a monitor by description before it is ever connected — the
// same block size an automatic monitor would get, taking the lowest ids free
// across the whole profile so two presets cannot collide if both turn out to
// be connected at once.

const forPresets = {
  version: 1,
  profiles: [{
    id: "default",
    match: { mode: "default" },
    assignments: { "Here": [1, 2, 3] },
    labels: {},
    fallback: { perMonitor: 2 }
  }]
}

const withPreset = context.addMonitorPreset(forPresets, "default", "New Screen")
assert.deepEqual(plain(withPreset.profiles[0].assignments), { "Here": [1, 2, 3], "New Screen": [4, 5] })
// The source config is untouched.
assert.deepEqual(plain(forPresets.profiles[0].assignments), { "Here": [1, 2, 3] })

// A description already assigned is left exactly as it is, not reshuffled.
assert.deepEqual(
  plain(context.addMonitorPreset(withPreset, "default", "Here").profiles[0].assignments),
  plain(withPreset.profiles[0].assignments)
)

// Blank descriptions and unknown profiles are no-ops.
assert.deepEqual(
  plain(context.addMonitorPreset(forPresets, "default", "   ").profiles[0].assignments),
  plain(forPresets.profiles[0].assignments)
)
assert.deepEqual(
  plain(context.addMonitorPreset(forPresets, "missing", "New Screen").profiles[0].assignments),
  plain(forPresets.profiles[0].assignments)
)

console.log("adding a monitor preset: ok")

// ------------------------------------------ legacy "*" wildcard is not a preset
//
// "*" used to be a display-time wildcard, replaced by the default profile's
// own allocation (see rulesProfile()). A config written before that may still
// carry the key; it names no monitor, so it must not show up as a preset nor
// tie up ids a real preset could use.

const withWildcard = {
  version: 1,
  profiles: [{
    id: "default",
    match: { mode: "default" },
    assignments: { "*": [1, 2, 3], "Here": [4, 5, 6] },
    labels: {}
  }]
}
assert.deepEqual(plain(context.storedMonitors(withWildcard.profiles[0])), [
  { description: "Here", workspaces: [4, 5, 6] }
])
assert.deepEqual(
  plain(context.addMonitorPreset(withWildcard, "default", "New Screen").profiles[0].assignments),
  { "*": [1, 2, 3], "Here": [4, 5, 6], "New Screen": [1, 2, 3] }
)

console.log("legacy wildcard is not a preset: ok")

// -------------------------------- adding a preset cannot collide with an
// -------------------------------- automatic, not-yet-materialized monitor
//
// The bug this guards against: addMonitorPreset() only reserves ids from a
// profile's own `assignments`, but a connected monitor with no explicit entry
// is drawing its ids from resolveGroups()'s automatic allocation instead — so
// asking for a preset without materializing first can hand out a number
// already showing on a connected screen. Service.addMonitorPreset() avoids
// this by materializing the default profile against whatever is connected
// before calling addMonitorPreset(); this test exercises that same
// composition directly against ProfileLogic.

const autoProfileForPreset = {
  version: 1,
  profiles: [{
    id: "default",
    match: { mode: "default" },
    assignments: {},
    labels: {},
    fallback: { perMonitor: 3 }
  }]
}
const connectedNow = ["Here"]

// Naively skipping materialization reproduces the bug: "Here" is showing
// 1, 2, 3 on screen (via resolveGroups()), yet nothing reserves those ids.
assert.deepEqual(
  plain(context.addMonitorPreset(autoProfileForPreset, "default", "Later").profiles[0].assignments),
  { "Later": [1, 2, 3] }
)
assert.deepEqual(
  plain(context.resolveGroups(autoProfileForPreset.profiles[0], connectedNow)).map(g => g.workspaces),
  [[1, 2, 3]]
)
// Both "Here" (once materialized) and "Later" would show workspace 1, 2, 3 —
// exactly the collision. Materializing first is the fix:
const materializedFirst = context.materializeFallback(autoProfileForPreset, "default", connectedNow)
const withPresetAfterMaterializing = context.addMonitorPreset(materializedFirst, "default", "Later")
assert.deepEqual(plain(withPresetAfterMaterializing.profiles[0].assignments), {
  "Here": [1, 2, 3],
  "Later": [4, 5, 6]
})

console.log("preset addition materializes first, no collision: ok")

// --------------------------------------------------------- listing profiles

const multiProfile = {
  version: 1,
  profiles: [
    {
      id: "desk",
      name: "Desk",
      match: { mode: "exact", monitors: ["Monitor B", "Monitor A"] },
      assignments: {}
    },
    {
      id: "default",
      name: "Default",
      match: { mode: "default" },
      assignments: {}
    }
  ]
}

assert.deepEqual(plain(context.savedProfiles(multiProfile)), [
  { id: "desk", name: "Desk", mode: "exact", monitors: ["Monitor B", "Monitor A"] },
  { id: "default", name: "Default", mode: "default", monitors: [] }
])

console.log("listing profiles: ok")

// -------------------------------------------------------- deleting a profile

const afterDeletingDesk = context.removeProfile(multiProfile, "desk")
assert.deepEqual(plain(context.savedProfiles(afterDeletingDesk)).map(p => p.id), ["default"])
// The source config is untouched.
assert.equal(multiProfile.profiles.length, 2)

// The last remaining profile cannot be deleted — there would be nothing left
// for activeProfile() to fall back to.
assert.deepEqual(
  plain(context.savedProfiles(context.removeProfile(afterDeletingDesk, "default"))).map(p => p.id),
  ["default"]
)

// An unknown id is a no-op.
assert.deepEqual(
  plain(context.savedProfiles(context.removeProfile(multiProfile, "missing"))).map(p => p.id),
  ["desk", "default"]
)

// The default profile is refused even with other profiles still standing —
// it is what every unrecognised monitor set falls back to, not just a
// placeholder kept around for the "at least one profile" rule above.
const threeProfiles = {
  version: 1,
  profiles: [
    { id: "desk", name: "Desk", match: { mode: "exact", monitors: ["A"] }, assignments: {} },
    { id: "default", name: "Default", match: { mode: "default" }, assignments: {} },
    { id: "travel", name: "Travel", match: { mode: "exact", monitors: ["B"] }, assignments: {} }
  ]
}
assert.deepEqual(
  plain(context.savedProfiles(context.removeProfile(threeProfiles, "default"))).map(p => p.id),
  ["desk", "default", "travel"]
)

console.log("deleting a profile: ok")

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

// ------------------------------------------------- screens sharing a description
//
// Two screens of the same model report the same EDID description, and both the
// assignments and the generated rules are keyed by it. Hyprland's `desc:`
// selector cannot address one of them either, so they resolve as one logical
// monitor rather than two — otherwise one would get a block no rule could
// reach, and materializing would overwrite the other's.

const twins = ["Same Model", "Same Model"]
const twinGroups = plain(context.resolveGroups(fallbackProfile, twins))

assert.deepEqual(twinGroups.map(group => group.workspaces), [[1, 2, 3], [1, 2, 3]])
assert.deepEqual(twinGroups.map(group => group.shared), [true, true])
assert.deepEqual(twinGroups.map(group => group.automatic), [true, true])

// A third, distinct screen still gets the next free block — the shared pair
// consumes one block between them, not two.
assert.deepEqual(
  allocation(fallbackProfile, ["Same Model", "Same Model", "Other"]),
  [[1, 2, 3], [1, 2, 3], [4, 5, 6]]
)

// Materializing writes one key and loses nothing.
const twinsMaterialized = context.materializeFallback(autoProfile, "default", twins)
assert.deepEqual(plain(twinsMaterialized.profiles[0].assignments), { "Same Model": [1, 2, 3] })
assert.deepEqual(
  allocation(twinsMaterialized.profiles[0], twins),
  allocation(autoProfile.profiles[0], twins)
)

// Distinct descriptions are untouched by any of this.
assert.deepEqual(allocation(fallbackProfile, ["A", "B"]), [[1, 2, 3], [4, 5, 6]])
assert.deepEqual(
  plain(context.resolveGroups(fallbackProfile, ["A", "B"])).map(group => group.shared),
  [false, false]
)

// An exact profile that names the shared description gives both screens the
// same ids, which is exactly what its single rule will do.
const twinExact = {
  id: "twin",
  match: { mode: "exact", monitors: ["Same Model"] },
  assignments: { "Same Model": [1, 2] }
}
assert.deepEqual(allocation(twinExact, twins), [[1, 2], [1, 2]])

console.log("shared descriptions: ok")

// ---------------------------------------------------------------------------
// Read outside Hyprland
//
// omarchy-menu-keybindings — SUPER+K — lists your keybindings by running
// ~/.config/hypr/hyprland.lua in a plain lua interpreter with a placeholder
// `hl` whose every field answers with itself. The hook dofile()s this module
// from there, so the module used to enumerate monitors against a table that
// never runs out of entries: an unbounded loop that filled tens of gigabytes
// of RAM and swap within seconds of pressing the key.

const guardedRules = context.renderRules(enabledConfig, {})
assert.match(guardedRules, /if type\(hl\) ~= "table" or type\(hl\.get_monitors\) ~= "function" then/)
assert.ok(
  guardedRules.indexOf("if type(hl)") < guardedRules.indexOf("hl.get_monitors()"),
  "nothing may touch the API before the guard has cleared it"
)
assert.match(
  context.renderRules(config, {}),
  /if type\(hl\) ~= "table"/,
  "an inert module is read by the same tools, so it is guarded too"
)

// The guard must not name hl.workspace_rule: Service.writeRules() reads that
// string to tell a module that claims rules from one that claims nothing, and
// would reload Hyprland for an inert stub.
assert.equal(context.renderRules(config, {}).includes("hl.workspace_rule"), false)

// And the loop itself reads a placeholder as empty rather than endless, so the
// guard is not the only thing standing between a scan and a runaway.
assert.match(guardedRules, /for index = 1, #connected do/)

// The real thing: run the generated module under that exact placeholder, with
// an address-space cap so a regression fails as a crash instead of taking the
// machine down with it. Skipped where lua is not installed.
const lua = spawnSync("sh", ["-c", "command -v lua"], { encoding: "utf8" })

if (lua.status !== 0) {
  console.log("placeholder hl: skipped (no lua interpreter)")
} else {
  const modulePath = path.join(os.tmpdir(), "dynamic-workspaces-rules-" + process.pid + ".lua")
  fs.writeFileSync(modulePath, guardedRules)

  try {
    const scan = spawnSync("sh", ["-c",
      // 512 MB of address space: the unguarded loop reached a gigabyte in
      // about four seconds, so it cannot pass this by being slow.
      "ulimit -v 524288; exec timeout 10 lua -e '"
        + 'local noop; noop = setmetatable({}, { __index = function() return noop end, __call = function() return noop end }); '
        + 'hl = setmetatable({}, { __index = function() return noop end }); '
        + 'local ok, err = pcall(dofile, os.getenv("RULES_PATH")); '
        + 'if not ok then io.stderr:write(tostring(err)); os.exit(1) end'
        + "'"
    ], { encoding: "utf8", env: Object.assign({}, process.env, { RULES_PATH: modulePath }) })

    assert.equal(
      scan.status,
      0,
      "the module must return immediately under a placeholder hl: " + (scan.stderr || "timed out or ran out of memory")
    )
    console.log("placeholder hl: ok")
  } finally {
    fs.rmSync(modulePath, { force: true })
  }
}

console.log("guarded module: ok")

// ---------------------------------------------------------------------------
// The rules the module actually builds
//
// Everything above tests the JavaScript half of the allocation. This runs the
// generated Lua half against a stand-in for Hyprland's API and reads back the
// rules it created, which is the only place the two halves can be compared on
// the same input.

if (lua.status !== 0) {
  console.log("built rules: skipped (no lua interpreter)")
} else {
  const builtRules = (monitors) => {
    const modulePath = path.join(os.tmpdir(), "dynamic-workspaces-built-" + process.pid + ".lua")
    fs.writeFileSync(modulePath, guardedRules)

    try {
      const run = spawnSync("lua", ["-e",
        "local monitors = " + monitors + " "
        + "local created = {} "
        + "hl = { "
        + "  get_monitors = function() return monitors end, "
        + "  workspace_rule = function(spec) "
        + "    local rule = { workspace = spec.workspace, monitor = spec.monitor, enabled = spec.enabled } "
        + "    function rule:set_enabled(value) self.enabled = value end "
        + "    table.insert(created, rule) "
        + "    return rule "
        + "  end, "
        + "  timer = function() end, "
        + "  on = function() end, "
        + "} "
        + "dofile(os.getenv('RULES_PATH')) "
        + "for _, rule in ipairs(created) do "
        + "  if rule.enabled then print(rule.workspace .. '\\t' .. rule.monitor) end "
        + "end"
      ], { encoding: "utf8", env: Object.assign({}, process.env, { RULES_PATH: modulePath }) })

      assert.equal(run.status, 0, run.stderr)
      return run.stdout.trim().split("\n").filter(Boolean).map(line => line.split("\t"))
    } finally {
      fs.rmSync(modulePath, { force: true })
    }
  }

  // An exact profile: the rules are the ones written into the module verbatim.
  assert.deepEqual(
    builtRules('{ { description = "Monitor A", name = "DP-1", x = 0, y = 0 }, '
      + '{ description = "Monitor B", name = "DP-2", x = 1920, y = 0 } }'),
    [["1", "desc:Monitor A"], ["2", "desc:Monitor A"], ["3", "desc:Monitor B"]]
  )

  // The default profile, allocating for screens it has never seen: three each,
  // left to right, matching resolveGroups() above.
  assert.deepEqual(
    builtRules('{ { description = "Unknown Right", name = "DP-2", x = 1920, y = 0 }, '
      + '{ description = "Unknown Left", name = "DP-1", x = 0, y = 0 } }'),
    [
      ["1", "desc:Unknown Left"], ["2", "desc:Unknown Left"], ["3", "desc:Unknown Left"],
      ["4", "desc:Unknown Right"], ["5", "desc:Unknown Right"], ["6", "desc:Unknown Right"]
    ]
  )

  // A screen that reports no description at all — a headless output, and some
  // adapters — must produce no rule. `desc:` matches by prefix, so the empty
  // selector would claim every screen connected and put one monitor's
  // workspaces on all of them.
  const withBlank = builtRules('{ { description = "Unknown Left", name = "DP-1", x = 0, y = 0 }, '
    + '{ description = "", name = "HEADLESS-1", x = 1920, y = 0 } }')

  assert.deepEqual(withBlank.map(rule => rule[1]), ["desc:Unknown Left", "desc:Unknown Left", "desc:Unknown Left"])
  assert.equal(withBlank.some(rule => rule[1] === "desc:"), false, "an empty selector claims every screen")

  console.log("built rules: ok")
}
