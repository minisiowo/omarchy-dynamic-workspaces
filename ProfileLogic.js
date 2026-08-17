.pragma library

function asArray(value) {
  return Array.isArray(value) ? value : []
}

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

function uniqueStrings(values) {
  var result = []
  var seen = {}

  for (var i = 0; i < asArray(values).length; i++) {
    var value = String(values[i] || "").trim()
    if (value === "" || seen[value]) continue
    seen[value] = true
    result.push(value)
  }

  return result
}

function monitorDescriptions(monitors) {
  var descriptions = []
  var values = asArray(monitors)

  for (var i = 0; i < values.length; i++) {
    if (!values[i]) continue
    descriptions.push(String(values[i].description || values[i].name || ""))
  }

  return uniqueStrings(descriptions)
}

function signature(descriptions) {
  var values = uniqueStrings(descriptions)
  values.sort()
  return values.join("\u001f")
}

// Defaults for the block that decides whether the generated Hyprland rules do
// anything. `enabled` starts false so installing the plugin never changes how
// an existing setup behaves until it is asked to.
function applySettings(value) {
  var apply = asObject(asObject(value).apply)
  var debounce = Number(apply.debounceMs)

  return {
    enabled: apply.enabled === true,
    persistent: apply.persistent !== false,
    debounceMs: Number.isFinite(debounce) ? Math.max(300, Math.min(5000, Math.round(debounce))) : 1200
  }
}

function normalizedConfig(value) {
  var config = asObject(value)
  var profiles = asArray(config.profiles)

  return {
    version: Number(config.version) || 1,
    apply: applySettings(config),
    profiles: profiles
  }
}

function withApplySettings(config, changes) {
  var next = copy(normalizedConfig(config))
  var patch = asObject(changes)

  for (var key in patch) next.apply[key] = patch[key]
  next.apply = applySettings(next)
  return next
}

function profileMatches(profile, descriptions) {
  if (!profile) return false

  var match = asObject(profile.match)
  if (String(match.mode || "") !== "exact") return false

  return signature(match.monitors) === signature(descriptions)
}

function activeProfile(config, descriptions) {
  var profiles = normalizedConfig(config).profiles
  var fallback = null

  for (var i = 0; i < profiles.length; i++) {
    var profile = profiles[i]
    var mode = String(asObject(profile.match).mode || "")

    if (mode === "default" && fallback === null) fallback = profile
    if (mode === "exact" && profileMatches(profile, descriptions)) return profile
  }

  return fallback
}

function workspaceIds(profile, monitorDescription) {
  if (!profile) return []

  var assignments = asObject(profile.assignments)
  var configured = assignments[monitorDescription]
  if (!Array.isArray(configured)) configured = assignments["*"]

  var ids = []
  var seen = {}
  var values = asArray(configured)

  for (var i = 0; i < values.length; i++) {
    var id = Number(values[i])
    if (!Number.isInteger(id) || id <= 0 || seen[id]) continue
    seen[id] = true
    ids.push(id)
  }

  return ids
}

function workspaceLabel(profile, workspaceId) {
  var labels = asObject(profile ? profile.labels : null)
  var value = labels[String(workspaceId)]
  if (value === undefined || value === null || String(value) === "") return String(workspaceId)
  return String(value)
}

function profileName(profile) {
  if (!profile) return "No matching profile"
  return String(profile.name || profile.id || "Unnamed profile")
}

function copy(value) {
  return JSON.parse(JSON.stringify(value))
}

function profileIndex(config, profileId) {
  var profiles = normalizedConfig(config).profiles
  for (var i = 0; i < profiles.length; i++) {
    if (String(profiles[i].id || "") === String(profileId || "")) return i
  }
  return -1
}

function withoutWorkspace(assignments, workspaceId) {
  var result = copy(asObject(assignments))
  var id = Number(workspaceId)

  for (var monitor in result) {
    var source = asArray(result[monitor])
    var filtered = []
    for (var i = 0; i < source.length; i++) {
      if (Number(source[i]) !== id) filtered.push(Number(source[i]))
    }
    result[monitor] = filtered
  }

  return result
}

function moveWorkspaceAt(config, profileId, workspaceId, monitorDescription, targetIndex) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  var id = Number(workspaceId)
  var target = String(monitorDescription || "")
  if (index < 0 || !Number.isInteger(id) || id <= 0 || target === "") return next

  var profile = next.profiles[index]
  var assignments = asObject(profile.assignments)
  var sourceMonitor = ""
  var sourceIndex = -1

  for (var monitor in assignments) {
    var sourceIds = asArray(assignments[monitor])
    for (var sourcePosition = 0; sourcePosition < sourceIds.length; sourcePosition++) {
      if (Number(sourceIds[sourcePosition]) !== id) continue
      sourceMonitor = monitor
      sourceIndex = sourcePosition
      break
    }
    if (sourceIndex >= 0) break
  }

  profile.assignments = withoutWorkspace(assignments, id)
  var targetIds = asArray(profile.assignments[target]).slice()
  var requestedIndex = Number(targetIndex)
  if (!Number.isInteger(requestedIndex)) requestedIndex = targetIds.length
  if (sourceMonitor === target && sourceIndex >= 0 && sourceIndex < requestedIndex) requestedIndex--
  requestedIndex = Math.max(0, Math.min(requestedIndex, targetIds.length))
  targetIds.splice(requestedIndex, 0, id)
  profile.assignments[target] = targetIds
  return next
}

function moveWorkspace(config, profileId, workspaceId, monitorDescription) {
  return moveWorkspaceAt(config, profileId, workspaceId, monitorDescription, undefined)
}

function removeWorkspace(config, profileId, workspaceId) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  if (index < 0) return next

  next.profiles[index].assignments = withoutWorkspace(next.profiles[index].assignments, workspaceId)
  return next
}

function setWorkspaceLabel(config, profileId, workspaceId, label) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  if (index < 0) return next

  var labels = copy(asObject(next.profiles[index].labels))
  var key = String(Number(workspaceId))
  var value = String(label || "").trim()
  if (value === "") delete labels[key]
  else labels[key] = value
  next.profiles[index].labels = labels
  return next
}

function setDivider(config, profileId, divider) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  if (index < 0) return next

  next.profiles[index].divider = String(divider === undefined || divider === null ? "" : divider)
  return next
}

function configuredWorkspaceIds(profile) {
  var assignments = asObject(profile ? profile.assignments : null)
  var ids = []
  var seen = {}

  for (var monitor in assignments) {
    var values = asArray(assignments[monitor])
    for (var i = 0; i < values.length; i++) {
      var id = Number(values[i])
      if (!Number.isInteger(id) || id <= 0 || seen[id]) continue
      seen[id] = true
      ids.push(id)
    }
  }

  ids.sort(function(left, right) { return left - right })
  return ids
}

function nextWorkspaceId(profile) {
  var ids = configuredWorkspaceIds(profile)
  var candidate = 1
  for (var i = 0; i < ids.length; i++) {
    if (ids[i] === candidate) candidate++
    else if (ids[i] > candidate) break
  }
  return candidate
}

// ---------------------------------------------------------------------------
// Hyprland rules
//
// Assignments are handed to Hyprland as a generated Lua module rather than
// applied at runtime. `hyprctl keyword` is rejected outright by Hyprland once
// the Lua parser is in use ("keyword can't work with non-legacy parsers"), and
// runtime rules created through `hyprctl eval` live only in memory: any config
// reload wipes the Lua state and takes them with it. Rules that live in the
// config survive reloads, and the profile switching runs inside Hyprland on its
// own monitor events, which is the same mechanism a hand-written workspaces.lua
// uses.

function luaString(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var result = ""

  for (var i = 0; i < text.length; i++) {
    var char = text.charAt(i)
    var code = text.charCodeAt(i)

    if (char === "\\") result += "\\\\"
    else if (char === "\"") result += "\\\""
    else if (char === "\n") result += "\\n"
    else if (char === "\r") result += "\\r"
    // Lua reads a decimal escape greedily, so "\9" directly before a digit
    // would swallow it. Always emitting three digits keeps them separate.
    else if (code < 32 || code === 127) result += "\\" + ("00" + code).slice(-3)
    else result += char
  }

  return "\"" + result + "\""
}

function monitorSelector(monitorDescription) {
  return "desc:" + String(monitorDescription || "")
}

// Profile shape the generated module works with: the monitor set that selects
// it, and its assignments already resolved to Hyprland monitor selectors.
function rulesProfile(profile) {
  var assignments = asObject(profile ? profile.assignments : null)
  var groups = []

  for (var monitorDescription in assignments) {
    var description = String(monitorDescription || "")
    // "*" is a display-time wildcard in the panel; it names no monitor, so it
    // cannot become a rule.
    if (description === "" || description === "*") continue

    var ids = workspaceIds(profile, description)
    if (ids.length === 0) continue

    groups.push({ selector: monitorSelector(description), workspaces: ids })
  }

  return {
    id: String(profile && profile.id ? profile.id : ""),
    monitors: uniqueStrings(asObject(profile ? profile.match : null).monitors),
    groups: groups
  }
}

function luaProfileEntry(profile, indent) {
  var lines = []
  var pad = indent
  var inner = indent + "  "
  var deep = inner + "  "

  lines.push(pad + "{")
  lines.push(inner + "id = " + luaString(profile.id) + ",")

  var monitors = []
  for (var i = 0; i < profile.monitors.length; i++) monitors.push(luaString(profile.monitors[i]))
  lines.push(inner + "monitors = " + (monitors.length === 0 ? "{}" : "{ " + monitors.join(", ") + " }") + ",")

  if (profile.groups.length === 0) {
    lines.push(inner + "groups = {},")
  } else {
    lines.push(inner + "groups = {")
    for (var groupIndex = 0; groupIndex < profile.groups.length; groupIndex++) {
      var group = profile.groups[groupIndex]
      lines.push(deep + "{ monitor = " + luaString(group.selector)
        + ", workspaces = { " + group.workspaces.join(", ") + " } },")
    }
    lines.push(inner + "},")
  }
  lines.push(pad + "},")

  return lines.join("\n")
}

// The half of the module that never changes: profile resolution, the debounced
// reaction to monitor events, and enabling exactly one profile's rules at a
// time. Kept verbatim so a diff of the generated file only ever shows data.
function rulesRuntime() {
  return [
    "local function signature(values)",
    "  local sorted = {}",
    "  for _, value in ipairs(values) do table.insert(sorted, value) end",
    "  table.sort(sorted)",
    "  return table.concat(sorted, \"\\31\")",
    "end",
    "",
    "-- Every rule of every profile is created up front and left disabled, so",
    "-- switching profiles is only ever a pair of set_enabled calls.",
    "local function build(profile)",
    "  local rules = {}",
    "  for _, group in ipairs(profile.groups) do",
    "    for _, workspace in ipairs(group.workspaces) do",
    "      table.insert(rules, hl.workspace_rule({",
    "        workspace = tostring(workspace),",
    "        monitor = group.monitor,",
    "        persistent = persistent,",
    "        enabled = false,",
    "      }))",
    "    end",
    "  end",
    "  return rules",
    "end",
    "",
    "local rules_by_id = {}",
    "for _, profile in ipairs(profiles) do rules_by_id[profile.id] = build(profile) end",
    "if fallback ~= nil then rules_by_id[fallback.id] = build(fallback) end",
    "",
    "local active_id = nil",
    "",
    "local function resolve()",
    "  local descriptions = {}",
    "  for _, monitor in ipairs(hl.get_monitors()) do",
    "    table.insert(descriptions, monitor.description)",
    "  end",
    "",
    "  local current = signature(descriptions)",
    "  for _, profile in ipairs(profiles) do",
    "    if signature(profile.monitors) == current then return profile.id end",
    "  end",
    "",
    "  return fallback ~= nil and fallback.id or nil",
    "end",
    "",
    "local function sync()",
    "  local id = resolve()",
    "  if id == active_id then return end",
    "",
    "  for _, rule in ipairs(rules_by_id[active_id] or {}) do rule:set_enabled(false) end",
    "  for _, rule in ipairs(rules_by_id[id] or {}) do rule:set_enabled(true) end",
    "  active_id = id",
    "end",
    "",
    "-- Opening a lid, waking, or docking produces a burst of monitor events and",
    "-- several intermediate monitor sets on the way to the final one. Settling",
    "-- first means the profile is chosen once, from the state that lasts. Each",
    "-- event supersedes the pending timer through the generation counter, which",
    "-- is how a one-shot timer is restarted without a handle to cancel.",
    "local generation = 0",
    "",
    "local function schedule()",
    "  generation = generation + 1",
    "  local scheduled = generation",
    "  hl.timer(function()",
    "    if scheduled == generation then sync() end",
    "  end, { timeout = debounce_ms, type = \"oneshot\" })",
    "end",
    "",
    "sync()",
    "hl.on(\"monitor.added\", schedule)",
    "hl.on(\"monitor.removed\", schedule)",
    "hl.on(\"monitor.layout_changed\", schedule)",
    ""
  ].join("\n")
}

function renderRules(config, options) {
  var normalized = normalizedConfig(config)
  var settings = normalized.apply
  var meta = asObject(options)
  var configPath = String(meta.configPath || "~/.config/omarchy/dynamic-workspaces/config.json")
  var exact = []
  var fallback = null

  for (var i = 0; i < normalized.profiles.length; i++) {
    var profile = normalized.profiles[i]
    var mode = String(asObject(profile.match).mode || "")
    if (mode === "exact") exact.push(rulesProfile(profile))
    else if (mode === "default" && fallback === null) fallback = rulesProfile(profile)
  }

  var lines = []
  lines.push("-- Generated by the Dynamic Workspaces plugin (minisiowo.dynamic-workspaces).")
  lines.push("-- Every edit here is overwritten. Change the profiles in:")
  lines.push("--   " + configPath)
  lines.push("--")
  lines.push("-- Load it from ~/.config/hypr/hyprland.lua with:")
  lines.push("--   pcall(dofile, os.getenv(\"HOME\") .. \"/.config/omarchy/dynamic-workspaces/rules.lua\")")
  lines.push("")
  lines.push("local persistent = " + (settings.persistent ? "true" : "false"))
  lines.push("local debounce_ms = " + settings.debounceMs)
  lines.push("")

  if (!settings.enabled) {
    lines.push("-- \"Apply workspace assignments\" is off, so this module claims nothing and")
    lines.push("-- Hyprland keeps whatever workspace rules your own config sets up.")
    lines.push("return")
    lines.push("")
    return lines.join("\n")
  }

  lines.push("local profiles = {")
  for (var exactIndex = 0; exactIndex < exact.length; exactIndex++) {
    lines.push(luaProfileEntry(exact[exactIndex], "  "))
  }
  lines.push("}")
  lines.push("")

  if (fallback === null) {
    lines.push("local fallback = nil")
  } else {
    lines.push("local fallback = " + luaProfileEntry(fallback, "").replace(/,$/, ""))
  }

  lines.push("")
  lines.push(rulesRuntime())

  return lines.join("\n")
}

function addExactProfile(config, id, name, descriptions, assignments) {
  var next = copy(normalizedConfig(config))
  next.profiles.unshift({
    id: String(id),
    name: String(name || "Current monitor setup"),
    match: { mode: "exact", monitors: uniqueStrings(descriptions) },
    assignments: copy(asObject(assignments)),
    labels: {},
    divider: "|"
  })
  return next
}
