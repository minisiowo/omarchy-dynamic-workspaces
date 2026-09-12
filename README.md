# Dynamic Workspaces for Omarchy

Your workspaces land on the right screen, whichever screens you happen to have plugged in.

## The problem

You work on a laptop. At your desk it drives two external monitors; on the train it is just the built-in display. Hyprland can pin workspace 4 to a particular monitor, but only if you write that down in advance, for one fixed arrangement. Unplug, and the workspaces that lived on the monitor you just removed pile onto whatever is left. Plug back in, and they do not go home by themselves.

This plugin remembers a layout for each set of screens you actually use, and switches between them on its own.

```
laptop on its own      1  2  3

docked                 1  2  3  │  4  5  6
                       built-in    external
```

Close the lid and the bar goes back to the first row. Open it and you get the second one. Nothing to press.

## What you get

An icon on the Omarchy bar opens a small panel showing every screen you have connected, with its workspaces as chips underneath. Drag a chip from one screen to another to decide where that workspace belongs. Give it a name, an emoji, or an icon if a number is not enough — a renamed chip keeps showing its workspace number underneath, because that number is what your keyboard shortcuts follow.

Once a layout looks right, save it. From then on, whenever exactly those screens are connected, that layout comes back — when you dock, when you undock, when you wake the machine up.

Plug in a screen the plugin has never seen and you do not get an empty bar: it hands each unfamiliar monitor its own block of workspaces so you can start working, and offers to save the arrangement as a new profile.

The plugin can also draw the workspace indicators on the bar itself, grouped by monitor with a divider between screens, in place of Omarchy's built-in ones.

Nothing reaches Hyprland until you switch it on — until then the panel is a preview you can play with freely.

## Requirements

Omarchy with its Quickshell bar, and Hyprland configured in **Lua** (`~/.config/hypr/hyprland.lua`). Applying a layout depends on that: the plugin writes a small Lua file for Hyprland to read. On the older `hyprland.conf` setup the panel still works as a preview, but nothing can be applied.

Beyond that it needs nothing you do not already have: it runs `hyprctl` to reload the compositor, and `wl-paste` so the panel's text fields can be pasted into. Both ship with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/minisiowo/omarchy-dynamic-workspaces --enable
```

That puts the control icon on the bar.

The grouped workspace indicators are a second mode of the same plugin, so using them means placing the plugin on the bar a second time and setting that instance's **Widget mode** to `Workspaces`. Do it from Omarchy's bar settings, or with `omarchy bar put` / `omarchy bar set` — run `omarchy bar --help` for the placement flags. If you use it, disable `omarchy.workspaces` so you do not end up with two sets of indicators.

## First run

1. **Click the icon** on the bar. The panel lists your connected screens.
2. **Arrange the workspaces.** Drag chips between screens, click one to rename it, use `+` to add another.
3. **Save the setup** when it looks right. It becomes a profile for exactly this set of screens.
4. **Turn on Apply** in the panel. The panel will then show you one line to add to `~/.config/hypr/hyprland.lua`:

   ```lua
   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/dynamic-workspaces/rules.lua")
   ```

   Add it, and the panel stops asking.

`rules.lua` checks that it is really running inside Hyprland before it does anything. Some tools read
`hyprland.lua` outside the compositor — `omarchy-menu-keybindings`, behind SUPER+K, is the one you press
every day — by running it in a plain Lua interpreter with a stand-in for Hyprland's API. Asked to list the
monitors, that stand-in answers forever, so a module that starts enumerating them there never stops. This one
returns instead, and the menu opens as it always did.

That line is the only change to your Hyprland configuration, and you make it yourself. The plugin writes two files of its own — `rules.lua` and `config.json`, both under `~/.config/omarchy/dynamic-workspaces/` — and touches nothing else. It never edits `monitors.lua`, `hyprland.lua`, your clamshell settings, or any Omarchy file.

## Everyday use

After the first run there is nothing to do. Dock, undock, close the lid, wake the machine — the set of connected screens changes, the matching profile is picked up, and the workspaces follow. It settles for a moment first, so a dock that comes up one monitor at a time results in one switch at the end rather than a scramble along the way.

**A screen you have not saved a profile for** still gets workspaces: each unknown monitor is handed its own block of three, left to right, and its card in the panel is marked **AUTO**. Edit any of them and the whole arrangement is written into the profile, the badges disappear, and it behaves like one you saved by hand.

**Two identical monitors** report the same name to the system, and Hyprland cannot tell them apart, so they share one set of workspaces and their cards are marked **SHARED**.

On the bar, the workspace you are looking at is drawn in the bar's own color, and the ones holding windows in your theme's accent — one bright mark among the busy ones, rather than the other way round. If color alone is not enough, the panel's **Replace** button shows a character in place of that workspace's number instead; click it again to change the character to any text, emoji, or Nerd Font glyph, and use the arrow beside it to go back to the default dot.

The panel also holds the **divider** shown between monitor groups on the bar — it appears only while two or more of your screens have workspaces, since that is the only time anything is drawn between them. The bar icon itself is any text, emoji, or Nerd Font glyph you like:

```bash
omarchy bar set io.github.minisiowo.dynamic-workspaces icon "🗂️"
```

## Turning it off

Switch **Apply** off in the panel. Hyprland goes back to whatever workspace rules your own configuration sets up. That is the reversible switch and it is enough day to day.

One thing to know: because the rules live in your Hyprland configuration rather than in the shell's memory, disabling or removing the plugin does **not** stop them on its own — Hyprland keeps reading `rules.lua` for as long as that one line is there. So switch Apply off first, or remove the line:

```bash
omarchy plugin disable io.github.minisiowo.dynamic-workspaces
# remove the pcall(dofile, ...) line from ~/.config/hypr/hyprland.lua
hyprctl reload
```

To uninstall it altogether:

```bash
omarchy plugin remove io.github.minisiowo.dynamic-workspaces
```

That leaves `~/.config/omarchy/dynamic-workspaces/` where it is, so your profiles are still there if you come back. Delete the directory to be rid of them.

To put Omarchy's built-in workspace widget back:

```bash
omarchy plugin enable omarchy.workspaces --section left
```

## Configuration file

Everything above is set from the panel. The file behind it is plain JSON, if you would rather edit it directly:

```text
~/.config/omarchy/dynamic-workspaces/config.json
```

`config.example.json` in this repository is a starting point. A saved profile looks like this:

```json
{
  "id": "desk-laptop-closed",
  "name": "Desk — laptop closed",
  "match": {
    "mode": "exact",
    "monitors": ["Monitor A", "Monitor B"]
  },
  "assignments": {
    "Monitor A": [1, 2, 3],
    "Monitor B": [4, 5, 6]
  },
  "labels": {
    "1": "💻",
    "4": "🌐"
  },
  "divider": "|"
}
```

Monitors are matched by the description they report, not by connector names such as `DP-7`, so they survive being plugged into a different port.

Exactly one profile may use `"mode": "default"`. That is the one used when nothing else matches, and it is what hands unfamiliar screens their own workspaces:

```json
{
  "id": "default",
  "match": { "mode": "default" },
  "assignments": {},
  "fallback": { "perMonitor": 3 }
}
```

`perMonitor` is how many workspaces each unrecognised screen gets, clamped to 1–10 so the ids stay within reach of the number keys.

How assignments are applied lives in the same file:

```json
"apply": {
  "enabled": false,
  "persistent": true,
  "debounceMs": 1200
}
```

`enabled` is the panel switch. `persistent` keeps configured workspaces alive even when they hold no windows, which is how most static Hyprland workspace setups behave. `debounceMs` is how long the set of screens has to stay unchanged before the profile switches.

How the bar marks the focused workspace sits beside it, outside the profiles, because it does not change with the screens you have plugged in:

```json
"appearance": {
  "focusMark": "●"
}
```

`focusMark` is the character the focused workspace shows instead of its number. Empty is the **Color** setting: the number stays and only the color marks it.

Two commands are worth knowing. To see exactly what would be handed to Hyprland, without applying anything:

```bash
qs -p /usr/share/omarchy/shell/shell.qml ipc call io.github.minisiowo.dynamic-workspaces.service preview
```

And to open or close the panel — useful on a Hyprland keybinding:

```bash
qs -p /usr/share/omarchy/shell/shell.qml ipc call io.github.minisiowo.dynamic-workspaces.service toggle
```

## How it works

Everything below is detail. You do not need it to use the plugin.

### Why a generated Lua file

Assignments reach Hyprland as a small generated Lua module rather than as runtime commands, because the runtime routes do not hold. `hyprctl keyword` is refused outright once Hyprland is configured in Lua (*"keyword can't work with non-legacy parsers"*), and rules created through `hyprctl eval` live only in memory, so any configuration reload — a theme change, an edit anywhere — silently drops them. Rules that live in the configuration survive reloads, and Hyprland does the profile switching itself.

That module is `~/.config/omarchy/dynamic-workspaces/rules.lua`, rewritten whenever you change a profile, followed by `hyprctl reload config-only`. From then on it reacts to `monitor.added`, `monitor.removed`, and `monitor.layout_changed` on its own. Those events are debounced inside the module — 1.2 s by default — so opening a lid, waking, or docking picks a profile once, from the state that lasts, instead of chasing every intermediate arrangement.

### How unknown screens get their workspaces

The default profile does not name the monitors it applies to, so its layout is worked out at the moment it is used: every connected screen it does not assign by hand takes the next free block of consecutive ids, ordered left to right by position. One unknown screen gets `1 2 3`, two get `1 2 3` and `4 5 6`, three get a third block of `7 8 9`.

Assignments written by hand win, and their ids are reserved — the automatic blocks route around them rather than colliding. With `"Home Screen": [1, 5]` pinned and two unknown monitors either side of it, the result is `2 3 4`, then `1 5`, then `6 7 8`.

Editing an automatically assigned screen writes the **whole** visible layout into the profile at once, which is why the AUTO badges all disappear together. It has to work that way: the allocation is recomputed from the stored assignments, so pinning a single screen would change the pool the others draw from and renumber them out from under you.

Saving an unrecognised setup as a profile records the layout the panel is showing rather than where Hyprland currently happens to put things. The two agree once Apply is on; before that they need not, and what you saw is what you meant to save.

The default profile keeps an assignment for every monitor it has ever allocated, connected or not — that is what lets a familiar screen get its old workspaces back the moment it is plugged in again. The **+** button on a monitor card picks the lowest id free among monitors actually connected right now, so a screen that had `1 2 3` gets `4` even if disconnected screens still hold higher ids in the profile.

The **DEFAULT PROFILE PRESETS** section at the bottom of the panel lists every one of those assignments, connected or not, each with a button to forget it. Typing a description and clicking **Add preset** assigns it a block up front — the same size an automatic monitor gets — so a screen you have not plugged in yet still comes up with its own workspaces the first time it does. This section always edits the default profile specifically, regardless of which profile is currently active — switching to an exact profile does not change what it shows or what "Add preset" writes to.

The **PROFILES** section, just above it, lists every profile in the config by name — the ones saved through *Save setup* included — with a button to delete any of them. The default profile has no delete button: it is the fallback every unrecognised monitor set lands on, so removing it would leave those monitors with no workspaces assigned at all. Deleting the last exact profile is refused too, for the same reason — there is always at least one profile left to match against.

### Screens that cannot be told apart

Monitors are addressed by the description they report, and two screens of the same model report the same one. Hyprland's `desc:` selector cannot single one of them out, and neither can the assignments, so they are resolved as a single logical monitor sharing one set of workspaces. A hand-written profile does not help; the limit is in what `desc:` can express.

### Why the rules are built late

A workspace rule's monitor is fixed when the rule is created, and the screens the default profile applies to are unknown until Hyprland reports them. So the generated module carries the allocation rule itself and builds its rules once the monitors exist, rather than shipping a pre-computed list.

## Development

Validate the repository first:

```bash
omarchy plugin validate .
```

For local development, link it into Omarchy's user plugin directory and enable it:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.minisiowo.dynamic-workspaces
omarchy plugin enable io.github.minisiowo.dynamic-workspaces --section left
```

Restart the shell with `omarchy-restart-shell` after every change. The shell does watch the plugin directory, but it watches it with `inotifywait -r`, which does not follow the symlink you just made, so nothing you edit here ever reaches a running shell on its own. Use `omarchy-restart-shell` — not `omarchy-refresh-shell`, which resets `~/.config/omarchy/shell.json` to Omarchy's defaults and drops your bar layout.

To remove the development symlink after disabling:

```bash
rm ~/.config/omarchy/plugins/io.github.minisiowo.dynamic-workspaces
```

The profile logic is a plain `.pragma library` with no QML dependencies, so it is tested in Node:

```bash
node tests/profile-logic.test.mjs
```

Those tests pin the workspace allocation exactly, because it is implemented twice — in JavaScript for the bar and the panel, and in Lua inside the generated module. The two must agree, or the bar shows workspaces on a monitor Hyprland will not put them on.

## How it got here

- `0.1`: safe profile detection and read-only preview;
- `0.2`: profile editor and drag-and-drop workspace assignment;
- `0.3`: opt-in Hyprland rule generation with clamshell debounce;
- `0.4`: a default profile that assigns unrecognised monitors on its own;
- `1.0`: hotplug switching verified against a live compositor, and the listing on omarchyplugins.com.

## License

MIT
