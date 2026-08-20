# Working on this plugin

An Omarchy (Quickshell) bar plugin that assigns workspaces to monitors per
profile, and hands the result to Hyprland as a generated Lua module. The README
explains what it does for a user; this file is the things that have bitten
someone working on it.

## Layout

| File | Role |
| --- | --- |
| `ProfileLogic.js` | All the logic, pure and testable: profile matching, the fallback allocation, and the Lua the plugin generates. `.pragma library`, so no QML types in here. |
| `Service.qml` | One instance per shell. Owns `config.json`, writes `rules.lua`, reloads Hyprland, exposes IPC. |
| `BarWidget.qml` | Loads `ControlWidget` or `WorkspaceWidget` depending on the widget's `mode` setting. |
| `ControlWidget.qml` | The panel: monitor cards, drag and drop, labels. |
| `WorkspaceWidget.qml` | The chips on the bar. |
| `tests/profile-logic.test.mjs` | Runs `ProfileLogic.js` in a `vm` context. |

## Running things

Tests are a plain script, not a runner — `node tests/profile-logic.test.mjs`.
It asserts as it goes and prints a line per section; a failure is an uncaught
`AssertionError`.

Live state without opening the panel:

```bash
qs ipc call minisiowo.dynamic-workspaces.service status   # active profile, monitors, groups
qs ipc call minisiowo.dynamic-workspaces.service preview  # the rules as they would be written
qs log -t 100 /run/user/1000/quickshell/by-id/*/log.qslog # add -r '*=true' for everything
hyprctl -j workspacerules                                 # what Hyprland actually ended up with
```

## The plugin directory is a symlink, so hot reload does not fire

`~/.config/omarchy/plugins/minisiowo.dynamic-workspaces` points at this repo.
Omarchy watches that directory with `inotifywait -r`, which does not descend
into symlinks, so **editing files here produces no "Local plugin changed"
reload**. `qs ipc call shell rescanPlugins` is not enough either: it calls
`Qt.clearComponentCache()`, which does not drop `.pragma library` JavaScript, so
a changed `ProfileLogic.js` keeps running from cache. Use
`omarchy-restart-shell` after touching it, and verify against `rules.lua` on
disk rather than assuming the change is live.

## Contracts that are easy to break

**Nothing in the generated module may touch `hl` before the guard.** Tools read
`hyprland.lua` outside the compositor with a placeholder `hl` whose every field
answers with itself — `omarchy-menu-keybindings`, behind SUPER+K, is the one
people press daily. Enumerating monitors against it never ends: that cost 27 GB
of RAM and 28 GB of swap before it was fixed. Prefer counted loops over
`ipairs()` for anything that comes back from the API.

**The guard must not contain the string `hl.workspace_rule`.**
`Service.writeRules()` searches for it to tell a module that claims rules from
one that claims nothing, and reloads Hyprland only when that answer changes. Put
it in the guard and installing the plugin reloads the compositor for an inert
stub.

**`renderRules()` must be a pure function of the config.** Writing it reloads
Hyprland, and `Service.writeRules()` skips that only when the text is byte-identical
to what is on disk. That is why `rulesProfile()` sorts its assignment keys —
reordering keys by hand must not rewrite the file.

**`normalizedConfig()` is the whole config schema.** It rewrites the config down
to the keys it names, so a section it does not list is silently dropped the next
time anything is saved. Adding a settings block means adding it there, next to
`applySettings()` and `appearanceSettings()`, not only where it is read.

**Display settings must not reach `renderRules()`.** The `appearance` block picks
how the bar marks the focused workspace; if any of it leaked into the rendered
Lua, choosing a focus mark would reload Hyprland. A test asserts the rendered
text is unchanged by it.

**The hook line lives in three places** and they have to agree: `Service.hookLine`,
`Service.parseHyprlandConfig()` which detects it, and the header comment
`renderRules()` writes into `rules.lua`. The plugin never edits anything under
`~/.config/hypr` — that line is the user's to add, so protection belongs in the
generated file instead.

**Live compositor state stays out of `Service.groups`.** Which workspace is
focused or occupied is read straight from `Hyprland` by each delegate. Folding it
into the model invalidates every chip in the bar and the panel on each focus
change, mid-drag included.

## Known bugs, not yet fixed

- The generated module syncs once, when Hyprland parses its config, and does not
  react afterwards. Plug in a second monitor and the rules stay on the profile
  that matched at parse time. The event names (`monitor.added`,
  `monitor.removed`, `monitor.layout_changed`) and `hl.timer` with
  `type = "oneshot"` are all valid in Hyprland 0.56.2, so the open question is
  whether handlers registered during parsing survive it.
- The "+" button on a monitor card does nothing: its `onClicked` in `component
  MonitorCard` (ControlWidget.qml) raises `ReferenceError: root is not defined`,
  because QML inline components cannot see ids declared outside the component.

## Commits

Subject lines say what changed and why in the same breath, imperative mood, no
prefix: "Resolve screens that share an EDID description as one monitor". The body
carries the reasoning — this repo's comments and messages are written for someone
who did not build it. Finished, verified work gets committed without being asked;
pushing is a separate decision.
