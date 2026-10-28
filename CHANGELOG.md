# Changelog

## 0.1.1 — 2026-10-28

- Added `./setup.sh` to check dependencies, build the app and native engine, select
  paths automatically, and preserve existing configuration and verified sessions.
- Enabled automatic startup by default through a native-session LaunchDaemon and
  backend and keyboard LaunchAgents. Added `./scripts/hyprwm-up` as a manual fallback.
- Added a no-Lua default keyboard setup, registration status and keyboard logs.
  Global shortcuts use Carbon and need no Input Monitoring; app Accessibility and
  optional shortcut-recorder access are shown separately.
- Added `--dry-run`, `--yes`, `--no-open` and `--no-autostart` setup options.
- Bundled app resources, kept persistent app state outside the signed app, and
  included owned startup services in normal uninstall.
- Documented exact macOS 26.7.1 / 25G241 / Apple silicon requirements, fully disabled
  SIP and Recovery steps. Partial debugging-only SIP changes remain unverified.
- Replaced the installation walkthrough with five steps and added build, SIP,
  Accessibility, shortcut and reboot-startup troubleshooting.
- Removed the outdated Swift test warning for closed issue
  [#21](https://github.com/sakenuGOD/hyprwm-macos/issues/21).

## 0.1.0 — 2026-10-28

First public source release.

- Dwindle tiling, keyboard controls, floating windows and fullscreen layout.
- Native animations, gradient borders, shadows, glow and window cropping.
- Focus follows mouse, menu bar controls and SwiftUI Settings.
- Live text configuration, imports and local `hyprwm` / `hyprwmctl` tools.

**Requirements:** building the app needs macOS 14+ and Xcode Command Line Tools.
Tiling needs **macOS 26.7.1 (25G241), Apple silicon, SIP fully disabled
and admin rights**. The engine runs inside WindowServer. Repeat
native setup after reboot. Keep the source folder after installing.

**Known issues:**
- [Source folder required](https://github.com/sakenuGOD/hyprwm-macos/issues/8), [hidden windows in Mission Control](https://github.com/sakenuGOD/hyprwm-macos/issues/9), [transparency](https://github.com/sakenuGOD/hyprwm-macos/issues/10).
- [Focus, dialogs and tabs](https://github.com/sakenuGOD/hyprwm-macos/issues/11), [remaining English translation](https://github.com/sakenuGOD/hyprwm-macos/issues/12).
- [New-window flashes](https://github.com/sakenuGOD/hyprwm-macos/issues/13), [shrinking and seams](https://github.com/sakenuGOD/hyprwm-macos/issues/14), [hidden-window restore](https://github.com/sakenuGOD/hyprwm-macos/issues/15), [drag throws](https://github.com/sakenuGOD/hyprwm-macos/issues/16).
- [Spaces and fullscreen](https://github.com/sakenuGOD/hyprwm-macos/issues/17), [animation settings without an effect](https://github.com/sakenuGOD/hyprwm-macos/issues/18), [inactive app appearance](https://github.com/sakenuGOD/hyprwm-macos/issues/19), [screen lock](https://github.com/sakenuGOD/hyprwm-macos/issues/20).

Native toolbar and configure-stream are experimental and off by default.

Source only, no prebuilt binary.
