import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "ProfileLogic.js" as ProfileLogic

Item {
  id: root

  property var shell: null
  property bool configLoaded: false
  property string configError: ""
  property var config: fallbackConfig()

  // Plain snapshots of the compositor's monitor list rather than the live
  // HyprlandMonitor objects: everything downstream only needs identity and
  // position, and copying them keeps this list changing when monitors change
  // instead of whenever anything on a monitor does.
  readonly property var activeMonitors: {
    var result = []
    var values = Hyprland.monitors.values

    for (var i = 0; i < values.length; i++) {
      var monitor = values[i]
      if (!monitor) continue
      result.push({
        name: String(monitor.name || ""),
        description: String(monitor.description || ""),
        x: Number(monitor.x || 0),
        y: Number(monitor.y || 0)
      })
    }

    return result
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy/dynamic-workspaces"
  readonly property string configPath: configDir + "/config.json"
  // Which block of ten workspaces Omarchy gave each connected monitor, by
  // connector. Omarchy owns this and the plugin only reads it.
  property var monitorBlocks: ({})

  // The character the bar paints in place of the focused workspace's number,
  // empty for none. Read straight off the config so a change reaches every bar
  // on every screen the moment it is saved.
  readonly property var appearance: ProfileLogic.appearanceSettings(config)
  readonly property string focusMark: appearance.focusMark
  readonly property string defaultFocusMark: ProfileLogic.defaultFocusMark()
  readonly property var monitorDescriptions: ProfileLogic.monitorDescriptions(activeMonitors)
  readonly property string monitorSignature: ProfileLogic.signature(monitorDescriptions)
  readonly property var activeProfile: ProfileLogic.activeProfile(config, monitorDescriptions)
  readonly property string activeProfileId: activeProfile ? String(activeProfile.id || "") : ""
  readonly property string activeProfileName: ProfileLogic.profileName(activeProfile)
  readonly property string activeProfileMode: activeProfile && activeProfile.match ? String(activeProfile.match.mode || "") : ""
  readonly property string activeDivider: activeProfile ? String(activeProfile.divider === undefined ? "|" : activeProfile.divider) : "|"
  readonly property var groups: buildGroups()

  // Which workspaces exist, how many windows each holds, and which are in view,
  // as plain values. Deliberately not part of `groups`: that model must not
  // change with live compositor state, or every chip is rebuilt whenever a
  // window opens.
  readonly property var liveWorkspaces: {
    var result = []
    var values = Hyprland.workspaces.values
    var inView = {}
    var monitors = Hyprland.monitors.values

    for (var m = 0; m < monitors.length; m++) {
      if (monitors[m] && monitors[m].activeWorkspace) inView[monitors[m].activeWorkspace.id] = true
    }

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (!workspace) continue
      result.push({
        id: Number(workspace.id),
        monitor: workspace.monitor ? String(workspace.monitor.name || "") : "",
        windows: workspace.toplevels ? workspace.toplevels.values.length : 0,
        active: inView[workspace.id] === true
      })
    }

    return result
  }

  // Workspaces a screen has to show although the active profile does not list
  // them: see ProfileLogic.strandedWorkspaces(). The saved profile is untouched.
  //
  // Copied into a plain property only when the answer differs. The candidate
  // is recomputed whenever a window opens or closes anywhere, and handing the
  // bar a fresh array each time would rebuild every chip on it.
  property var strandedWorkspaces: []
  readonly property var strandedCandidate: ProfileLogic.strandedWorkspaces(groups, liveWorkspaces)

  function refreshStranded() {
    if (JSON.stringify(strandedCandidate) !== JSON.stringify(strandedWorkspaces))
      strandedWorkspaces = strandedCandidate
  }

  onStrandedCandidateChanged: refreshStranded()
  // The bar draws a divider between groups, so it needs two of them to draw one
  // at all. The panel hides the setting on the same test.
  readonly property int populatedGroupCount: {
    var count = 0
    for (var i = 0; i < groups.length; i++) {
      if (groups[i] && groups[i].workspaces.length > 0) count++
    }
    return count
  }
  // Every profile in the config, by name — what a "PROFILES" section lists
  // and offers to delete. Includes the default profile alongside every named
  // exact one.
  readonly property var savedProfiles: ProfileLogic.savedProfiles(root.config)

  // Every monitor the default profile has a saved layout for, connected or
  // not — the panel's preset list. Deliberately the default profile always,
  // not root.activeProfile: presets belong to the fallback, and reading
  // whichever profile is active would show (and let you edit) an exact
  // profile's real, in-use assignments instead. `connected` just decorates
  // each entry for display; it plays no part in which ones are offered.
  readonly property var monitorPresets: {
    var connected = root.monitorDescriptions
    var stored = ProfileLogic.storedMonitors(ProfileLogic.defaultProfile(root.config))
    var result = []
    for (var i = 0; i < stored.length; i++) {
      result.push({
        description: stored[i].description,
        workspaces: stored[i].workspaces,
        connected: connected.indexOf(stored[i].description) >= 0
      })
    }
    return result
  }

  // The tiling layout of the workspace the keyboard is on, which the bar shows on
  // that workspace's chip. Read through Omarchy's own command, the one its layout
  // toggle keeps honest, rather than guessing from Hyprland's fields.
  property string focusedLayout: "dwindle"
  property bool layoutStale: false
  readonly property int focusedWorkspaceId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1

  onFocusedWorkspaceIdChanged: readLayout()

  function readLayout() {
    if (root.focusedWorkspaceId <= 0) return
    if (layoutProcess.running) {
      root.layoutStale = true
      return
    }
    layoutProcess.workspaceId = root.focusedWorkspaceId
    layoutProcess.command = ["omarchy-hyprland-workspace-layout-current", String(root.focusedWorkspaceId)]
    layoutProcess.running = true
  }

  // Panel open/close arrives here rather than at the bar widget. A widget-level
  // IPC target is claimed by whichever instance registers first, and the bar
  // assigns widget settings twice — an empty object, then the real entry — so a
  // Workspaces-mode slot briefly instantiates a ControlWidget that can win the
  // target and then be destroyed, leaving the route pointing at nothing. The
  // service is one object per shell, so its target is unambiguous; it names the
  // action and lets the panels decide which of them is on screen.
  signal panelRequested(string action)

  visible: false
  width: 0
  height: 0

  function fallbackConfig() {
    return {
      version: 1,
      appearance: { focusMark: "" },
      profiles: [{
        id: "default",
        name: "Default",
        match: { mode: "default" },
        assignments: {},
        labels: {},
        divider: "|"
      }]
    }
  }

  function loadConfig(raw) {
    var text = String(raw || "").trim()
    if (text === "") {
      root.config = fallbackConfig()
      root.configError = ""
      root.configLoaded = true
      return
    }

    try {
      root.config = ProfileLogic.normalizedConfig(JSON.parse(text))
      root.configError = ""
    } catch (error) {
      root.config = fallbackConfig()
      root.configError = String(error)
      console.warn("dynamic-workspaces: invalid config:", root.configError)
    }

    root.configLoaded = true
  }

  function applyConfig(nextConfig) {
    root.config = ProfileLogic.normalizedConfig(nextConfig)
    root.configError = ""
    configSaveTimer.restart()
  }

  // Every edit goes through here first. On the default profile the layout on
  // screen is allocated rather than stored, so it is written down before the
  // edit lands — otherwise the edit would be applied to assignments that do
  // not yet describe what the user is looking at.
  function editableConfig() {
    if (root.activeProfileMode !== "default") return root.config
    return ProfileLogic.materializeFallback(root.config, root.activeProfileId, root.orderedDescriptions())
  }

  function moveSlot(monitorDescription, slot, targetIndex) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.placeSlot(root.editableConfig(), root.activeProfileId, monitorDescription, slot, targetIndex))
  }

  // Returns the slot it added, or 0 when the monitor already shows all ten.
  function addSlot(monitorDescription) {
    if (!root.activeProfile) return 0

    var next = root.editableConfig()
    var index = ProfileLogic.profileIndex(next, root.activeProfileId)
    if (index < 0) return 0

    var slot = ProfileLogic.nextSlot(next.profiles[index], monitorDescription)
    if (slot === 0) return 0

    applyConfig(ProfileLogic.placeSlot(next, root.activeProfileId, monitorDescription, slot, undefined))
    return slot
  }

  function removeSlot(monitorDescription, slot) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.removeSlot(root.editableConfig(), root.activeProfileId, monitorDescription, slot))
  }

  // Always the default profile, never root.activeProfileId — see
  // monitorPresets above. Deliberately not through editableConfig() either:
  // the entry being forgotten is already explicit, so there is nothing to
  // materialize first, and editableConfig() only ever materializes the
  // active profile, which need not be the default one this targets.
  function forgetMonitor(monitorDescription) {
    var profile = ProfileLogic.defaultProfile(root.config)
    if (!profile) return
    applyConfig(ProfileLogic.forgetMonitor(root.config, profile.id, monitorDescription))
  }

  // Returns whether a preset was actually added, so the panel knows whether to
  // clear its input field.
  function addMonitorPreset(monitorDescription) {
    var profile = ProfileLogic.defaultProfile(root.config)
    if (!profile) return false

    var trimmed = String(monitorDescription || "").trim()
    if (trimmed === "") return false
    if (Object.prototype.hasOwnProperty.call(profile.assignments || {}, trimmed)) return false

    applyConfig(ProfileLogic.addMonitorPreset(root.config, profile.id, trimmed))
    return true
  }

  function setWorkspaceLabel(monitorDescription, slot, label) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.setWorkspaceLabel(root.editableConfig(), root.activeProfileId, monitorDescription, slot, label))
  }

  function setDivider(divider) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.setDivider(root.config, root.activeProfileId, divider))
  }

  // Appearance is not part of any profile, so this goes through root.config
  // rather than editableConfig() — there is nothing about the layout to write
  // down first. Clearing the mark is how it is turned off, so an empty string
  // is a valid value rather than a no-op.
  function setFocusMark(mark) {
    applyConfig(ProfileLogic.withAppearance(root.config, { focusMark: mark }))
  }

  function removeProfile(profileId) {
    applyConfig(ProfileLogic.removeProfile(root.config, profileId))
  }

  function assignmentsFromGroups() {
    var assignments = {}
    var groups = root.groups

    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      var group = groups[groupIndex]
      var ids = []

      for (var workspaceIndex = 0; workspaceIndex < group.workspaces.length; workspaceIndex++)
        ids.push(Number(group.workspaces[workspaceIndex].slot))

      // Screens sharing an EDID description resolve to one group, so the
      // second one would only rewrite the first with the same ids.
      if (assignments[group.description] === undefined) assignments[group.description] = ids
    }

    return assignments
  }

  function saveCurrentSetup(name) {
    if (root.activeProfileMode === "exact" || root.monitorDescriptions.length === 0) return false
    var profileId = "setup-" + Date.now()
    // Labels and the divider come from the profile the layout is being
    // captured from — usually the default one — so "Save setup" keeps what
    // you named your workspaces and how you divided them, not just their ids.
    var next = ProfileLogic.addExactProfile(
      root.config,
      profileId,
      String(name || "Current monitor setup"),
      root.monitorDescriptions,
      assignmentsFromGroups(),
      root.activeProfile ? root.activeProfile.labels : {},
      root.activeProfile ? root.activeProfile.divider : "|"
    )
    applyConfig(next)
    return true
  }

  function flushConfig() {
    configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  // Connected monitors, sorted left to right by position, which is the order the
  // bar draws their groups in.
  function sortedConnectedMonitors() {
    var monitors = []
    var values = root.activeMonitors
    for (var i = 0; i < values.length; i++) {
      if (values[i]) monitors.push(values[i])
    }

    monitors.sort(function(left, right) {
      var leftX = Number(left.x || 0)
      var rightX = Number(right.x || 0)
      if (leftX !== rightX) return leftX - rightX

      var leftY = Number(left.y || 0)
      var rightY = Number(right.y || 0)
      if (leftY !== rightY) return leftY - rightY

      return String(left.name || "").localeCompare(String(right.name || ""))
    })

    return monitors
  }

  function connectedDescriptionsInOrder() {
    var monitors = sortedConnectedMonitors()
    var descriptions = []
    for (var i = 0; i < monitors.length; i++) {
      descriptions.push(String(monitors[i].description || monitors[i].name || ""))
    }
    return descriptions
  }

  // Monitor descriptions in the order the groups are laid out.
  function orderedDescriptions() {
    return connectedDescriptionsInOrder()
  }

  // Only what the profile decides: which slots each monitor shows and what they
  // are called, with the real id each one has in that monitor's block. Whether a workspace is occupied or focused is
  // live compositor state, and the views read that straight from Hyprland —
  // folding it in here would invalidate this whole model, and with it every
  // delegate in the bar and the panel, on each focus change.
  function buildGroups() {
    var monitors = sortedConnectedMonitors()
    var descriptions = connectedDescriptionsInOrder()

    var groups = ProfileLogic.resolveGroups(root.activeProfile, descriptions)
    var result = []

    for (var monitorIndex = 0; monitorIndex < monitors.length; monitorIndex++) {
      var monitor = monitors[monitorIndex]
      var group = groups[monitorIndex]
      var slots = group ? group.workspaces : []
      var description = descriptions[monitorIndex]
      // Omarchy writes a monitor's block before anything can land on it, so the
      // default only ever shows for the instant before its file has been read.
      var block = root.monitorBlocks[monitor.name] === undefined ? 0 : root.monitorBlocks[monitor.name]
      var workspaces = []

      for (var workspaceIndex = 0; workspaceIndex < slots.length; workspaceIndex++) {
        var slot = slots[workspaceIndex]
        workspaces.push({
          id: ProfileLogic.workspaceIdFor(block, slot),
          slot: slot,
          number: ProfileLogic.slotNumber(slot),
          label: ProfileLogic.workspaceLabel(root.activeProfile, description, slot)
        })
      }

      result.push({
        name: String(monitor.name || "Unknown monitor"),
        description: description,
        block: block,
        automatic: group ? group.automatic === true : false,
        shared: group ? group.shared === true : false,
        workspaces: workspaces
      })
    }

    return result
  }

  Process {
    id: ensureConfigDir
    command: ["mkdir", "-p", root.configDir]
    running: false
  }

  Timer {
    id: configSaveTimer
    interval: 180
    repeat: false
    onTriggered: root.flushConfig()
  }

  Process {
    id: layoutProcess
    property int workspaceId: -1

    stdout: StdioCollector {
      onStreamFinished: {
        var layout = text.trim()
        if (layout !== "" && layoutProcess.workspaceId === root.focusedWorkspaceId) root.focusedLayout = layout
      }
    }

    onExited: {
      if (!root.layoutStale) return
      root.layoutStale = false
      // Deferred: the process still reports running while it signals exit.
      Qt.callLater(root.readLayout)
    }
  }

  // Omarchy's layout commands announce a change on this target, which belongs to
  // its own workspace widget. With that widget off the bar, it arrives here.
  ShellIpc {
    target: "omarchy.workspaces"

    function refresh(): void { root.readLayout() }
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "configreloaded") root.readLayout()

      // Quickshell credits every workspace switch to the focused monitor and does
      // not learn that a workspace changed number, and Omarchy renumbers them when
      // a monitor comes or goes, so ask Hyprland for the truth.
      if (name === "workspacev2" || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
    }
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.monitorBlocks = ProfileLogic.parseBlocks(text())
    onLoadFailed: root.monitorBlocks = ({})
  }

  // Versions before 2.0 wrote workspace rules here, which fight Omarchy's own
  // per-monitor numbering. Once it is gone, a line left in hyprland.lua loads
  // nothing, through the pcall it was written with, and the running compositor
  // only needs one reload to let go of what it read.
  FileView {
    path: root.configDir + "/rules.lua"
    printErrors: false
    onLoaded: removeOldRules.running = true
  }

  Process {
    id: removeOldRules
    command: ["rm", "-f", root.configDir + "/rules.lua"]
    onExited: reloadWithoutOldRules.running = true
  }

  Process {
    id: reloadWithoutOldRules
    command: ["hyprctl", "reload", "config-only"]
  }

  IpcHandler {
    target: "io.github.minisiowo.dynamic-workspaces.service"

    function status(): string {
      return JSON.stringify({
        profile: root.activeProfileName,
        signature: root.monitorSignature,
        monitors: root.monitorDescriptions,
        configLoaded: root.configLoaded,
        configError: root.configError,
        appearance: root.appearance,
        blocks: root.monitorBlocks,
        groups: root.groups
      })
    }

    function open(): string {
      root.panelRequested("open")
      return "ok"
    }

    function close(): string {
      root.panelRequested("close")
      return "ok"
    }

    function toggle(): string {
      root.panelRequested("toggle")
      return "ok"
    }

    function setProfileDivider(divider: string): string {
      root.setDivider(divider)
      return "ok"
    }

    function setFocusMark(mark: string): string {
      root.setFocusMark(mark)
      return root.focusMark === "" ? "(none)" : root.focusMark
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
    onFileChanged: reload()
  }

  Component.onCompleted: {
    root.refreshStranded()
    root.readLayout()
    ensureConfigDir.running = true
    Qt.callLater(function() { configFile.reload() })
  }
}
