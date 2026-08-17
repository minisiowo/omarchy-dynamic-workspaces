import QtQuick
import Quickshell
import Quickshell.Io
import "ProfileLogic.js" as ProfileLogic

Item {
  id: root

  property var shell: null
  property bool configLoaded: false
  property string configError: ""
  property var config: fallbackConfig()
  property var activeMonitors: []
  property var activeWorkspaces: []

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
  readonly property string renderedRules: ProfileLogic.renderRules(config, { configPath: configPath })
  readonly property var monitorDescriptions: ProfileLogic.monitorDescriptions(activeMonitors)
  readonly property string monitorSignature: ProfileLogic.signature(monitorDescriptions)
  readonly property var activeProfile: ProfileLogic.activeProfile(config, monitorDescriptions)
  readonly property string activeProfileId: activeProfile ? String(activeProfile.id || "") : ""
  readonly property string activeProfileName: ProfileLogic.profileName(activeProfile)
  readonly property string activeProfileMode: activeProfile && activeProfile.match ? String(activeProfile.match.mode || "") : ""
  readonly property string activeDivider: activeProfile ? String(activeProfile.divider === undefined ? "|" : activeProfile.divider) : "|"
  readonly property var groups: buildGroups()

  visible: false
  width: 0
  height: 0

  function fallbackConfig() {
    return {
      version: 1,
      apply: { enabled: false, persistent: true, debounceMs: 1200 },
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

  function moveWorkspaceAt(workspaceId, monitorDescription, targetIndex) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.moveWorkspaceAt(root.config, root.activeProfileId, workspaceId, monitorDescription, targetIndex))
  }

  function moveWorkspace(workspaceId, monitorDescription) {
    moveWorkspaceAt(workspaceId, monitorDescription, undefined)
  }

  function addWorkspace(monitorDescription) {
    if (!root.activeProfile) return 0
    var workspaceId = ProfileLogic.nextWorkspaceId(root.activeProfile)
    moveWorkspace(workspaceId, monitorDescription)
    return workspaceId
  }

  function removeWorkspace(workspaceId) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.removeWorkspace(root.config, root.activeProfileId, workspaceId))
  }

  function setWorkspaceLabel(workspaceId, label) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.setWorkspaceLabel(root.config, root.activeProfileId, workspaceId, label))
  }

  function setDivider(divider) {
    if (root.activeProfileId === "") return
    applyConfig(ProfileLogic.setDivider(root.config, root.activeProfileId, divider))
  }

  function assignmentsFromCurrentWorkspaces() {
    var assignments = {}
    var monitorNames = {}

    for (var monitorIndex = 0; monitorIndex < root.activeMonitors.length; monitorIndex++) {
      var monitor = root.activeMonitors[monitorIndex]
      if (!monitor) continue
      var description = String(monitor.description || monitor.name || "")
      assignments[description] = []
      monitorNames[String(monitor.name || "")] = description
    }

    for (var workspaceIndex = 0; workspaceIndex < root.activeWorkspaces.length; workspaceIndex++) {
      var workspace = root.activeWorkspaces[workspaceIndex]
      if (!workspace || Number(workspace.id) <= 0) continue
      var target = monitorNames[String(workspace.monitor || "")]
      if (target && assignments[target]) assignments[target].push(Number(workspace.id))
    }

    for (var descriptionKey in assignments)
      assignments[descriptionKey].sort(function(left, right) { return left - right })

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
      assignmentsFromCurrentWorkspaces()
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

    rulesFile.setText(root.renderedRules)
    root.lastWrittenRules = root.renderedRules
    reloadHyprland()
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

  function parseHyprlandConfig(text) {
    root.hookInstalled = String(text || "").indexOf("dynamic-workspaces/rules.lua") !== -1
  }

  function parseMonitorData(raw) {
    try {
      var parsed = JSON.parse(String(raw || "[]"))
      root.activeMonitors = Array.isArray(parsed) ? parsed : []
    } catch (error) {
      console.warn("dynamic-workspaces: monitor query failed:", String(error))
    }
  }

  function parseWorkspaceData(raw) {
    try {
      var parsed = JSON.parse(String(raw || "[]"))
      root.activeWorkspaces = Array.isArray(parsed) ? parsed : []
    } catch (error) {
      console.warn("dynamic-workspaces: workspace query failed:", String(error))
    }
  }

  function workspaceById(id) {
    var values = root.activeWorkspaces
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].id === id) return values[i]
    }
    return null
  }

  function workspaceFocused(id) {
    var monitors = root.activeMonitors
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i] && monitors[i].activeWorkspace && monitors[i].activeWorkspace.id === id) return true
    }
    return false
  }

  function buildGroups() {
    var monitors = []
    var values = root.activeMonitors
    for (var i = 0; i < values.length; i++) {
      if (values[i]) monitors.push(values[i])
    }

    monitors.sort(function(left, right) {
      var leftX = Number(left.x || 0)
      var rightX = Number(right.x || 0)
      if (leftX !== rightX) return leftX - rightX
      return Number(left.y || 0) - Number(right.y || 0)
    })

    var result = []
    for (var monitorIndex = 0; monitorIndex < monitors.length; monitorIndex++) {
      var monitor = monitors[monitorIndex]
      var description = String(monitor.description || monitor.name || "")
      var ids = ProfileLogic.workspaceIds(root.activeProfile, description)
      var workspaces = []

      for (var workspaceIndex = 0; workspaceIndex < ids.length; workspaceIndex++) {
        var id = ids[workspaceIndex]
        var workspace = root.workspaceById(id)
        workspaces.push({
          id: id,
          label: ProfileLogic.workspaceLabel(root.activeProfile, id),
          occupied: workspace !== null && Number(workspace.windows || 0) > 0,
          focused: root.workspaceFocused(id)
        })
      }

      result.push({
        name: String(monitor.name || "Unknown monitor"),
        description: description,
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
    id: monitorQuery
    command: ["hyprctl", "-j", "monitors"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseMonitorData(text)
    }
  }

  Process {
    id: workspaceQuery
    command: ["hyprctl", "-j", "workspaces"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseWorkspaceData(text)
    }
  }

  Timer {
    interval: 1500
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (!monitorQuery.running) monitorQuery.running = true
      if (!workspaceQuery.running) workspaceQuery.running = true
    }
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

    onExited: function(exitCode) {
      if (exitCode !== 0 && root.applyError === "")
        root.applyError = "hyprctl reload failed with exit code " + exitCode
      if (exitCode === 0 && root.applyError === "") root.appliedAt = Date.now()
      if (root.reloadPending) {
        root.reloadPending = false
        root.reloadHyprland()
      }
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
    target: "minisiowo.dynamic-workspaces.service"

    function status(): string {
      return JSON.stringify({
        profile: root.activeProfileName,
        signature: root.monitorSignature,
        monitors: root.monitorDescriptions,
        configLoaded: root.configLoaded,
        configError: root.configError,
        editable: true,
        apply: root.applySettings,
        hookInstalled: root.hookInstalled,
        rulesPath: root.rulesPath,
        applyError: root.applyError,
        groups: root.groups
      })
    }

    // The rules exactly as they would be written, so what Hyprland is asked to
    // do can be read before anything is applied.
    function preview(): string {
      return root.renderedRules
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
