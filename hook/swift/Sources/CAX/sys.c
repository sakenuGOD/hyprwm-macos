// Wrappers for private SkyLight and CoreGraphics functions, matching ctypes calls in hook/hyprwm.py.
#include <ApplicationServices/ApplicationServices.h>
#include <stdint.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#ifndef HYPRWM_GIT_REVISION
#define HYPRWM_GIT_REVISION "unknown"
#endif
#ifndef HYPRWM_SOURCE_DIRTY
#define HYPRWM_SOURCE_DIRTY 1
#endif
const char *hs_build_revision(void) { return HYPRWM_GIT_REVISION; }
int hs_build_source_dirty(void) { return HYPRWM_SOURCE_DIRTY; }

int hs_window_server_pid(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count > 65536) return -1;
    pid_t *pids = calloc((size_t)count + 64, sizeof *pids);
    if (!pids) return -1;
    int actual = proc_listallpids(pids, (count + 64) * sizeof *pids);
    int result = -1;
    for (int i = 0; i < actual && i < count + 64; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (pids[i] <= 0 || proc_pidpath(pids[i], path, sizeof path) <= 0) continue;
        if (!strcmp(path, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")) { result = pids[i]; break; }
    }
    free(pids); return result;
}

int hs_process_birth(int pid, uint64_t *seconds, uint64_t *micros) {
    struct proc_bsdinfo info = {0};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return -1;
    *seconds = info.pbi_start_tvsec; *micros = info.pbi_start_tvusec; return 0;
}

extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *owner);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CGError SLSCopyConnectionProperty(int caller, int target, CFStringRef key, CFTypeRef *value);
extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
extern CGError _SLPSGetFrontProcess(ProcessSerialNumber *psn);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *r);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *a);
extern CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *ordered);
extern CGError SLSMoveWindowsToManagedSpace(int cid, CFArrayRef wids, uint64_t space);
extern uint64_t SLSGetActiveSpace(int cid);
extern OSStatus GetProcessPID(const ProcessSerialNumber *psn, pid_t *pid);

static int cid;
int hs_cid(void) {                     // WS connection: lazy, only while the daemon actually runs
    if (!cid) cid = SLSMainConnectionID();
    return cid;
}

int hs_session_locked(void) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return 1;
    CFTypeRef locked = CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
    CFTypeRef console = CFDictionaryGetValue(session, kCGSessionOnConsoleKey);
    int result = (locked && CFEqual(locked,kCFBooleanTrue)) || !console || !CFEqual(console,kCFBooleanTrue);
    CFRelease(session); return result;
}

int hs_window_connection(unsigned wid, int expected_pid) {
    int owner = 0; pid_t pid = 0;
    if (expected_pid <= 0 || SLSGetWindowOwner(hs_cid(), wid, &owner) || owner <= 0 ||
        SLSConnectionGetPID(owner, &pid) || pid != expected_pid) return -1;
    return owner;
}

/* Same four-argument Copy ABI as identity/transport_native.m. The property is
 * data only: root grant/module authority is checked by the Swift reader. */
int hs_copy_configure_stream_json(unsigned wid, int pid, uint64_t seconds, uint64_t micros,
                                  char *buffer, unsigned capacity, int *connection) {
    uint64_t sec=0,usec=0;pid_t caller=0;CFTypeRef value=NULL;int result=-1;
    if(!buffer || capacity<2 || capacity>65536 || !connection || !wid || pid<=1 ||
       hs_process_birth(pid,&sec,&usec) || sec!=seconds || usec!=micros)return -1;
    int owner=hs_window_connection(wid,pid);
    if(owner<=0 || SLSConnectionGetPID(hs_cid(),&caller) || caller!=getpid())return -1;
    if(!SLSCopyConnectionProperty(hs_cid(),owner,CFSTR("hyprwm.configure-stream.v1"),&value) &&
       value && CFGetTypeID(value)==CFDataGetTypeID()) {
        CFIndex length=CFDataGetLength((CFDataRef)value);
        const UInt8 *bytes=CFDataGetBytePtr((CFDataRef)value);
        if(length>0 && length<=16384 && length<capacity && !memchr(bytes,0,(size_t)length)) {
            memcpy(buffer,bytes,(size_t)length);buffer[length]=0;result=(int)length;
        }
    }
    if(value)CFRelease(value);
    if(result<0 || hs_window_connection(wid,pid)!=owner || hs_process_birth(pid,&sec,&usec) ||
       sec!=seconds || usec!=micros)return -1;
    *connection=owner;return result;
}

int hs_win_pid_level(unsigned wid, int *pid, int *level) {
    int o = 0; pid_t p = 0; int lv = 0;
    if (SLSGetWindowOwner(hs_cid(), wid, &o) || SLSConnectionGetPID(o, &p)) return -1;
    SLSGetWindowLevel(hs_cid(), wid, &lv);      // as in Python: window-level errors are not checked
    *pid = p; *level = lv;
    return 0;
}

/* Native ordering survives alpha0, unlike CGWindowIsOnscreen. Read only,
 * fenced by the same owner connection/PID before and after the witness. */
int hs_window_ordered_in(int pid,unsigned wid) {
    int before=0,after=0;pid_t ownerPID=0;uint8_t ordered=0;
    if(pid<=0 || !wid || SLSGetWindowOwner(hs_cid(),wid,&before) ||
       SLSConnectionGetPID(before,&ownerPID) || ownerPID!=pid ||
       SLSWindowIsOrderedIn(hs_cid(),wid,&ordered) ||
       SLSGetWindowOwner(hs_cid(),wid,&after) || after!=before ||
       SLSConnectionGetPID(after,&ownerPID) || ownerPID!=pid)return -1;
    return ordered ? 1:0;
}

int hs_front_pid(int *pid) {
    ProcessSerialNumber psn = {0, 0};
    pid_t p = 0;
    if (_SLPSGetFrontProcess(&psn) || GetProcessPID(&psn, &p)) return -1;
    *pid = p;
    return 0;
}

int hs_win_bounds(unsigned wid, double *out) {
    CGRect r = CGRectZero;
    if (SLSGetWindowBounds(hs_cid(), wid, &r)) return -1;
    out[0] = r.origin.x; out[1] = r.origin.y; out[2] = r.size.width; out[3] = r.size.height;
    return 0;
}

int hs_win_alpha(unsigned wid, float *a) {
    *a = -1;
    return SLSGetWindowAlpha(hs_cid(), wid, a) ? -1 : 0;
}

void hs_move_to_space(const int32_t *wids, int n, uint64_t space) {
    CFNumberRef nums[n > 0 ? n : 1];
    for (int i = 0; i < n; i++) nums[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &wids[i]);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)nums, n, &kCFTypeArrayCallBacks);
    SLSMoveWindowsToManagedSpace(hs_cid(), a, space);
    CFRelease(a);
    for (int i = 0; i < n; i++) CFRelease(nums[i]);
}

uint64_t hs_active_space(void) { return SLSGetActiveSpace(hs_cid()); }

void hs_mouse(double *x, double *y) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    *x = p.x; *y = p.y;
}

// As in Python: CGEventSourceButtonState(1, 0). 1 = kCGEventSourceStateHIDSystemState (the comment in
// hyprwm.py says "combinedSessionState", but the number there is 1; preserved exactly).
int hs_mouse_down(void) { return CGEventSourceButtonState((CGEventSourceStateID)1, kCGMouseButtonLeft); }

void hs_spotlight(void) {               // Cmd+Space
    for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, 49, down);
        CGEventSetFlags(e, (CGEventFlags)(1 << 20));
        CGEventPost((CGEventTapLocation)0, e);
        CFRelease(e);
    }
}

// Passive read of the existing AppKit publisher's birth-qualified notify values.
// This never installs observers in another application or mutates any native window.
#include <notify.h>
#include <math.h>
struct hs_resize_context {
    uint64_t sequence, epoch;
    uint32_t wid, phase;
    double x,y,w,h,mx,my,time,event_time;
    double accepted_x,accepted_y,accepted_w,accepted_h,accepted_time;
    uint64_t sample;
};
struct resize_tokens { int pid; uint64_t sec,usec; int token[20]; };
static struct resize_tokens resize_slots[8];
static unsigned resize_next;
static const char *resize_fields[20]={"seq","epoch","wid","phase","x","y","w","h","mx","my","time","event_time","down","live","accepted_x","accepted_y","accepted_w","accepted_h","accepted_time","sample"};
static void resize_drop(struct resize_tokens *slot) {
    if (slot->pid) for (unsigned i=0;i<20;i++) if(slot->token[i]>=0) notify_cancel(slot->token[i]);
    memset(slot,0,sizeof *slot);
}
int hs_read_resize_context(int pid,double now,struct hs_resize_context *out) {
    uint64_t sec=0,usec=0;
    if (!out || !isfinite(now) || hs_process_birth(pid,&sec,&usec) || !sec) return -1;
    struct resize_tokens *slot=NULL;
    for(unsigned i=0;i<8;i++) {
        if(resize_slots[i].pid==pid) {
            if(resize_slots[i].sec==sec && resize_slots[i].usec==usec) slot=&resize_slots[i];
            else resize_drop(&resize_slots[i]);
        }
    }
    if(!slot) {
        for(unsigned i=0;i<8;i++) if(!resize_slots[i].pid) {slot=&resize_slots[i];break;}
        if(!slot) {slot=&resize_slots[resize_next++%8];resize_drop(slot);}
        slot->pid=pid;slot->sec=sec;slot->usec=usec;
        for(unsigned i=0;i<20;i++) slot->token[i]=-1;
        for(unsigned i=0;i<20;i++) {
            char name[160];snprintf(name,sizeof name,"hyprwm.native_resize.%d.%llu.%llu.%s",pid,(unsigned long long)sec,(unsigned long long)usec,resize_fields[i]);
            if(notify_register_check(name,&slot->token[i])!=NOTIFY_STATUS_OK) {resize_drop(slot);return -2;}
        }
    }
    for(unsigned attempt=0;attempt<2;attempt++) {
        uint64_t values[20]={0},first=0,last=0;
        if(notify_get_state(slot->token[0],&first)!=NOTIFY_STATUS_OK || !first || first&1) continue;
        unsigned index;
        for(index=0;index<20;index++) if(notify_get_state(slot->token[index],&values[index])!=NOTIFY_STATUS_OK) break;
        if(index!=20 || notify_get_state(slot->token[0],&last)!=NOTIFY_STATUS_OK || first!=last || first!=values[0]) continue;
        if(!values[1] || !values[2] || values[2]>UINT32_MAX || values[3]<1 || values[3]>4) continue;
        struct hs_resize_context context={.sequence=first,.epoch=values[1],.wid=(uint32_t)values[2],.phase=(uint32_t)values[3]};
        double *target=&context.x;
        for(unsigned i=0;i<8;i++) memcpy(&target[i],&values[i+4],sizeof(double));
        context.sample=values[19];
        if(context.sample) {
            double *actual=&context.accepted_x;
            unsigned i;for(i=0;i<5;i++) {memcpy(&actual[i],&values[i+14],sizeof(double));if(!isfinite(actual[i]))break;}
            if(i!=5 || context.accepted_w<=0 || context.accepted_h<=0 || now-context.accepted_time<0 || now-context.accepted_time>.25)continue;
            int owner=0,level=0;
            if(hs_win_pid_level(context.wid,&owner,&level) || owner!=pid || level!=0)continue;
        }
        if(!isfinite(context.time) || now-context.time<0 || now-context.time>.25) continue;
        if(context.phase<=2) {
            if(values[12]!=1 || values[13]!=1 || !isfinite(context.event_time) || now-context.event_time<0 || (context.phase==1 && now-context.event_time>.5) || context.event_time>context.time) continue;
            unsigned i;for(i=0;i<6;i++) if(!isfinite(target[i])) break;
            int owner=0,level=0;
            if(i!=6 || context.w<=0 || context.h<=0 || hs_win_pid_level(context.wid,&owner,&level) || owner!=pid || level!=0) continue;
        }
        uint64_t finalSec=0,finalUsec=0;
        if(hs_process_birth(pid,&finalSec,&finalUsec) || finalSec!=sec || finalUsec!=usec || notify_get_state(slot->token[0],&last)!=NOTIFY_STATUS_OK || last!=first) continue;
        *out=context;return 0;
    }
    return -3;
}

uint64_t hs_overview10_mode(void) {
    int token=-1; uint64_t mode=0;
    if(notify_register_check("hyprwm.overview10.state",&token)!=NOTIFY_STATUS_OK) return UINT64_MAX;
    int result=notify_get_state(token,&mode);notify_cancel(token);
    return result==NOTIFY_STATUS_OK ? mode : UINT64_MAX;
}

int hs_notify_poll(const char *name,int *token) {
    if(!name || !token)return -1;
    if(*token<0 && notify_register_check(name,token)!=NOTIFY_STATUS_OK)return -2;
    int changed=0;
    if(notify_check(*token,&changed)!=NOTIFY_STATUS_OK)return -3;
    return changed!=0;
}
void hs_notify_cancel(int token) {if(token>=0)notify_cancel(token);}

int hs_notify_state(const char *name,uint64_t *value) {
    if(!name || !value || strlen(name)>160)return -1;
    int token=-1;
    if(notify_register_check(name,&token)!=NOTIFY_STATUS_OK)return -2;
    int status=notify_get_state(token,value);notify_cancel(token);
    return status==NOTIFY_STATUS_OK ? 0 : -3;
}

int hs_notify_publish_state(const char *name,uint64_t value) {
    if(!name || strlen(name)>160)return -1;
    int token=-1;
    if(notify_register_check(name,&token)!=NOTIFY_STATUS_OK)return -2;
    int status=notify_set_state(token,value);
    if(status==NOTIFY_STATUS_OK)status=notify_post(name);
    notify_cancel(token);
    return status==NOTIFY_STATUS_OK ? 0 : -3;
}
