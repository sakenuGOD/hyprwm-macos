# Troubleshooting and recovery

Start with the mode, permissions and configuration diagnosis. Use the installed CLI:

```sh
~/.local/bin/hyprwm doctor
```

Keep its output local until you have removed personal paths and private application information. A successful build is not a permission grant or proof that windows are being managed. A working `status` response proves a daemon answers; it does not prove native focus or visibility.

## Nothing tiles / permission is missing

In **System Settings → Privacy & Security → Accessibility**, enable the process that actually controls windows. For an installed app that is HyprWM; for a command-line development launch, macOS may attribute access to your terminal host or the executable shown in the permission prompt. Follow the process identity reported by doctor and the OS prompt. Relaunch HyprWM after changing permissions.

Screen capture animation needs **Screen & System Audio Recording** permission (called **Screen Recording** on some macOS versions). A denied capture permission should reduce Lite to live AX placement rather than make windows disappear. Carbon runtime shortcuts do not need Input Monitoring. The settings shortcut recorder uses an event tap and can request **Input Monitoring**. **Automation → System Events** is for GUI scripting used in testing, not an instruction to grant blanket Automation access to every process.

If you recently rebuilt or moved the app, verify that the granted item is the current copy. Avoid running an old companion and a new daemon from different checkouts. Close the old companion through its menu before opening another.

If HyprWM is absent from the permission list, add the installed `~/Applications/HyprWM.app` with **+**. For capture permission, [Apple's instructions](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac) describe adding an app below the Screen & System Audio Recording list. The current Lite capture path checks permission before capturing; do not wait for an automatic capture prompt to appear.

## A window is invisible, hidden or parked

Keep the app and checkout installed until recovery finishes:

```sh
~/.local/bin/hyprwm restore-all
```

This is the recovery entry point for HyprWM-owned hidden/parked windows. Read any refusal or pending result; do not assume every window was restored because a command was sent. Confirm the real windows are visible. If the daemon is still alive, let it finish recovery before quitting. If it crashed, retain its persisted state and use the documented startup/recovery path rather than deleting state files.

Do not kill WindowServer, Dock or the affected application to recover a HyprWM window. Do not delete the state ledger, force a window alpha globally, or overwrite the configuration while diagnosing ownership. If recovery refuses a stale or reused window identity, report the exact refusal and keep the state for inspection.

## Focus does not follow the mouse

Confirm the session is enabled and `focus.follow_mouse = 1` in the effective configuration:

```sh
~/.local/bin/hyprwmctl status
~/.local/bin/hyprwm --print-config
```

Check for a matching `no_follow_mouse` rule, a modal dialog, Mission Control, a menu, a floating window under the cursor, a held mouse button or missing Accessibility permission. These can intentionally suppress tile focus. `runtime.pointer_focus_pause_ms` adds a delay after relevant focus activity. After returning from a Space or Mission Control, move over a tile, stop, and test typing in a disposable document. Report whether the actual key window/input or only the border is wrong.

Press **Control–Option–P**, choose the menu’s pause action, or use the client while investigating an unexpected layout/focus loop:

```sh
~/.local/bin/hyprwmctl pause
# Resume when ready:
~/.local/bin/hyprwmctl resume
```

`pause` stops automatic tiling for the session; it is not an uninstall or a promise to unhide every parked window. Use `restore-all` for visibility recovery. `runtime.enabled` controls the persistent setting. An unrelated config save preserves a manual pause. Resume explicitly, or change the persistent enable setting; incomplete Lite recovery must finish before resuming.

## A dialog or sheet is buried

Record whether the object is an AX dialog, sheet, modal panel or an ordinary floated window; include its parent relationship if available. Do not solve generic dialog policy with application-name exceptions. Pause the manager if necessary, dismiss the dialog normally, and check where input lands after dismissal. Remove experimental rules from the reproduction. Report separate cases for staying above tiles, preserving modal input and returning focus to the parent.

## A config edit has no effect

Use the shared text file, not a generated cache or an old JSON input. `HYPRWM_CONFIG` can select a different path than the default. In settings, the Advanced page exposes the file. Inspect line-numbered warnings and [CONFIG.md](CONFIG.md), including its **accepted, not yet effective** entries.

One invalid assignment should not discard an independent valid gap edit. Save one valid change and compare the effective value. The watcher handles atomic replacement and coalesces rapid saves. Appearance-only changes should not trigger layout geometry. If they do, include the smallest edit and the before/after rects in your report. Preserve the original file and a backup; do not repeatedly reset all preferences to diagnose one line.

## A shortcut does nothing

Settings → Hotkeys is the effective binding list. Check duplicate chords, imported modifier translation and whether the watcher is running. Carbon runtime bindings do not require Input Monitoring; check that permission if the settings shortcut recorder cannot observe keys. Readable text bindings map `SUPER` to Command, `ALT` to Option and `CTRL` to Control. The legacy Lua defaults use a separate translation; the README lists the actual macOS keys.

A shortcut contains a HyprWM command argument array, not arbitrary shell syntax. Imported shell commands and unsupported actions produce warnings. See [MIGRATING.md](MIGRATING.md) for the supported subset.

## The socket is unavailable / command refused

```sh
~/.local/bin/hyprwmctl status
```

The command socket defaults to `/tmp/hyprwm.ctl`. Set the same `HYPRWM_CTL` in both client and daemon if using a custom path. The event socket defaults to that path plus `.events`, with an optional `HYPRWM_EVENTS` override. Do not delete a live socket or start a second daemon over it. A stale socket can be removed by the daemon only when it belongs to the current user and no process answers.

A focus request can be queued before macOS accepts it. Ownership, session lock, dialogs or a changing Space can cause a command to be refused. Clients must handle empty responses and nonzero exits. See [API.md](API.md) for the bounded wire protocol.

## Motion, borders or capture look wrong

Record which mode is running and whether capture permission is granted. Lite and Engine have different rendering paths. Do not infer SIP-on compatibility from a run made with SIP off. Disable optional capture animation or use ordinary AX placement if the current build reports the capability unavailable. User transparency and the hidden-window Mission Control pool remain unfinished; keep opacity at `1` and hidden-window overview off for a conservative reproduction.

For a motion bug, provide a short real recording with the first frame, retarget and landing visible. Check whether body/border diverge, content resizes late or the final frame snaps. A settings screenshot cannot prove runtime motion.

Lite discovers application windows after they are displayed. Public Accessibility APIs cannot prevent the initial default-position frame; a brief TextEdit entrance flash has been observed. Captured proxies also contain a static image during motion. Distinguish these limits from a client that remains parked after landing, which needs recovery.

## Installation or removal fails

Read the first error rather than repeatedly rebuilding. Check the macOS/Swift requirements and command-line tools, writable `~/Applications`, the existing configuration and the selected checkout. The installed Lite app bundles its base resources. Keep the checkout for the matching uninstaller; a separately built development menu companion still depends on its checkout. See [packaging](../hook/swift/PACKAGING.md) for the difference between the local menu bundle and a standalone installer.

Run the matching `./uninstall.sh` from the same checkout. It must restore managed windows before deleting the app. If restoration is pending, keep the app, state and checkout and follow the recovery message. User preferences/backups should be kept unless you intentionally remove them afterwards. An uninstall does not automatically reverse independently configured Engine security settings; follow [Engine reversal](../README.md#returning-from-engine-to-lite).

## What to include in a report

Include macOS version, build/commit, mode, permission status, the smallest relevant config, exact steps, expected/actual behavior, recovery outcome and whether the behavior reproduced in another mode. Include sanitized IPC/native/capture evidence where possible. Remove window titles, personal paths, app contents and credentials. Mark unverified steps as unverified instead of filling them in from assumptions.
