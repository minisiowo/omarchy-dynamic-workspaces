# Dynamic Workspaces for Omarchy

A profile-aware workspace manager for monitor setups that change throughout the day.

> **Status:** `0.4.2`. Profiles are editable, persisted, and — once the switch in the panel is on and the one-line hook is in place — applied to Hyprland.

## Current behavior

- adds one configurable control icon to the Omarchy bar;
- renders configured workspace groups in a separate instance at the normal workspace position;
- opens a native Omarchy popup panel built from the shell's own panel kit (hero header, section headers, separators, scrollable content);
- observes active Hyprland monitors and workspaces;
- matches profiles by the exact set of active monitor descriptions;
- falls back to an editable default profile that gives every unrecognised monitor its own block of workspaces;
- displays only workspace ids configured in the selected profile;
- adds and removes configured workspace ids;
- saves the monitor set on screen as a named profile;
- moves workspace definitions between monitor groups with drag-and-drop;
- edits arbitrary labels, emoji, Nerd Font glyphs, and the divider;
- saves the profile atomically outside the plugin checkout;
- generates a Hyprland Lua module that assigns workspaces to monitors and switches profiles on its own when the monitor set changes;
- supports separate `Control` and `Workspaces` widget modes from the same marketplace plugin.

This makes clamshell transitions predictable: closing or opening a laptop changes the active monitor set, which changes the selected profile. Omarchy remains solely responsible for enabling and disabling displays.

## Applying assignments

Assignments reach Hyprland as a generated Lua module, not as runtime commands. Two things rule out the runtime route: `hyprctl keyword` is refused outright once Hyprland is configured in Lua (*"keyword can't work with non-legacy parsers"*), and rules created through `hyprctl eval` live only in memory, so any config reload — a theme change, an edit anywhere in the config — silently drops them. Rules that live in the config survive reloads, and Hyprland does the profile switching itself on its own monitor events.

Turn on **Apply** in the panel, then add one line to `~/.config/hypr/hyprland.lua`:

```lua
pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/dynamic-workspaces/rules.lua")
```

The panel shows that line until it finds it. Everything else is automatic: editing a profile rewrites `rules.lua` and runs `hyprctl reload config-only`, and from then on the module reacts to `monitor.added`, `monitor.removed`, and `monitor.layout_changed` by itself. Monitor events are debounced inside the module (1.2 s by default), so opening a lid, waking, or docking picks a profile once, from the state that lasts, instead of chasing every intermediate monitor set.

The plugin writes `rules.lua` and its own `config.json`, and nothing else. It never edits `monitors.lua`, `hyprland.lua`, the clamshell configuration, or any Omarchy file — the `dofile` line is yours to add and yours to remove.

Assignment behavior settings live in `config.json`:

```json
"apply": {
  "enabled": false,
  "persistent": true,
  "debounceMs": 1200
}
```

`enabled` is the panel switch. `persistent` keeps configured workspaces alive even when empty, which is what most static Hyprland workspace setups do. `debounceMs` is how long the monitor set has to stay unchanged before the profile switches.

To see exactly what would be handed to Hyprland without applying anything:

```bash
qs -p /usr/share/omarchy/shell/shell.qml ipc call minisiowo.dynamic-workspaces.service preview
```

The same target opens and closes the panel — useful for a Hyprland keybinding:

```bash
qs -p /usr/share/omarchy/shell/shell.qml ipc call minisiowo.dynamic-workspaces.service toggle
```

## Development install

Validate the repository first:

```bash
omarchy plugin validate .
```

For local development, link the repository into Omarchy's user plugin directory and enable it:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/minisiowo.dynamic-workspaces
omarchy plugin enable minisiowo.dynamic-workspaces --section left
```

The shell hot-reloads changes under the plugin directory.

## Configuration

The plugin reads:

```text
~/.config/omarchy/dynamic-workspaces/config.json
```

Copy `config.example.json` as a starting point. Exact profiles have this shape:

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
  }
}
```

Monitor matching uses EDID descriptions rather than connector names such as `DP-7`.

### The default profile

Exactly one profile may use `"mode": "default"`. It is selected whenever no exact profile matches the connected monitors, and it is the reason plugging in an unfamiliar screen never leaves you looking at an empty bar.

Unlike an exact profile, it does not have to name the monitors it applies to. Every connected monitor it does not assign by hand gets its own block of consecutive workspaces, laid out left to right:

```json
{
  "id": "default",
  "match": { "mode": "default" },
  "assignments": {},
  "fallback": { "perMonitor": 3 }
}
```

One unknown monitor gets `1 2 3`; two get `1 2 3` and `4 5 6`; three get a third block of `7 8 9`. `perMonitor` is clamped to 1–10, so the ids stay within reach of the number-key bindings.

Assignments you write by hand still win, and their ids are reserved — the automatic blocks route around them rather than colliding. With `"Home Screen": [1, 5]` pinned and two unknown monitors either side of it, the result is `2 3 4`, then `1 5`, then `6 7 8`.

When the connected monitors match no exact profile, the panel offers to save them as one. It records the layout it is showing — the resolved allocation — so what you save is what you were looking at, whether or not Apply is on.

The panel marks an automatically assigned monitor with an **AUTO** badge. Editing any of them writes the whole visible layout into the profile at once, and the badges disappear — from then on the default profile behaves like an exact one. It has to work that way: the allocation is recomputed from the stored assignments, so pinning a single monitor would change the pool the others draw from and renumber them out from under you.

Because the monitors are unknown until Hyprland reports them — and a workspace rule's monitor cannot be changed once the rule exists — the generated module carries the allocation rule itself and builds the rules when the monitors appear, rather than shipping pre-computed groups.

Two screens of the same model report the same EDID description. Assignments and Hyprland's `desc:` selector are both keyed by it, so neither can address one of them alone — they are resolved as a single logical monitor sharing one set of workspaces, and the panel marks their cards **SHARED**. An exact profile does not help here; the limitation is in what `desc:` can express.

The bar icon can be changed to any text, emoji, or Nerd Font glyph:

```bash
omarchy bar set minisiowo.dynamic-workspaces icon "🗂️"
```

## Disable and rollback

Turning **Apply** off in the panel rewrites `rules.lua` as a module that claims nothing, so Hyprland falls back to the workspace rules in your own config. That is the reversible switch, and it is enough for everyday use.

Because the rules live in the config rather than in the shell's memory, disabling or removing the plugin does **not** stop them — Hyprland keeps loading `rules.lua` for as long as the `dofile` line is there. Turn Apply off first, or drop the line:

```bash
omarchy plugin disable minisiowo.dynamic-workspaces
# remove the pcall(dofile, ...) line from ~/.config/hypr/hyprland.lua
hyprctl reload
```

To restore the previous cloned workspace widget after disabling:

```bash
omarchy plugin enable minisiowo.workspaces --section left
```

For a development symlink, remove it after disabling:

```bash
rm ~/.config/omarchy/plugins/minisiowo.dynamic-workspaces
```

## Roadmap

- `0.1`: safe profile detection and read-only preview;
- `0.2`: profile editor and drag-and-drop workspace assignment;
- `0.3`: opt-in Hyprland rule generation with clamshell debounce;
- `0.4`: a default profile that assigns unrecognised monitors on its own;
- `1.0`: documentation, screenshots, release and listing on omarchyplugins.com.

## License

MIT
