# HyprWM API

This launch branch is Engine-only. Sections explicitly describing Lite, its status fields or virtual workspaces document the separate experimental `lite/2026-10-16` implementation; they are unavailable in this branch. See [branch availability](../README.md#experimental-lite).

HyprWM exposes local Unix sockets owned by the current user with mode `0600`.
The command socket is `/tmp/hyprwm.ctl`; set `HYPRWM_CTL` in both the daemon and
client environment to use another path. No network port is opened.

## Command-line client

From a checkout, use `scripts/hyprwmctl`. The installer also adds `~/.local/bin/hyprwmctl`; use that absolute path or add `~/.local/bin` to your PATH for the short command.

```bash
scripts/hyprwmctl status
scripts/hyprwmctl focus left
scripts/hyprwmctl move right
scripts/hyprwmctl layout balance
scripts/hyprwmctl layout togglesplit
scripts/hyprwmctl layout retile
scripts/hyprwmctl layout fullscreen
scripts/hyprwmctl float
scripts/hyprwmctl reload
scripts/hyprwmctl pause
scripts/hyprwmctl resume
scripts/hyprwmctl restore-all
```

`status` prints the daemon's JSON state. Directional `move` rearranges the focused
window in the current layout. Layout actions operate on the existing dwindle
layout; selecting a different layout engine is not supported. `float` toggles the
focused window between floating and tiled. `pause` and `resume` change the running
session; edit `runtime.enabled` in `hyprwm.conf` for a persistent setting.
The client exits nonzero for invalid arguments, connection failures, empty replies,
or a refused command. A successful queued focus request acknowledges scheduling;
it does not guarantee that an application has already accepted focus.

## Command wire protocol

Connect, write one UTF-8 command followed by a newline, then read one newline
terminated response. The daemon closes the connection after replying. Commands
accept a JSON array of string arguments or quoted text; there is no shell expansion.
State responses are JSON; mutation responses are plain text. Handler failures return
a sanitized `error: …` line (at most 1024 Unicode scalars of message). Protocol/size
failures can still close the connection without a response. Read until newline or EOF, rather than assuming
that one `recv` contains the entire response. Requests are bounded to 64 KiB and
responses to 1 MiB; a serviced connection expires after one second.

```bash
printf '["status"]\n' | nc -U -w 5 /tmp/hyprwm.ctl
printf '["focus","left"]\n' | nc -U -w 5 /tmp/hyprwm.ctl
```

```python
import json
import os
import socket

path = os.environ.get("HYPRWM_CTL", "/tmp/hyprwm.ctl")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(5)
    client.connect(path)
    client.sendall(json.dumps(["status"]).encode() + b"\n")
    with client.makefile("rb") as stream:
        reply = stream.readline(1_048_577)
        if not reply.endswith(b"\n") or len(reply) > 1_048_576:
            raise RuntimeError("Incomplete or oversized daemon response")
        state = json.loads(reply)
print(state["space"], state["focus"], state["rects"])
```

Useful state fields include `enabled`, `space`, `focus`, `tree`, `rects`, `floating`,
`hidden`, and `engine`. Mode-aware builds also report top-level `mode`, `daemon.mode`,
`engine.mode` and `engine.available`. In Lite, `space` is a virtual workspace ID,
not a native macOS Space ID. The `lite` object reports capture/animation capability,
proxy/direct-placement/capture-failure counters, recovery count/error and hotkey
conflicts; `hotkey_bindings` supplies that mode’s settings metadata. The diagnostic
`lite.focus_context` is `[frontmost PID, AX-focused window ID, focus flags]`, and
`lite.pointer_hit` is the current public census receiver ID or null. A reported
capture capability is not evidence that a particular animation succeeded. Window IDs are session lifetime observations, not
persistent identifiers; obtain a fresh state before acting on them. Additional
fields are diagnostic and may change between releases.

Production Engine status also exposes `configuration.submitted`, `configuration.running` and `configuration.pending` for the shared AX configuration queue. `submitted` is a process-local job sequence, not an AX setter-call count; `running` counts active jobs and `pending` counts queued jobs not yet taken. These read-only diagnostics can help distinguish an appearance reload from geometry work. They are null when that sink is unavailable.

## Cropped content navigation

With a compatible Engine, `pan left|right|up|down|reset` moves the selected
tile's live content in 64-point steps. The tile and its neighbors keep their
positions. `reset` returns to the top-left corner. The menu offers the same
actions under **Pan Cropped Content**; arrows are enabled only where content
extends beyond the tile. Application scrolling keeps its usual meaning.

`status.viewport.supported` reports the native capability. Its optional `window`
contains the selected window identity, current offsets, maximum offsets and
`pending`. A queued reply confirms scheduling; offsets become accepted only
after the native acknowledgement. An older engine reports the feature unavailable.
The optional form `pan DIRECTION WID PID BIRTH SPACE` binds a menu action to the
remembered selection and refuses a stale identity or selection.

Panning is limited to idle tiled windows on the current native Space. Layout,
hide, drag and Space changes reset it. The native lease also resets it if the
manager stops renewing the request. It does not resize the application's content
or move a window to another Space.

## Lite virtual workspace commands

Lite workspace IDs are `1…10`. These commands require enabled tiling, completed recovery and no active mouse interaction or session lock. They do not create or switch Mission Control Spaces. Sending to the current workspace is a no-op.

| Command | Behavior |
| --- | --- |
| `workspace N` / `ws N` | Select virtual workspace N. |
| `workspace previous` | Return to the previous virtual workspace. |
| `wsstep -1` / `wsstep 1` | Select the previous/next ID, wrapping through 1…10. |
| `moveworkspace N` / `moveworkspace N follow` | Move the native-focused managed tile and follow it. |
| `moveworkspace N silent` | Move that tile while staying on the source workspace. |
| `sendws N [wid]` | Send silently; an explicit ID must identify a visible managed tile on the current workspace. |

Use a fresh `status` before an explicit-ID mutation. Engine workspace commands use separate native capability checks; do not interpret a Lite ID as a native Space ID.

Before leaving a managed key window for an empty Lite workspace, or sending its last tile silently, Lite reserves a visible **Workspace N / No windows** keyboard receiver. Failed focus or lifetime verification refuses the transition before parking the current window. The diagnostic `workspace_public.empty_receiver` reports `visible`, `key`, `window` and `key_events`; the last field counts key events without retaining typed content. It does not certify input delivery in another application.

## Event subscriptions

The event socket defaults to `/tmp/hyprwm.ctl.events`; set `HYPRWM_EVENTS` in both
the daemon and client environment to override it. Connect without sending a
request. Each line is a JSON object. The first line is
`{"event":"connected","version":1}`. Subsequent event types are:

| Event | Meaning |
| --- | --- |
| `window_opened` | A layer-zero window first appears in the existing window census. |
| `window_closed` | A previously observed window disappears, or its owning PID changes. |
| `window_focused` | The WM's recorded focus changes; `window` can be null. |
| `space_changed` | The WM observes another current workspace; its ID is native in Engine and virtual in Lite. |

```bash
scripts/hyprwmctl subscribe
# Example event (sequence numbers restart with the daemon):
# {"event":"window_focused","sequence":3,"timestamp":1792050000.5,"space":1,"window":{"wid":42,"pid":1234,"space":1}}
```

```python
import json
import os
import socket

control = os.environ.get("HYPRWM_CTL", "/tmp/hyprwm.ctl")
path = os.environ.get("HYPRWM_EVENTS", control + ".events")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    with client.makefile("rb") as stream:
        for line in stream:
            event = json.loads(line)
            print(event["event"], event.get("window"))
```

Events use the WM's cached census and add no AX scans. They describe observations,
not guaranteed delivery of every OS transition: a very short-lived window between
censuses may not appear, and hiding is not closing. Initial existing windows are
not replayed as opened events. Use `status` to establish and resynchronize state.
The stream has no history or replay guarantee. Slow clients are disconnected when
their pending output exceeds 32 KiB; at most 16 subscribers are accepted. Reconnect
and query state after disconnection. The event version covers envelope semantics;
clients should ignore unknown fields and event types.

## Configuration and offline CLI

The editable file is `~/.config/hyprwm/hyprwm.conf`, or the explicit `HYPRWM_CONFIG` path. [CONFIG.md](CONFIG.md) lists all accepted keys, defaults, consumers and currently ineffective settings. [MIGRATING.md](MIGRATING.md) gives the supported foreign formats and conversion limits.

After the source installer has bundled the base configuration:

```sh
~/.local/bin/hyprwm --help
~/.local/bin/hyprwm doctor
~/.local/bin/hyprwm --print-config
~/.local/bin/hyprwm import /path/to/aerospace.toml
```

`--print-config` resolves and prints selected layout/curve/animation values; it does not start a daemon or prove live behavior. If the text config is absent, reading it may create a default file. `import FILE` applies supported settings and creates a sibling backup before replacing an existing configuration. Foreign input is never executed. It requires a regular UTF-8 file up to 256 KiB. Unsupported statements are reported by original line number; zero mapped settings is an error. Rectangle is detected but not converted.

`scripts/hyprwm` is the developer wrapper for the source binary; its config-dependent modes additionally need the generated `hook/config/hypr_cfg.json`. The installed CLI uses the app’s bundled baseline instead. `HYPRWM_HOOK` locates a `hook` directory and its schema/base configuration. `HYPRWM_STATE_DIR` selects the persistent daemon-state directory (native default `/tmp/hyprwm-swift`). `HYPRWM_TIME_SCALE` overrides geometry timing in the range `0.1…4`. Production does not create solid backing windows; native clipping and decoration remain separate. Debug/experimental environment switches are implementation details, not stable API contracts.

## Recovery and diagnostics

`hyprwm doctor` reports version, requested/running mode, the control socket, config path and line-numbered parse issues, and the current process's Accessibility, Screen Recording, Input Monitoring and Automation status. It does not request a permission prompt or create config. The Engine daemon's fixed Carbon panic shortcut does not need Input Monitoring. Its separate legacy hotkey watcher and the settings recorder can require it; Lite's runtime Carbon bindings belong to the experimental branch. Automation → System Events is for scripted desktop verification.

`hyprwm --init-config` explicitly creates commented defaults only when the selected config is absent, and preserves an existing file. The source installer uses this entry point with the portable bundled baseline.

`hyprwm restore-all` routes to a responding daemon or, where supported, the stopped Lite runtime's persisted recovery ledger. Restoration verifies window lifetimes and retains unresolved records. An empty stopped-Lite ledger can be checked without starting a window manager; restoring actual records needs Accessibility and a desktop session. Stopped Engine recovery requires the matching Engine runtime and native resources.

Explicit `restore-all` leaves tiling paused. Confirm the real windows are visible and inspect their placement before `hyprwmctl resume`. Success is distinct from a queued command. `visibility.restore_pending` includes Engine hidden-window jobs and visible pause landings awaiting acknowledgement; `visibility.engine_recovery_active` reports the Engine recovery pump. An empty hidden list alone does not prove completion.

Lite and Engine return mode-specific `restoration pending:` errors while asynchronous work remains. The CLI clients and uninstaller retry those specific markers with a four-second budget; a direct socket client must implement its own pending handling. The Engine pump has a separate eight-second attempt window. A client can therefore return pending while the daemon is still restoring. Keep it running, inspect status and native visibility, then retry `restore-all` if needed. A timeout keeps unresolved state and the daemon paused; it does not authorize deleting the ledger or installation.

On Engine startup, hidden records without a valid prepared handover trigger recovery before the normal paused guard. A deliberately prepared restart can preserve the exact hidden ledger through a validated one-use handover marker; startup consumes that marker, so a later crash again takes the recovery path. Startup recovery may resume the configured enabled state after completion; an explicit pause, disable or `restore-all` revokes that automatic resume. The legacy `unhide all` command retains its earlier semantics and is not a substitute for this recovery protocol.

The Engine recovery implementation has passed a scoped live test with a disposable owned window: crash/restart, graceful exit, prepared restart and explicit restoration. That does not establish recovery of every pre-existing user window, every application or changed display/Space topology. Startup preflight checks the hidden-ledger shape and file safety; it is not a complete saved-layout validator or an atomic validated-snapshot handoff to the state loader.

Both Lite startup and offline recovery refuse outstanding Engine hidden-window records; startup stays paused and reports `lite.recovery_error`. Lite's public AX path cannot recover native Engine alpha/Space ownership. Restore those records in the matching Engine runtime before switching modes.

When a rule newly ignores a Lite-owned window, Lite cancels its pending placement and uses the same recovery scheduler to restore its recorded original frame before releasing ownership. This includes parked members of inactive virtual workspaces. `lite.ignored_release_count` counts releases still awaiting verified restoration or departure; unresolved records remain in the ledger. A config reload alone does not prove that recovery has completed.

The raw command `quit` targets the focused **application**. It is not a daemon shutdown command. Use **Quit HyprWM** or the matching uninstaller for restoration-aware daemon shutdown.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for permission panes, visibility recovery, config warnings and safe shutdown. A session pause and restoring hidden windows are separate operations. Treat refusal/pending responses as incomplete work, preserve state, and verify real windows before deleting an installation.

The command protocol is local control, not a remote-service authentication boundary. Do not expose its Unix socket through a network bridge or share a socket with another user. Window/PID identities can be reused; the daemon revalidates ownership for mutations. Consumers should never persist a window ID as a durable external identity.
