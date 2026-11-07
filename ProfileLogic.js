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

// Omarchy numbers workspaces in blocks of ten, one block per monitor, so a
// profile never says which Hyprland workspace goes where. It says which of a
// monitor's own ten slots the bar shows, in what order, and what they are
// called. A slot's real id is worked out from the block Omarchy gave that
// monitor, and SUPER + N reaches slot N of the focused monitor.
var slotsPerMonitor = 10

// Omarchy binds slot 10 to the 0 key and prints it that way too.
function slotNumber(slot) {
  return Number(slot) === slotsPerMonitor ? "0" : String(slot)
}

function workspaceIdFor(block, slot) {
  return Number(block) * slotsPerMonitor + Number(slot)
}

function blockOf(workspaceId) {
  return Math.floor((Number(workspaceId) - 1) / slotsPerMonitor)
}

// Omarchy's state file: `block<TAB>connector<TAB>identity`, one line per monitor
// it has ever seen, with the connector empty while the monitor is unplugged.
function parseBlocks(text) {
  var blocks = {}
  var lines = String(text || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t")
    var block = parseInt(fields[0], 10)
    if (fields.length >= 3 && fields[1] !== "" && Number.isInteger(block)) blocks[fields[1]] = block
  }

  return blocks
}

// What the bar and the panel dispatch to reach a workspace. Going through
// o.workspaces is what keeps Omarchy's bookkeeping right: it brings the
// workspace back from wherever an unplug left it, which a plain focus would not.
// A workspace visiting from an unplugged monitor has no slot here (slot 0) and
// can only be named by its id, the way Omarchy's own bar does it.
function focusExpression(workspace) {
  var target = asObject(workspace)
  if (Number(target.slot) > 0)
    return "o.workspaces.focus(" + Number(target.slot) + ", " + JSON.stringify(String(target.monitor)) + ")"
  return "hl.dsp.focus({ workspace = " + JSON.stringify(String(target.id)) + " })"
}

// Labels used to be flat ({ "1": "web" }) back when a workspace number could sit
// on one monitor only. Now every monitor has its own slot 1, so they are kept per
// monitor. A flat label belonged to whichever monitor listed that number.
function normalizedProfile(value) {
  var profile = asObject(value)
  var labels = asObject(profile.labels)
  var flat = false

  for (var key in labels) {
    if (typeof labels[key] !== "object" || labels[key] === null) flat = true
  }
  if (!flat) return profile

  var result = copy(profile)
  var assignments = asObject(profile.assignments)
  result.labels = {}

  for (var entry in labels) {
    var entryValue = labels[entry]
    if (typeof entryValue === "object" && entryValue !== null) {
      result.labels[entry] = copy(entryValue)
      continue
    }

    for (var monitor in assignments) {
      if (workspaceIds(profile, monitor).indexOf(Number(entry)) < 0) continue
      if (!result.labels[monitor]) result.labels[monitor] = {}
      result.labels[monitor][entry] = entryValue
    }
  }

  return result
}

function normalizedConfig(value) {
  var config = asObject(value)
  var profiles = asArray(config.profiles)
  var normalized = []

  for (var i = 0; i < profiles.length; i++) normalized.push(normalizedProfile(profiles[i]))

  return {
    version: Number(config.version) || 1,
    // Listed here or lost: this function rewrites the config down to the keys
    // it names, so a section left out would be dropped on the next save.
    appearance: appearanceSettings(config),
    profiles: normalized
  }
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

// The one profile every unrecognised monitor set falls back to — independent
// of which profile happens to be active right now. Presets belong to this
// profile specifically, not to whatever the panel is currently showing, so
// anything that edits them needs to find it directly rather than going
// through activeProfile().
function defaultProfile(config) {
  var profiles = normalizedConfig(config).profiles

  for (var i = 0; i < profiles.length; i++) {
    if (String(asObject(profiles[i].match).mode || "") === "default") return profiles[i]
  }

  return null
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
    if (!Number.isInteger(id) || id <= 0 || id > slotsPerMonitor || seen[id]) continue
    seen[id] = true
    ids.push(id)
  }

  return ids
}

// How many slots an unrecognised monitor shows from the default profile. A slot
// left out is not lost: SUPER + N still reaches it, and it joins the bar as soon
// as it is in view or holds a window.
function fallbackPerMonitor(profile) {
  var settings = asObject(profile ? profile.fallback : null)
  var count = Number(settings.perMonitor)

  return Number.isFinite(count) ? Math.max(1, Math.min(10, Math.round(count))) : 3
}

function isFallbackProfile(profile) {
  return String(asObject(profile ? profile.match : null).mode || "") === "default"
}

// Turns a profile plus the monitors actually connected — in left-to-right
// order — into the groups the bar and the panel draw. Exact profiles answer
// purely from their own assignments; the default profile shows the first few
// slots of every monitor it does not name.
//
// Two screens of the same model report the same EDID description, and every
// assignment here is keyed by it, so they show one set of chips. Omarchy does
// tell them apart, so each still reaches its own block.
function resolveGroups(profile, orderedDescriptions) {
  var descriptions = []
  var values = asArray(orderedDescriptions)
  for (var i = 0; i < values.length; i++) descriptions.push(String(values[i] || ""))

  var groups = []
  var fallback = isFallbackProfile(profile)
  var firstSeenAt = {}
  var automaticSlots = []
  for (var slot = 1; slot <= fallbackPerMonitor(profile); slot++) automaticSlots.push(slot)

  for (var index = 0; index < descriptions.length; index++) {
    var description = descriptions[index]
    var shared = Object.prototype.hasOwnProperty.call(firstSeenAt, description)
    var ids = workspaceIds(profile, description)
    var automatic = fallback && ids.length === 0

    groups.push({
      description: description,
      workspaces: automatic ? automaticSlots.slice() : ids,
      automatic: automatic,
      // True on every screen that shares its description with another, the
      // first one included.
      shared: false
    })

    if (shared) {
      groups[index].shared = true
      groups[firstSeenAt[description]].shared = true
    } else {
      firstSeenAt[description] = index
    }
  }

  return groups
}

// Writes the slots the default profile is currently showing into its own
// assignments, so an edit lands on exactly what the user is looking at and the
// AUTO badges go. A profile with nothing automatic is returned unchanged, so
// this is safe to call before any edit.
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

function workspaceLabel(profile, monitorDescription, slot) {
  var labels = asObject(asObject(profile ? profile.labels : null)[monitorDescription])
  var value = labels[String(slot)]
  if (value === undefined || value === null || String(value) === "") return slotNumber(slot)
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

// Every profile in the config, in order — what a "PROFILES" section lists and
// offers to delete by name. An exact profile carries the monitors it was
// saved for; the default profile names none, so its list is empty.
function savedProfiles(config) {
  var profiles = normalizedConfig(config).profiles
  var result = []

  for (var i = 0; i < profiles.length; i++) {
    var profile = profiles[i]
    var match = asObject(profile.match)
    var mode = String(match.mode || "")
    var monitors = []

    if (mode === "exact") {
      var values = asArray(match.monitors)
      for (var j = 0; j < values.length; j++) monitors.push(String(values[j]))
    }

    result.push({
      id: String(profile.id || ""),
      name: profileName(profile),
      mode: mode,
      monitors: monitors
    })
  }

  return result
}

// Deletes a profile outright — the panel's way of clearing out a saved setup
// nobody uses any more. Refuses to empty the list entirely: a config with no
// profiles has nothing for activeProfile() to fall back to, so the last one
// standing stays no matter which id is asked for. The default profile is
// refused unconditionally, even with exact profiles left standing: without it
// any monitor set that does not match one of those exactly — a new screen, an
// unfamiliar docking station — would get no workspaces assigned at all.
function removeProfile(config, profileId) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  if (index < 0 || next.profiles.length <= 1) return next
  if (isFallbackProfile(next.profiles[index])) return next

  next.profiles.splice(index, 1)
  return next
}

// Places a slot on a monitor, or moves it along that monitor's row if it is
// already there. There is no moving between monitors: every monitor has its own
// slot 1, so "the same workspace on another screen" is not a thing that exists.
function placeSlot(config, profileId, monitorDescription, slot, targetIndex) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  var id = Number(slot)
  var monitor = String(monitorDescription || "")
  if (index < 0 || !Number.isInteger(id) || id <= 0 || id > slotsPerMonitor || monitor === "") return next

  var profile = next.profiles[index]
  var slots = workspaceIds(profile, monitor)
  var source = slots.indexOf(id)
  var requested = Number(targetIndex)
  if (!Number.isInteger(requested)) requested = slots.length

  if (source >= 0) {
    slots.splice(source, 1)
    if (source < requested) requested--
  }

  slots.splice(Math.max(0, Math.min(requested, slots.length)), 0, id)
  var assignments = copy(asObject(profile.assignments))
  assignments[monitor] = slots
  profile.assignments = assignments
  return next
}

function removeSlot(config, profileId, monitorDescription, slot) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  var monitor = String(monitorDescription || "")
  if (index < 0) return next

  var profile = next.profiles[index]
  var kept = workspaceIds(profile, monitor).filter(function(id) { return id !== Number(slot) })
  var assignments = copy(asObject(profile.assignments))
  assignments[monitor] = kept
  profile.assignments = assignments

  // The name goes with it. Left behind, it is invisible dead weight that comes
  // back to life if that slot is ever added again, wearing a name you gave it
  // months ago for something else.
  return withLabel(next, index, monitor, slot, "")
}

// Every monitor a profile has an assignment for, connected or not — the
// panel's list of presets. Sorted by description so the list does not reorder
// itself between renders.
function storedMonitors(profile) {
  var assignments = asObject(profile ? profile.assignments : null)
  var result = []

  for (var monitor in assignments) {
    // "*" used to be a display-time wildcard and names no real monitor; an old
    // config can still carry the key.
    if (monitor === "" || monitor === "*") continue
    result.push({ description: String(monitor), workspaces: workspaceIds(profile, monitor) })
  }

  result.sort(function(left, right) { return left.description.localeCompare(right.description) })
  return result
}

// Gives a monitor its slots before it is ever connected — the panel's way of
// adding a preset. A description already assigned is left untouched.
function addMonitorPreset(config, profileId, monitorDescription) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  var monitor = String(monitorDescription || "").trim()
  if (index < 0 || monitor === "") return next

  var profile = next.profiles[index]
  var assignments = copy(asObject(profile.assignments))
  if (Object.prototype.hasOwnProperty.call(assignments, monitor)) return next

  var slots = []
  for (var slot = 1; slot <= fallbackPerMonitor(profile); slot++) slots.push(slot)

  assignments[monitor] = slots
  profile.assignments = assignments
  return next
}

// Drops a monitor's saved slots and names from a profile — the panel's way of
// clearing out a screen that is not coming back.
function forgetMonitor(config, profileId, monitorDescription) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  var monitor = String(monitorDescription || "")
  if (index < 0 || monitor === "") return next

  var profile = next.profiles[index]
  var assignments = copy(asObject(profile.assignments))
  if (!Object.prototype.hasOwnProperty.call(assignments, monitor)) return next

  delete assignments[monitor]
  profile.assignments = assignments

  var labels = copy(asObject(profile.labels))
  delete labels[monitor]
  profile.labels = labels
  return next
}

function withLabel(next, index, monitor, slot, label) {
  var labels = copy(asObject(next.profiles[index].labels))
  var own = asObject(labels[monitor])
  var key = String(Number(slot))
  var value = String(label || "").trim()

  if (value === "") delete own[key]
  else own[key] = value

  if (Object.keys(own).length > 0) labels[monitor] = own
  else delete labels[monitor]

  next.profiles[index].labels = labels
  return next
}

function setWorkspaceLabel(config, profileId, monitorDescription, slot, label) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  var monitor = String(monitorDescription || "")
  if (index < 0 || monitor === "") return next
  return withLabel(next, index, monitor, slot, label)
}

function setDivider(config, profileId, divider) {
  var next = copy(normalizedConfig(config))
  var index = profileIndex(next, profileId)
  if (index < 0) return next

  next.profiles[index].divider = String(divider === undefined || divider === null ? "" : divider)
  return next
}

// The lowest slot this monitor does not show yet, or 0 once it shows all ten.
function nextSlot(profile, monitorDescription) {
  var slots = workspaceIds(profile, monitorDescription)
  for (var slot = 1; slot <= slotsPerMonitor; slot++) {
    if (slots.indexOf(slot) < 0) return slot
  }
  return 0
}

// Workspaces a monitor has to show that its group does not list, so nothing is
// ever out of reach: the ones holding windows, which is also what an unplugged
// screen leaves behind, and the one in view, because SUPER + N goes to any of a
// monitor's ten slots whether the profile lists it or not. `live` is
// [{ id, monitor, windows, active }] read from the compositor; `groups` is
// [{ name, block, workspaces: [{ id }] }]. A workspace from this monitor's own
// block carries its slot; one visiting from another block gets slot 0.
function strandedWorkspaces(groups, live) {
  var assigned = {}
  var blocks = {}
  var groupList = asArray(groups)
  for (var g = 0; g < groupList.length; g++) {
    blocks[groupList[g].name] = groupList[g].block
    var ids = asArray(groupList[g].workspaces)
    for (var w = 0; w < ids.length; w++) assigned[Number(ids[w].id)] = true
  }

  var result = []
  var entries = asArray(live)
  for (var i = 0; i < entries.length; i++) {
    var entry = asObject(entries[i])
    var id = Number(entry.id)
    var wanted = Number(entry.windows) > 0 || entry.active === true
    // Special workspaces carry negative ids and are not part of any layout.
    if (!(id > 0) || !wanted || assigned[id]) continue

    var monitor = String(entry.monitor || "")
    var own = blocks[monitor] === blockOf(id)
    var slot = own ? (id - 1) % slotsPerMonitor + 1 : 0
    result.push({ id: id, monitor: monitor, slot: slot, number: own ? slotNumber(slot) : String(id) })
  }

  result.sort(function(left, right) { return left.id - right.id })
  return result
}


// `labels`/`divider` carry over from the profile the layout was captured from.
// Labels are filtered to the slots that survived into `assignments`.
function addExactProfile(config, id, name, descriptions, assignments, labels, divider) {
  var next = copy(normalizedConfig(config))
  var finalAssignments = copy(asObject(assignments))
  var sourceLabels = asObject(labels)
  var finalLabels = {}

  for (var monitor in finalAssignments) {
    var own = asObject(sourceLabels[monitor])
    var values = asArray(finalAssignments[monitor])
    for (var i = 0; i < values.length; i++) {
      var key = String(values[i])
      if (own[key] === undefined) continue
      if (!finalLabels[monitor]) finalLabels[monitor] = {}
      finalLabels[monitor][key] = own[key]
    }
  }

  next.profiles.unshift({
    id: String(id),
    name: String(name || "Current monitor setup"),
    match: { mode: "exact", monitors: uniqueStrings(descriptions) },
    assignments: finalAssignments,
    labels: finalLabels,
    divider: String(divider === undefined || divider === null ? "|" : divider)
  })
  return next
}
