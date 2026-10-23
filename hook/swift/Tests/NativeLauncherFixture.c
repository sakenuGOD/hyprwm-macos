/* Pure callback fixture: creates local CGEvents, never posts events or starts a tap.
 * clang -O2 -Wno-deprecated-declarations -F/System/Library/PrivateFrameworks
 *   -framework ApplicationServices -framework SkyLight Tests/NativeLauncherFixture.c -o /tmp/hyprwm-launcher-fixture
 */
#define AXUIElementCopyMultipleAttributeValues fixture_copy_multiple
#define AXUIElementCopyAttributeValue fixture_copy_single
#include "../../src/axlib.c"
#include <assert.h>
#include <stdio.h>
static int fixture_batch_calls, fixture_single_calls, fixture_unsupported;
AXError fixture_copy_multiple(AXUIElementRef element,CFArrayRef attributes,AXCopyMultipleAttributeOptions options,CFArrayRef *values) {
    (void)element;(void)options;++fixture_batch_calls;
    assert(CFArrayGetCount(attributes)==2);
    assert(CFEqual(CFArrayGetValueAtIndex(attributes,0),kAXPositionAttribute));
    assert(CFEqual(CFArrayGetValueAtIndex(attributes,1),kAXSizeAttribute));
    *values=NULL;if (fixture_unsupported) return kAXErrorNotImplemented;
    CGPoint point={-10,20};CGSize size={400,500};
    CFTypeRef entries[]={AXValueCreate(kAXValueCGPointType,&point),AXValueCreate(kAXValueCGSizeType,&size)};
    *values=CFArrayCreate(NULL,entries,2,&kCFTypeArrayCallBacks);CFRelease(entries[0]);CFRelease(entries[1]);return kAXErrorSuccess;
}
AXError fixture_copy_single(AXUIElementRef element,CFStringRef attribute,CFTypeRef *value) {
    (void)element;(void)attribute;++fixture_single_calls;*value=NULL;return kAXErrorAttributeUnsupported;
}
static void key(int code, CGEventFlags flags) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, true);
    assert(event); CGEventSetFlags(event, flags);
    assert(launcher_callback(NULL, kCGEventKeyDown, event, NULL) == event);
    CFRelease(event);
}
static void mouse(uint32_t wid, double x, double y) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointMake(x,y), kCGMouseButtonLeft);
    assert(event); CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, wid);
    assert(launcher_callback(NULL, kCGEventLeftMouseDown, event, NULL) == event);
    CFRelease(event);
}
int main(void) {
    _Static_assert(sizeof(ax_launcher_intent) == 32, "ctypes ABI must remain 32 bytes");
    uint32_t dock[] = {123}; double rectangles[] = {400,700,300,100};
    ax_launcher_cache_dock(1,101,dock,rectangles,1);
    ax_launcher_intent value={0};
    key(17,kCGEventFlagMaskCommand); assert(ax_launcher_read(0,&value)==0); /* Cmd-T is never activation. */
    key(49,kCGEventFlagMaskCommand); assert(ax_launcher_read(0,&value)==1);
    assert(value.kind==1 && value.origin_space==1 && value.front_pid==101 && value.monotonic_ns>0);
    uint64_t sequence=value.sequence;
    ax_launcher_cache_dock(2,202,dock,rectangles,1);
    assert(ax_launcher_read(sequence,&value)==0); assert(value.origin_space==1); /* cache updates don't alter captured origin */
    key(48,kCGEventFlagMaskCommand); assert(ax_launcher_read(sequence,&value)==1); assert(value.origin_space==2);
    ax_launcher_cache_dock(3,303,dock,rectangles,1); sequence=value.sequence;
    key(48,kCGEventFlagMaskCommand); assert(ax_launcher_read(sequence,&value)==1); assert(value.origin_space==2 && value.front_pid==202);
    key(124,kCGEventFlagMaskControl); assert(ax_launcher_read(0,&value)==1 && value.kind==0 && value.origin_space==0);
    sequence=value.sequence;
    key(49,kCGEventFlagMaskAlternate); assert(ax_launcher_read(sequence,&value)==0); /* Option-Space isn't Spotlight. */
    key(48,kCGEventFlagMaskAlternate); assert(ax_launcher_read(sequence,&value)==1 && value.kind==2 && value.origin_space==3);
    ax_launcher_cache_dock(4,404,dock,rectangles,1); sequence=value.sequence;
    key(48,kCGEventFlagMaskAlternate|kCGEventFlagMaskShift); assert(ax_launcher_read(sequence,&value)==1 && value.kind==2 && value.origin_space==3 && value.front_pid==303);
    sequence=value.sequence;
    key(48,kCGEventFlagMaskAlternate|kCGEventFlagMaskControl); assert(ax_launcher_read(sequence,&value)==0);
    key(53,0);assert(ax_launcher_read(0,&value)==1 && value.kind==0);ax_launcher_cache_dock(3,303,dock,rectangles,1);
    sequence=value.sequence; mouse(999,410,710); assert(ax_launcher_read(sequence,&value)==0); /* wrong positive WID doesn't use geometric alias */
    mouse(123,410,710); assert(ax_launcher_read(sequence,&value)==1 && value.kind==3 && value.origin_space==3);
    sequence=value.sequence; ax_launcher_clear(sequence-1); assert(ax_launcher_read(0,&value)==1 && value.kind==3);
    ax_launcher_clear(sequence); assert(ax_launcher_read(0,&value)==1 && value.kind==0);
    mouse(0,410,710); assert(ax_launcher_read(sequence,&value)==1 && value.kind==3); /* zero-WID fallback */
    key(53,0); assert(ax_launcher_read(0,&value)==1 && value.kind==0);
    assert(ax_launcher_available()==0); assert(ax_launcher_now_ns()>=value.monotonic_ns);
    CGPoint point={-10,20};CGSize size={400,500};double frame[]={9,9,9,9};
    AXValueRef position=AXValueCreate(kAXValueCGPointType,&point),dimensions=AXValueCreate(kAXValueCGSizeType,&size);
    assert(frame_values(position,dimensions,frame)==0 && frame[0]==-10 && frame[2]==400);
    assert(frame_values(kCFNull,dimensions,frame)==-2 && frame[0]==-10);
    assert(frame_values(dimensions,position,frame)==-2 && frame[2]==400);
    assert(frame_values(CFSTR("position"),dimensions,frame)==-2);
    CFRelease(position);point.x=NAN;position=AXValueCreate(kAXValueCGPointType,&point);
    assert(frame_values(position,dimensions,frame)==-2 && frame[0]==-10);
    CFRelease(position);CFRelease(dimensions);
    cache[0].wid=999;cache[0].pid=99;cache[0].el=(AXUIElementRef)CFRetain(CFSTR("fixture element"));
    assert(ax_get_frame(99,999,frame)==0 && fixture_batch_calls==1 && fixture_single_calls==0 && frame[2]==400);
    fixture_unsupported=1;
    assert(ax_get_frame(99,999,frame)==-2 && fixture_batch_calls==2 && fixture_single_calls==0 && frame[2]==400);
    ax_forget(999);
    puts("Native launcher and coherent AX frame callback assertions passed; no native AX reads/events/tap");
    return 0;
}
