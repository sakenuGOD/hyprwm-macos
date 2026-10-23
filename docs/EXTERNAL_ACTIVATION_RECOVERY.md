# External activation recovery

An existing hidden System Settings primary was observed on the current ordinary
Space with native alpha0 and a parked offscreen frame. URL/open activation did
not have a Dock/Spotlight launcher token, so the production hidden-key guard
refused restoration. Pointer focus could then reassert an unmoved old receiver.

The production front-edge path now passes the previous foreground PID. Without
a launcher, restoration requires the exact current-Space native target, a live
hidden record and the previous app's last identity-fenced primary still visible
in that same Space. Closed/replaced/hidden source windows cannot authorize it.
No cross-Space transfer, new admission or guessed focus is granted.

Stationary pointer coordinates no longer reassert an old primary. A real pointer
move still records a bounded dwell retry; a new external foreground transition
cancels the previous pointer ticket. Existing no-key and explicit launcher paths
remain covered by their controls.

Four new production tests reproduce three failing assertions before the fix;
the full suite then passes287tests with1skip and0failures. Release and diff
checks pass. Actual owned AppKit live validation uses the existing fenced
LaunchServices activate_existing operation:25samples restore the exact hidden
window and preserve its real native foreground/key under an unmoved pointer.
The restored body was visually inspected and the actor was cleaned exactly.
A preliminary focus-only fixture call did not actually activate on this macOS
and is not accepted as a production test result. Native engine errors remain2.

Private local evidence is kept in settings-invisible-2216, including native red,
scoped Settings restoration, suite/build receipts and owned-live-ls screenshots.
The operator restored only the requested Settings WID through existing unhide,
never by independently clearing native alpha or dropping its ownership ledger.
This does not qualify unrelated first-map, all link handlers or workspace actions.
