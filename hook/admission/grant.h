#import <Foundation/Foundation.h>
// Optional exact-process admission grant; zero means menu-only, one installed.
int HAInstallGranted(NSDictionary *identity);
// Explicit loader entry. Derives current process/main image identity locally;
// the private, exact-process grant remains mandatory.
int HAInstallCurrentGrant(void);
