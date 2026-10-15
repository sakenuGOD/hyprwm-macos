# HyprWM for macOS

HyprWM is an independent, experimental tiling window manager for macOS, inspired by Hyprland's layouts and motion. It combines a Swift runtime, a menu bar settings companion, and a native WindowServer animation engine.

## Install

Visit the [latest release](https://github.com/sakenuGOD/hyprwm-macos/releases/latest), download the `.dmg` asset when available, mount it, and drag **HyprWM.app** into **Applications**. Build details are on the [releases page](https://github.com/sakenuGOD/hyprwm-macos/releases).

**The current app package is a menu companion. It requires an already installed native engine, a running compatible daemon, and the source checkout used to build it. It is not a standalone window manager installer.** The package stores a source path and does not bundle or install the native engine. Moving or deleting that checkout can break settings and runtime discovery. A fresh Mac installation is not yet a supported end-to-end flow.

The Swift package targets macOS 14 or later; this is a build minimum, not a compatibility guarantee for the private WindowServer integration. Native engine development currently requires a specially configured development system. The DMG does not configure that system for you.

Grant **Accessibility** access in **System Settings → Privacy & Security → Accessibility** to the app or process actually controlling windows. The native global hotkey watcher also needs the event-access permissions requested by macOS. Relaunch after changing permissions. Permissions alone do not install or start the native engine.

## Configuration

The shared editable configuration is `~/.config/hyprwm/hyprwm.conf`. Settings and the Swift runtime use this file; edits are watched and applied after saving. `HYPRWM_CONFIG` can select another file. For example:

```conf
layout {
    gaps_in = 5
    gaps_out.top = 12
}
runtime {
    overview_hidden_windows = false
}
```

Use the settings window's **Advanced** page to open, import, export, or reset the configuration. Import accepts a valid HyprWM UTF-8 text configuration up to 256 KiB and backs up the existing file before replacing it. Arbitrary Hyprland configurations are not interchangeable with this format. The developer Lua importer is separate and executes Lua; inspect imported files first.

Edit shortcuts in **Settings → Hotkeys**. The native watcher must already have a generated binding baseline. Typical onboarding shortcuts are **Control–Option–Arrow** for focus, **Control–Option–Shift–Arrow** to move a window, and **Control–Option–F** for floating; the installed list is authoritative because imported bindings may differ. Text `bind` entries override existing actions rather than creating arbitrary new actions.

## Control and development

The runtime exposes a local Unix socket, normally `/tmp/hyprwm.ctl`. From a source checkout:

```sh
hook/ctl.sh status
```

See the [API reference](docs/API.md) for command syntax, configuration, and runtime interfaces, and [CONTRIBUTING.md](CONTRIBUTING.md) for builds, source navigation, and manual verification.

## Current limitations

- Showing hidden windows in **Mission Control is in progress and off by default**. The experimental setting is not a completion claim.
- **Window transparency is unfinished**; appearance controls do not imply reliable end-to-end transparency.
- Focus after close, modal/dialog handling, Zen browser behavior, and rapid animation bursts still need live validation. Automated tests cannot establish those behaviors.
- The app package depends on the existing native installation and checkout. Broad macOS compatibility and clean-machine installation remain unverified.

Tracked work: [standalone installation](https://github.com/sakenuGOD/hyprwm-macos/issues/1), [Mission Control hidden windows](https://github.com/sakenuGOD/hyprwm-macos/issues/2), [transparency](https://github.com/sakenuGOD/hyprwm-macos/issues/3), [focus/dialog validation](https://github.com/sakenuGOD/hyprwm-macos/issues/4), [Zen compatibility](https://github.com/sakenuGOD/hyprwm-macos/issues/5), and [animation bursts](https://github.com/sakenuGOD/hyprwm-macos/issues/6). Follow the [roadmap](docs/ROADMAP.md) and [issue tracker](https://github.com/sakenuGOD/hyprwm-macos/issues). Reports should include macOS version, build, relevant settings, exact steps, and observed behavior. Remove private window titles, application content, and personal paths from logs.

## Uninstall

Choose **Quit HyprWM** from the menu and wait for shutdown/restoration to finish. The companion delegates this to the existing lifecycle helper, which must be present in the source checkout. Confirm hidden windows are visible before removing anything; if shutdown reports an error, keep the runtime and checkout in place until recovery is complete. The legacy `hook/stop.sh` targets the Python daemon and is not a general Swift-runtime uninstaller.

Remove **HyprWM.app** from Applications. Optionally remove `~/.config/hyprwm` after saving configuration and backups, and revoke its Accessibility/event-access grants in System Settings. The DMG does not remove an independently installed native engine or reverse development-system settings; undo those through the procedure used to install them.
