// Dormant explicit-FP C bodies for the independently qualified C++ entries.
// Counter balance does not authorize native recovery of a quarantined capsule.
static int display_unwind_bindings(struct display_unwind_bridge *b) {
    return du_valid(b) && display_visibility_valid(b->visibility) &&
        !__atomic_load_n(&b->sink->enabled,__ATOMIC_ACQUIRE) &&
        b->visibility->sink==b->sink && b->sink->source.pair==b->pair;
}
static int display_unwind_local(struct display_unwind_bridge *b,struct du_local *l,unsigned kind) {
    return display_unwind_bindings(b) && l && l->bridge==b &&
        l->generation==b->generation && l->entry_kind==kind;
}
void anim_display_unwind_abort(struct du_local *l) {
    struct display_unwind_bridge *b=l->bridge;
    if(!display_unwind_bindings(b) || l->generation!=b->generation)return;
    struct display_pair *p=b->pair;struct display_visibility *v=b->visibility;
    // Release only the exact OWN latch acquired by this invocation. All private
    // workspace, borrowed diagnostic scalars and retained native refs stay put.
    if(l->owned_epoch && p->active_epoch==l->owned_epoch &&
       p->active_revision==l->owned_revision) {
        p->active_revision=0;p->active_begin=0;p->active_end=0;
        __atomic_store_n(&p->active_epoch,0,__ATOMIC_RELEASE);
    }
    if(l->owns_receipt && v->entry_receipt==l->owned_receipt) {
        v->entry_receipt=0;v->frame_receipt=0;v->frame_epoch=0;
    }
    __atomic_store_n(&v->enabled,0,__ATOMIC_RELEASE);
    if(!__atomic_load_n(&v->phase,__ATOMIC_ACQUIRE))
        display_visibility_phase(v,DISPLAY_VISIBILITY_QUARANTINED);
}
static u64 display_unwind_visibility_begin(struct display_unwind_bridge *b,
                                          struct du_local *l,u64 caller) {
    struct display_visibility *v=b->visibility;u64 nested;
    if(!du_legacy_enter(l,DU_VIS_ENTRY,&v->entered,&v->returned,&v->inflight,&nested))return 0;
    if(__atomic_load_n(&v->phase,__ATOMIC_ACQUIRE))
        __atomic_fetch_add(&v->mutating_entries,1,__ATOMIC_RELAXED);
    struct display_pair *p=b->pair;
    if(!p->probe.is_main || p->probe.is_main()!=1) {
        __atomic_fetch_add(&v->nonmain,1,__ATOMIC_RELAXED);return 0;
    }
    if(!caller)__atomic_fetch_add(&v->unknown,1,__ATOMIC_RELAXED);
    if(__atomic_load_n(&b->quarantine_generation,__ATOMIC_ACQUIRE))return 0;
    u64 receipt=__atomic_load_n(&v->committed,__ATOMIC_ACQUIRE);
    if(!nested) {
        l->owns_receipt=1;l->owned_receipt=receipt;
        v->entry_receipt=receipt;v->last_caller=caller;v->frame_receipt=0;v->frame_epoch=0;
    }
    return receipt;
}
int anim_display_unwind_pair_body(void *connection,u64 force,void *begin,void *end,
        struct display_unwind_bridge *b,display_original_fn original,
        u64 entry_fp,u64 native_fp,struct du_local *l) {
    if(!display_unwind_local(b,l,DU_PAIR))return original(connection,force,begin,end);
    struct display_pair *p=b->pair;struct display_visibility *v=b->visibility;u64 caller=0;
    if(du_forward_only(b)) {
        u64 prior;
        int tracked=du_legacy_enter(l,DU_VIS_ENTRY,&v->entered,&v->returned,&v->inflight,&prior);
        int result=display_pair_dispatch(connection,force,begin,end,p,original,0,0,l);
        if(tracked)du_legacy_close(l,DU_VIS_ENTRY);
        return result;
    }
    if(display_pair_live(p) && p->thread_self && p->stack_top && p->stack_size) {
        void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
        if(size>=4096 && size<=0x40000000ULL && top>=size)
            caller=display_pair_framed_caller(p,entry_fp,native_fp,top-size,top);
    }
    u64 receipt=display_unwind_visibility_begin(b,l,caller);
    if(receipt && !p->active_epoch && __atomic_load_n(&v->inflight,__ATOMIC_ACQUIRE)==1)
        __atomic_store_n(&p->revision,receipt>>4,__ATOMIC_RELEASE);
    int result=display_pair_dispatch(connection,force,begin,end,p,original,caller,0,l);
    // Every native getter/helper has returned before this possible ACK. The
    // remaining receipt/role close and C++ normal close are scalar operations.
    if(!du_forward_only(b))
        display_visibility_construction_end(v,receipt,result);
    if(l->owns_receipt && v->entry_receipt==l->owned_receipt) {
        v->last_receipt=receipt;v->entry_receipt=0;
    }
    du_legacy_close(l,DU_VIS_ENTRY);return result;
}
int anim_display_unwind_source_body(void *redraw,void *window,
        struct display_unwind_bridge *b,display_generate_fn original,
        u64 entry_fp,u64 native_fp,struct du_local *l) {
    if(!display_unwind_local(b,l,DU_SOURCE))return original(redraw,window);
    // First integrated qualifier observes unmodified native Source output.
    // Private generation/cleanup needs its own quarantine checkpoints before
    // this bridge can admit a sink. The binding above refuses enabled sinks.
    return display_source_dispatch(redraw,window,&b->sink->source,original,0,
                                   entry_fp,native_fp,0,l);
}
void anim_display_unwind_timer_begin(struct ctx *c,struct display_unwind_bridge *b,struct du_local *l) {
    if(!display_unwind_local(b,l,DU_TIMER) || b->pair->probe.engine!=c)return;
    struct display_visibility *v=b->visibility;u64 prior;
    if(!du_legacy_enter(l,DU_VIS_TIMER,&v->timer_entered,&v->timer_returned,&v->timer_inflight,&prior))return;
    if(__atomic_load_n(&v->phase,__ATOMIC_ACQUIRE))
        __atomic_fetch_add(&v->mutating_entries,1,__ATOMIC_RELAXED);
}
static int display_unwind_timer_drained(struct display_unwind_bridge *b) {
    for(unsigned i=0;i<DU_ENTRIES;i++)
        if(!du_balanced(__atomic_load_n(&b->entry_entered[i],__ATOMIC_ACQUIRE),
                       __atomic_load_n(&b->entry_returned[i],__ATOMIC_ACQUIRE),
                       __atomic_load_n(&b->entry_unwound[i],__ATOMIC_ACQUIRE),i==DU_TIMER?1:0) ||
           __atomic_load_n(&b->entry_inflight[i],__ATOMIC_ACQUIRE)!=(i==DU_TIMER?1:0))return 0;
    return 1;
}
void anim_display_unwind_timer_mutation(struct ctx *c,double now,
        struct display_unwind_bridge *b,struct du_local *l) {
    (void)now;
    if(!display_unwind_local(b,l,DU_TIMER) || b->pair->probe.engine!=c ||
       du_forward_only(b) ||
       !display_unwind_timer_drained(b))return;
    struct display_visibility *v=b->visibility;
    if(!display_visibility_configured(v) || !v->view->capture ||
       !v->view->capture->pc.is_main || v->view->capture->pc.is_main()!=1 ||
       pc_normal_frame(&v->view->capture->pc))return;
    display_visibility_apply(v);
}
void anim_display_unwind_timer_normal_end(struct display_unwind_bridge *b,struct du_local *l) {
    if(display_unwind_local(b,l,DU_TIMER))du_legacy_close(l,DU_VIS_TIMER);
}
void anim_display_unwind_frame(void *mctx,void *display,void *third,struct display_unwind_bridge *b) {
    if(!display_unwind_bindings(b) || du_forward_only(b))return;
    display_pair_frame_dispatch(mctx,display,third,b->pair,
        (u64)__builtin_frame_address(0),0,b->visibility);
}
unsigned anim_display_unwind_bridge_size(void){return sizeof(struct display_unwind_bridge);}
