# Configuration

This launch branch is Engine-only. Lite applicability below describes the separate experimental `lite/2026-10-16` implementation, not a selectable mode in this build. See [branch availability](../README.md#experimental-lite).

HyprWM reads `~/.config/hyprwm/hyprwm.conf`. Set `HYPRWM_CONFIG` to an explicit file path to use another document. The settings UI and daemon share this file. Save to reload; the watcher observes the containing directory as well as the file, so atomic-save editors are supported. A 65 ms debounce coalesces writes. Invalid assignments produce line-numbered warnings while independent valid assignments remain usable.

```conf
layout {
    gaps_in = 8
    gaps_out.top = 12
}
focus {
    follow_mouse = 1
}
appearance {
    border.size = 2
    border.active.colors = ["rgba(ffb4a4ee)", "rgba(7fd0f5ee)"]
    border.active.angle = 45
}
bind = CTRL ALT, H, focus, left
windowrule = float, app:^Calculator$
```

Each section opener, assignment and closing brace goes on its own line. Dotted assignments also work outside sections: `layout.gaps_in = 8`. Values are JSON strings, finite numbers, booleans, arrays or objects; unquoted strings and `yes`/`no`/`on`/`off` are accepted. `#` starts a comment outside a quoted string. Documents must be UTF-8 and at most 256 KiB. These are HyprWM settings, not a complete Hyprland configuration language: `source`, shell commands and arbitrary Hyprland dispatchers are not supported.

## Defaults and precedence

The tables describe the portable baseline in [`hyprland.lua`](../hook/config/defaults/.config/hypr/hyprland.lua), generated text defaults in [`TextConfig.swift`](../hook/swift/Sources/HyprCore/TextConfig.swift), and consumer fallbacks. An existing configuration remains authoritative. On legacy first startup, `TextConfig.read` can also migrate `hook/config/runtime.json` and `swift-runtime.json`; those may contain local overrides and are not portable defaults. Environment overrides take precedence where listed below. The installed app reads its bundled base without Lua. An external development `HYPRWM_HOOK` can rebuild `hypr_cfg.json` through `hypr_shim.lua` when the Lua inputs are newer; that path requires Lua and the matching source configuration.

The schema is [`runtime.schema.json`](../hook/config/runtime.schema.json). Swift adds `runtime.enabled`, `runtime.menu_bar`, `runtime.startup_animation` and rule role/subrole fields while loading it. Parsing a field is distinct from a renderer consuming it. Engine consumers below refer to the native path; see the [separate Lite research report](https://github.com/sakenuGOD/hyprwm-macos/blob/lite/2026-10-16/docs/LITE_RESEARCH.md) for its capability and validation limits.

## Runtime, layout, focus and drag

All numeric distances are macOS points unless the name says milliseconds.

| Key | Default | Example / allowed value | Actual consumer |
| --- | --- | --- | --- |
| `version` | `1` | `version = 1` | `NativeRuntimeConfig.build` validates the document version. |
| `time_scale` | `1` | `time_scale = 1.5` (`0.1…4`) | `NativeRuntimeConfig.build` scales geometry animation timing; `HYPRWM_TIME_SCALE` overrides it. |
| `runtime.enabled` | `true` | `runtime.enabled = false` | `RuntimeOptions.load` and runtime reload enable/disable automatic tiling. |
| `runtime.menu_bar` | `true` | `runtime.menu_bar = false` | `RuntimeOptions.load`, daemon menu construction at launch; restart to change menu presence. `HYPRWM_MENU_BAR=0/1` overrides it. |
| `runtime.startup_animation` | `false` in generated file | `runtime.startup_animation = true` | **Accepted, not currently effective:** `RuntimeOptions.load` passes `startupAnimation` to `MenuBarController`, which does not consume it. The options fallback is `true` if a hand-written file omits it. |
| `runtime.window_resize_mode` | `native` | `native` or `buffer` | `Channel.configureAppearance` sets the engine's live-buffer scale flag. Neither mode enables per-frame AX configuration. |
| `runtime.overview_hidden_windows` | `false` | `runtime.overview_hidden_windows = false` | `RuntimeOptions.load` → overview policy. Experimental hidden-window Mission Control path; leave off unless separately verified. |
| `runtime.prehide` | `false` | `runtime.prehide = false` | `LiveEngine` publishes native prehide policy; `WM` first-map path reads it. `HYPRWM_PREHIDE=0/1` overrides it. |
| `runtime.hold_max_ms` | `200` | `runtime.hold_max_ms = 200` (`0…2000`) | `LiveEngine` publishes the native first-frame hold bound. `HYPRWM_HOLD` overrides it in seconds. |
| `runtime.capture_sampling` | `false` | `runtime.capture_sampling = false` | `WM` gates window-edge color image sampling. It does not enable Lite proxy animation capture. |
| `runtime.pointer_focus_pause_ms` | `100` | `runtime.pointer_focus_pause_ms = 100` (`0…2000`) | `WM.pointerFocus` delay after relevant native focus activity. |
| `layout.gaps_in` | `5` | `layout.gaps_in = 8` (`0…100`) | `HyprConfig.gaps` → `Dwindle.withGaps`. Applied to each interior tile edge on both axes: adjacent margins combine, so `5` normally leaves `10 pt` between clients. |
| `layout.gaps_out` | top `8`, right/bottom/left `12` | `layout.gaps_out = 12` or `layout.gaps_out.top = 16` (`0…200`) | `HyprConfig.gaps` → layout inset. A scalar applies to every side; side fields are `top`, `right`, `bottom`, `left`. Consumer fallback is `20` on an absent side. |
| `layout.default_split_ratio` | `1` | `layout.default_split_ratio = 1.2` (`0.1…1.9`) | `HyprConfig.makeDwindle` divides by two for new splits: `1` gives a 50/50 split. Existing ratios are not balanced by this setting. |
| `layout.split_width_multiplier` | `1` | `layout.split_width_multiplier = 1` (`0.1…10`) | `Dwindle` chooses split orientation using aspect ratio. |
| `layout.minimum_policy` | `native` | `native` or `ratio` | `Dwindle` minimum-size policy. `native` considers learned client minimums; `ratio` preserves split ratios. |
| `focus.follow_mouse` | `1` | `focus.follow_mouse = 0` (integer `0/1`) | `WM.pointerFocus`; `0` disables pointer-driven tile focus. |
| `focus.focus_on_close` | `0` (consumer fallback) | integer `0…2` | `FocusPolicy.focusAfterClose`: `0` nearest surviving tile, `1` tile under pointer with nearest fallback, `2` previous focused tile with nearest fallback. |
| `focus.no_focus_fallback` | `false` | `focus.no_focus_fallback = true` | `FocusPolicy.focusAfterClose` disables fallback selection when true. |
| `drag.mode` | `swap` | `swap` or `insert` | `RuntimeOptions.load` → `WMProduction` titlebar-throw policy. |
| `drag.throw_distance_pt` | `32` | `drag.throw_distance_pt = 32` (`8…400`) | `WMProduction` minimum titlebar-throw displacement. |
| `drag.direction_ratio` | `1.25` | `drag.direction_ratio = 1.5` (`1…4`) | `WMProduction` dominant-direction threshold for a throw. |
| `$schema` | absent | `$schema = "https://example.org/schema.json"` | Editor metadata only. Accepted, not effective at runtime; no schema is fetched. |

## Appearance

[`Appearance.swift`](../hook/swift/Sources/HyprCore/Appearance.swift) parses border, shadow and glow values; `Channel` and `LiveEngine` send them to the native renderer. A valid appearance control does not establish that its visual result has passed live QA. In particular, user transparency remains unfinished.

Colors use `rgb(RRGGBB)`, `rgba(RRGGBBAA)` or `0xAARRGGBB`. Alpha is the final byte for `rgba`, the first for `0x`.

| Key | Portable default | Example / bounds | Consumer / limitation |
| --- | --- | --- | --- |
| `appearance.rounding` | `18` | `appearance.rounding = 18` (`0…100`) | `Appearance.radius` → native effects packet. |
| `appearance.rounding_power` | `2.6` | `appearance.rounding_power = 2.6` (`1…10`) | `Appearance.roundingPower` → native corner shape. |
| `appearance.active_opacity` | `1` | `appearance.active_opacity = 1` (`0…1`) | `WindowPolicy`/WM focus alpha target; unfinished transparency. |
| `appearance.inactive_opacity` | `1` | `appearance.inactive_opacity = 1` (`0…1`) | `WindowPolicy`/WM inactive alpha target; unfinished transparency. |
| `appearance.fullscreen_opacity` | `1` fallback | `appearance.fullscreen_opacity = 1` (`0…1`) | WM fullscreen alpha target; unfinished transparency. |
| `appearance.border.size` | `2` | `appearance.border.size = 2` (`0…20`) | `Appearance.width` → native border width. |
| `appearance.border.active.colors` | `["rgba(ffb4a4ee)", "rgba(7fd0f5ee)"]` | array of `1…8` colors | `Appearance.gradient` builds the active border gradient. |
| `appearance.border.active.angle` | `45` | `appearance.border.active.angle = 45` (`0…90`) | `Appearance.endpoints` controls the gradient. |
| `appearance.border.inactive` | `rgba(53434155)` | `appearance.border.inactive = "rgba(53434155)"` | `Appearance.inactive` → native border. |
| `appearance.shadow.enabled` | `true` | boolean | `Appearance.shadowOn` → native shadow enable. |
| `appearance.shadow.range` | `34` | `appearance.shadow.range = 34` (`1…200`) | Shadow packet blur extent. |
| `appearance.shadow.render_power` | `3` | integer `1…4` | Shadow packet falloff. |
| `appearance.shadow.scale` | `1` fallback | `appearance.shadow.scale = 1` (`0…1`) | Shadow packet scale. |
| `appearance.shadow.offset` | `[0,10]` | two numbers, each `-2000…2000` | Shadow packet x/y displacement. |
| `appearance.shadow.color` | `rgba(00000077)` | color string | Active shadow packet color. |
| `appearance.shadow.color_inactive` | `rgba(00000044)` | color string | Inactive shadow packet color; absent field inherits active color. |
| `appearance.glow.enabled` | `true` in portable baseline | boolean | `Appearance.glowOn` → native glow enable. Consumer fallback is `false`. |
| `appearance.glow.range` | `18` | `appearance.glow.range = 18` (`0…200`) | Native effects packet extent. |
| `appearance.glow.render_power` | `3` | number `1…10` | Native effects packet falloff. |
| `appearance.glow.color` | `rgba(ffb4a433)` | color string | Active glow color. |
| `appearance.glow.color_inactive` | `rgba(ffb4a400)` | color string | Inactive glow color; absent field inherits active color. |

## Lite applicability

The shared parser accepts the same document for both modes. The Lite adapter has a narrower rendering surface; accepted configuration does not imply a foreign macOS window can be styled through public AX APIs. These are source-level capabilities, not a live acceptance claim.

| Keys | Lite behavior |
| --- | --- |
| Layout, focus, drag, rules, runtime enable, text reload | Shared policy is used through the Lite adapters; verify actual app behavior separately. |
| Border size, active colors/angle, inactive color | Consumed by overlay borders and proxy borders. |
| `appearance.rounding` | Rounds overlay/proxy edges; does not change a foreign application's native corner shape. |
| `appearance.rounding_power`, `appearance.shadow.*`, `appearance.glow.*` | **Accepted, not yet effective in Lite:** no corresponding overlay rendering consumer. |
| `appearance.active_opacity`, `inactive_opacity`, `fullscreen_opacity`, rule `opacity` | **Accepted, not effective as user transparency in Lite:** foreign clients remain opaque. Internal zero-alpha commands mean parking/hiding, not public control of another process's window alpha. |
| `runtime.prehide`, `hold_max_ms`, `window_resize_mode`, `capture_sampling` | **Accepted, not effective in Lite:** native first-frame/resize/edge-sampling knobs. Lite capture availability comes from Screen Recording permission and the capture capability. |
| `runtime.overview_hidden_windows` | Forced off in Lite; virtual workspaces do not enable the native hidden-window Mission Control pool. |
| `animations.windowsIn`, `windowsMove`, `windowsOut` and geometry curves | Used by captured-proxy motion when capture is available. Denial/failure falls back to direct AX placement. |
| `animations.border.duration_ms` / enabled | Controls overlay border color transition duration. Moving-proxy border fades use the configured Bezier curve; idle border fades use Core Animation’s default timing, and spring color interpolation is not implemented. |
| `animations.fadeShadow`, `fadeGlow` | **Accepted, not yet effective in Lite:** no shadow/glow render path. |
| `animations.fadeIn`, `fadeOut` | No independent foreign-client fade curve. Opening alpha requests trigger the proxy entrance; cached close proxy duration is bounded by `windowsOut` and `fadeOut` durations. |
| `animations.fadeSwitch` | Does not provide fractional foreign-client focus opacity in Lite. |

## Curves and animations

Use a named curve object and an animation event object. A spring settles according to its physical parameters; `duration_ms` is rejected for a spring. Scale its time with `time_scale` instead. At most 16 distinct active native curves are supported.

```conf
curves {
    calm = {"type":"bezier","points":[[0.25,1],[0.5,1]]}
    settle = {"type":"spring","mass":1,"stiffness":210,"damping":24}
}
animations {
    enabled = true
    windowsMove.curve = settle
    windowsMove.time_scale = 1
    windowsOut.curve = calm
    windowsOut.duration_ms = 260
    windowsOut.style = "popin 92%"
}
```

| Curve field | Default / example | Consumer and bounds |
| --- | --- | --- |
| `curves.<name>.type` | required: `bezier` or `spring` | `NativeRuntimeConfig.build` → `HyprConfig.curves`; names begin with a letter and contain at most 64 letters/digits/`_`/`-`. |
| `curves.<name>.points` | required for bezier: `[[0.25,1],[0.5,1]]` | Exactly two `[x,y]` pairs; x `0…1`, y `-10…10`. |
| `curves.<name>.mass` | `1` | Spring mass `0.001…100`. |
| `curves.<name>.stiffness` | `250` fallback | Spring stiffness `0.001…100000`. |
| `curves.<name>.damping` | `25` fallback | Spring damping `0.001…10000`. |
| `curves.<name>.dampening` | alias for `damping` | Accepted and effective alias; do not supply both. |

Portable named curves are `smooth` (`[[0.25,1],[0.5,1]]`), `snappy` (`[[0.2,0.9],[0.1,1]]`), `overshot` (`[[0.05,0.9],[0.1,1.06]]`), `drift` (spring `1/210/24`) and `bounce` (spring `1/260/20`). Built-in `default` is `[[0,0.75],[0.15,1]]`.

The following fields apply to **each event listed in the next table**. Unspecified fields inherit from the nearest configured ancestor, finally `global`. `animations.enabled` is a master boolean, default `true`.

| Event field | Default | Example / actual consumer |
| --- | --- | --- |
| `animations.<event>.enabled` | inherited, normally `true` | `animations.windowsMove.enabled = false`; `HyprConfig.anim` gates that event. Angle events default off. |
| `animations.<event>.curve` | inherited | `animations.windowsOut.curve = snappy`; resolved by `HyprConfig.curves`. |
| `animations.<event>.duration_ms` | inherited; table below | `animations.windowsOut.duration_ms = 260` (`0…10000`); Bezier timing only. |
| `animations.<event>.time_scale` | geometry: top-level `time_scale`; others: `1` | `animations.windowsMove.time_scale = 1.2` (`0.1…4`); scales duration or spring parameters. |
| `animations.<event>.style` | inherited, normally empty | Custom style is supported only on `global`, `windows`, `windowsIn`, `windowsOut`. Use empty, `fade`, `popin N%`, `slidefade N%`, `slidefadevert N%`, N `0…100`. Native open/close consumers use fade/popin scale; other styles have no separate Swift choreography. A style on other events is rejected by semantic validation. |

| Event(s) | Portable default | Consumer / status |
| --- | --- | --- |
| `global` | enabled, `smooth`, `800 ms` | Inheritance root. |
| `windows` | inherits global | Parent of window events. |
| `windowsIn` | `bounce` spring, scale `1`, `popin 86%` | `WM.apply` opening geometry. |
| `windowsOut` | `snappy`, `260 ms`, `popin 92%` | `WM` close/hide; native close packet. |
| `windowsMove` | `drift` spring, scale `1` | `WM.apply` layout movement and resize. |
| `fade` | inherits global | Parent of fade events. |
| `fadeIn` | `smooth`, `300 ms` | Opening/restore alpha in WM and `Visibility`. |
| `fadeOut` | `smooth`, `240 ms` | Closing/hiding alpha in WM and native close packet. |
| `fadeSwitch` | `smooth`, `400 ms` | `Visibility` focus alpha. |
| `border` | `smooth`, `600 ms` | `Channel.configureAppearance` border transition. |
| `fadeShadow` | inherits fade (`smooth`, `800 ms`) | `Channel.configureAppearance` shadow transition. |
| `fadeGlow` | inherits fade (`smooth`, `800 ms`) | `Channel` effects update duration. |
| `borderangle`, `shadowangle`, `glowangle` | disabled, built-in `default`, `100 ms` | **Accepted, not yet effective:** no angle animation consumer. |
| `layers`, `layersIn`, `layersOut` | global inheritance | **Accepted, not yet effective:** no macOS layer choreography consumer. |
| `fadeDim`, `fadeDpms` | fade inheritance | **Accepted, not yet effective:** no dim/DPMS event consumer. |
| `fadeLayers`, `fadeLayersIn`, `fadeLayersOut` | fade inheritance | **Accepted, not yet effective:** no layer fade consumer. |
| `fadePopups`, `fadePopupsIn`, `fadePopupsOut` | fade inheritance | **Accepted, not yet effective:** no popup fade consumer. |
| `zoomFactor`, `monitorAdded` | global inheritance | **Accepted, not yet effective:** no corresponding event consumer. |
| `workspaces`, `workspacesIn`, `workspacesOut` | global inheritance | **Accepted, not yet effective in the native path:** no consumer of these animation records. Workspace command support is separate. |
| `specialWorkspace`, `specialWorkspaceIn`, `specialWorkspaceOut` | workspace inheritance | **Accepted, not yet effective:** no special-workspace animation consumer. |

## Rules and shortcuts

Rules are evaluated in order. All conditions in `match` must match. Regexes match the **whole value**, so use `.*Editor.*` for a substring. Prefix `negative:` to invert a regex. `class` means the macOS owner/application name, not a Linux WM_CLASS or bundle identifier.

```conf
windowrule = float, app:^Calculator$
windowrule = no_follow_mouse, title:.*Preview.*
# Object form exposes fields that the readable syntax does not:
windowrule = {"name":"quiet","match":{"class":"^Calculator$"},"no_anim":true}
bind = CTRL ALT, H, focus, left
```

| Rule field (`windowrule = {...}` / `window_rules` array) | Default | Consumer / example |
| --- | --- | --- |
| `name` | absent | Diagnostic/UI label, at most 128 characters; `"calculator"`. |
| `enabled` | `true` | `WindowProperties.matches`; false skips a rule. |
| `match.class` | absent | `WindowProperties.matches` against owner name; `"^Calculator$"`. |
| `match.title` | absent | `WindowProperties.matches` against title; `".*Preview.*"`. |
| `match.role`, `match.subrole` | absent | `WindowProperties.matches` against AX role/subrole, e.g. `"^AXWindow$"` / `"^AXDialog$"`. Unknown/empty metadata never satisfies either a positive or negative match. |
| `float` | unchanged | WM classification; `true` floats, `false` permits tiling when otherwise eligible. A matched float classification is latched for that observed window lifetime in the running daemon; see below. |
| `ignore` | `false` | `WM.ignored`/`releaseIgnored` excludes a window from management. |
| `no_anim` | `false` | `WM.windowPolicy` suppresses core-managed move/open/hide/restore/focus animation. The Lite external-close proxy path does not currently consult this rule. |
| `no_follow_mouse` | `false` | `WM.windowPolicy` suppresses pointer focus for that window. |
| `opacity` | no override | `WindowProperties.opacity` → WM alpha. Number `0…1`, or up to three values for active/inactive/fullscreen, e.g. `"1 0.9 1"`; suffix a value with `override` to replace rather than multiply the global opacity. Transparency is unfinished. |

At most 128 rules are accepted, each with at least one condition and regex length at most 512. Later matching rules replace earlier values for each action they specify.

**Float rules are currently lifetime-latched.** Once a live window matches a float rule, changing/removing that rule or setting `float = false` does not clear its cached classification through hot reload. The explicit float toggle also does not clear this rule cache. Restarting HyprWM re-evaluates rules; separately saved explicit floating state still applies. This exception is distinct from appearance-only rule changes and other hot-reloaded values.

Readable `bind` syntax uses `SUPER`/`CMD`/`COMMAND` = **Command**, `ALT`/`OPTION` = **Option**, `CTRL`/`CONTROL` = **Control**, plus `SHIFT`. At least Command, Option or Control is required. This differs from the legacy Lua baseline's modifier translation; use the actual macOS key names when editing text. Supported named keys include letters, digits, arrows, punctuation, Return, Tab, Space, Escape, Backspace and F1–F12; `code:0…127` selects a Carbon keycode.

| Binding object field (`bind = {...}` / `hotkeys` array) | Default | Actual consumer |
| --- | --- | --- |
| `id` | readable bind generates `2048 + ordinal` | Baseline identity `0…4095`; `NativeHotkeys.apply` or `LiteHotkeys.reload` resolves an override. IDs alone refer to the active mode's baseline; include `command` when moving bindings between modes. |
| `keycode` | required by text schema | Carbon code `0…127`, e.g. H = `4`. |
| `modifiers` | required by text schema | Carbon mask: Command `256`, Shift `512`, Option `2048`, Control `4096`; combine with addition. |
| `enabled` | `true` | The active hotkey handler skips disabled bindings. |
| `command` | baseline action if omitted | Array of `1…32` strings, each at most 512 characters. Matches an existing action or adds a binding when chord fields are supplied; not a shell program. |

At most 256 overrides are accepted. Duplicate enabled chords are refused. Lite registers its built-in baseline and overrides through Carbon in the runtime. Engine needs its native binding baseline and separate hotkey watcher; parsing a `bind` line alone does not start that watcher. Engine also registers a separate fixed Control–Option–P panic shortcut through Carbon; editing ordinary binding overrides does not remap or disable that safety chord. Another application can already own a Carbon chord; Lite reports the registration conflict count in `status.lite.hotkey_conflicts`. Settings → Hotkeys shows the configured bindings. See [API.md](API.md) for supported command arguments and [MIGRATING.md](MIGRATING.md) for foreign modifier conversion.
