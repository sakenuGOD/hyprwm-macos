# HyprWM

HyprWM is an experimental tiling window manager for macOS. It arranges application windows in a dwindle layout, adds keyboard controls and animates their presentation through a native engine. Applications keep their own window identity, input and Spaces membership.

The Swift daemon, menu, settings, configuration tools and reference tests are available here. Running the tiling engine requires a separately qualified native installation. The source installer builds the app and command-line tools; it does not install that engine.

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

To build the user-local app and CLI wrappers:

```sh
./install.sh
```

This preserves existing configuration and leaves the app stopped. The installed app launches the daemon; the separate `build_app.sh` workflow builds a menu companion. Keep the checkout in place. See [packaging](hook/swift/PACKAGING.md) for bundle details.

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

The native image has a separate build and deployment workflow. `hook/build_anim4.sh` is a legacy developer entry point; it does not build the current presentation C++/assembly entry points or perform whole-image qualification. Native rebuilds also require the complete optional effects source package, which is outside this checkout. Do not deploy a partial image into a desktop session.

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
presentation is cropped to the allocated tile. Fullscreen and float controls
can expose clipped controls; independent viewport panning is still unfinished.

## Current limits

The native presentation path uses accepted client texture dimensions for 1:1 crop and edge extension. It retains working frames during transfer and falls back to the application when a source cannot be qualified. Generic first-display pop-in still needs an early positive primary-window admission; it is not complete. Native presentation and compatibility remain experimental, and a source build alone does not qualify a machine.

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
