# Working on this plugin

An Omarchy (Quickshell) bar plugin that stands in for `omarchy.workspaces` and
remembers, per set of monitors, which workspaces each screen shows and what they
are called. It only draws: Omarchy owns the numbering. The README explains what it
does for a user; this file is the things that have bitten someone working on it.

## Layout

| File | Role |
| --- | --- |
| `ProfileLogic.js` | All the logic, pure and testable: profile matching, slots, labels, and the mapping onto Omarchy's blocks. `.pragma library`, so no QML types in here. |
| `Service.qml` | One instance per shell. Owns `config.json`, reads Omarchy's block file and the focused layout, exposes IPC. |
| `BarWidget.qml` | The one bar entry: `WorkspaceWidget` followed by `ControlWidget`. |
| `ControlWidget.qml` | The panel: monitor cards, drag and drop, labels. |
| `WorkspaceWidget.qml` | The chips on the bar. |
| `tests/profile-logic.test.mjs` | Runs `ProfileLogic.js` in a `vm` context. |

## Running things

Tests are a plain script, not a runner — `node tests/profile-logic.test.mjs`.
It asserts as it goes and prints a line per section; a failure is an uncaught
`AssertionError`.

Live state without opening the panel:

```bash
qs -p /usr/share/omarchy/shell/shell.qml ipc call io.github.minisiowo.dynamic-workspaces.service status  # profile, blocks, groups
qs log -t 100 /run/user/1000/quickshell/by-id/*/log.qslog # add -r '*=true' for everything
cat ~/.local/state/omarchy/monitor-workspaces             # which block Omarchy gave each monitor
```

## The plugin directory is a symlink, so hot reload does not fire

`~/.config/omarchy/plugins/io.github.minisiowo.dynamic-workspaces` points at this repo.
Omarchy watches that directory with `inotifywait -r`, which does not descend
into symlinks, so **editing files here produces no "Local plugin changed"
reload**. `qs ipc call shell rescanPlugins` is not enough either: it calls
`Qt.clearComponentCache()`, which does not drop `.pragma library` JavaScript, so
a changed `ProfileLogic.js` keeps running from cache. Use
`omarchy-restart-shell` after touching it.

## Contracts that are easy to break

**Omarchy owns the workspace numbers; the plugin must never decide one.** Since
4.5, `default/hypr/monitor-workspaces.lua` gives each physical monitor a block of
ten ids and binds SUPER + N to slot N of the focused monitor's block, and it
renumbers workspaces when monitors come and go. Version 1 pinned global numbers to
monitors with generated Hyprland rules, and the two silently disagreed: on a laptop
on block 2 the bar offered empty workspaces 1-4 that no key reached, while the
keys and the windows were on 21-24. The tests passed and `hyprctl -j
workspacerules` looked right, so check the keys too (`hyprctl dispatch
'o.workspaces.focus(3)'`, which is what SUPER + 3 runs). A number in a profile is a
slot; only `ProfileLogic.workspaceIdFor()` turns one into an id, from the block in
Omarchy's state file. No rules, no hook, nothing under `~/.config/hypr`.

**Focus through `ProfileLogic.focusExpression()`, not `hl.dsp.focus`.** A plain
focus skips `o.workspaces`, which is what reclaims a workspace an unplug left on
another monitor. Only a guest from another block, which has no slot here, is
focused by id.

**Keep to one entry on the bar.** The swap with `omarchy.workspaces` is Omarchy's
clone mechanism: `omarchy.clonedFrom` in the manifest makes `PluginRegistry.qml`
replace one with the other in place, in both directions, and restore on disable.
It handles a single entry, so a second instance survives disabling and keeps the
plugin enabled, which is why the old Control/Workspaces modes are gone. Do not add
a mode or `allowMultiple`, and do not reimplement the swap by editing `shell.json`.

**The `omarchy.workspaces` IPC target is ours while we stand in.** Omarchy's layout
toggle calls `omarchy-shell omarchy.workspaces refresh`, and with its widget off
only `Service.qml` answers. Without that the chip keeps the old layout's icon.

**A file removed in 2.0 is only gone once.** `Service.qml` deletes a stale
`rules.lua` and reloads Hyprland once. That block can go when 1.x is ancient
history, not before, because the file would otherwise keep fighting Omarchy through
a hook line the plugin must not edit.

**`normalizedConfig()` is the whole config schema.** It rewrites the config down
to the keys it names, so a section it does not list is silently dropped the next
time anything is saved. Adding a settings block means adding it there, next to
`appearanceSettings()`, not only where it is read.

**Qt's clipboard is dead on the panel's surface.** Text fields there can only be
typed into: Ctrl+V hands back nothing, which is why the rest of the Omarchy shell
shells out to `wl-copy` / `wl-paste` too. Every field in `ControlWidget.qml` routes
`StandardKey.Paste` through `root.pasteInto()`, which reads the clipboard with
`wl-paste`. A new field without that handler will silently refuse to paste.

**Live compositor state stays out of `Service.groups`.** Which workspace is
focused or occupied is read straight from `Hyprland` by each delegate. Folding it
into the model invalidates every chip in the bar and the panel on each focus
change, mid-drag included.

## Verified against a live compositor

`hyprctl output create headless DW-TEST` is a real second monitor: Omarchy gave it
block 3 and the bar `1 2 3 | 1 2 3`, with `o.workspaces.focus(2, "DW-TEST")` landing
on 32. `hyprctl output remove DW-TEST` undoes it, but Omarchy remembers the block,
so put `~/.local/state/omarchy/monitor-workspaces` back and run `hyprctl reload
config-only` afterwards. A headless output reports an empty description, which is
why `Service.qml` falls back to the connector name.

The swap was exercised with `omarchy plugin enable` and `disable` in every order,
against `shell.json`, from a clean native bar.

The glyph Omarchy uses for a scrolling workspace is a filled circle, which looks
exactly like the default `●` focus mark. It is not a bug to chase.

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
