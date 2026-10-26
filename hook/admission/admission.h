#import <AppKit/AppKit.h>

// Explicit prototype lifecycle. Install/uninstall on the application main thread.
// No constructor, swizzle, screen capture or AX calls. A successfully offered
// first map temporarily owns native alpha until engine claim/cancel/timeout.
typedef void (*HAEventCallback)(NSDictionary *event);
int hypradmission_install(NSString *socketPath, double budgetMS, HAEventCallback callback);
int hypradmission_uninstall(void);
BOOL hypradmission_is_installed(void);
// Installed custody can remain during a refused release; it is not accepting
// new windows until that drain has completed.
BOOL hypradmission_is_accepting(void);
#ifdef HYPRADMISSION_OWNED_DIAGNOSTICS
// Built only for disposable owned cold-launch fixtures; no reinstall/core writes.
int hypradmission_owned_set_logger(HAEventCallback callback);
NSDictionary *hypradmission_owned_state(void);
#endif
