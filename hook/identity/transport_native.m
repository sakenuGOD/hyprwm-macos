#import "transport_native.h"
#include <dlfcn.h>
#include <notify.h>
#include <unistd.h>

typedef int (*PIDFunction)(int, pid_t *);
typedef int (*SetFunction)(int, int, CFStringRef, CFTypeRef);
typedef int (*CopyFunction)(int, int, CFStringRef, CFTypeRef *);
static PIDFunction pidFunction;
static SetFunction setFunction;
static CopyFunction copyFunction;
static CFStringRef key = CFSTR("hyprwm.identity.v1");
static BOOL resolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            pidFunction = dlsym(handle, "SLSConnectionGetPID");
            setFunction = dlsym(handle, "SLSSetConnectionProperty");
            copyFunction = dlsym(handle, "SLSCopyConnectionProperty");
        }
    });
    return pidFunction && setFunction && copyFunction;
}
int (^HIIdentityNativeWriter(int own, int *error))(NSData *) {
    if (error) *error = -1001;
    if (!resolve()) return nil;
    pid_t pid = 0;
    if (pidFunction(own, &pid) || pid != getpid()) return nil;
    if (error) *error = 0;
    return ^int(NSData *data) {
        if (!data || data.length > 65536) return -1004;
        pid_t owner = 0;
        if (pidFunction(own, &owner) || owner != getpid()) return -1001;
        return setFunction(own, own, key, (__bridge CFDataRef)data);
    };
}
void HIIdentityPostHint(void) {
    char name[80]; snprintf(name, sizeof name, "hyprwm.identity.%d", getpid());
    notify_post(name); // Wake hint only; all coherence lives in the property envelope.
}
char *hypridentity_copy_connection_json(int caller, int target, int expectedPID, int *error) {
    if (error) *error = -1001;
    if (!resolve()) return NULL;
    pid_t owner = 0;
    if (pidFunction(caller, &owner) || owner != getpid()) return NULL;
    if (error) *error = -1002;
    if (expectedPID <= 0 || pidFunction(target, &owner) || owner != expectedPID) return NULL;
    CFTypeRef value = NULL;
    int code = copyFunction(caller, target, key, &value);
    if (error) *error = code ?: -1003;
    char *result = NULL;
    if (!code && value && CFGetTypeID(value) == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        CFIndex length = CFDataGetLength(data);
        if (error) *error = -1004;
        if (length > 0 && length <= 65536) {
            const UInt8 *bytes = CFDataGetBytePtr(data);
            if (error) *error = -1005;
            if (!memchr(bytes, 0, (size_t)length)) {
                result = malloc((size_t)length + 1);
                if (result) {
                    memcpy(result, bytes, (size_t)length); result[length] = 0;
                    if (error) *error = 0;
                }
            }
        }
    }
    if (value) CFRelease(value);
    return result;
}
