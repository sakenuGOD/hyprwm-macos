#import <Foundation/Foundation.h>

// Foundation/POSIX only: these functions never create NSApplication or windows.
double HAClock(void);
NSDictionary *HAExchange(NSString *path, NSDictionary *request, double deadline);
BOOL HAOfferUsable(NSDictionary *offer, NSDictionary *request, double now);
void HASetServerExecutable(NSString *executable);
BOOL HAHasServerExecutable(void);
