<h1 align="center">HyprWM</h1>

<p align="center">
  <a href="docs/media/showcase.mp4">
    <img src="docs/media/hero.gif" width="100%" alt="HyprWM tiling windows on macOS with animated borders">
  </a>
</p>

<p align="center">
  Hyprland-style tiling for macOS: dwindle layout, keyboard control,<br>
  smooth animations and gradient borders.
</p>

> [!WARNING]
> **Experimental. Read before installing.**
> - Tiling requires the native engine, which runs inside WindowServer.
> - The engine supports only **macOS 26.7.1 (build 25G241), Apple silicon**.
>   Other builds are refused at startup.
> - It needs **System Integrity Protection (SIP) fully disabled**
>   and `sudo` for setup. Use a machine you are comfortable experimenting on.
> - Setup installs automatic startup services by default; keep their recovery files.
> - A native-engine failure can disrupt your desktop. Save your work first.

## Features

- Dwindle tiling with adjustable gaps and split ratios.
- Keyboard commands for focus, moving windows, floating and fullscreen.
- Animated window opening, closing, movement and resizing.
- Gradient borders, rounded corners, shadows and glow.
- Focus follows mouse, with rules for individual applications.
- Menu bar controls and a SwiftUI Settings window.
- Text configuration with live reload and import from Hyprland and other WMs.
- Local `hyprwm` and `hyprwmctl` command-line tools.

Closing animations and some focus cases still need work. See [known issues](#status-and-known-issues).

## Screenshots

| Settings | Appearance |
| --- | --- |
| ![General settings](docs/screenshots/general.png) | ![Appearance settings](docs/screenshots/appearance.png) |
| ![Menu bar controls](docs/screenshots/menu.png) | ![Advanced settings](docs/screenshots/advanced.png) |

[Watch the 48-second demo](docs/media/showcase.mp4) · [View the poster](docs/media/poster.png)

## Requirements

| What you want to do | What you need |
| --- | --- |
| Build the Swift app | macOS 14+, Xcode Command Line Tools (Swift 5.9+), Python 3 and Git. |
| Run with tiling | All of the above, **macOS 26.7.1 (25G241), Apple silicon, SIP fully disabled, and admin rights**. |
| Rebuild a Hyprland Lua configuration in a source checkout | Optional: `lua` (`brew install lua`). The installed app does not need Lua. |

Tiling stays off without the native engine. There is no Lite mode in this branch.

## Install

0. **Check the Mac and SIP before building.** Run:

   ```sh
   sw_vers -productVersion
   sw_vers -buildVersion
   uname -m
   csrutil status
   ```

   The first three must print `26.7.1`, `25G241` and `arm64`. SIP must be **fully
   disabled**; debugging-only changes have not been verified. If needed, shut down,
   hold the power button until startup options appear, choose **Options → Continue**,
   then **Utilities → Terminal**. Run `csrutil disable` in Recovery, restart, and
   confirm `csrutil status` reports `System Integrity Protection status: disabled.`
   This reduces system protection. Re-enable it with `csrutil enable` in Recovery
   and restart when you stop using the native engine. See [Apple's SIP instructions](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection)
   and [Apple silicon Recovery steps](https://support.apple.com/102518).

1. **Clone and run setup as your normal user:**

   ```sh
   git clone https://github.com/sakenuGOD/hyprwm-macos.git
   cd hyprwm-macos
   ./setup.sh
   ```

   Setup builds the app and native engine, installs global shortcuts and automatic
   startup, and opens the app. It requests missing Command Line Tools and waits for
   installation; if Git or Python is still missing, it uses an existing Homebrew.
   Defaults do not need Lua. Each privileged action explains why it needs `sudo`.
   If cloning opens the Command Line Tools installer, finish it and repeat the clone.

2. **Allow Accessibility for HyprWM** in **System Settings → Privacy & Security →
   Accessibility** when setup opens it. Setup waits for access. The keyboard helper
   uses Carbon's `RegisterEventHotKey` and needs neither Accessibility nor Input
   Monitoring. The optional shortcut recorder in Settings may need Input Monitoring.

3. **Try the default shortcuts** with two ordinary application windows open:

   | Shortcut | Action |
   | --- | --- |
   | Control–Option–arrows | Focus a neighboring tile. |
   | Control–Option–Shift–arrows | Move the focused tile. |
   | Control–Option–F | Toggle floating. |
   | Option–F | Toggle fullscreen layout. |
   | Option–Shift–Return | Toggle maximized layout. |
   | Control–Option–P | Pause/resume tiling; fixed global safety shortcut. |

   Check **HyprWM Settings → Keyboard Shortcuts** for the helper's registration
   status and your active bindings. Successful setup prints
   `Tiling:ON, hotkeys:ON, autostart:ON`.

4. **Automatic startup is enabled by default.** The services are designed to prepare
   the engine and start HyprWM and its keyboard helper when you log in after a
   reboot. Setup checks the current session; it does not reboot to test the next
   login. If automatic startup fails, use `./scripts/hyprwm-up` as a manual fallback
   and follow the [startup checks and logs](docs/TROUBLESHOOTING.md#automatic-startup-fails-after-a-reboot).

Keep the checkout for updates and manual recovery. Add `~/.local/bin` to `PATH` to
use `hyprwm` and `hyprwmctl` by name. See [INSTALL.md](docs/INSTALL.md) for setup
options, manual installation, logs and removal.

## Configuration

Edit `~/.config/hyprwm/hyprwm.conf`, or use Settings. Save to reload.
For example:

```conf
layout.gaps_in = 8
appearance.border.size = 2
focus.follow_mouse = 1
windowrule = float, app:^Calculator$
```

Read [configuration and imports](docs/CONFIG.md) and the [CLI reference](docs/CLI.md).
Import a supported text configuration with `hyprwm import /path/to/hyprland.conf`.

## Uninstall / if something goes wrong

Restore windows before removing the app:

```sh
~/.local/bin/hyprwmctl restore-all
./uninstall.sh
```

If restoration is pending, keep the app and its state until it finishes.
Use **Control–Option–P** to pause an unexpected layout or focus loop.
See [troubleshooting](docs/TROUBLESHOOTING.md) and [native rollback](docs/INSTALL.md#rollback-and-uninstall).

## How it works

A Swift daemon handles layout, configuration, UI and local commands.
It uses Accessibility to control application windows.
A native engine loaded into WindowServer through LLDB/task access handles
animation and cropping. Its framework addresses and UUIDs match one macOS build,
so updating macOS can make it refuse to start.

## Status and known issues

This is a source-only experimental release. There is no prebuilt binary.

- [Hidden windows in Mission Control are unfinished](https://github.com/sakenuGOD/hyprwm-macos/issues/9); the Beta option is off by default.
- [Window transparency is unreliable](https://github.com/sakenuGOD/hyprwm-macos/issues/10).
- [Focus after closing windows, modal dialogs and Zen tabs needs work](https://github.com/sakenuGOD/hyprwm-macos/issues/11).
- [Remaining Russian comments](https://github.com/sakenuGOD/hyprwm-macos/issues/12) need translation.
- [New windows can flash before reaching their tile](https://github.com/sakenuGOD/hyprwm-macos/issues/13).
- [Windows can jump or show a seam while shrinking](https://github.com/sakenuGOD/hyprwm-macos/issues/14).
- [Restoring a hidden window can end with a jump](https://github.com/sakenuGOD/hyprwm-macos/issues/15).
- [Drag throws can be ignored or choose the wrong tile](https://github.com/sakenuGOD/hyprwm-macos/issues/16).
- [Windows can disappear during Space and fullscreen changes](https://github.com/sakenuGOD/hyprwm-macos/issues/17).
- [Some animation settings are accepted without a visible effect](https://github.com/sakenuGOD/hyprwm-macos/issues/18).
- [Inactive app appearance is inconsistent](https://github.com/sakenuGOD/hyprwm-macos/issues/19).
- [The layout can be lost after locking the screen](https://github.com/sakenuGOD/hyprwm-macos/issues/20).
- Experimental, off by default: native toolbar, configure-stream.

## Development

Run `./scripts/build-hyprwm` and `./scripts/test-hyprwm`.
Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing native code.

## License

[GPL-3.0](LICENSE).
