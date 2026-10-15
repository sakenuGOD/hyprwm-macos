# Passive identity sidecar prototype

This adds **facts** for native AppKit tab groups and window lifecycle. It does
not change tiling, alpha, geometry, focus, animation, `hyprforce`, or WindowServer.
It has no constructor and installs no method replacements. An already injected
v5/v6 `hyprforce` need not be loaded a second time to try this sidecar.

It now has an **opt-in** bounded connection-property publisher and a separate
Foundation reader. No daemon integration is enabled. The public API/ABI and AppKit binary
paths are documented in
[`2026-10-11_window_identity.md`](../../notes/research/2026-10-11_window_identity.md).

## Build and offline checks

```
sh hook/identity/build.sh /tmp/hyprwm-identity-dev
```

Builds signed arm64+arm64e `identity.dylib` and `identity_reader.dylib`, plus
`offline_test` and `fixture`.
The build script runs **only** the offline test; it never launches the GUI fixture.
The test uses real Foundation KVO on fake window/group objects, leaving NSApp nil.

```
clang -fobjc-arc -framework AppKit -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  hook/identity/identity.m hook/identity/publisher.m \
  hook/identity/transport_native.m hook/identity/offline_test.m \
  -o /tmp/hypridentity-offline-asan
/tmp/hypridentity-offline-asan
```

Tested: group membership and selection, prior state before AppKit-like cleanup,
retained-window close/reopen, no public lazy getter reads, weak object lifetimes,
explicit teardown, stale queued callback after reinstall, JSON serialization,
and bounded event/history/transport storage. **41 checks** pass normally and with ASan/UBSan.
Root's real plain/CAP6 fixture runs exposed nested KVO and post-callback detach
flag changes; both now have offline RED→GREEN replays. See research §9 for exact
live coverage; V3 plain/CAP6 runs also confirm the settled-detach fix on AppKit.

## Explicit API and ownership

All C calls run on the application's main thread:

```c
int hypridentity_install(void);       // idempotent, no duplicated observers
char *hypridentity_copy_json(void);   // malloc buffer; caller free()
int hypridentity_uninstall(void);     // removes only this sidecar's observers
unsigned hypridentity_capabilities(void);
int hypridentity_transport_start(int ownConnection); // opt-in, already owned WS connection
int hypridentity_transport_stop(void); // queues revocation, never waits on WS
```

Install returns -1 without NSApp, -2 on a foreign thread. Copy returns NULL when
uninstalled or off-main. Capabilities bits are 1=group membership, 2=selection,
4=hidden-tab getter, 8=lifecycle journal; this describes supported schema fields,
not successful observation of every possible app. Missing private getters are
reported as nil group / null hidden_tab; never infer membership from them.

The installer owns one journal. Notification tokens and each successfully added
KVO key/context are owned and removed exactly by that journal. App windows and
groups are **weakly** held; temporary reads retain only during the callback.
Associated scalar nonces live with objects; they do not retain windows or groups.
Reinstall uses a new generation. Foreign-thread callbacks defer to main, include
`off_main_gap`, and check generation/installation before reading any AppKit state.
Prior proof is unavailable across such a gap. Deallocation of observed fake
objects was tested under ASan/UBSan; native subclass deallocation remains a live gate.

Do not `dlclose` the library after uninstall: Objective-C classes remain registered
with the runtime. Uninstall is observer teardown, not unloading its machine code.
Do not load separately copied revisions of this dylib into the same process;
their Objective-C class names would collide. Rebuild/restart only the disposable
fixture until the live version is accepted.

KVO itself may create Foundation's observing subclass. Compatibility with AppKit
and custom Swift/Qt subclasses is a live gate. The sidecar never calls object_setClass
or swizzles a method itself. Existing `hyprforce` v6 policy uses inheritance and
associated flags rather than exact class equality; static inspection found no
competing identity getter implementation there. That is not proof for every app.

## Export contract

`copy_json` returns a full envelope with `schema=1`, pid, process launch nonce,
journal generation, monotonically increasing seq, uptime_seconds on events,
`windows`, `groups`, `live_objects`, `live_groups`, and the last 256 `events`.
Group/window object nonces are scoped by launch nonce. Exported WIDs can be
nonpositive during native construction; they are **not** usable CGWindowIDs yet.
No raw pointers, titles, or window content are exported.

`windows` and `groups` contain last-observed historical metadata. Only the
`live_objects/live_groups` arrays identify currently retained native objects in
the weak registry; even those are not equivalent to mapped windows. Closed
retained windows can remain live. `dropped_events>0` means the oldest journal
entries were evicted. A consumer whose last seq predates the first returned event
must reconcile a full snapshot before trusting a transition; never invent the
missing before-state. On initial snapshot consume identity without replaying old
open/close events. Installing observers alone starts no IPC or daemon polling.

Group callbacks schedule one coalesced passive main-queue read after native code
returns. `reconcile_pending`, `revision`, and `settled_revision` expose that
boundary; a `settled` event lists any corrected window/group facts and sampling
completeness. It never schedules itself or polls. Callback-time hidden_tab can be
stale during detach: root's native trace proves the flag clears after final KVO.
Wait for the settled revision before treating such facts as a completed operation;
this still does not replace CG visibility. Old pending work is generation guarded.

Event causes include `window_observed`, `group_prior`, `group_changed`,
`window_group_prior`, `window_group_changed`, native order-on/off, will/did-close,
key/resign-key, minimized/deminimized, and sheet begin/end. Group change records
carry `before` plus current metadata. Closed records retain `previous_group`
from before cleanup; NSWindowWillClose is too late to discover it for the first time.
This is historical evidence: consume its surrounding sequence, not a lone record
as proof of a current tab replacement. A standalone order-on or settled visible
detach clears its old membership cache. `sampling_unavailable` marks an incomplete native observation
(including a transient selectedWindow getter exception); treat it as unknown.

KVO is registered with **Prior only**, not Old/New: automatic Old/New access on
window.tabGroup could call its lazy-creating getter. The passive getter is
`_windowStackController`, ABI checked before invoking. `hidden_tab` uses verified
`_isInHiddenWindowTab`; both are read-only. The actual on-screen notification
names are resolved via exported NSString symbols, not guessed from symbol names.

Native selectedWindow KVO is nested. Group events expose `depth`, `paired`, and
`outermost`; consume only a paired outermost `group_changed` as the logical
selection transition. Each nesting level retains its own prior state.

Historical scalar storage prunes dead/retained-closed windows beyond 256 records
and historical groups beyond 128; `history_pruned` reports loss. Current live
objects are still observed for reopen. If live inventory exceeds the wire's
capacity, its `complete=false` explicitly withholds identity proof. Group membership is cached from real KVO; if a subclass
does not emit it, this prototype does not synthesize or repair those facts.
Missing notification symbols, unsupported KVO, foreign-thread gaps, retained
window reopen, and internal single-WID document tabs must remain distinct.

## Root-only live fixture

Run `/tmp/hyprwm-identity/fixture --floating` to create two **own** AppKit windows
in a native tab group, at a level the daemon excludes from normal tiling. Omit
`--floating` only when deliberately testing interaction with the running daemon.
The fixture links the sidecar directly, installs it before creating the group,
retains windows after close, and prints JSON after each command:

```
dump
select a
select b
close b
dump
reopen b
join b
detach b
uninstall
install
quit
```

Rejoin after reopening before testing detach: reopen creates a standalone window,
so detach without join is a no-op. Allow a run-loop turn before `dump` when recording native ordering. The fixture's
initial immediate dump may precede some visibility notifications. `quit`/stdin EOF
uninstalls and closes only fixture-owned windows. Do not send EOF while a root-owned
WindowServer experiment still depends on those windows.

For coexistence with v6, preload the current `hyprforce.dylib` only into this
disposable fixture, then compare the journal to the baseline fixture. Test live
KVO prior/current states for both selectedWindow and windows, selected-tab close,
close/reopen retained objects, group detach, and final uninstall while windows
stay alive. A separate test of injection into a user app needs the root's review
after these pass; the agent has not performed any injection.

Normal mode (without `--floating`) uses Regular activation policy. Root can use
`select-key a` / `select-key b` to select a native tab, make it key, and activate
the fixture; subsequent `dump` records key/main facts. Floating-mode traces had
neither window key and therefore did not test focus correctness.

## Separate property transport gate

Build with `sh hook/identity/build_transport_probe.sh /tmp/hyprwm-identity`.
The script runs only `property_transport_probe --offline-selftest` (9 checks),
which never loads SkyLight or connects to WindowServer. No sidecar IPC is enabled.

Root-only live producer: `/tmp/hyprwm-identity/property_transport_probe producer 60`.
The first JSON record supplies `connection`, `pid`, `launch`, `revision`, native
return codes, and exact own-readback result. Keep stdin open. From another process:

```
/tmp/hyprwm-identity/property_transport_probe consumer CID PID LAUNCH REVISION
```

Consumer checks remote connection ownership, expected nonce/revision, CFData type,
JSON null/UTF8, and data size. It returns nonzero on a mismatch and releases its
own reader connection. Producer commands are `put-null`, `fit` (65536 JSON bytes),
`oversize` (65537 rejected before WS, existing property checked unchanged),
`tombstone`, and `quit`. Each successful write increments revision; use its new
value for the next consumer check. `oversize` emits two JSON lines and leaves the
revision unchanged. Explicit tombstone remains remotely readable until quit.

Both processes create only their own standalone connections. The producer never
accepts a foreign write target, has no windows, uses a probe-only property key,
and writes a tombstone before releasing its connection on EOF/quit/deadline/signals.
Lifetime is 1–120 seconds; use an outer timeout as native WS calls have no verified
timeout. Neither this probe nor the sidecar changes existing CAP5/CAP6 modules.

Root passed this gate in `cache/rollout-20261011/property-transport-live.json`:
own and remote reads at ready, null, exactly 65536 bytes, tombstone; 65537 rejected
before WS with old data preserved; producer/readers released their own connections.
Sandbox support and notification delivery have not yet been measured.

## Opt-in identity publisher and reader

`hypridentity_transport_start(ownConnection)` verifies that the existing connection
belongs to this process. It publishes CFData JSON to `hyprwm.identity.v1`, never to
another connection. A native main-thread callback makes a bounded immutable copy;
one serial queue serializes/writes it and posts `hyprwm.identity.<pid>` as a wake
hint only after success. The worker receives no native window/group objects.
It retains at most one pending latest snapshot plus one in-flight write. There is
no timer, polling or automatic connection creation.

Wire fields:

| Field | Meaning |
|---|---|
| `schema=1`, `transport=ws-connection-v1` | Independent identity metadata contract |
| `pid`, `launch` | OS PID and process nonce; validate connection ownership separately |
| `generation` | Journal installation generation |
| `publication` | **Process-lifetime** monotonic wire number, across stop/start/reinstall |
| `seq` | Journal fact sequence, resets with generation |
| `revision`, `settled_revision`, `reconcile_pending` | Native coalesced group boundary |
| `installed` | False is authoritative revocation, not window closure |
| `complete`, `gap`, `dropped_events`, `history_pruned` | Current-fact and historical coverage |
| `windows`, `groups`, `events` | ≤128 windows, ≤128 groups with ≤128 members, ≤32 events |

The final encoded packet is at most 65536 bytes. Trim events first; if current
facts cannot fit, publish explicit incomplete/empty facts. Never interpret omitted
objects as destroyed. `group_known`, `group_kvo`, and group membership/selection
KVO flags distinguish known absence from an unavailable getter/observer. Transport
readiness does not imply hyprforce CAP6 native configure or animation streaming.

Stop removes the session as a producer immediately, then queues installed=false
tombstone behind any in-flight write. All sessions share the serial queue: old
data cannot arrive after its tombstone or a replacement generation. Uninstall
also stops transport. Neither operation blocks app main waiting for WS. A native
write failure posts no success hint and leaves consumers with older data until a
later change publishes successfully; consumer reconciliation must treat that as
stale evidence rather than substitute a PID guess. No automatic retries spin.

`identity_reader.dylib` exports
`char *hypridentity_copy_connection_json(int caller, int target, int expectedPID, int *error)`.
It validates both connection owners, requires CFData ≤65536 bytes, CFReleases the
native result, and returns a malloc buffer (caller free). It creates no connection.
Errors -1001/-1002 are caller/target ownership or resolution, -1003 type/native copy
failure fallback, -1004 size, -1005 invalid buffer/allocation; native copy errors
remain their original code. JSON/schema validation lives in `identity_protocol.py`.

`IdentityStore(pid, connection, launch)` pins a source. It rejects stale publication,
old generation, foreign launch/connection, inconsistent selected WIDs/membership,
and values outside the uint32 WID upper bound. Higher install generation starts a
baseline; do not replay historical opens. Complete snapshots can recover after
event loss, but missing historical transitions remain unknown. A tombstone revokes
authority immediately. `snapshot.window(wid)` returns no proof for unknown/nonpositive
WIDs, pending state, or incomplete current facts. This store makes no layout changes.

Run parser checks without WS:

```
python3 -m unittest discover -s hook/identity -p 'test_*.py' -v
```

For a **root-only** live publisher check, use the dev fixture and command
`transport-start`. Its dump includes `transport_connection` and `transport_result`.
After one run-loop turn, read from a separate process:

```
python3 hook/identity/identity_consumer.py CID PID /tmp/hyprwm-identity-dev/identity_reader.dylib --full
```

The CLI creates/releases only its own reader connection. Exercise tab select,
join/detach, close/reopen, `transport-stop` (read tombstone while fixture stays
alive), `uninstall`, `install`, `transport-start` (new generation, larger publication).
Root live validation passed for this publisher/reader in both plain and CAP6
fixtures: 9 snapshots each (18 total), baseline, select a/b, close/reopen,
join/detach, uninstall tombstone, reinstall generation2, and stale-old rejection.
Every ready remote snapshot matches local native membership and selected WID.
Evidence: `cache/rollout-20261011/identity-transport-live/{plain,cap6}.json`, root
runner `identity_transport_check.py` in the rollout directory. Sandbox behavior
and hint delivery remain separate gates; root's reader deliberately queried snapshots.

Before the user's reboot, reviewed dev binaries and exact source copies were
preserved in `cache/rollout-20261011/pre-reboot/identity/`, with `manifest.json`.
Rebuild using `sh hook/identity/build.sh /tmp/hyprwm-identity-dev`; 41 native offline
checks and 6 parser tests passed. No daemon integration or user-app sidecar
injection has been performed by this agent. Do not load a second sidecar revision
into an existing process; restart the disposable fixture for code changes.
