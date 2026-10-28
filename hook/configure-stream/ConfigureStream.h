#ifndef HYPR_CONFIGURE_STREAM_H
#define HYPR_CONFIGURE_STREAM_H

/* Source-only candidate interface. No runtime qualification is implied.

   The ON authority is a root-owned regular JSON file, with root-owned and
   non-group/other-writable ancestor directories, at:
     /Library/Application Support/HyprWM/Configure Stream Grants/<uid>/
       <pid>-<uid>-<birthSec>-<birthUsec>.json

   Required grant fields:
     schema: 1, kind: "configure-stream-v1", scope: "qualified-own-windows"
     target: {birth:[pid,uid,birthSec,birthUsec], executable, main_uuid}
     manager: {birth:[pid,uid,birthSec,birthUsec], executable}
     window_server: {birth:[pid,uid,birthSec,birthUsec], executable}
     module_uuid: uppercase loaded receiver slice UUID
     skylight_uuid: uppercase loaded SkyLight UUID
     epoch: integer 1...2^53-1, strictly increasing for this target process
     expires: mach_absolute_time seconds, now < expires <= now+30
     ordinary_space: positive current single-display ordinary Space ID
     windows: 1...32 {wid:positiveInteger, object:lowercaseHexAddress} bindings
     allow_activation: false, allow_input: false, allow_restart: false

   Publication is CFData JSON in the existing own-connection property transport,
   key "hyprwm.configure-stream.v1". No legacy cap/min token is overwritten.
   A manager reader MUST fence the connection owner/PID and target process birth
   before/after read, require its exact accepted grant/manager/epoch/module UUID,
   connection and WID/object cohort, require installed+enabled, capability==6,
   proof_kind=="synchronous-frame-readback-v1", not_before<t0<=observed_at,
   now<expires and 0<=now-observed_at<=.2, and require each selected row ready
   with a positive minimum equal to the existing hyprwm.min.<wid> contract.
   Each row's initial_probe_ack must have positive sequence/time, a four-number
   actual frame and not_before<t0<=time<=observed_at. This dedicated proof is
   immutable for the lease. row.sequence/t0 describe newest received input;
   last_ack describes an actually read-back native frame after a synchronous
   public setter return. It may lag while a newer sample is pending or awaiting
   real WS bounds. awaiting_readback reports that distinction. CAP6 requires
   the initial probe ACK, never an
   equality between the newest input sequence and the immutable probe sequence.
   Root's independently verified retained-loader receipt remains mandatory;
   the property cannot authorize its own module or expand its own cohort.
   grant_sha256 is immutable SHA256 of the exact accepted protected file bytes,
   including whitespace/newlines, never a canonicalized JSON serialization.
   Require equality with the current protected file and retained-loader receipt.

   Bootstrap: action0 returns a bounded read-only "inspection" of existing own
   normal/resizable windows (WID + object tag, no titles). Review that exact
   identity/object cohort before writing its protected grant. ON verifies those
   exact objects and reports cap0. Send OP_CFG with F_STREAM and each exact current
   native frame, not its target. Only the return of public NSWindow
   setFrame:display: (without requesting animate:) followed by exact
   SLSGetWindowBounds readback establishes that WID's cap6 readiness. A probe
   that changes the frame is refused. Only then select F_NATIVE|F_STREAM for the
   complete admitted peer cohort. Existing CAP5 and ordinary/native other paths
   remain independent. SCFG has no wire epoch: local ON floor and strictly
   increasing t0 bind samples to this lease; future t0 is refused without a
   tolerance. Zero-size cancellation wins ties and retires the complete lease;
   a newer explicitly reviewed ON is required afterwards.

   This initial own-cohort interface intentionally has no automatic grant renewal
   or broad application loader. A new ON needs a drained OFF and a newer root
   grant. Off status may be read through the same connection property after
   detach; installed may remain true, but enabled=false, capability=0,
   inactive=true, in_flight=0, drain_scheduled=false, admitted_callbacks=0 and
   all pending=false are required for OFF proof. OFF revokes synchronously;
   if queued bookkeeping or an admitted callback remains, it reports pending.
   There are no receiver-owned native completion blocks or deferred setters.
   An awaiting readback can only read/acknowledge the last synchronous setter;
   OFF discards it. This proof describes actual geometry, never texture/draw
   readiness. Changed-frame behavior still needs disposable own qualification.
   WindowServer identity uses the existing managed_process_identity.c sysctl
   implementation plus before/after exact proc_pidpath fencing.
*/

// Explicit, constructor-free lifecycle. Call on the actual application main
// thread through an independently qualified, retained dylib handle.
// action: 0 status, 1 ON from the fixed root grant, 2 OFF.
// ON request is {"epoch":positiveInteger}; OFF requires the owned epoch too.
// Returns 0 only for the requested proved state. OFF returns 1 while earlier
// queue/callback bookkeeping remains; enabled/capability are already zero.
// Supply an output buffer of 32768...65536 bytes. JSON output is NUL-terminated.
// No callback or loader handle may be unloaded, including after successful OFF.
int hypr_configure_stream_v1_json(unsigned action, const char *request,
                                  char *output, unsigned capacity);
#endif
