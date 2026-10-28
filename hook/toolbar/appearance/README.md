# Telegram main-only appearance source

This is a source-only export of the completed Telegram adapter from `a9a5fbb`.
It is not integrated with the public toolbar session, installer, build command
or autostart. Nothing in this directory enables appearance changes by default.
The public distribution does not include a qualified appearance controller or
native module, so this export is not a runnable clean-install feature.

The adapter requests main appearance through existing authenticated session
events. Its native action preserves actual focus, input, responder, ordering,
geometry and animation state. Exact process birth, executable, main-image UUID,
WID, native method/image checks, retained original handle custody and explicit
policy requirements remain in the source. It pins the reviewed lifecycle to
`9943ac9b93596617fc08d9fb04bdb4d7467e43ff44ed88c79eda78034005cc33`.
A different lifecycle must refuse until separately reviewed.

The export contains:

- `telegram_appearance.py`: the adapter, with only the original imports changed
  to the local relative `source_support` import. The lifecycle-pin repair and
  preflight-before-native-operation behavior are preserved.
- `source_support.py`: an explicit source-relative resolver for the existing
  public `../native_companion.py` read/contract helpers and the original
  byte-preserving `atomic` function. The public toolbar JSON writer has a
  different interface.
- `Appearance.m` and `Appearance.h`: the unchanged native module source and C
  interface, including main-only action 3. The AppKit image UUID is an exact
  provenance guard, not a portability claim.
- `driver-body.txt`: the unchanged LLDB body. It requires a reviewed controller
  to supply its exact identity, artifact, module, output and operation inputs.

The private v4 controller template is deliberately absent. It binds a historic
exact target and own-host authorization, module hash/UUID, deadline, desktop
lease, evidence paths and source-pin manifests. Replacing those bindings with
generic defaults would change its authorization contract. No private policy,
profile, manifest, receipt, token, build output or machine path is exported.
There is no standalone module build recipe in this export; native binaries and
their new provenance must be built and qualified separately.

For a future implementation to run, it still needs a reviewed portable
controller/template and corresponding source-pin manifest, a qualified native
module plus its matching UUID/hash and content-addressed artifact, a compatible
metadata helper, an explicitly enabled Telegram-only policy, a currently
qualified Telegram main-image UUID, and integration with the locked session
event context. A pre-existing operation additionally needs its original
token/receipt chain. These inputs cannot be replaced with sample qualification
or borrowed receipts. The existing public `native/metadata.m` provides metadata
source, but a newly built helper is not qualified by this export.

The adapter's `create()` returns no adapter when its runtime policy is absent.
The public session does not import or call it. No activation, restart, input or
native qualification waiver has been added.
