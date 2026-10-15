// Shim: compiles hook/src/axlib.c itself.
#include <stdlib.h>
#include <unistd.h>
#include "include/CAX.h"
#include "../../../src/axlib.c"

/* Read-only tri-state: 1 present, 0 confirmed absent, -1 unavailable.
 * Called once per departure on Swift's existing background AX queue. */
int hs_window_presence(int pid,unsigned wid) {
    if(pid<=0 || !wid)return -1;
    AXUIElementRef app=AXUIElementCreateApplication(pid);if(!app)return -1;
    AXUIElementSetMessagingTimeout(app,0.03f);
    CFTypeRef value=NULL;AXError error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&value);
    CFRelease(app);
    if(error!=kAXErrorSuccess || !value || CFGetTypeID(value)!=CFArrayGetTypeID()) {
        if(value)CFRelease(value);return -1;
    }
    CFArrayRef windows=(CFArrayRef)value;CFIndex count=CFArrayGetCount(windows);
    int result=count<=128 ? 0:-1;uint64_t start=ax_launcher_now_ns();
    for(CFIndex i=0;i<count && result>=0;i++) {
        AXUIElementRef window=(AXUIElementRef)CFArrayGetValueAtIndex(windows,i);
        if(!window || CFGetTypeID(window)!=AXUIElementGetTypeID()){result=-1;break;}
        AXUIElementSetMessagingTimeout(window,0.005f);CGWindowID found=0;
        if(_AXUIElementGetWindow(window,&found)!=kAXErrorSuccess){result=-1;break;}
        if(found==wid){result=1;break;}
        if(ax_launcher_now_ns()-start>30000000ULL){result=-1;break;}
    }
    CFRelease(windows);return result;
}

/* Cached exact-window close, bounded per IPC. Only the Swift background close
 * worker calls this; request acceptance never implies actual native unmap. */
void hs_close_request(int pid,unsigned wid,hs_close_metrics *out) {
    if(!out)return;
    memset(out,0,sizeof(*out));out->result=-1;out->stage=1;
    uint64_t start=ax_launcher_now_ns();AXUIElementRef window=lookup(pid,wid,0);
    out->lookup_ns=ax_launcher_now_ns()-start;
    if(!window)return;
    AXUIElementSetMessagingTimeout(window,0.15f);
    CFTypeRef button=NULL;out->stage=2;start=ax_launcher_now_ns();
    AXError result=AXUIElementCopyAttributeValue(window,kAXCloseButtonAttribute,&button);
    out->button_ns=ax_launcher_now_ns()-start;
    if(result==kAXErrorSuccess && button && CFGetTypeID(button)==AXUIElementGetTypeID()) {
        out->stage=3;AXUIElementSetMessagingTimeout((AXUIElementRef)button,0.15f);start=ax_launcher_now_ns();
        result=AXUIElementPerformAction((AXUIElementRef)button,kAXPressAction);
        out->press_ns=ax_launcher_now_ns()-start;
    } else if(result==kAXErrorSuccess)result=kAXErrorAttributeUnsupported;
    out->result=(int32_t)result;
    if(button)CFRelease(button);CFRelease(window);
}
