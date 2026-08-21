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

**Display settings must not reach `renderRules()`.** The `appearance` block holds
the character the bar paints on the focused workspace; if any of it leaked into
the rendered Lua, changing that character would reload Hyprland. A test asserts
the rendered text is unchanged by it.

**Qt's clipboard is dead on the panel's surface.** Text fields there can only be
typed into: Ctrl+V hands back nothing, which is why the rest of the Omarchy shell
shells out to `wl-copy` / `wl-paste` too. Every field in `ControlWidget.qml` routes
`StandardKey.Paste` through `root.pasteInto()`, which reads the clipboard with
`wl-paste`. A new field without that handler will silently refuse to paste.

**The hook line lives in three places** and they have to agree: `Service.hookLine`,
`Service.parseHyprlandConfig()` which detects it, and the header comment
`renderRules()` writes into `rules.lua`. The plugin never edits anything under
`~/.config/hypr` — that line is the user's to add, so protection belongs in the
generated file instead.

**Live compositor state stays out of `Service.groups`.** Which workspace is
focused or occupied is read straight from `Hyprland` by each delegate. Folding it
into the model invalidates every chip in the bar and the panel on each focus
change, mid-drag included.

## Verified against a live compositor

The generated module does react to monitors appearing and disappearing after
Hyprland has parsed its configuration. Handlers registered by `hl.on()` during
parsing survive it: adding a virtual screen with `hyprctl output create
headless` switched the active profile to the fallback allocation after the
debounce, and `hyprctl output remove HEADLESS-1` switched it back, each time
leaving the superseded rules present but `enabled: false`. `hyprctl -j
workspacerules` lists disabled rules too, so read the `enabled` field rather
than the presence of a rule. An earlier entry here recorded this as an open
question; it is not one.

That test also exposed a real bug, since fixed: a headless output reports an
empty description, and `desc:` matches by prefix, so the empty selector it
produced claimed every connected screen. `ordered_monitors()` in the generated
module now drops screens without a description, mirroring the guard
`rulesProfile()` already had. `tests/profile-logic.test.mjs` covers it by
running the generated Lua under a stand-in `hl` and reading back the rules it
built — the only place the JavaScript and Lua halves of the allocation are
compared on the same input.

(An earlier entry claimed the "+" button on a monitor card raises
`ReferenceError: root is not defined` because inline components cannot see ids
declared outside them. It does not, in this Qt: bindings inside `component
MonitorCard` read `root.panelForeground` and `root.panelDim` and paint correctly,
and adding a workspace through that button works. Removed rather than left to
send the next session chasing it.)

## Commits

Subject lines say what changed and why in the same breath, imperative mood, no
prefix: "Resolve screens that share an EDID description as one monitor". The body
carries the reasoning — this repo's comments and messages are written for someone
who did not build it. Finished, verified work gets committed without being asked;
pushing is a separate decision.
