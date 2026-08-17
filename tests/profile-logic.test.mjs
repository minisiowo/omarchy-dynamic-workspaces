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
const sparseRules = context.renderRules(sparse, {})
assert.match(sparseRules, /monitor = "desc:Monitor A", workspaces = \{ 1 \}/)
assert.equal(sparseRules.includes('desc:*'), false)
assert.equal(sparseRules.includes('"desc:"'), false)
assert.equal(sparseRules.includes("Monitor B"), false)

assert.equal(
  context.renderRules(context.withApplySettings(enabledConfig, { persistent: false }), {}).includes("local persistent = false"),
  true
)

console.log("profile logic: ok")
