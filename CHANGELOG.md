# Changelog

## 0.1.0 — 2026-10-28

First public source release.

- Dwindle tiling, keyboard controls, floating windows and fullscreen layout.
- Native animations, gradient borders, shadows, glow and window cropping.
- Focus follows mouse, menu bar controls and SwiftUI Settings.
- Live text configuration, imports and local `hyprwm` / `hyprwmctl` tools.

**Requirements:** building the app needs macOS 14+ and Xcode Command Line Tools.
Tiling needs **macOS 26.7.1 (25G241), Apple silicon, disabled SIP debugging
restrictions and admin rights**. The engine runs inside WindowServer. Repeat
native setup after reboot. Keep the source folder after installing.

**Known issues:**
- [Source folder required](https://github.com/sakenuGOD/hyprwm-macos/issues/8), [hidden windows in Mission Control](https://github.com/sakenuGOD/hyprwm-macos/issues/9), [transparency](https://github.com/sakenuGOD/hyprwm-macos/issues/10).
- [Focus, dialogs and tabs](https://github.com/sakenuGOD/hyprwm-macos/issues/11), [remaining English translation](https://github.com/sakenuGOD/hyprwm-macos/issues/12).
- [New-window flashes](https://github.com/sakenuGOD/hyprwm-macos/issues/13), [shrinking and seams](https://github.com/sakenuGOD/hyprwm-macos/issues/14), [hidden-window restore](https://github.com/sakenuGOD/hyprwm-macos/issues/15), [drag throws](https://github.com/sakenuGOD/hyprwm-macos/issues/16).
- [Spaces and fullscreen](https://github.com/sakenuGOD/hyprwm-macos/issues/17), [animation settings without an effect](https://github.com/sakenuGOD/hyprwm-macos/issues/18), [inactive app appearance](https://github.com/sakenuGOD/hyprwm-macos/issues/19), [screen lock](https://github.com/sakenuGOD/hyprwm-macos/issues/20).
- [Three existing Swift test failures](https://github.com/sakenuGOD/hyprwm-macos/issues/21); the Swift app builds, but the full suite is not green.

Native toolbar and configure-stream are experimental and off by default.

Source only, no prebuilt binary.
