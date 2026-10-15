# HyprWM for macOS

HyprWM is an independent, experimental tiling window manager that brings Hyprland-inspired binary split layouts and motion to macOS. Open a window and the layout makes room; move focus or rearrange tiles from the keyboard, tune gaps and appearance in a native settings window, and keep the same configuration in a hot-reloaded text file. If you are new to tiling, start with two disposable windows; if you already use Hyprland or AeroSpace, start with the [migration guide](docs/MIGRATING.md). Lite is the intended everyday path without system security changes; Engine is an opt-in development path with deeper native integration.

<a id="showcase"></a>
**Showcase pending:** the launch recording and hero GIF/WebP will be linked here after real desktop capture and frame review. Existing [settings screenshots](#settings) show the interface, not proof of runtime motion.

## 60-second quickstart

The commands take about a minute to enter; the first build takes longer. This preview currently lives on `launch/2026-10-16`, so clone that branch. You need macOS 14 or later, Xcode Command Line Tools with Swift 5.9 or later, and Python 3. The installed Lite path uses a bundled baseline and does not need Lua. This is a source preview; no downloadable standalone release is promised here.

```sh
git clone --branch launch/2026-10-16 https://github.com/sakenuGOD/hyprwm-macos.git
cd hyprwm-macos
./install.sh
```

**Install/launch verification pending on this development branch.** The install and recovery CLI are being integrated. Do not treat this section as a clean-machine pass until the final verification note replaces this paragraph. The installer builds the app into `~/Applications`, adds `hyprwm` and `hyprwmctl` under `~/.local/bin`, preserves existing config and does not launch a daemon. Launch after granting permissions with `open ~/Applications/HyprWM.app`; desktop launch still needs separate verification.

Grant **Accessibility** access to HyprWM (or the exact controlling process named by the OS prompt) in **System Settings → Privacy & Security → Accessibility**. Screen capture animations additionally need **Screen & System Audio Recording** / **Screen Recording**. Carbon runtime shortcuts do not need Input Monitoring; the settings shortcut recorder can request it. Relaunch after granting permissions. Stop another automatic tiler before starting HyprWM.

Once running, open two disposable Terminal or TextEdit windows. Try the focus/move shortcuts below and keep the recovery commands available:

```sh
~/.local/bin/hyprwm doctor
~/.local/bin/hyprwmctl status
~/.local/bin/hyprwm restore-all
```

`doctor` diagnoses readiness; `status` reports runtime state; `restore-all` is for HyprWM-owned hidden/parked windows. A pending/refused result needs attention before removal. See [troubleshooting](docs/TROUBLESHOOTING.md).

## Default shortcuts

These are actual macOS keys from the portable baseline. An existing or imported configuration may differ; **Settings → Hotkeys** is authoritative. Shortcuts require the mode’s hotkey handler. Carbon runtime shortcuts do not require Input Monitoring; the settings recorder uses an event tap.

| Shortcut | Action |
| --- | --- |
| Control–Option–P | Panic pause / resume; also available in the menu. |
| Control–Option–Arrow | Focus the neighboring tile. |
| Control–Option–Shift–Arrow | Move the current tile in that direction. |
| Control–Option–Return | Toggle the current split orientation. |
| Control–Option–F | Toggle floating. |
| Option–F | Toggle layout fullscreen. |
| Option–Shift–Return | Toggle maximized layout in the working area. |
| Option–Q | Close the current window. |
| Option–W / Option–Shift–W | Hide / restore the most recently hidden window. |
| Option–Shift–B | Balance split ratios. |
| Control–Option–Shift–T | Retile. |
| Option–1…9, Option–0 | Select workspace 1…10, where the active mode supports it. |
| Control–Option–1…9 / Control–Option–0 | Move to a workspace where supported; verify the mode's command capability. |

Workspace bindings in the baseline do not establish native Space creation or switching support. Engine uses existing macOS Spaces through capability-checked backends; Lite's virtual workspace path is tracked separately. Read the mode status before relying on workspace actions.

## Lite and Engine

| | Lite | Engine |
| --- | --- | --- |
| System changes | Intended to run with SIP on, no boot arguments, no WindowServer injection, no root at runtime. | Requires a development system with SIP disabled and `amfi_get_out_of_my_way=1`, plus an injected native engine. |
| Window control | Accessibility-based live placement and focus. | Swift policy and AX client frames plus native presented-frame control. |
| Motion and borders | Overlay/proxy path; capture permission and available capabilities determine animation support. | WindowServer engine owns the presented body/border timeline. |
| Workspace model | Virtual workspace implementation; consult the current capability report. | Existing native macOS Spaces; backend availability is checked. |
| Validation | SIP-on compatibility must be sourced or tested on SIP-on hardware. A SIP-off test is insufficient. | Private integration is OS-sensitive; macOS 14 deployment target does not prove broad engine compatibility. |

**Lite integration and its live acceptance gate are pending in this branch.** See [Lite research](docs/LITE_RESEARCH.md) for capability probes, fallbacks and the distinction between source evidence and local verification. Mode selection uses `HYPRWM_MODE=auto` by default and chooses Lite if verified Engine attachment fails. `HYPRWM_MODE=lite` skips Engine channel attachment entirely; `HYPRWM_MODE=engine` fails with the actual attachment error instead of falling back. The installer does not alter security settings.

After quitting an existing instance, a foreground installed Lite launch is:

```sh
HYPRWM_MODE=lite ~/.local/bin/hyprwm
```

Engine additionally needs the matching native development installation's `hook` resources, including its `anim4.state` and generated base config. An app installed for Lite does not bundle those external native installation records. A development launch uses an explicit path:

```sh
HYPRWM_HOOK=/path/to/native-checkout/hook HYPRWM_MODE=engine ~/.local/bin/hyprwm
```

These commands start a real window manager and require a desktop session; they are not part of the no-launch installation dry run.

Engine changes the system's security posture and loads code into WindowServer through a separate development procedure. Installing the menu app does not install the engine, disable SIP or set boot arguments. Lite is the appropriate first install path. Apple's [SIP overview](https://support.apple.com/en-us/102149) explains the protection being relaxed.

### Returning from Engine to Lite

First restore managed windows and quit HyprWM normally. Stop any engine auto-injection helper installed by your development setup. A loaded WindowServer library is removed by a normal reboot; do not kill WindowServer to unload it. Restore the saved pre-Engine boot-argument value, removing only the changes you made for Engine and preserving unrelated arguments. If you did not record that value, inspect the existing arguments rather than deleting the whole variable. Re-enable SIP from macOS Recovery with `csrutil enable`, then reboot and verify `csrutil status`, following [Apple’s Recovery procedure](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection). Start Lite explicitly and confirm its reported mode. App uninstall does not perform these system changes for you.

## How it compares

Different workflows have different strengths. These descriptions were checked against each project's primary documentation on 2026-10-15; they are not a comparative performance benchmark.

| Project | What it offers / does better | Why try HyprWM |
| --- | --- | --- |
| [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide) | Documented i3-style tree/accordion layouts, binding modes, callbacks, monitor assignment and virtual workspaces. Its current config also supports focus follows mouse. | A Hyprland-inspired binary split workflow with a native settings UI and configurable motion path; validate the current Lite build before switching a daily session. |
| [yabai](https://github.com/asmvik/yabai) | Established BSP command/scripting ecosystem and native Space integration. Its [SIP guide](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) lists features such as animations and Space mutation that need the scripting addition. | A shared text/UI configuration and a planned no-injection Lite motion path, with Engine as a separate opt-in. |
| [Amethyst](https://github.com/ianyh/Amethyst) | A broad choice of tall, wide, column, BSP and custom layouts, plus GUI/YAML configuration. Prefer it if cycling those layouts is central to your workflow. | A focused binary split model with Hyprland-style curve and per-event motion controls. |

HyprWM is a preview. A shorter feature list, unverified mode or unfinished recovery flow is not a reason to claim it beats an established manager. Keep your previous setup until your actual focus/dialog/restore workflow passes.

## Configure it

Edit `~/.config/hyprwm/hyprwm.conf` or use the settings window. Save to hot-reload. `HYPRWM_CONFIG` selects another file.

```conf
layout {
    gaps_in = 8
    gaps_out.top = 12
}
focus {
    follow_mouse = 1
}
runtime {
    overview_hidden_windows = false
}
bind = CTRL ALT, H, focus, left
windowrule = float, app:^Calculator$
```

Readable text bindings use `SUPER` = Command, `ALT` = Option and `CTRL` = Control. The default table above already uses macOS key names. [CONFIG.md](docs/CONFIG.md) documents every key's default, real consumer, bounds and example, including accepted settings without an effective renderer. The [motion specification](docs/MOTION.md) defines the intended choreography; live validation remains separate. User transparency and hidden-window Mission Control remain unfinished; keep opacity at `1` and hidden-window overview off for a conservative setup.

## Bring your configuration

```sh
~/.local/bin/hyprwm import /path/to/aerospace.toml
```

Import conservatively maps supported Hyprland, AeroSpace, yabai/skhd, i3/sway and Amethyst preferences. It makes a backup and reports unsupported lines; it never runs your old shell configuration. **Rectangle conversion is manual**, and automatic import does not map it. See [MIGRATING.md](docs/MIGRATING.md) for concept tables and actual input/output examples for all six families.

## When something goes wrong

- **No tiling:** run `~/.local/bin/hyprwm doctor`, grant Accessibility to the controlling process and relaunch.
- **Invisible/parked window:** run `~/.local/bin/hyprwm restore-all`, read the result and confirm the window is visible before quitting/removing files.
- **Pointer focus stopped:** check `focus.follow_mouse`, pause state, matching rules, menus/modals and held mouse buttons; compare actual keyboard input with the border.
- **Buried dialog:** pause, dismiss normally, and report role/modal/parent behavior rather than adding app-name exceptions.

Detailed recovery, config, hotkey and socket guidance is in [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The [API reference](docs/API.md) covers IPC and event subscriptions.

## Uninstall

From the same checkout:

```sh
./uninstall.sh
```

The matching uninstaller must restore windows before removing the installed app. If recovery is pending, keep the app, checkout, configuration and state until it completes. Preserve preferences/backups unless you intentionally delete them afterwards. Removing the app does not unload an independently injected engine or reverse SIP/boot-argument changes; follow [Engine reversal](#returning-from-engine-to-lite).

## FAQ

**Is this Hyprland or a fork?** No. It is an independent macOS window manager inspired by Hyprland's behavior and motion.

**Must I disable SIP?** Lite is designed to avoid that requirement. Engine requires the development prerequisites above. Do not weaken system security merely to try the menu app.

**Is it ready for my main desktop?** It is experimental. Check current mode capability, permissions and recovery, then test your apps with disposable windows. A build/test pass is not live desktop evidence.

**Can I keep another tiler running?** Two automatic managers can fight over frames and focus. Stop the other tiler before starting HyprWM; retain its configuration for rollback.

**Does fullscreen mean macOS fullscreen?** Layout fullscreen/maximized changes HyprWM's layout. Native macOS fullscreen uses a different Space and lifecycle.

**Can I delete the checkout after installing?** The source installer bundles the Lite app’s configuration resources and installs local CLI launchers; keep the checkout for the matching `uninstall.sh`. The separate `build_app.sh` development menu companion still records a checkout dependency. See [packaging](hook/swift/PACKAGING.md).

**Where is the release download?** This README uses the source install flow. A draft release without assets is not an installable distribution.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Useful reports include mode, macOS/build, minimal config, exact steps, recovery outcome and sanitized evidence. Never attach private window content or unsanitized title logs.

<a id="settings"></a>
## Settings screenshots

[Menu](docs/screenshots/menu.png) · [General](docs/screenshots/general.png) · [Layout](docs/screenshots/layout.png) · [Animations](docs/screenshots/animations.png) · [Appearance](docs/screenshots/appearance.png) · [Focus](docs/screenshots/focus.png) · [Shortcuts](docs/screenshots/hotkeys.png) · [Rules](docs/screenshots/rules.png) · [Advanced](docs/screenshots/advanced.png) · [About](docs/screenshots/about.png).
