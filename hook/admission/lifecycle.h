#import <AppKit/AppKit.h>

// Local lookup only: no IPC, AX, activation or geometry changes from this callback.
// Return NO unless this exact window has a current engine/owner/presentation bind
// and is an ordinary visible window. Output HLC1:<32hex>:<32hex>:<16hex> + NUL.
typedef BOOL (*HLCMarker)(NSWindow *window, uint32_t wid, char out[256]);
typedef struct { uint32_t schema; HLCMarker marker; } HLCConfig;

// Constructor-free, application main thread only. Images remain loaded after OFF.
int HLCInstall(const HLCConfig *config);
// -3 means draining: new markers disabled, ownership retained until native copied
// order operations finish or are discarded. Retry on a normal application update.
int HLCUninstall(void);
NSDictionary *HLCState(void);
