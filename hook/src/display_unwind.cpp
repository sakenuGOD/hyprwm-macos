// Dormant copied-image entries. Native originals remain immutable island args.
#include "display_unwind.h"

class DisplayInvocation {
    display_unwind_bridge *bridge;
    bool normal;
public:
    du_local local;
    explicit DisplayInvocation(display_unwind_bridge *b,unsigned kind) noexcept
        : bridge(b),normal(false) {
        for(unsigned i=0;i<sizeof(local);i++)
            ((volatile unsigned char *)&local)[i]=0;
        local.bridge=b;local.generation=b->generation;local.entry_kind=kind;
        local.timer_turn=kind==DU_TIMER?
            __atomic_add_fetch(&b->timer_ticket,1,__ATOMIC_ACQ_REL):
            __atomic_load_n(&b->timer_ticket,__ATOMIC_ACQUIRE);
        __atomic_fetch_add(&b->entry_entered[kind],1,__ATOMIC_RELAXED);
        __atomic_fetch_add(&b->entry_inflight[kind],1,__ATOMIC_ACQ_REL);
    }
    void finish() noexcept { normal=true;local.stage=DU_STAGE_COMPLETE; }
    ~DisplayInvocation() noexcept {
        unsigned kind=local.entry_kind;
        if(!normal) {
            du64 roles=DU_FAIL_ENTRY(kind);
            for(unsigned i=0;i<local.count;i++)
                if(local.token[i].state==DU_OPEN)roles|=DU_FAIL_ROLE(local.token[i].role);
            // A private Source call includes helpers as well as its original.
            // ENTRY/UNKNOWN is never described as a proven original-only throw.
            if(local.stage==DU_STAGE_ORIGINAL) {
                roles|=DU_FAIL_ORIGINAL;
                __atomic_fetch_add(&bridge->original_threw,1,__ATOMIC_RELAXED);
            } else if(local.stage==DU_STAGE_MUTATION) {
                roles|=DU_FAIL_MUTATION;
                __atomic_fetch_add(&bridge->mutation_threw,1,__ATOMIC_RELAXED);
            } else roles|=DU_FAIL_UNKNOWN;
            du_quarantine(&local,roles);
            anim_display_unwind_abort(&local); // OWN scalars only; never native cleanup.
        }
        for(unsigned i=local.count;i;i--) {
            du_token *t=&local.token[i-1];
            if(t->state!=DU_OPEN)continue;
            __atomic_fetch_add(t->unwound,1,__ATOMIC_RELAXED);
            __atomic_fetch_sub(t->inflight,1,__ATOMIC_RELEASE);t->state=DU_CLOSED;
        }
        __atomic_fetch_add(normal?&bridge->entry_returned[kind]:
                                  &bridge->entry_unwound[kind],1,__ATOMIC_RELAXED);
        __atomic_fetch_sub(&bridge->entry_inflight[kind],1,__ATOMIC_RELEASE);
    }
};

extern "C" __attribute__((noinline)) int anim_display_unwind_pair(
        void *connection,du64 force,void *begin,void *end,
        display_unwind_bridge *b,du_pair_original original,du64 native_fp) {
    if(!du_valid(b))return original(connection,force,begin,end);
    DisplayInvocation invocation(b,DU_PAIR);
    invocation.local.entry_fp=(du64)__builtin_frame_address(0);
    invocation.local.native_fp=native_fp;
    int result=anim_display_unwind_pair_body(connection,force,begin,end,b,original,
        invocation.local.entry_fp,native_fp,&invocation.local);
    invocation.finish();return result;
}

extern "C" __attribute__((noinline)) int anim_display_unwind_source(
        void *redraw,void *window,display_unwind_bridge *b,
        du_source_original original,du64 native_fp) {
    if(!du_valid(b))return original(redraw,window);
    DisplayInvocation invocation(b,DU_SOURCE);
    invocation.local.entry_fp=(du64)__builtin_frame_address(0);
    invocation.local.native_fp=native_fp;
    int result=anim_display_unwind_source_body(redraw,window,b,original,
        invocation.local.entry_fp,native_fp,&invocation.local);
    invocation.finish();return result;
}

extern "C" __attribute__((noinline)) void anim_display_unwind_timer(
        ctx *c,double now,display_unwind_bridge *b,du_timer_original original) {
    if(!du_valid(b)){original(c,now);return;}
    DisplayInvocation invocation(b,DU_TIMER);
    anim_display_unwind_timer_begin(c,b,&invocation.local);
    invocation.local.stage=DU_STAGE_ORIGINAL;
    original(c,now); // Original exceptions propagate; there is no retry.
    try {
        invocation.local.stage=DU_STAGE_MUTATION;
        anim_display_unwind_timer_mutation(c,now,b,&invocation.local);
    } catch(...) {
        // The payload has unwound. This invocation closes as exception-aborted,
        // even though this void boundary returns. No normal construction ACK.
        return;
    }
    anim_display_unwind_timer_normal_end(b,&invocation.local);
    invocation.finish();
}

#include "display_private_source.h"
extern "C" __attribute__((noinline)) int anim_display_private_source(
 void*r,void*w,display_private_source*t,du_source_original original,du64 native_fp) {
 if(!ps_valid(t))return original(r,w);
 DisplayInvocation invocation(&t->bridge,DU_SOURCE);
 invocation.local.entry_fp=(du64)__builtin_frame_address(0);
 invocation.local.native_fp=native_fp;
 int result=anim_display_private_source_body(r,w,t,original,
  invocation.local.entry_fp,native_fp,&invocation.local);
 invocation.finish();return result;
}
