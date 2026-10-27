# HyprWM

HyprWM is an experimental tiling window manager for macOS. It arranges application windows in a dwindle layout, adds keyboard controls and animates their presentation through a native engine. Applications keep their own window identity, input and Spaces membership.

The Swift daemon, menu, settings, configuration tools and native build sources are available here. The native engine has a separate, privileged setup for the supported macOS fingerprint. The app installer preserves the selected engine installation.

## Build

You need macOS 14 or later, Xcode Command Line Tools with Swift 5.9 or later, Python 3 and Git.

```sh
git clone https://github.com/sakenuGOD/hyprwm-macos.git
cd hyprwm-macos
./scripts/build-hyprwm
```

The executable is `hook/swift/.build/release/hyprwm-swift`. You can inspect configuration and layout without starting the daemon:

```sh
./scripts/hyprwm --help
./scripts/hyprwm --print-config
```

To build the user-local app and CLI wrappers for an existing qualified native installation:

```sh
./install.sh --engine-state /path/to/qualified-native-hook/anim4.state
```

This preserves existing configuration and leaves the app stopped. The native receipt stays outside the signed app; updates preserve its selected location. `HYPRWM_ENGINE_STATE` can explicitly override it at runtime. The installed app launches the daemon; the separate `build_app.sh` workflow builds a menu companion. Keep the checkout in place. See [packaging](hook/swift/PACKAGING.md) for bundle details.

## Run

On a machine with a qualified native engine and its support libraries:

```sh
./scripts/hyprwm
./scripts/hyprwmctl status
```

Grant Accessibility access when macOS requests it. HyprWM checks the macOS build and framework UUIDs, reads the native window census, then verifies placement using its own service window. Failed qualification leaves tiling disabled and shows an unverified status in the menu. The currently qualified development fingerprint is macOS build `25G241`; another build needs its own qualification.

Use the menu's restoration-aware quit action to return managed windows before
exiting. See [deployment and rollback](DEPLOY.md) before updating a running
daemon. The legacy `hook/start.sh` and `hook/stop.sh` depend on development-only
lifecycle support and are not the clean-checkout launch path.

For a first native installation, follow [native Engine setup](DEPLOY.md#native-engine-first-setup). `hook/tools/build_native.py` builds the complete current image and runs its structural and unwind checks. Its OS-derived output stays in a private directory outside the checkout. `hook/build_anim4.sh` is a legacy entry point and does not build the current image.

## Configuration and controls

Configuration lives in `~/.config/hyprwm/hyprwm.conf`. Existing settings survive installation. The menu provides status, pause/resume and settings; local commands use the user-owned Unix socket `/tmp/hyprwm.ctl`.

```sh
./scripts/hyprwmctl focus left
./scripts/hyprwmctl layout balance
./scripts/hyprwmctl float
./scripts/hyprwmctl pause
./scripts/hyprwmctl resume
```

See [configuration](docs/CONFIG.md), [commands and events](docs/API.md), [migration](docs/MIGRATING.md) and [troubleshooting](docs/TROUBLESHOOTING.md). Shortcut registration is supplied by the optional `hook/keys` helper. Native workspace switching requires a current session-bound service; an old session lease is refused.

Explicit floats, float rules and native auxiliary windows share the floating
plane above ordinary tiles. Local playback documents identified through macOS
Accessibility and file types stay floating. `layout.minimum_policy = "ratio"`
keeps split proportions when an application needs a larger native frame; its
presentation is cropped to the allocated tile. Use `hyprwmctl pan left`, `right`, `up`, `down` and `reset` to reach clipped content where the native viewport is available. Fullscreen and float controls remain available. The separate toolbar navigation UI is not included.

## Current limits

The native presentation path uses accepted client texture dimensions for 1:1 crop and edge extension. It retains working frames during transfer and falls back to the application when a source cannot be qualified. The optional [application helper](DEPLOY.md#application-menus) enables first-map handoff for new ordinary AppKit windows. Cold-launch first windows can precede helper attachment; universal first-display and restore coverage remain incomplete. Retained-close prewarming is disabled: the closing window can still disappear abruptly, even when its neighbor animates. Native presentation and compatibility remain experimental, and a source build alone does not qualify a machine.

The current checkout ships the Engine runtime. Historical Lite behavior appears
in the [animation comparison](docs/ANIMATION_AUDIT.md), with unavailable code
and unverified behavior explicitly marked.

## Development

```sh
./scripts/test-hyprwm
```

The wrapper regenerates the large deterministic WM scenarios locally from the Python reference, then runs the Swift tests. Generated scenarios and build outputs stay outside Git. These tests cover configuration, layout and policy; desktop focus, input and presentation require observation in a real session.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the source map and verification conventions. Reports should include the macOS build, runtime mode, a small reproduction and recovery outcome. Remove private window titles and content from shared evidence.

## License

[GNU General Public License v3.0](LICENSE).
