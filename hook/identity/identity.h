#import <Foundation/Foundation.h>

// Passive prototype. Main-thread API; no swizzles, window creation, geometry writes or IPC.
@interface HIIdentityJournal : NSObject
@property(nonatomic, readonly) BOOL installed;
@property(nonatomic, readonly) NSUInteger generation;
- (instancetype)initWithWindows:(NSArray *)windows;
- (void)observeWindow:(id)window;
- (NSDictionary *)snapshot;
- (void)uninstall;
@end

// Explicit lifecycle for a separately loaded dylib. No automatic constructor.
// Return: 0 success/already installed, -1 no NSApp, -2 wrong thread.
int hypridentity_install(void);
int hypridentity_uninstall(void);
// Caller owns malloc buffer; NULL on wrong thread or when not installed.
char *hypridentity_copy_json(void);
unsigned hypridentity_capabilities(void);
// Opt-in transport, main-thread only; install alone never starts IPC.
// Start requires caller's already existing own WS connection; no CAP5/6 stream implication.
int hypridentity_transport_start(int ownConnection);
int hypridentity_transport_stop(void); // queues authoritative revocation, never waits on WS
