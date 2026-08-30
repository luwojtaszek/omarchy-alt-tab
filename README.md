# Alt-Tab Switcher for Omarchy

A macOS-style Alt-Tab window switcher, running inside the Omarchy shell
(`omarchy-shell`) as a plugin — no extra processes, no extra dependencies.

![preview](preview.png)

- **MRU order** — windows listed by most-recently-used; the first `Alt+Tab`
  selects your previous window, exactly like macOS / Windows.
- **Release Alt to switch** — hold Alt and cycle with Tab; releasing Alt
  focuses the selection. A quick tap switches to the previous window without
  the switcher ever appearing.
- **Type to filter** — just start typing while the switcher is open; it
  latches into sticky mode (Enter focuses, Escape cancels).
- **Theme-native** — the palette maps live onto your active Omarchy theme
  (background / foreground / accent / muted from `colors.toml`). Light and
  dark themes both work; nothing is hard-coded.
- **Two looks** — `two-line` (default: app icon, window title on its own
  line, key-hint footer) and `bare` (compact rows with `alt+<n>` jump
  numbers that focus a window directly).

## Install

```bash
omarchy plugin add https://github.com/luwojtaszek/omarchy-alt-tab.git --enable
```

## Keybindings

The plugin does not register keybindings itself — add these to your Hyprland
config. Omarchy (Lua config):

```lua
o.bind("ALT + TAB", "Window switcher",
  "omarchy-shell shell summon io.github.luwojtaszek.alt-tab '{\"dir\":\"next\"}'")
o.bind("ALT + SHIFT + TAB", "Window switcher (back)",
  "omarchy-shell shell summon io.github.luwojtaszek.alt-tab '{\"dir\":\"prev\"}'")
```

Classic Hyprland config syntax:

```ini
bind = ALT, Tab, exec, omarchy-shell shell summon io.github.luwojtaszek.alt-tab '{"dir":"next"}'
bind = ALT SHIFT, Tab, exec, omarchy-shell shell summon io.github.luwojtaszek.alt-tab '{"dir":"prev"}'
```

## Keys (while open)

| Key | Action |
|---|---|
| `Alt+Tab` / `Tab` / `↓` / `` ` `` | next window |
| `Alt+Shift+Tab` / `⇧Tab` / `↑` | previous window |
| release `Alt` | focus selection (unless you typed a filter) |
| type text | filter windows; switcher stays open |
| `1`–`9` | focus the n-th row directly (`bare` variant) |
| `↵` | focus selection |
| `Esc` / click outside | cancel |

## Options

Options are passed in the summon payload:

| Key | Values | Default | |
|---|---|---|---|
| `dir` | `next`, `prev` | `next` | initial / repeated cycle direction |
| `variant` | `two-line`, `bare` | `two-line` | visual style |

Example — the `bare` variant:

```
omarchy-shell shell summon io.github.luwojtaszek.alt-tab '{"dir":"next","variant":"bare"}'
```

## How it works, dependencies, privileges

The switcher is a `menu`-kind plugin: a fullscreen layer surface with
exclusive keyboard focus, summoned into the long-running `omarchy-shell`
process. Repeated `Alt+Tab` presses arrive as repeated summons (the Hyprland
bind consumes the key) and cycle the selection; the Alt release reaches the
focused surface as an ordinary key event.

- Window list: `hyprctl -j clients`, sorted by `focusHistoryID`.
- Focusing: Hyprland `focuswindow` dispatch. Both classic and Lua-config
  Hyprland dispatch syntax are supported (probed once at startup).
- No daemons, no root, no extra packages. Runs unsandboxed inside the shell
  process with your user permissions, like every Omarchy shell plugin.
- Typography follows the Omarchy brand font: JetBrains Mono. With only the
  stock `ttf-jetbrains-mono-nerd-basic` installed the Light/Medium weights
  render as Regular; install `ttf-jetbrains-mono` for the full effect.

## License

MIT
