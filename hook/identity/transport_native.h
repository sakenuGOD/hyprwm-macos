#import <Foundation/Foundation.h>

// Resolves ABI and verifies own connection. Does not create a connection.
int (^HIIdentityNativeWriter(int ownConnection, int *error))(NSData *);
void HIIdentityPostHint(void);
// Foundation-only reader dylib; malloc result, caller free(). No connection creation.
char *hypridentity_copy_connection_json(int callerConnection, int targetConnection, int expectedPID, int *error);
