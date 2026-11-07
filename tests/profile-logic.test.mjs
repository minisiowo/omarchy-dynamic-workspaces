import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"

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
      assignments: { "Monitor A": [1, 2, 3], "Monitor B": [1, 2] },
      labels: {}
    },
    { id: "default", name: "Default", match: { mode: "default" }, assignments: {}, labels: {} }
  ]
}
const desk = value => context.normalizedConfig(value).profiles[0]

// ------------------------------------------------------------ profile matching

assert.equal(context.signature(["Monitor B", "Monitor A"]), context.signature(["Monitor A", "Monitor B"]))
assert.equal(context.activeProfile(config, ["Monitor A", "Monitor B"]).id, "desk")
assert.equal(context.activeProfile(config, ["Monitor A"]).id, "default")
// Unlike activeProfile(), independent of which monitors are connected.
assert.equal(context.defaultProfile(config).id, "default")
console.log("profile matching: ok")

// ----------------------------------------------------------- Omarchy's numbering

// The contract with default/hypr/monitor-workspaces.lua: a block of ten per
// monitor, and SUPER + N goes to block * 10 + N. The laptop in the bug that
// started this sat on block 2, so its slot 1 is workspace 21, not 1.
assert.equal(context.workspaceIdFor(0, 1), 1)
assert.equal(context.workspaceIdFor(2, 1), 21)
assert.equal(context.workspaceIdFor(1, 10), 20)
assert.equal(context.blockOf(10), 0)
assert.equal(context.blockOf(11), 1)
assert.equal(context.blockOf(21), 2)
assert.equal(context.slotNumber(3), "3")
assert.equal(context.slotNumber(10), "0") // the key that reaches it

// A monitor that is unplugged keeps its block but has no connector, and must not
// answer for the empty string.
assert.deepEqual(
  plain(context.parseBlocks("0\t\tLenovo P24h\n1\tDP-1\tFALLBACK\n2\teDP-1\tLenovo LP140\n")),
  { "DP-1": 1, "eDP-1": 2 })
assert.deepEqual(plain(context.parseBlocks("")), {})

// Slots go through o.workspaces so Omarchy reclaims a workspace an unplug moved.
assert.equal(
  context.focusExpression({ id: 21, slot: 1, monitor: "eDP-1" }),
  'o.workspaces.focus(1, "eDP-1")')
// A visitor from another monitor's block has no slot here and is reached by id.
assert.equal(
  context.focusExpression({ id: 13, slot: 0, monitor: "eDP-1" }),
  'hl.dsp.focus({ workspace = "13" })')
console.log("omarchy numbering: ok")

// ------------------------------------------------------------------------ slots

// Only what a number key can reach can be listed.
const noisy = { assignments: { M: [1, 2, 2, -1, 11, "3"] } }
assert.deepEqual(plain(context.workspaceIds(noisy, "M")), [1, 2, 3])

// The same slot on two monitors is the normal case: each monitor has its own.
const moved = context.placeSlot(config, "desk", "Monitor A", 3, 0)
assert.deepEqual(plain(desk(moved).assignments), { "Monitor A": [3, 1, 2], "Monitor B": [1, 2] })

assert.deepEqual(plain(desk(context.placeSlot(config, "desk", "Monitor A", 3, 1)).assignments["Monitor A"]), [1, 3, 2])
assert.deepEqual(plain(desk(context.placeSlot(config, "desk", "Monitor A", 1, 3)).assignments["Monitor A"]), [2, 3, 1])
assert.deepEqual(plain(desk(context.placeSlot(config, "desk", "Monitor B", 5)).assignments["Monitor B"]), [1, 2, 5])
// Out of reach of the number keys, so nothing changes.
assert.deepEqual(plain(desk(context.placeSlot(config, "desk", "Monitor B", 11)).assignments["Monitor B"]), [1, 2])

// Removing a slot from one monitor leaves the other's slot of the same number.
const removed = context.removeSlot(config, "desk", "Monitor A", 2)
assert.deepEqual(plain(desk(removed).assignments), { "Monitor A": [1, 3], "Monitor B": [1, 2] })

assert.equal(context.nextSlot(desk(config), "Monitor A"), 4)
assert.equal(context.nextSlot(desk(config), "Monitor B"), 3)
assert.equal(context.nextSlot(desk(config), "New monitor"), 1)
const full = { assignments: { M: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] } }
assert.equal(context.nextSlot(full, "M"), 0)
console.log("slots: ok")

// ----------------------------------------------------------------------- labels

// Named on one monitor, and only there.
const labeled = context.setWorkspaceLabel(config, "desk", "Monitor A", 1, "🧪")
assert.equal(context.workspaceLabel(desk(labeled), "Monitor A", 1), "🧪")
assert.equal(context.workspaceLabel(desk(labeled), "Monitor B", 1), "1")
assert.equal(context.workspaceLabel(desk(labeled), "Monitor A", 10), "0")

const cleared = context.setWorkspaceLabel(labeled, "desk", "Monitor A", 1, "  ")
assert.deepEqual(plain(desk(cleared).labels), {})

// A removed slot takes its name with it: left behind, it comes back to life on
// whatever is added under that number next.
assert.deepEqual(plain(desk(context.removeSlot(labeled, "desk", "Monitor A", 1)).labels), {})

// Configs from before slots were per monitor keep their names, on the monitor
// that listed the number. Reading is idempotent, and saving writes the new shape.
const flat = {
  profiles: [{
    id: "old",
    match: { mode: "exact", monitors: ["A", "B"] },
    assignments: { A: [1, 2], B: [4] },
    labels: { "1": "💻", "4": "🌐", "9": "gone" }
  }]
}
const migrated = context.normalizedConfig(flat)
assert.deepEqual(plain(migrated.profiles[0].labels), { A: { "1": "💻" }, B: { "4": "🌐" } })
assert.deepEqual(plain(context.normalizedConfig(migrated)), plain(migrated))
assert.equal(context.workspaceLabel(migrated.profiles[0], "B", 4), "🌐")
console.log("labels: ok")

// ------------------------------------------------------------ default profile

const slots = (profile, descriptions) =>
  plain(context.resolveGroups(profile, descriptions)).map(group => group.workspaces)

const fallbackProfile = { id: "default", match: { mode: "default" }, assignments: {} }

// Every unknown monitor shows its own first slots: nothing to hand out, because
// Omarchy already gave each one all ten.
assert.deepEqual(slots(fallbackProfile, ["A"]), [[1, 2, 3]])
assert.deepEqual(slots(fallbackProfile, ["A", "B"]), [[1, 2, 3], [1, 2, 3]])
assert.equal(context.resolveGroups(fallbackProfile, ["A"])[0].automatic, true)

assert.equal(context.fallbackPerMonitor({ fallback: { perMonitor: 5 } }), 5)
assert.equal(context.fallbackPerMonitor({ fallback: { perMonitor: 99 } }), 10)
assert.equal(context.fallbackPerMonitor({ fallback: { perMonitor: 0 } }), 1)
assert.equal(context.fallbackPerMonitor({}), 3)

// What a monitor names by hand is left alone and does not affect the others.
const pinned = { id: "default", match: { mode: "default" }, assignments: { Pinned: [1, 5] } }
assert.deepEqual(slots(pinned, ["A", "Pinned"]), [[1, 2, 3], [1, 5]])

// An exact profile never allocates: a monitor it does not name stays empty.
const exactProfile = { id: "x", match: { mode: "exact", monitors: ["A", "B"] }, assignments: { A: [1] } }
assert.deepEqual(slots(exactProfile, ["A", "B"]), [[1], []])
assert.equal(context.resolveGroups(exactProfile, ["A", "B"])[1].automatic, false)

// Two screens of one model read as one entry in a profile.
const twins = plain(context.resolveGroups(fallbackProfile, ["Same", "Same"]))
assert.deepEqual(twins.map(group => group.shared), [true, true])
assert.deepEqual(twins.map(group => group.workspaces), [[1, 2, 3], [1, 2, 3]])

// Editing what is shown automatically first writes it down.
const autoConfig = { profiles: [{ ...fallbackProfile, assignments: {}, labels: {} }] }
const materialized = context.materializeFallback(autoConfig, "default", ["A", "B"])
assert.deepEqual(plain(materialized.profiles[0].assignments), { A: [1, 2, 3], B: [1, 2, 3] })
assert.deepEqual(slots(materialized.profiles[0], ["A", "B"]), slots(autoConfig.profiles[0], ["A", "B"]))
assert.equal(context.resolveGroups(materialized.profiles[0], ["A"])[0].automatic, false)
console.log("default profile: ok")

// ---------------------------------------------------------------------- presets

const preset = context.addMonitorPreset(autoConfig, "default", "  Future  ")
assert.deepEqual(plain(preset.profiles[0].assignments), { Future: [1, 2, 3] })
// A preset already there is not reshuffled.
const customised = context.placeSlot(preset, "default", "Future", 7, 0)
assert.deepEqual(
  plain(context.addMonitorPreset(customised, "default", "Future").profiles[0].assignments),
  { Future: [7, 1, 2, 3] })

const namedPreset = context.setWorkspaceLabel(preset, "default", "Future", 1, "web")
const forgotten = context.forgetMonitor(namedPreset, "default", "Future")
assert.deepEqual(plain(forgotten.profiles[0].assignments), {})
assert.deepEqual(plain(forgotten.profiles[0].labels), {})

assert.deepEqual(plain(context.storedMonitors({ assignments: { B: [1], A: [2], "*": [3], "": [4] } })), [
  { description: "A", workspaces: [2] },
  { description: "B", workspaces: [1] }
])
console.log("presets: ok")

// --------------------------------------------------------------------- profiles

const withProfile = context.addExactProfile(
  config, "travel", "Travel", ["USB", "USB"], { USB: [1, 2] },
  { USB: { "1": "web", "9": "dropped" }, Other: { "1": "dropped" } }, "/")
const travel = withProfile.profiles[0]
assert.equal(travel.id, "travel")
assert.deepEqual(plain(travel.match.monitors), ["USB"])
assert.deepEqual(plain(travel.labels), { USB: { "1": "web" } })
assert.equal(travel.divider, "/")
assert.equal(context.addExactProfile(config, "t", "T", ["USB"], { USB: [1] }).profiles[0].divider, "|")

// The default profile and the last profile standing both stay.
assert.equal(context.removeProfile(config, "default").profiles.length, 2)
assert.equal(context.removeProfile(config, "desk").profiles.length, 1)
assert.deepEqual(
  plain(context.savedProfiles(config)).map(profile => [profile.id, profile.mode, profile.monitors.length]),
  [["desk", "exact", 2], ["default", "default", 0]])

const divided = context.setDivider(config, "desk", "·")
assert.equal(desk(divided).divider, "·")
console.log("profiles: ok")

// ------------------------------------------------------------------- appearance

assert.equal(context.appearanceSettings({}).focusMark, "")
assert.equal(context.appearanceSettings({ appearance: { focusMark: " ● " } }).focusMark, "●")
// A stored mark from when this was a set of named styles, switched off.
assert.equal(context.appearanceSettings({ appearance: { focusMark: "●", focusStyle: "color" } }).focusMark, "")
assert.equal(context.appearanceSettings({ appearance: { focusMark: "●", focusStyle: "replace" } }).focusMark, "●")

// normalizedConfig() rewrites the config down to the keys it names, so a section
// it forgets is lost on the next save.
const marked = context.withAppearance(config, { focusMark: "●" })
assert.equal(context.normalizedConfig(marked).appearance.focusMark, "●")
// And what used to be the rules' settings does not come back.
assert.equal(context.normalizedConfig({ apply: { enabled: true } }).apply, undefined)
console.log("appearance: ok")

// -------------------------------------------------------- workspaces outside it

const groups = [
  { name: "eDP-1", block: 2, workspaces: [{ id: 21 }, { id: 22 }] },
  { name: "DP-1", block: 0, workspaces: [{ id: 1 }] }
]
const stranded = live => plain(context.strandedWorkspaces(groups, live))

// Listed, empty, and special workspaces stay out.
assert.deepEqual(stranded([
  { id: 21, monitor: "eDP-1", windows: 3, active: true },
  { id: 24, monitor: "eDP-1", windows: 0, active: false },
  { id: -98, monitor: "eDP-1", windows: 1, active: false }
]), [])

// SUPER + 7 goes to a slot the profile does not list, and it has to be on the bar
// while you are on it, windows or not.
assert.deepEqual(stranded([{ id: 27, monitor: "eDP-1", windows: 0, active: true }]), [
  { id: 27, monitor: "eDP-1", slot: 7, number: "7" }
])
assert.deepEqual(stranded([{ id: 30, monitor: "eDP-1", windows: 1, active: false }]), [
  { id: 30, monitor: "eDP-1", slot: 10, number: "0" }
])

// A visitor from another block has no slot here, and keeps its id.
assert.deepEqual(stranded([{ id: 12, monitor: "eDP-1", windows: 1, active: false }]), [
  { id: 12, monitor: "eDP-1", slot: 0, number: "12" }
])

// Sorted, so a new array from the compositor does not reorder the chips.
assert.deepEqual(
  stranded([
    { id: 29, monitor: "eDP-1", windows: 1 },
    { id: 25, monitor: "eDP-1", windows: 1 }
  ]).map(entry => entry.id),
  [25, 29])
console.log("workspaces outside the profile: ok")

// -------------------------------------------------------------------- the bar

// The icon and the chips are separate bar entries, so each can be dragged on its
// own. Declaring omarchy.clonedFrom would tie the plugin to a single entry.
const manifest = JSON.parse(fs.readFileSync(new URL("../manifest.json", import.meta.url), "utf8"))
assert.equal(manifest.barWidget.allowMultiple, true)
assert.equal(manifest.omarchy, undefined)
console.log("bar entries: ok")
