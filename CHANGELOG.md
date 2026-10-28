# Changelog

## 0.1.1 — 2026-10-28

- Added checks before installation for macOS 26.7.1, build 25G241 and Apple silicon.
- Clarified that the supported native setup uses **SIP fully disabled**, with
  Recovery instructions and a `csrutil status` check. Debugging-only SIP changes
  have not been verified for this engine.
- Added complete manual keyboard-helper build and start commands, default focus
  and move shortcuts, and permission requirements. The app installer does not
  build or start the helper.
- Clarified that only an existing HyprWM session needs to quit before native setup.
- Removed the outdated Swift test failure warning for closed issue
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
