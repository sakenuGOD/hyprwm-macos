/* Exercises the production AX setters with an asynchronous AX provider.
 * No application is contacted and no events are posted. */
#define AXUIElementCreateApplication fixture_application
#define AXUIElementCopyAttributeValue fixture_copy
#define AXUIElementSetAttributeValue fixture_set
#include "../../src/axlib.c"
#include <assert.h>
#include <stdio.h>

static int enhanced, supported, disable_error, frame_error, toggles;
static CGPoint origin, pending;
static CGSize dimensions;
static AXUIElementRef application(void) { return (AXUIElementRef)CFSTR("application"); }
static AXUIElementRef window(void) { return (AXUIElementRef)CFSTR("window"); }

AXUIElementRef fixture_application(pid_t pid) {
    assert(pid == 99); return (AXUIElementRef)CFRetain(application());
}
AXError fixture_copy(AXUIElementRef el, CFStringRef attr, CFTypeRef *value) {
    assert(el == application() && CFEqual(attr, CFSTR("AXEnhancedUserInterface")));
    *value = NULL;
    if (!supported) return kAXErrorAttributeUnsupported;
    *value = CFRetain(enhanced ? kCFBooleanTrue : kCFBooleanFalse);
    return kAXErrorSuccess;
}
AXError fixture_set(AXUIElementRef el, CFStringRef attr, CFTypeRef value) {
    if (el == application()) {
        assert(CFEqual(attr, CFSTR("AXEnhancedUserInterface")));
        int next = CFBooleanGetValue(value);
        if (!next && disable_error) return kAXErrorCannotComplete;
        enhanced = next; ++toggles; return kAXErrorSuccess;
    }
    assert(el == window());
    if (frame_error) return kAXErrorAttributeUnsupported;
    if (CFEqual(attr, kAXPositionAttribute)) {
        CGPoint point; assert(AXValueGetValue(value, kAXValueCGPointType, &point));
        if (enhanced) pending = point; else origin = point;
    } else {
        assert(CFEqual(attr, kAXSizeAttribute));
        assert(AXValueGetValue(value, kAXValueCGSizeType, &dimensions));
        dimensions.height = fmin(dimensions.height, 956 - origin.y);
    }
    return kAXErrorSuccess;
}
static void reset(int enabled, int available) {
    enhanced=enabled; supported=available; toggles=0; disable_error=0; frame_error=0;
    origin=CGPointMake(12,439); pending=origin; dimensions=CGSizeMake(720,495);
}
int main(void) {
    cache[0].wid=991; cache[0].pid=99; cache[0].el=(AXUIElementRef)CFRetain(window());
    reset(1,1);
    assert(ax_frame(99,991,12,41,720,903)==0);
    assert(origin.y==41 && dimensions.height==903); /* Original P-S-P clamps before delayed movement. */
    assert(enhanced==1 && toggles==2);
    reset(0,1);
    assert(ax_frame(99,991,12,41,720,903)==0);
    assert(origin.y==41 && dimensions.height==903 && enhanced==0 && toggles==0);
    reset(0,0);
    assert(ax_frame(99,991,12,41,720,903)==0);
    assert(dimensions.height==903 && toggles==0); /* Unsupported providers keep the normal path. */
    reset(1,1); frame_error=1;
    assert(ax_frame(99,991,12,41,720,903)==kAXErrorAttributeUnsupported);
    assert(enhanced==1 && toggles==2); /* Restore even when the frame setter fails. */
    reset(1,1); disable_error=1;
    assert(ax_frame(99,991,12,41,720,903)==0);
    assert(enhanced==1 && toggles==0); /* Never enable a mode we did not disable. */
    reset(1,1); origin.y=41;
    assert(ax_size(99,991,720,903)==0);
    assert(dimensions.height==903 && enhanced==1 && toggles==2);
    ax_forget(991);
    puts("AX configure: delayed position, mode preservation, unsupported/error and size-only assertions passed");
    return 0;
}
