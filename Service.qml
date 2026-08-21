import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
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

  property string applyError: ""
  property bool reloadPending: false
  property string lastWrittenRules: ""
  property bool rulesLoaded: false
  property double appliedAt: 0

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy/dynamic-workspaces"
  readonly property string configPath: configDir + "/config.json"
  readonly property string rulesPath: configDir + "/rules.lua"
  readonly property string hyprlandConfigPath: home + "/.config/hypr/hyprland.lua"
  readonly property string hookLine: "pcall(dofile, os.getenv(\"HOME\") .. \"/.config/omarchy/dynamic-workspaces/rules.lua\")"

  // Hyprland only runs the generated module if the user's own config loads it.
  // Adding that line is the one manual step, and it is theirs to make — the
  // plugin never edits anything under ~/.config/hypr.
  property bool hookInstalled: false

  readonly property var applySettings: ProfileLogic.applySettings(config)
  readonly property bool applyEnabled: applySettings.enabled
  // The character the bar paints in place of the focused workspace's number,
  // empty for none. Read straight off the config so a change reaches every bar
  // on every screen the moment it is saved.
  readonly property var appearance: ProfileLogic.appearanceSettings(config)
  readonly property string focusMark: appearance.focusMark
  readonly property string defaultFocusMark: ProfileLogic.defaultFocusMark()
  readonly property string renderedRules: ProfileLogic.renderRules(config, { configPath: configPath })
  readonly property var monitorDescriptions: ProfileLogic.monitorDescriptions(activeMonitors)
  readonly property string monitorSignature: ProfileLogic.signature(monitorDescriptions)
  readonly property var activeProfile: ProfileLogic.activeProfile(config, monitorDescriptions)
  readonly property string activeProfileId: activeProfile ? String(activeProfile.id || "") : ""
  readonly property string activeProfileName: ProfileLogic.profileName(activeProfile)
  readonly property string activeProfileMode: activeProfile && activeProfile.match ? String(activeProfile.match.mode || "") : ""
  readonly property string activeDivider: activeProfile ? String(activeProfile.divider === undefined ? "|" : activeProfile.divider) : "|"
  readonly property var groups: buildGroups()
  // The bar draws a divider between groups, so it needs two of them to draw one
  // at all. The panel hides the setting on the same test.
  readonly property int populatedGroupCount: {
    var count = 0
    for (var i = 0; i < groups.length; i++) {
      if (groups[i] && groups[i].workspaces.length > 0) count++
    }
    return count
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
      apply: { enabled: false, persistent: true, debounceMs: 1200 },
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

  function moveWorkspaceAt(workspaceId, monitorDescription, targetIndex) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.moveWorkspaceAt(root.editableConfig(), root.activeProfileId, workspaceId, monitorDescription, targetIndex))
  }

  function moveWorkspace(workspaceId, monitorDescription) {
    moveWorkspaceAt(workspaceId, monitorDescription, undefined)
  }

  // The next free id has to be read from the materialized profile: on the
  // default profile the visible workspaces are allocated, not assigned, so
  // asking the stored assignments would hand back an id already on screen.
  function addWorkspace(monitorDescription) {
    if (!root.activeProfile) return 0

    var next = root.editableConfig()
    var index = ProfileLogic.profileIndex(next, root.activeProfileId)
    if (index < 0) return 0

    // Applied to the same materialized config the id was read from, rather than
    // going back through moveWorkspace() and materializing a second time.
    var workspaceId = ProfileLogic.nextWorkspaceId(next.profiles[index])
    applyConfig(ProfileLogic.moveWorkspaceAt(next, root.activeProfileId, workspaceId, monitorDescription, undefined))
    return workspaceId
  }

  function removeWorkspace(workspaceId) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.removeWorkspace(root.editableConfig(), root.activeProfileId, workspaceId))
  }

  function setWorkspaceLabel(workspaceId, label) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.setWorkspaceLabel(root.editableConfig(), root.activeProfileId, workspaceId, label))
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

  // Saves what the panel is showing, not where Hyprland currently happens to
  // put things. The two agree once Apply is on, because the module has already
  // imposed the layout — but Apply is off by default, and then the panel shows
  // the allocation while the compositor still follows the user's own config.
  // Saving the visible layout is what makes the button predictable: you get
  // what you were looking at.
  function assignmentsFromGroups() {
    var assignments = {}
    var groups = root.groups

    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      var group = groups[groupIndex]
      var ids = []

      for (var workspaceIndex = 0; workspaceIndex < group.workspaces.length; workspaceIndex++)
        ids.push(Number(group.workspaces[workspaceIndex].id))

      // Screens sharing an EDID description resolve to one group, so the
      // second one would only rewrite the first with the same ids.
      if (assignments[group.description] === undefined) assignments[group.description] = ids
    }

    return assignments
  }

  function saveCurrentSetup(name) {
    if (root.activeProfileMode === "exact" || root.monitorDescriptions.length === 0) return false
    var profileId = "setup-" + Date.now()
    var next = ProfileLogic.addExactProfile(
      root.config,
      profileId,
      String(name || "Current monitor setup"),
      root.monitorDescriptions,
      assignmentsFromGroups()
    )
    applyConfig(next)
    return true
  }

  function flushConfig() {
    configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  function setApply(enabled) {
    applyConfig(ProfileLogic.withApplySettings(root.config, { enabled: enabled === true }))
  }

  // The generated module is the only thing the plugin hands to Hyprland, and
  // it is written whenever the profiles or the apply settings change. Writing
  // is cheap and idempotent; the reload that follows is not, so it only runs
  // when the rendered text actually differs from what is already on disk.
  function writeRules() {
    if (!root.configLoaded || !root.rulesLoaded) return
    if (root.renderedRules === root.lastWrittenRules) return

    // Reload only when the module has something to say or has just stopped
    // saying it. A first run with Apply off writes an inert stub, and
    // reloading Hyprland for that would be a side effect of merely installing
    // the plugin.
    var claimedBefore = root.lastWrittenRules.indexOf("hl.workspace_rule") !== -1
    var needsReload = root.applyEnabled || claimedBefore

    rulesFile.setText(root.renderedRules)
    root.lastWrittenRules = root.renderedRules
    if (needsReload) reloadHyprland()
  }

  // `config-only` keeps Hyprland from re-applying monitor configuration, which
  // this plugin has no business touching — only the workspace rules in the
  // regenerated module need to be picked up.
  function reloadHyprland() {
    if (reloadProcess.running) {
      root.reloadPending = true
      return
    }
    root.applyError = ""
    reloadProcess.running = true
  }

  // Line by line, with each line cut at its comment marker: a commented-out
  // hook is exactly the state the panel most needs to report, and a plain
  // substring search over the file would read it as installed and hide the very
  // line that is missing. Cutting rather than skipping also catches a hook
  // commented out behind live code on the same line.
  function parseHyprlandConfig(text) {
    var lines = String(text || "").split("\n")

    for (var i = 0; i < lines.length; i++) {
      var comment = lines[i].indexOf("--")
      var code = comment === -1 ? lines[i] : lines[i].slice(0, comment)

      if (code.indexOf("dynamic-workspaces/rules.lua") !== -1) {
        root.hookInstalled = true
        return
      }
    }

    root.hookInstalled = false
  }

  // Monitor descriptions in the order the groups are laid out, which is what
  // the fallback allocation is computed against.
  function orderedDescriptions() {
    var groups = root.groups
    var result = []
    for (var i = 0; i < groups.length; i++) result.push(groups[i].description)
    return result
  }

  // Only what the profile decides: which workspaces belong to which monitor,
  // and what they are called. Whether a workspace is occupied or focused is
  // live compositor state, and the views read that straight from Hyprland —
  // folding it in here would invalidate this whole model, and with it every
  // delegate in the bar and the panel, on each focus change.
  function buildGroups() {
    var monitors = []
    var values = root.activeMonitors
    for (var i = 0; i < values.length; i++) {
      if (values[i]) monitors.push(values[i])
    }

    // Same order the generated module sorts by, so the ids the bar shows for an
    // unrecognised monitor are the ids Hyprland assigns it.
    monitors.sort(function(left, right) {
      var leftX = Number(left.x || 0)
      var rightX = Number(right.x || 0)
      if (leftX !== rightX) return leftX - rightX

      var leftY = Number(left.y || 0)
      var rightY = Number(right.y || 0)
      if (leftY !== rightY) return leftY - rightY

      return String(left.name || "").localeCompare(String(right.name || ""))
    })

    var descriptions = []
    for (var descriptionIndex = 0; descriptionIndex < monitors.length; descriptionIndex++) {
      var current = monitors[descriptionIndex]
      descriptions.push(String(current.description || current.name || ""))
    }

    var groups = ProfileLogic.resolveGroups(root.activeProfile, descriptions)
    var result = []

    for (var monitorIndex = 0; monitorIndex < monitors.length; monitorIndex++) {
      var monitor = monitors[monitorIndex]
      var group = groups[monitorIndex]
      var ids = group ? group.workspaces : []
      var workspaces = []

      for (var workspaceIndex = 0; workspaceIndex < ids.length; workspaceIndex++) {
        var id = ids[workspaceIndex]
        workspaces.push({
          id: id,
          label: ProfileLogic.workspaceLabel(root.activeProfile, id)
        })
      }

      result.push({
        name: String(monitor.name || "Unknown monitor"),
        description: descriptions[monitorIndex],
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

  Process {
    id: reloadProcess
    command: ["hyprctl", "reload", "config-only"]
    running: false

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.applyError = message
      }
    }

    // Deferred: stderr is collected on its own signal, and its ordering
    // against onExited is not guaranteed, so deciding success here would
    // sometimes stamp a time onto a run that turns out to have failed.
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.applyError === "")
        root.applyError = "hyprctl reload failed with exit code " + exitCode

      Qt.callLater(function() {
        if (root.applyError === "") root.appliedAt = Date.now()
        if (root.reloadPending) {
          root.reloadPending = false
          root.reloadHyprland()
        }
      })
    }
  }

  Timer {
    id: configSaveTimer
    interval: 180
    repeat: false
    onTriggered: root.flushConfig()
  }

  // Profile edits arrive one drag or keystroke at a time; settling first means
  // one file write and one reload per burst instead of one per change.
  Timer {
    id: rulesWriteTimer
    interval: 250
    repeat: false
    onTriggered: root.writeRules()
  }

  // Rules are a pure function of the config, so one binding covers every reason
  // they can change: a drag in the panel, the apply toggle, or a hand edit of
  // config.json picked up by the file watcher.
  onRenderedRulesChanged: rulesWriteTimer.restart()
  onConfigLoadedChanged: rulesWriteTimer.restart()
  onRulesLoadedChanged: rulesWriteTimer.restart()

  FileView {
    id: rulesFile
    path: root.rulesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false

    // The current contents are the baseline for "did anything change": a shell
    // restart with an untouched config must not reload Hyprland.
    onLoaded: {
      root.lastWrittenRules = text()
      root.rulesLoaded = true
    }
    onLoadFailed: {
      root.lastWrittenRules = ""
      root.rulesLoaded = true
    }
  }

  // Read-only: the panel needs to know whether the user's Hyprland config loads
  // the generated module, so it can show the one line that is still missing.
  FileView {
    id: hyprlandConfigFile
    path: root.hyprlandConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseHyprlandConfig(text())
    onLoadFailed: root.parseHyprlandConfig("")
    onFileChanged: reload()
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
        editable: true,
        apply: root.applySettings,
        appearance: root.appearance,
        hookInstalled: root.hookInstalled,
        rulesPath: root.rulesPath,
        appliedAt: root.appliedAt,
        applyError: root.applyError,
        groups: root.groups
      })
    }

    // The rules exactly as they would be written, so what Hyprland is asked to
    // do can be read before anything is applied.
    function preview(): string {
      return root.renderedRules
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

    function setApply(enabled: string): string {
      root.setApply(String(enabled) === "true" || String(enabled) === "1")
      return root.applyEnabled ? "enabled" : "disabled"
    }

    function move(workspaceId: string, monitorDescription: string): string {
      root.moveWorkspace(Number(workspaceId), monitorDescription)
      return "ok"
    }

    function moveAt(workspaceId: string, monitorDescription: string, targetIndex: string): string {
      root.moveWorkspaceAt(Number(workspaceId), monitorDescription, Number(targetIndex))
      return "ok"
    }

    function setLabel(workspaceId: string, label: string): string {
      root.setWorkspaceLabel(Number(workspaceId), label)
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
    ensureConfigDir.running = true
    Qt.callLater(function() { configFile.reload() })
  }
}
