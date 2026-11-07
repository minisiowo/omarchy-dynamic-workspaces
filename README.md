# Dynamic Workspaces for Omarchy

Omarchy's workspace widget, with a saved layout for each set of screens you use.

## The problem

Omarchy gives every monitor its own workspaces: SUPER + 3 is the third workspace of the screen you are on, and a screen gets its workspaces back when you plug it in again. What it does not do is remember anything about how you want them shown. Every bar counts the same way, on every screen, in every setup, and a workspace has a number and nothing else.

This plugin takes the place of that widget and remembers, for each set of screens, what the bar should show.

```
laptop on its own      1  2  3  4

docked                 💻  2  3  │  🌐  2
                       left         right
```

Close the lid and the bar goes back to the first row. Open it and you get the second one. Nothing to press.

## What you get

The bar shows the workspaces of all your screens together, grouped by monitor with a divider between them, and the icon after them opens a small panel with a card for each screen. Choose which workspaces a screen shows and in what order, and give any of them a name, an emoji, or an icon if a number is not enough — a renamed chip keeps showing its number underneath, because that number is what your keyboard shortcuts follow.

Once a layout looks right, save it. From then on, whenever exactly those screens are connected, that layout comes back — when you dock, when you undock, when you wake the machine up.

Everything else stays Omarchy's. The keys, the block of ten workspaces each monitor owns, what happens when one is unplugged, and the layout of each workspace all work as they do without the plugin. It only draws them, and it writes nothing to Hyprland, so there is nothing left behind when you switch it off.

## Requirements

Omarchy 4.5 or later: the version that gives each monitor its own block of workspaces. The panel uses `wl-paste` so its text fields can be pasted into, which ships with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/minisiowo/omarchy-dynamic-workspaces --enable
```

It takes the place of `omarchy.workspaces` on the bar, in the same spot. The two are swapped by Omarchy itself, so they cannot end up side by side: enabling either one switches the other off, however you do it.

## First run

1. **Click the icon** after the workspaces on the bar. The panel lists your connected screens.
2. **Arrange the workspaces.** Use `+` to show another one, drag a chip along its row to reorder it, click one to rename it.
3. **Save the setup** when it looks right. It becomes a profile for exactly this set of screens.

## Everyday use

After the first run there is nothing to do. Dock, undock, close the lid, wake the machine — the set of connected screens changes and the matching profile is picked up.

**A screen you have not saved a profile for** shows its first three workspaces, and its card in the panel is marked **AUTO**. Edit any of them and the whole arrangement is written into the profile, the badges disappear, and it behaves like one you saved by hand.

**A workspace the profile does not list** is never out of reach. SUPER + N goes to any of a screen's ten workspaces, and whichever you are on or that holds windows joins the bar after the ones you chose, and the panel lists it under **ALSO HERE**. That is also where a screen's workspaces turn up when you unplug it: Omarchy moves them to the screen that is left, and sends them home when it returns.

**Two identical monitors** report the same name, so a profile cannot tell them apart. Both show the same row of chips, marked **SHARED**, and Omarchy still gives each its own workspaces.

On the bar, the workspace you are looking at is drawn in the bar's own color, and the ones holding windows in your theme's accent — one bright mark among the busy ones, rather than the other way round. If color alone is not enough, the panel's **Replace** button shows a character in place of that workspace's number instead; click it again to change the character to any text, emoji, or Nerd Font glyph, and use the arrow beside it to go back to the default dot.

As on Omarchy's own bar, clicking the workspace you are on cycles its layout, and the wheel moves along a screen's row. A workspace that scrolls or floats shows that layout's icon whatever you chose above.

The panel also holds the **divider** shown between monitor groups on the bar — it appears only while two or more of your screens have workspaces, since that is the only time anything is drawn between them. The bar icon itself is any text, emoji, or Nerd Font glyph you like:

```bash
omarchy bar set io.github.minisiowo.dynamic-workspaces icon "🗂️"
```

## Turning it off

```bash
omarchy plugin disable io.github.minisiowo.dynamic-workspaces
```

Omarchy's widget comes back where this one was, and `omarchy plugin enable omarchy.workspaces` does the same thing from the other side. Enabling this plugin again swaps them back.

To uninstall it altogether:

```bash
omarchy plugin remove io.github.minisiowo.dynamic-workspaces
```

That leaves `~/.config/omarchy/dynamic-workspaces/` where it is, so your profiles are still there if you come back. Delete the directory to be rid of them.

## Upgrading from 1.x

Version 1 assigned workspace numbers to monitors through generated Hyprland rules, and those fight the per-monitor numbering Omarchy has had since 4.5: the bar and the keyboard stopped agreeing about which workspace was which. Version 2 leaves numbering to Omarchy.

- `rules.lua` removes itself the first time version 2 runs. The `pcall(dofile, ...)` line in `~/.config/hypr/hyprland.lua` then loads nothing and can be deleted.
- The plugin is one entry on the bar now. If you had a second one for the control icon, remove it in Omarchy's bar settings.
- Profiles carry over. The numbers in them now mean a workspace of that monitor, so a screen that listed `4 5 6` shows the workspaces SUPER + 4, 5, and 6 reach on that screen. Names stay on the monitor that listed them.
- Chips no longer move between monitors, because every monitor has its own 1 and there is nothing to move.

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
    "Monitor B": [1, 2]
  },
  "labels": {
    "Monitor A": { "1": "💻" },
    "Monitor B": { "1": "🌐" }
  },
  "divider": "|"
}
```

The numbers are which of a monitor's own ten workspaces it shows, in the order the bar draws them; 10 is the one on the 0 key. Monitors are matched by the description they report, not by connector names such as `DP-7`, so they survive being plugged into a different port.

Exactly one profile may use `"mode": "default"`. That is the one used when nothing else matches:

```json
{
  "id": "default",
  "match": { "mode": "default" },
  "assignments": {},
  "fallback": { "perMonitor": 3 }
}
```

`perMonitor` is how many workspaces each unrecognised screen shows, from 1 to 10.

How the bar marks the focused workspace sits beside the profiles, not inside them, because it does not change with the screens you have plugged in:

```json
"appearance": {
  "focusMark": "●"
}
```

`focusMark` is the character the focused workspace shows instead of its number. Empty is the **Color** setting: the number stays and only the color marks it.

To open or close the panel — useful on a Hyprland keybinding:

```bash
qs -p /usr/share/omarchy/shell/shell.qml ipc call io.github.minisiowo.dynamic-workspaces.service toggle
```

## How it works

Everything below is detail. You do not need it to use the plugin.

### Omarchy owns the numbering

Omarchy gives each physical monitor a block of ten workspace ids, kept in `~/.local/state/omarchy/monitor-workspaces` so a screen gets the same block every time. On a laptop that has met two monitors before, the built-in panel can easily be 21–30, so the bar reads that file to know which id each chip stands for, and never computes one of its own. Clicking a chip calls `o.workspaces.focus()`, the same thing SUPER + N calls, which is what brings a workspace back from wherever an unplug left it.

A profile only says what to show. That is why the plugin needs no hook in `hyprland.lua` and leaves nothing in the compositor.

### How it replaces Omarchy's widget

The manifest declares `omarchy.clonedFrom: "omarchy.workspaces"`, the same field `omarchy plugin clone` writes. Omarchy then swaps the two in place and restores the original on disable. It needs the plugin to be one entry on the bar, because a second one would stay behind and keep the plugin enabled, which is why the widget has no modes and `allowMultiple` is off.

### The default profile and its presets

The default profile keeps an entry for every monitor you have edited under it, connected or not, which is what lets a familiar screen get its chips back the moment it is plugged in again.

The **DEFAULT PROFILE PRESETS** section at the bottom of the panel lists those entries, each with a button to forget it. Typing a description and clicking **Add preset** writes one up front, so a screen you have not plugged in yet comes up the way you want the first time. This section always edits the default profile, whichever one is active.

The **PROFILES** section, just above it, lists every profile by name with a button to delete it. The default profile has no delete button, because it is what every unrecognised set of screens lands on, and the last profile standing cannot be deleted either.

## Development

Validate the repository first:

```bash
omarchy plugin validate .
```

For local development, link it into Omarchy's user plugin directory and enable it:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.minisiowo.dynamic-workspaces
omarchy plugin enable io.github.minisiowo.dynamic-workspaces
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

## How it got here

- `0.1`: safe profile detection and read-only preview;
- `0.2`: profile editor and drag-and-drop workspace assignment;
- `0.3`: opt-in Hyprland rule generation with clamshell debounce;
- `0.4`: a default profile that assigns unrecognised monitors on its own;
- `1.0`: hotplug switching verified against a live compositor, and the listing on omarchyplugins.com;
- `2.0`: numbering left to Omarchy's per-monitor workspaces, no more Hyprland rules, and a clean swap with `omarchy.workspaces`.

## License

MIT
