# Troubleshooting

Start with `~/.local/bin/hyprwm doctor` and `~/.local/bin/hyprwmctl status`.
Remove private paths and window information before sharing diagnostics.

## Unsupported macOS build

Run `sw_vers -buildVersion` and `uname -m`. Setup requires exact build **25G241**
(macOS 26.7.1) and a native **arm64** process on Apple silicon. Other builds and
Rosetta are refused. Do not edit the build check, addresses or state to bypass it.
`./setup.sh --dry-run` reports the host without changing it.

## SIP is enabled or only partly disabled

Run `csrutil status`. The supported setup requires
`System Integrity Protection status: disabled.` Enabled, custom and unverified
states stop setup before native operations. Partial debugging-only changes have
not been verified. Follow [the Recovery instructions](INSTALL.md#disable-sip-in-recovery),
restart and check status again. Setup never changes SIP.

## Accessibility is missing

Enable the current `~/Applications/HyprWM.app` in **System Settings → Privacy &
Security → Accessibility**. Setup waits for the actual permission state; if it
stopped waiting, enable access and rerun `./setup.sh`. For source launches, enable
the process named by macOS. Check `~/.local/bin/hyprwm doctor` for permission state.

## Global shortcuts do nothing

Open **HyprWM Settings → Keyboard Shortcuts** and inspect the helper's registration
status. Run:

```sh
python3 scripts/install_keyboard.py status
tail -n 80 "$HOME/Library/Logs/HyprWM/keyboard.log"
```

The helper should be loaded and ready with all expected shortcuts registered.
Check duplicate chords, shortcuts reserved by macOS or another app, and any second
keyboard helper. `./setup.sh` installs the user keyboard service; `install.sh` alone
does not. The helper uses Carbon's `RegisterEventHotKey` and needs neither
Accessibility nor Input Monitoring. The optional recorder in Settings may need
Input Monitoring. The app still needs Accessibility to manage windows.
**Control–Option–P** is the app's separate fixed safety shortcut.

Text bindings use `SUPER` = Command, `ALT` = Option and `CTRL` = Control; imported
Hyprland defaults use `SUPER` = Option. See [imports](CONFIG.md#import-from-another-window-manager).

## Automatic startup fails after a reboot

Default setup installs native, backend and keyboard startup services. Inspect
current service state before trying manual preparation:

```sh
python3 scripts/install_autostart.py status --uid "$(id -u)"
python3 scripts/install_keyboard.py status
~/.local/bin/hyprwmctl status
sudo tail -n 80 "/Library/Application Support/HyprWM/native-session-$(id -u)/runtime/native-service.log"
tail -n 80 /tmp/hyprwm.log
```

Use `./scripts/hyprwm-up` as the manual fallback. It checks the host and saved
images and asks existing services to start only when safe. If it reports an
incomplete native attempt, retain the saved files and read the first error;
repeating preparation can make recovery harder. If you selected `--no-autostart`,
manual startup is expected. Do not restart WindowServer, Dock or apps to recover.
Setup verifies the current session and does not reboot to test a later login.

## Nothing tiles

Check the five cases above, `~/.local/bin/hyprwm doctor` and
`~/.local/bin/hyprwmctl status`. The engine must belong to the current WindowServer.
A responding socket alone cannot verify tiling: test focus and movement on two
ordinary application windows and inspect `/tmp/hyprwm.log` if either fails.

## A window is invisible or hidden

Keep the app, checkout and saved state. Run `~/.local/bin/hyprwmctl restore-all`.
If the daemon crashed, retain the matching engine resources and restart HyprWM to
let startup recovery restore its saved windows. Read any refusal before continuing.
`Engine restoration pending:` means work is still running. The client waits four
seconds; daemon recovery can take eight. Keep it running, check actual windows,
and retry after the attempt finishes. `status` shows `visibility.restore_pending`
and `visibility.engine_recovery_active`. An empty hidden list alone is insufficient.
Restoration leaves tiling paused; use `~/.local/bin/hyprwmctl resume` only after
checking visibility and placement. Never delete saved state or restart WindowServer,
Dock or an application to recover a window.

## Focus goes to the wrong window

Check `focus.follow_mouse = 1`, matching `no_follow_mouse` rules and Accessibility.
Dialogs, menus, Mission Control, floating windows and a held mouse button can
intentionally delay pointer focus. Move over a tile, stop, and try typing in a
throwaway document. Report whether input or only the border is wrong.
If opening a URL or activating a hidden app leaves it invisible, try `restore-all`.
Use **Control–Option–P** or `hyprwmctl pause` to stop an unexpected focus loop.
A reload reapplies `runtime.enabled`; set it to `false` to stay paused across edits.

## A dialog is behind a tile

Pause HyprWM, dismiss the dialog normally, and check where input returns.
Report the app, how you opened the dialog, and whether it is a sheet or separate
window. Include the smallest relevant rules. Do not add app-name exceptions as a workaround.

## A config edit has no effect

Edit `~/.config/hyprwm/hyprwm.conf`, or the path selected by `HYPRWM_CONFIG`.
Read line-numbered warnings with `hyprwm doctor` and compare `hyprwm --print-config`.
See [settings and limits](CONFIG.md). Some parsed settings have no effect yet.
Float rules stay attached to a window until HyprWM restarts, even after the rule is
removed; saved explicit floating state can also keep a window floating.

## The socket is unavailable or a command is refused

Start one daemon. Match `HYPRWM_CTL` in its environment and your client; the default
is `/tmp/hyprwm.ctl`. Keep a live socket in place. Read the first refusal before
retrying: a changing Space, dialog or session lock can prevent a command.
See [CLI commands](CLI.md) for exact arguments and reply handling.

## Motion, transparency or Mission Control looks wrong

Keep opacity at `1` and hidden-window Mission Control off for a simple reproduction.
Both transparency and hidden-window overview are unfinished. Visible managed windows
can also have missing Mission Control cards. Exit normally and inspect desktop windows;
use restoration above if a window stays invisible. For motion bugs, record a short clip
showing the start and landing, and say whether content, border or final size jumps.

## Installation or removal fails

Read the first error. Check Command Line Tools, Swift, Python and writable
`~/Applications`. Keep the checkout for updates and manual recovery.
Run the matching `./uninstall.sh`; pending restoration must finish before removal.
Remove separately installed services using [rollback steps](INSTALL.md#rollback-and-uninstall).
Report `sw_vers`, chip, `csrutil status`, **About → Copy Diagnostics**, steps and
expected/actual behavior. Keep private titles, files and credentials out of the report.
