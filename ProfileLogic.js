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

// How the bar marks the workspace you are looking at. There is one setting and
// the character is its own switch: give it something and the focused workspace
// shows that instead of its number, leave it empty and the number stays and the
// color alone says which one it is. Not per profile — the divider depends on how
// a profile groups monitors, but this is taste, and there is no reason for it to
// change when you dock. Left uncapped on purpose: workspace labels and the
// divider are free text too, and cutting a string at a fixed length would split
// an emoji built from several UTF-16 units.
// The character the panel offers when nothing has been chosen, and the one its
// reset goes back to. Lives here so the panel, the placeholder, and the reset
// all read the same value.
function defaultFocusMark() {
  return "\u25cf"
}

function appearanceSettings(value) {
  var appearance = asObject(asObject(value).appearance)
  var mark = String(appearance.focusMark === undefined || appearance.focusMark === null ? "" : appearance.focusMark).trim()

  // Configs written while this was a set of named styles carry a `focusStyle`.
  // Only `replace` ever painted the character, so anything else means the mark
  // was stored but switched off, and turning it on now would change how someone's
  // bar looks behind their back.
  var legacy = appearance.focusStyle
  if (legacy !== undefined && legacy !== null && String(legacy).trim().toLowerCase() !== "replace") mark = ""

  return { focusMark: mark }
}

function normalizedConfig(value) {
  var config = asObject(value)
  var profiles = asArray(config.profiles)

  return {
    version: Number(config.version) || 1,
    apply: applySettings(config),
    // Listed here or lost: this function rewrites the config down to the keys
    // it names, so a section left out would be dropped on the next save.
    appearance: appearanceSettings(config),
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

function withAppearance(config, changes) {
  var next = copy(normalizedConfig(config))
  var patch = asObject(changes)

  for (var key in patch) next.appearance[key] = patch[key]
  next.appearance = appearanceSettings(next)
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

// How many workspaces an unrecognised monitor gets from the default profile.
// Three is the block size most people end up with by hand, and it is small
// enough that even four unknown screens stay inside the single-digit ids that
// the number-key bindings reach.
function fallbackPerMonitor(profile) {
  var settings = asObject(profile ? profile.fallback : null)
  var count = Number(settings.perMonitor)

  return Number.isFinite(count) ? Math.max(1, Math.min(10, Math.round(count))) : 3
}

function isFallbackProfile(profile) {
  return String(asObject(profile ? profile.match : null).mode || "") === "default"
}

// Turns a profile plus the monitors actually connected — in left-to-right
// order — into the workspace groups both the bar and the generated Lua module
// work from. Exact profiles answer purely from their own assignments; the
// default profile hands every monitor it does not name a block of consecutive
// workspaces, taking the lowest ids its explicit assignments leave free.
//
// This is the one place the allocation is decided. `rulesRuntime()` mirrors it
// in Lua, because rules for monitors nobody has described yet cannot exist
// until those monitors do.
//
// Two screens of the same model report the same EDID description, and every
// assignment here — and every rule in the generated module — is keyed by that
// description. Hyprland's `desc:` selector cannot tell them apart either, so
// they are resolved as one logical monitor sharing a single group. Treating
// them as two would allocate a block that no rule could ever address, and
// writing both down would have the second silently overwrite the first.
// Profile matching already reads them this way, through `uniqueStrings()`.
function resolveGroups(profile, orderedDescriptions) {
  var descriptions = []
  var values = asArray(orderedDescriptions)
  for (var i = 0; i < values.length; i++) descriptions.push(String(values[i] || ""))

  var groups = []
  var fallback = isFallbackProfile(profile)
  var reserved = {}
  var pending = []
  var firstSeenAt = {}

  for (var index = 0; index < descriptions.length; index++) {
    var description = descriptions[index]
    var shared = Object.prototype.hasOwnProperty.call(firstSeenAt, description)
    var ids = workspaceIds(profile, description)
    var automatic = fallback && !shared && ids.length === 0

    groups.push({
      description: description,
      workspaces: ids,
      automatic: automatic,
      // True on every screen that shares its description with another, the
      // first one included: none of them can be addressed on its own.
      shared: false
    })

    if (shared) {
      groups[index].automatic = groups[firstSeenAt[description]].automatic
      groups[index].shared = true
      groups[firstSeenAt[description]].shared = true
      continue
    }

    firstSeenAt[description] = index

    if (automatic) pending.push(index)
    else for (var reserve = 0; reserve < ids.length; reserve++) reserved[ids[reserve]] = true
  }

  var perMonitor = fallbackPerMonitor(profile)
  var nextId = 1

  for (var slot = 0; slot < pending.length; slot++) {
    var allocated = []

    while (allocated.length < perMonitor) {
      if (!reserved[nextId]) {
        reserved[nextId] = true
        allocated.push(nextId)
      }
      nextId += 1
    }

    groups[pending[slot]].workspaces = allocated
  }

  // Screens sharing a description show the group their description resolved to.
  for (var copyIndex = 0; copyIndex < groups.length; copyIndex++) {
    if (!groups[copyIndex].shared) continue
    var source = firstSeenAt[groups[copyIndex].description]
    if (source !== copyIndex) groups[copyIndex].workspaces = groups[source].workspaces.slice()
  }

  return groups
}

// Writes the allocation the default profile is currently showing into its own
// assignments, turning an implicit layout into an explicit one.
//
// Editing an automatically assigned monitor is otherwise incoherent: the
// editing functions all reason about explicit assignments, so they would place
// a workspace the allocation has already handed out, and pinning one monitor
// changes the pool the others draw from — touching one card renumbers the rest.
// Materializing first means an edit lands on exactly what the user is looking
// at, and every later edit behaves like it would on an exact profile.
//
// A profile that allocates nothing is returned unchanged, so this is safe to
// call before any edit without checking the profile's mode first.
function materializeFallback(config, profileId, orderedDescriptions) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  if (index < 0) return next

  var profile = next.profiles[index]
  if (!isFallbackProfile(profile)) return next

  var groups = resolveGroups(profile, orderedDescriptions)
  var assignments = copy(asObject(profile.assignments))
  var changed = false

  for (var i = 0; i < groups.length; i++) {
    if (!groups[i].automatic) continue
    assignments[groups[i].description] = groups[i].workspaces
    changed = true
  }

  if (!changed) return next

  profile.assignments = assignments
  return next
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

  // The name goes with it. Left behind, it is invisible dead weight that comes
  // back to life if that id is ever added again — and a workspace wearing a
  // name you gave it months ago, for a different layout, is exactly the kind of
  // surprise this panel is meant to prevent.
  var labels = copy(asObject(next.profiles[index].labels))
  delete labels[String(Number(workspaceId))]
  next.profiles[index].labels = labels

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
  var keys = []

  for (var key in assignments) keys.push(key)
  // Sorted so the generated module is a function of what the config says, not
  // of the order its keys happen to sit in. Reordering keys by hand would
  // otherwise rewrite rules.lua and reload Hyprland for no semantic change.
  keys.sort()

  for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
    var monitorDescription = keys[keyIndex]
    var description = String(monitorDescription || "")
    // "*" used to be a display-time wildcard; the default profile's own
    // allocation replaced it. Configs written before that may still carry the
    // key, and it names no monitor, so it can never become a rule.
    if (description === "" || description === "*") continue

    var ids = workspaceIds(profile, description)
    if (ids.length === 0) continue

    groups.push({ description: description, selector: monitorSelector(description), workspaces: ids })
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

// The default profile is emitted differently from an exact one: it names no
// monitor set, so all the generated file can carry is the assignments the user
// pinned by hand plus the block size to hand out for everything else.
function luaFallbackEntry(profile, perMonitor) {
  var lines = []

  lines.push("{")
  lines.push("  id = " + luaString(profile.id) + ",")
  lines.push("  per_monitor = " + perMonitor + ",")

  if (profile.groups.length === 0) {
    lines.push("  explicit = {},")
  } else {
    lines.push("  explicit = {")
    for (var index = 0; index < profile.groups.length; index++) {
      var group = profile.groups[index]
      lines.push("    { description = " + luaString(group.description)
        + ", workspaces = { " + group.workspaces.join(", ") + " } },")
    }
    lines.push("  },")
  }

  lines.push("}")

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
    "local function build(groups)",
    "  local rules = {}",
    "  for _, group in ipairs(groups) do",
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
    "-- Left to right, so the block a screen gets follows where it physically is",
    "-- rather than the order Hyprland happened to discover it in.",
    "local function ordered_monitors()",
    "  local monitors = {}",
    "  -- Counted rather than iterated with ipairs(): a placeholder table reports no",
    "  -- length, so this reads as empty instead of never ending if the guard above is",
    "  -- ever bypassed.",
    "  local connected = hl.get_monitors()",
    "  for index = 1, #connected do",
    "    -- A screen that reports no description cannot be addressed: `desc:` matches",
    "    -- by prefix, so the empty selector it would produce claims every screen",
    "    -- there is. Leave it out rather than spread the workspaces of one screen",
    "    -- over all of them. Mirrors the same guard in rulesProfile() in ProfileLogic.js.",
    "    local monitor = connected[index]",
    "    if type(monitor.description) == \"string\" and monitor.description ~= \"\" then",
    "      table.insert(monitors, monitor)",
    "    end",
    "  end",
    "  table.sort(monitors, function(left, right)",
    "    if left.x ~= right.x then return left.x < right.x end",
    "    if left.y ~= right.y then return left.y < right.y end",
    "    return left.name < right.name",
    "  end)",
    "  return monitors",
    "end",
    "",
    "-- The default profile names no monitors, so its rules cannot be built until",
    "-- the monitors exist. Every screen it does not assign by hand gets its own",
    "-- block of per_monitor workspaces, taking the lowest ids the explicit",
    "-- assignments leave free. Mirrors resolveGroups() in ProfileLogic.js.",
    "local function fallback_groups(monitors)",
    "  local explicit = {}",
    "  for _, entry in ipairs(fallback.explicit) do",
    "    explicit[entry.description] = entry.workspaces",
    "  end",
    "",
    "  local groups = {}",
    "  local reserved = {}",
    "  local pending = {}",
    "",
    "  for index, monitor in ipairs(monitors) do",
    "    local ids = explicit[monitor.description]",
    "    groups[index] = { monitor = \"desc:\" .. monitor.description, workspaces = ids or {} }",
    "",
    "    if ids == nil then",
    "      table.insert(pending, index)",
    "    else",
    "      for _, id in ipairs(ids) do reserved[id] = true end",
    "    end",
    "  end",
    "",
    "  local next_id = 1",
    "  for _, index in ipairs(pending) do",
    "    local ids = {}",
    "    while #ids < fallback.per_monitor do",
    "      if not reserved[next_id] then",
    "        reserved[next_id] = true",
    "        table.insert(ids, next_id)",
    "      end",
    "      next_id = next_id + 1",
    "    end",
    "    groups[index].workspaces = ids",
    "  end",
    "",
    "  return groups",
    "end",
    "",
    "-- Rules are built once per distinct outcome and kept disabled in between,",
    "-- so a profile that has been seen before switches on set_enabled alone.",
    "local rules_by_key = {}",
    "local active_key = nil",
    "",
    "local function resolve()",
    "  local monitors = ordered_monitors()",
    "  local descriptions = {}",
    "  for _, monitor in ipairs(monitors) do",
    "    table.insert(descriptions, monitor.description)",
    "  end",
    "",
    "  local current = signature(descriptions)",
    "  for _, profile in ipairs(profiles) do",
    "    if signature(profile.monitors) == current then return profile.id, profile.groups end",
    "  end",
    "",
    "  if fallback == nil then return nil, {} end",
    "",
    "  -- The monitor set is part of the key: falling back twice onto different",
    "  -- unknown screens has to rebuild, not reuse.",
    "  return fallback.id .. \"\\31\" .. current, fallback_groups(monitors)",
    "end",
    "",
    "local function sync()",
    "  local key, groups = resolve()",
    "  if key == active_key then return end",
    "",
    "  for _, rule in ipairs(rules_by_key[active_key] or {}) do rule:set_enabled(false) end",
    "",
    "  if key ~= nil then",
    "    if rules_by_key[key] == nil then rules_by_key[key] = build(groups) end",
    "    for _, rule in ipairs(rules_by_key[key]) do rule:set_enabled(true) end",
    "  end",
    "",
    "  active_key = key",
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
  var fallbackPer = 3

  for (var i = 0; i < normalized.profiles.length; i++) {
    var profile = normalized.profiles[i]
    var mode = String(asObject(profile.match).mode || "")
    if (mode === "exact") {
      exact.push(rulesProfile(profile))
    } else if (mode === "default" && fallback === null) {
      fallback = rulesProfile(profile)
      fallbackPer = fallbackPerMonitor(profile)
    }
  }

  var lines = []
  lines.push("-- Generated by the Dynamic Workspaces plugin (minisiowo.dynamic-workspaces).")
  lines.push("-- Every edit here is overwritten. Change the profiles in:")
  lines.push("--   " + configPath)
  lines.push("--")
  lines.push("-- Load it from ~/.config/hypr/hyprland.lua with:")
  lines.push("--   pcall(dofile, os.getenv(\"HOME\") .. \"/.config/omarchy/dynamic-workspaces/rules.lua\")")
  lines.push("")
  // Tools that want to know what a Hyprland config declares — omarchy-menu-keybindings
  // is the one on every SUPER+K — read hyprland.lua with a plain lua interpreter and a
  // placeholder `hl` whose every field answers with itself. Enumerating monitors against
  // that placeholder never runs out of entries, so the scan turned into an unbounded loop
  // that filled RAM and swap in seconds. Nothing below may touch the API before this
  // check. It names only get_monitors: a missing workspace_rule raises, which the hook's
  // pcall already contains, and spelling it here would also make Service.writeRules() read
  // an inert stub as a module that claims rules.
  lines.push("-- Read outside Hyprland — by omarchy-menu-keybindings, for one — `hl` is a")
  lines.push("-- placeholder whose every field answers with itself, and enumerating monitors")
  lines.push("-- against it never ends. Claim nothing until the real API is present.")
  lines.push("if type(hl) ~= \"table\" or type(hl.get_monitors) ~= \"function\" then")
  lines.push("  return")
  lines.push("end")
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
    lines.push("local fallback = " + luaFallbackEntry(fallback, fallbackPer))
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
