# Moving to HyprWM

HyprWM has a binary split layout, a shared text configuration, a native settings UI and a local command socket. It borrows concepts from other window managers without implementing their complete configuration languages. Stop your other automatic tiler before starting HyprWM so two managers do not resize the same windows.

After `./install.sh`, use the installed CLI (or add `~/.local/bin` to PATH and run `hyprwm`):

```sh
~/.local/bin/hyprwm import /path/to/aerospace.toml
```

Import reads a regular UTF-8 file no larger than 256 KiB, parses it as data, merges supported values, and makes a sibling `hyprwm.conf.backup-<UUID>` before replacing an existing configuration. It never executes the source file. Unsupported or invalid entries produce warnings with their original line numbers; supported independent entries can still apply. If nothing maps, import fails and preserves the configuration. Review the warnings and resulting file before running a session. To undo an import, quit/pause HyprWM and copy the reported sibling backup back over `hyprwm.conf`.

The examples below show the supported patch against a fresh baseline. Binding IDs can be reassigned when merging with existing overrides; command and chord values are what matter.

The filename helps identify the format: use names containing `hyprland`, `aerospace`, `yabai`, `skhd`, `i3`, `sway`, `amethyst` or `rectangle`. Files are handled individually: import `yabairc` and `skhdrc` separately. The importer does not recursively follow includes, invoke shell scripts, expand arbitrary environment variables or interpret every TOML/YAML construct.

## Hyprland

| Hyprland concept | HyprWM equivalent / limit |
| --- | --- |
| Dwindle | Binary split layout; `layout.default_split_ratio` uses the same `1 = 50/50` convention. Other layout engines are not imported. |
| `general.gaps_in`, `gaps_out`, `border_size` | `layout.gaps_in`, `layout.gaps_out`, `appearance.border.size`. |
| Decoration rounding and opacity | Matching appearance keys; transparency remains unfinished. |
| `input.follow_mouse` | `focus.follow_mouse`, integer `0/1`. |
| `movefocus`, `movewindow` / `swapwindow` | `focus`, `move`, with `l/r/u/d` converted to full direction names. |
| `togglefloating`, `killactive`, `fullscreen`, `togglesplit` | `float`, `close`, `fullscreen`, `togglesplit`. |
| `windowrule` / `windowrulev2` float/tile, class/title | Supported conservative rule subset; Linux WM_CLASS is compared to macOS owner name and often needs editing. |
| `$mainMod` and binds | Simple declared variables are substituted. Imported `SUPER` becomes Command; `ALT` becomes Option. |
| Monitor rules, plugins, services, shell exec, workspace dispatchers | Not automatically mapped; warnings identify unsupported lines. |

Input `hyprland.conf`:

```conf
general {
    gaps_in = 8
    border_size = 2
}
$mainMod = SUPER
bind = $mainMod, H, movefocus, l
windowrulev2 = float, class:^Calculator$
```

Converted HyprWM assignments (object order/formatting may differ):

```conf
layout.gaps_in = 8
appearance.border.size = 2
bind = {"id":0,"keycode":4,"modifiers":256,"enabled":true,"command":["focus","left"]}
windowrule = {"match":{"class":"^Calculator$"},"float":true}
```

HyprWM is a macOS window manager, not a Wayland compositor. Linux application launchers, layer-shell surfaces, rendering plugins and monitor configuration need macOS replacements. Curves and animation settings should be configured in [CONFIG.md](CONFIG.md), not assumed to migrate from arbitrary Hyprland directives.

## AeroSpace

| AeroSpace concept | HyprWM equivalent / limit |
| --- | --- |
| `gaps.inner.horizontal` / `.vertical` | One `layout.gaps_in`; differing axes cannot be represented and produce a warning. |
| `gaps.outer.<side>` | `layout.gaps_out.<side>` for scalar values. Per-monitor arrays do not import. |
| `[mode.main.binding]` | Native binding overrides for supported focus/move/float/fullscreen/close/balance actions. |
| Tree containers / accordion layouts | HyprWM uses a binary split tree; accordion and arbitrary multi-child containers do not map. |
| `on-window-detected` float/tile callbacks | App-name/title regex plus a supported layout action can become a rule. App-ID conditions and callback arrays are not equivalent. |
| Named virtual workspaces, monitor assignment, binding modes, shell sequences | No automatic conversion; configure supported HyprWM commands explicitly. |

Input `aerospace.toml`:

```toml
[gaps]
inner.horizontal = 8
inner.vertical = 8
outer.top = 12
[mode.main.binding]
alt-h = 'focus left'
alt-shift-h = 'move left'
```

Converted:

```conf
layout.gaps_in = 8
layout.gaps_out.top = 12
bind = {"id":0,"keycode":4,"modifiers":2048,"enabled":true,"command":["focus","left"]}
bind = {"id":1,"keycode":4,"modifiers":2560,"enabled":true,"command":["move","left"]}
```

AeroSpace's current configuration also has `focus-follows-mouse.enabled`; the importer does not map every setting merely because HyprWM has a similar feature. Set `focus.follow_mouse` yourself. See the [official AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide) for the original workspace/tree model.

## yabai + skhd

| yabai/skhd concept | HyprWM equivalent / limit |
| --- | --- |
| BSP | Binary split layout, with different insertion and recovery policy. |
| `window_gap`, edge padding | Inner gap and outer side gaps. |
| `focus_follows_mouse autofocus/off` | `focus.follow_mouse = 1/0`. Mouse warping is a separate concept. |
| `rule --add app=… manage=off/on` | Matching float/tile rule. |
| skhd chord → `yabai -m window --focus/--swap/--warp` | `focus` or `move`; directions west/east/north/south map to left/right/up/down. |
| `--toggle float`, `--toggle zoom-fullscreen`, `--close` | `float`, `fullscreen`, `close`. |
| Shell conditionals, signals, scripts, Space management, scripting addition | Not executed or installed by import. |

Input `yabairc`:

```sh
yabai -m config window_gap 8
yabai -m config top_padding 12
yabai -m rule --add app="^Calculator$" manage=off
```

Input `skhdrc`, imported separately:

```text
alt - h : yabai -m window --focus west
alt + shift - h : yabai -m window --swap west
```

Converted combined result:

```conf
layout.gaps_in = 8
layout.gaps_out.top = 12
windowrule = {"match":{"class":"^Calculator$"},"float":true}
bind = {"id":0,"keycode":4,"modifiers":2048,"enabled":true,"command":["focus","left"]}
bind = {"id":1,"keycode":4,"modifiers":2560,"enabled":true,"command":["move","left"]}
```

Only import supported declarative lines. A shell shebang is ignored; arbitrary setup commands become warnings. HyprWM does not remove a yabai scripting addition or change its system prerequisites.

## i3 / sway

| i3/sway concept | HyprWM equivalent / limit |
| --- | --- |
| `gaps inner/outer` | `layout.gaps_in` / scalar `layout.gaps_out`. |
| `focus_follows_mouse yes/no` | `focus.follow_mouse = 1/0`. |
| `bindsym` with simple `set` variables | Supported native shortcuts; Mod4 becomes Command, Mod1 becomes Option. |
| `focus`, `move`, `kill`, `floating toggle`, `fullscreen toggle`, `split toggle` | Matching focus/move/close/float/fullscreen/togglesplit commands. |
| Marks, criteria, modes, scratchpads, outputs, bars, exec, includes | No complete equivalent in the importer. |

Input `sway.conf` (also works as `i3.conf`):

```text
set $mod Mod4
gaps inner 8
gaps outer 12
focus_follows_mouse yes
bindsym $mod+h focus left
bindsym $mod+Shift+space floating toggle
```

Converted:

```conf
layout.gaps_in = 8
layout.gaps_out = 12
focus.follow_mouse = 1
bind = {"id":0,"keycode":4,"modifiers":256,"enabled":true,"command":["focus","left"]}
bind = {"id":1,"keycode":49,"modifiers":768,"enabled":true,"command":["float"]}
```

The screen/output server, status bar and application commands remain macOS responsibilities. A successful binding import does not recreate an i3/sway session.

## Amethyst

| Amethyst concept | HyprWM equivalent / limit |
| --- | --- |
| `window-margin-size` | `layout.gaps_in`; this is a direct scalar mapping, so compare the visual spacing. |
| `screen-padding-left/right/top/bottom` | Corresponding outer side gaps. |
| Tall/wide/column/custom layouts | HyprWM binary splits; layout lists are not imported. |
| Main pane count / ratios | No automatic equivalent. |
| `mouse-follows-focus` | Cursor movement after focus; **not** `focus.follow_mouse`. The importer warns instead of inverting the meaning. |
| Amethyst shortcuts and app floating lists | Not mapped by the current YAML importer. |

Input `.amethyst.yml`:

```yaml
window-margin-size: 8
screen-padding-top: 12
screen-padding-left: 12
```

Converted:

```conf
layout.gaps_in = 8
layout.gaps_out.top = 12
layout.gaps_out.left = 12
```

## Rectangle

**Automatic Rectangle import is not supported.** A recognized Rectangle filename reports unsupported entries; an import with zero mapped settings fails without replacing your configuration. Binary plists are not accepted as UTF-8 text. Do not treat a detected format as successful conversion.

| Rectangle concept | Manual HyprWM equivalent / limit |
| --- | --- |
| Left/right half shortcuts | Automatic tiling plus directional focus/move; no exact equivalent to independent snap regions. |
| Maximize | HyprWM layout fullscreen/maximized behavior, distinct from macOS native fullscreen. |
| Move to display | No promise of direct Rectangle action parity. |
| Gaps | Set HyprWM inner/outer gaps manually. |
| Saved shortcuts/preferences | Read them in Rectangle settings and rebind supported actions in HyprWM. |

A concrete manual conversion: if your Rectangle setup uses **Control–Option–H** for Left Half, decide whether your intended tiled action is to **focus** the left neighbor or **move** the current tile left. For the latter, add this to `hyprwm.conf`:

```conf
bind = CTRL ALT, H, move, left
```

This is a real HyprWM binding, but it rearranges the split layout; it does not promise a Rectangle-style half-screen snap. For “focus left” instead, change `move` to `focus`. Review the effective binding in Settings → Hotkeys before using it.

## Check the result

Read the edited `hyprwm.conf` and import warnings. Inspect effective configuration through the installed bundled baseline without starting a daemon:

```sh
~/.local/bin/hyprwm --print-config
```

A configuration printout establishes parsing and resolved values. Test actual focus, tiling, workspace and recovery behavior separately with disposable windows. Keep the source file and generated backup until the new session behaves as expected. See [troubleshooting](TROUBLESHOOTING.md) for permissions and recovery.
