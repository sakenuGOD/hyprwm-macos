// OWN, A-unfenced visibility qualifier. Native control runs only on the existing
// serialized MAIN timer, before display ingestion. No exclusive fallback claim.
#define DISPLAY_VISIBILITY_MAGIC 0x31534956574d5748ULL
#define DISPLAY_VISIBILITY_VERSION 2
#define DISPLAY_VISIBILITY_COMMAND_MAGIC 0x31434c56574d5748ULL
struct display_visibility_command {
    u64 magic;u32 size,version;
    u64 request,completed,constructed; // completed means native apply ONLY.
};
enum { DISPLAY_VISIBILITY_SHOW_A,DISPLAY_VISIBILITY_TEST_B,DISPLAY_VISIBILITY_REVOKE_B };
enum { DISPLAY_VISIBILITY_IDLE,DISPLAY_VISIBILITY_CHECKING,DISPLAY_VISIBILITY_PREPARING,
       DISPLAY_VISIBILITY_APPLYING,DISPLAY_VISIBILITY_REVOKING,
       DISPLAY_VISIBILITY_INVALIDATING,DISPLAY_VISIBILITY_QUARANTINED,DISPLAY_VISIBILITY_OBSERVING };
enum { DISPLAY_VISIBILITY_OK,DISPLAY_VISIBILITY_REQUEST,DISPLAY_VISIBILITY_BUSY,
       DISPLAY_VISIBILITY_PROFILE,DISPLAY_VISIBILITY_REGION,DISPLAY_VISIBILITY_ALPHA,
       DISPLAY_VISIBILITY_ORDER,DISPLAY_VISIBILITY_REENTRY };
enum { DISPLAY_VISIBILITY_B_ZERO=1,DISPLAY_VISIBILITY_B_ONE,DISPLAY_VISIBILITY_B_OUT };
struct display_visibility {
    u64 magic;u32 size,version;
    struct display_source_sink *sink;
    struct rgba_view *view;
    struct display_visibility_command *command;
    void *region;
    void (*invalidate)(void *,void *,void *);
    struct display_transition *profile; // Immutable display/ContainsRegion profile.
    rect footprint;
    u64 capture_witness;
    // Optional OWN normal-return refusal experiment. Immutable, zero normally.
    u64 refuse_word;
    u32 enabled,phase,reason,terminal;
    u64 claimed,committed,applications,revocations,invalidations,refused;
    // Entry observation is independent of Pair's sampled/classified epoch.
    u64 entered,returned,inflight,mutating_entries,nonmain,unknown;
    u64 entry_receipt,last_receipt,last_caller;
    u64 frame_receipt,frame_epoch,covered_frames,uncovered_frames;
    u64 timer_entered,timer_returned,timer_inflight;
    int (*get_boolean)(void *,const void *,unsigned char *);
    const void *fade_on_order_out_key;
};
static void display_visibility_phase(struct display_visibility *v,unsigned phase) {
    __atomic_store_n(&v->phase,phase,__ATOMIC_RELEASE);
}
static int display_visibility_valid(struct display_visibility *v) {
    return v && v->magic==DISPLAY_VISIBILITY_MAGIC && v->size==sizeof(*v) &&
        v->version==DISPLAY_VISIBILITY_VERSION && display_source_sink_valid(v->sink) &&
        display_pair_valid(v->sink->source.pair);
}
static int display_visibility_configured(struct display_visibility *v) {
    return display_visibility_valid(v) && v->view && v->profile &&
        display_transition_valid(v->profile) && v->profile->sink==v->sink &&
        v->profile->view==v->view && v->profile->capture_witness==v->capture_witness &&
        v->profile->contains && v->profile->display && v->profile->display_vtable &&
        rgba_view_same(v->profile->footprint,v->footprint) &&
        rgba_view_same(v->profile->display_bounds,v->view->display_bounds) &&
        v->command && v->command->magic==DISPLAY_VISIBILITY_COMMAND_MAGIC &&
        v->command->size==sizeof(*v->command) && v->command->version==1 &&
        v->invalidate && v->get_boolean && v->fade_on_order_out_key &&
        v->capture_witness && rgba_view_rect(v->footprint);
}
static int display_visibility_drained(struct display_visibility *v,int revoke) {
    struct display_source_sink *q=v->sink;struct display_pair *p=q->source.pair;
    return display_pair_live(p) && q->a_unfenced==1 && q->profile_verified==1 &&
        !__atomic_load_n(&q->enabled,__ATOMIC_ACQUIRE) &&
        !__atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE) &&
        __atomic_load_n(&p->probe.entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&p->probe.returned,__ATOMIC_ACQUIRE) &&
        !p->active_epoch && !__atomic_load_n(&q->source.inflight,__ATOMIC_ACQUIRE) &&
        __atomic_load_n(&q->source.entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&q->source.returned,__ATOMIC_ACQUIRE) &&
        !__atomic_load_n(&v->inflight,__ATOMIC_ACQUIRE) &&
        __atomic_load_n(&v->entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&v->returned,__ATOMIC_ACQUIRE) &&
        __atomic_load_n(&v->timer_inflight,__ATOMIC_ACQUIRE)==1 &&
        __atomic_load_n(&v->timer_entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&v->timer_returned,__ATOMIC_ACQUIRE)+1 &&
        (revoke || (!q->workspace.phase && !q->workspace.head));
}
// The accepted finish-order callback temporarily owns shared in_cb. Admit only
// its quiet route: no tracked order transition can allocate a close snapshot or
// drop an edge. This is a bounded qualifier profile, not exception recovery.
static int display_visibility_quiet_order(struct display_visibility *v) {
    struct ctx *c=v->sink->source.pair->probe.engine;u32 wid=v->view->wid;
    for(unsigned i=0;i<P8_N;i++)if(P8_TAB(c)[i].live)return 0;
    struct birth_state *birth=birth_state(c);
    if(*(void **)((char *)c+BIRTH_STATE_OFFSET) && !birth)return 0;
    if(birth)for(unsigned i=0;i<BIRTH_WINDOWS;i++)
        if(birth->windows[i].holding ||
           (birth->windows[i].wid==wid && !birth->windows[i].superseded))return 0;
    for(unsigned i=0;i<CH_NW;i++) {
        struct ch_win *w=&c->ch->win[i];
        if(!w->used)continue;
        if(w->wid==wid)return 0;
        char *native=c->by_id(w->wid);
        unsigned on=native && !!(*(u64 *)(native+0x928)&(1ULL<<44));
        if(P8_ON(c)[i]!=on)return 0;
    }
    return !c->in_cb;
}
// Native bit23 enters a policy branch, not necessarily a fade. Its immediate
// route accepts zero effective alpha or an absent/non-Boolean/false property.
// The getter/key are pinned by the installer; no native flag/property is edited.
static int display_visibility_immediate_order(struct display_visibility *v) {
    char *b=v->view->window;
    if(!(*(u64 *)(b+0x928)&(1ULL<<23)))return 1;
    float alpha=*(float *)(b+0x1d8);
    if(!__builtin_isfinite(alpha) || alpha<0 || alpha>1 ||
       *(float *)(b+0x1dc)!=1 || *(float *)(b+0x1e0)!=1)return 0;
    if(alpha==0)return 1;
    unsigned char value=0xa5;
    int present=v->get_boolean(*(void **)(b+0x88),v->fade_on_order_out_key,&value);
    return present==0 || (present==1 && value==0);
}
static int display_visibility_profile(struct display_visibility *v) {
    struct display_pair *p=v->sink->source.pair;struct rgba_view *w=v->view;
    struct rgba_capture *g=w->capture;struct ctx *c=p->probe.engine;
    if(!rgba_view_valid(w,g) || g->pc.engine!=c || g->destroyed || g->pc.dead ||
       w->retired || !w->prepared || !w->shown || w->pre_display ||
       w->active || w->command || w->sequence!=w->ack ||
       g->pc.command || g->pc.active_command || g->pc.command_sequence!=g->pc.command_ack ||
       g->pc.stage!=3 || g->pc.gpu_status!=4 || g->pc.gpu_pending || g->clear_status!=4 ||
       g->pc.capture_witness!=v->capture_witness || !g->pc.texture_ref ||
       w->texture!=g->pc.texture_ref || !display_pair_window(p,0) ||
       g->pc.source!=p->identity[0].window || g->pc.wid!=p->identity[0].wid ||
       g->pc.creator!=p->identity[0].creator || g->pc.pid_version!=p->identity[0].pid_version ||
       !p->identity[0].creator || p->identity[1].creator ||
       w->window!=display_pair_window(p,1) || !rgba_view_native_ready(w) ||
       !rgba_view_same(w->current,v->footprint) || !rgba_view_same(w->target,v->footprint) ||
       !rgba_view_contains(w->display_bounds,v->footprint) ||
       !c->rgn || !c->bbox || c->shape_off!=0x170 || !w->api.order ||
       !w->api.display_id || w->api.display_id(w->window)!=w->display)return 0;
    char *b=w->window;
    char *a=(char *)g->pc.source;
    return display_visibility_immediate_order(v) && !*(void **)(b+0x428) &&
        !*(void **)(b+0x488) && !*(void **)(b+0x878) &&
        !*(void **)(b+0x880) && !*(void **)(b+0x8b0) &&
        *(void **)(b+0x170) && rgba_view_same(c->bbox(*(void **)(b+0x170)),v->footprint) &&
        *(void **)(a+0x170) && rgba_view_same(c->bbox(*(void **)(a+0x170)),g->pc.capture_rect);
}
static int display_visibility_order_out(struct display_visibility *v,u64 reentries) {
    struct rgba_view *w=v->view;
    display_visibility_phase(v,DISPLAY_VISIBILITY_REVOKING);v->revocations++;
    if(!display_visibility_drained(v,1) || !display_visibility_quiet_order(v))return 0;
    // A failed alpha readback may mean identity/profile loss. Never turn that
    // into an order-by-reused-WID mutation of an unrelated allocation.
    if(!rgba_view_owned(w) || w->window!=display_pair_window(v->sink->source.pair,1))return 0;
    char *b=w->window;
    if(*(void **)(b+0x888) || *(void **)(b+0x1f0) || !display_visibility_immediate_order(v) ||
       *(void **)(b+0x428) || *(void **)(b+0x488) || *(void **)(b+0x878) ||
       *(void **)(b+0x880) || *(void **)(b+0x8b0) ||
       __atomic_load_n(&v->mutating_entries,__ATOMIC_ACQUIRE)!=reentries)return 0;
    if(w->api.order(0,w->wid,0,0) || !rgba_view_owned(w) ||
       (*(u64 *)((char *)w->window+0x928)&(1ULL<<44)) ||
       v->sink->source.pair->probe.engine->in_cb)return 0;
    w->shown=0;v->terminal=1;return 1;
}
static void display_visibility_apply(struct display_visibility *v) {
    if(!display_visibility_configured(v) || !__atomic_load_n(&v->enabled,__ATOMIC_ACQUIRE) ||
       __atomic_load_n(&v->phase,__ATOMIC_ACQUIRE) || v->terminal)return;
    u64 word=__atomic_load_n(&v->command->request,__ATOMIC_ACQUIRE);
    if(word==v->claimed)return;
    // A committed receipt packs this word plus a two-bit native visibility route.
    if(!(word>>2) || (word&3)==3 || word>(~0ULL>>2) ||
       (word>>2)<=(v->claimed>>2)) {
        v->reason=DISPLAY_VISIBILITY_REQUEST;v->refused++;return;
    }
    if(!display_visibility_drained(v,(word&3)==DISPLAY_VISIBILITY_REVOKE_B)) {
        v->reason=DISPLAY_VISIBILITY_BUSY;v->refused++;return;
    }
    v->claimed=word;v->reason=DISPLAY_VISIBILITY_OK;
    u64 reentries=__atomic_load_n(&v->mutating_entries,__ATOMIC_ACQUIRE);
    // Every potentially throwing native read/helper has persistent phase custody.
    // No shared engine in_cb or native owner flag is changed by this controller.
    display_visibility_phase(v,DISPLAY_VISIBILITY_CHECKING);
    if(!display_visibility_profile(v)) {
        v->reason=DISPLAY_VISIBILITY_PROFILE;v->refused++;
        display_visibility_phase(v,DISPLAY_VISIBILITY_QUARANTINED);return;
    }
    struct ctx *c=v->sink->source.pair->probe.engine;
    if(!v->region) {
        display_visibility_phase(v,DISPLAY_VISIBILITY_PREPARING);
        v->region=c->rgn(v->footprint); // Permanent OWN reference, including OFF/throw.
        if(!v->region || !rgba_view_same(c->bbox(v->region),v->footprint)) {
            v->reason=DISPLAY_VISIBILITY_REGION;
            display_visibility_phase(v,DISPLAY_VISIBILITY_QUARANTINED);return;
        }
    }
    if(__atomic_load_n(&v->mutating_entries,__ATOMIC_ACQUIRE)!=reentries) {
        v->reason=DISPLAY_VISIBILITY_REENTRY;
        display_visibility_phase(v,DISPLAY_VISIBILITY_QUARANTINED);return;
    }
    unsigned route=DISPLAY_VISIBILITY_B_OUT;
    if((word&3)==DISPLAY_VISIBILITY_REVOKE_B) {
        if(!display_visibility_order_out(v,reentries))goto order_failed;
    } else {
        float alpha=(word&3)==DISPLAY_VISIBILITY_TEST_B?1:0;
        display_visibility_phase(v,DISPLAY_VISIBILITY_APPLYING);v->applications++;
        c->set_alpha(0,v->view->window,alpha,0);
        if(!rgba_view_native_alpha(v->view,alpha) ||
           !display_visibility_immediate_order(v) || word==v->refuse_word) {
            v->reason=DISPLAY_VISIBILITY_ALPHA;
            // Normal-return inverse experiment only; an unreturned setter never
            // reaches here. OrderOut is terminal, never followed by re-order-in.
            if(!display_visibility_order_out(v,reentries))goto order_failed;
        } else {
            v->view->current_alpha=v->view->alpha=alpha;
            route=alpha?DISPLAY_VISIBILITY_B_ONE:DISPLAY_VISIBILITY_B_ZERO;
        }
    }
    display_visibility_phase(v,DISPLAY_VISIBILITY_INVALIDATING);v->invalidations++;
    v->invalidate(0,0,v->region);
    if(__atomic_load_n(&v->mutating_entries,__ATOMIC_ACQUIRE)!=reentries) {
        v->reason=DISPLAY_VISIBILITY_REENTRY;
        display_visibility_phase(v,DISPLAY_VISIBILITY_QUARANTINED);return;
    }
    // Publish ONE native receipt. Neither a pending request nor this completion
    // is a frame/coverage/presentation ACK. A remains native in every mode.
    __atomic_store_n(&v->committed,(word<<2)|route,__ATOMIC_RELEASE);
    __atomic_store_n(&v->command->completed,word,__ATOMIC_RELEASE);
    display_visibility_phase(v,DISPLAY_VISIBILITY_IDLE);return;
order_failed:
    v->reason=DISPLAY_VISIBILITY_ORDER;
    display_visibility_phase(v,DISPLAY_VISIBILITY_QUARANTINED);
}
void anim_display_visibility_dispatch(struct ctx *c,double now,struct display_visibility *v,
                                      void (*original)(struct ctx *,double)) {
    int tracked=display_visibility_valid(v) && v->sink->source.pair->probe.engine==c;
    if(tracked) {
        __atomic_fetch_add(&v->timer_entered,1,__ATOMIC_RELAXED);
        __atomic_fetch_add(&v->timer_inflight,1,__ATOMIC_ACQ_REL);
        if(__atomic_load_n(&v->phase,__ATOMIC_ACQUIRE))
            __atomic_fetch_add(&v->mutating_entries,1,__ATOMIC_RELAXED);
    }
    original(c,now); // Immutable independent island argument, exactly once.
    if(!display_visibility_configured(v) || v->sink->source.pair->probe.engine!=c ||
       !v->view->capture || !v->view->capture->pc.is_main ||
       v->view->capture->pc.is_main()!=1 || pc_normal_frame(&v->view->capture->pc))goto done;
    display_visibility_apply(v);
done:
    if(tracked) {
        __atomic_fetch_add(&v->timer_returned,1,__ATOMIC_RELAXED);
        __atomic_fetch_sub(&v->timer_inflight,1,__ATOMIC_RELEASE);
    }
}
static u64 display_visibility_entry_begin(struct display_visibility *v,u64 caller) {
    if(!display_visibility_valid(v))return 0;
    __atomic_fetch_add(&v->entered,1,__ATOMIC_RELAXED);
    u64 nested=__atomic_fetch_add(&v->inflight,1,__ATOMIC_ACQ_REL);
    if(__atomic_load_n(&v->phase,__ATOMIC_ACQUIRE))
        __atomic_fetch_add(&v->mutating_entries,1,__ATOMIC_RELAXED);
    struct display_pair *p=v->sink->source.pair;
    if(!p->probe.is_main || p->probe.is_main()!=1) {
        __atomic_fetch_add(&v->nonmain,1,__ATOMIC_RELAXED);return 0;
    }
    if(!caller)__atomic_fetch_add(&v->unknown,1,__ATOMIC_RELAXED);
    // Even classifier-unknown FULL entry observes committed, never requested.
    u64 receipt=__atomic_load_n(&v->committed,__ATOMIC_ACQUIRE);
    if(!nested){v->entry_receipt=receipt;v->last_caller=caller;v->frame_receipt=0;v->frame_epoch=0;}
    return receipt;
}
static void display_visibility_observe(struct display_visibility *v,struct display_pair *p,
                                       const struct display_pair_record *r,char *redraw) {
    if(!display_visibility_configured(v) || v->sink->source.pair!=p ||
       __atomic_load_n(&v->phase,__ATOMIC_ACQUIRE) || !v->region || !v->profile ||
       !v->profile->contains || !v->entry_receipt || r->reason || !redraw ||
       r->redraw!=(u64)redraw || r->epoch!=p->active_epoch ||
       r->revision!=(v->entry_receipt>>4) || !(r->found_mask&1) ||
       v->entry_receipt!=__atomic_load_n(&v->committed,__ATOMIC_ACQUIRE) ||
       !display_transition_display(v->profile,(void *)r->display))return;
    unsigned route=v->entry_receipt&3;struct rgba_view *w=v->view;
    display_visibility_phase(v,DISPLAY_VISIBILITY_OBSERVING);
    if(!rgba_view_owned(w)) {display_visibility_phase(v,DISPLAY_VISIBILITY_IDLE);return;}
    char *b=w->window,*cwc=*(char **)(b+0x18);
    int native_matches=route==DISPLAY_VISIBILITY_B_OUT?
        (v->terminal && !(*(u64 *)(b+0x928)&(1ULL<<44)) && r->found_mask==1):
        (cwc && rgba_view_native_alpha(w,route==DISPLAY_VISIBILITY_B_ONE?1:0) &&
         *(float *)(cwc+0x174)==(route==DISPLAY_VISIBILITY_B_ONE?1:0) &&
         // SourceItem.alpha is local content opacity (S+188). Whole-window
         // opacity is prepared into CWC+174 above; local content may remain 1.
         (route==DISPLAY_VISIBILITY_B_ONE?r->found_mask==3:
          (r->found_mask==1 || r->found_mask==3)));
    if(!native_matches) {display_visibility_phase(v,DISPLAY_VISIBILITY_IDLE);return;}
    void *clip=*(void **)(redraw+0x58);
    if(!clip) {display_visibility_phase(v,DISPLAY_VISIBILITY_IDLE);return;}
    int covered=v->profile->contains(clip,v->region)&1;
    display_visibility_phase(v,DISPLAY_VISIBILITY_IDLE);
    if(covered) {
        v->covered_frames++;v->frame_receipt=v->entry_receipt;v->frame_epoch=r->epoch;
    } else v->uncovered_frames++;
    struct display_pair_record proof;
    for(unsigned i=0;i<sizeof(proof);i++)
        ((volatile unsigned char *)&proof)[i]=((const unsigned char *)r)[i];
    proof.event=DISPLAY_PAIR_VISIBILITY;proof.native_result=covered;
    display_pair_publish(p,&proof);
}
static void display_visibility_entry_end(struct display_visibility *v,u64 receipt) {
    if(!display_visibility_valid(v))return;
    if(v->sink->source.pair->probe.is_main && v->sink->source.pair->probe.is_main()==1 &&
       __atomic_load_n(&v->inflight,__ATOMIC_ACQUIRE)==1) {
        v->last_receipt=receipt;v->entry_receipt=0;
    }
    __atomic_fetch_add(&v->returned,1,__ATOMIC_RELAXED);
    __atomic_fetch_sub(&v->inflight,1,__ATOMIC_RELEASE);
}
static void display_visibility_construction_end(struct display_visibility *v,u64 receipt,int result) {
    if(!display_visibility_configured(v))return;
    struct display_pair *p=v->sink->source.pair;
    // A nested return may still see the outer frame's positive latch. Only the
    // normally completed, balanced outer entry has authority to publish it.
    if(!result && receipt && __atomic_load_n(&v->inflight,__ATOMIC_ACQUIRE)==1 &&
       __atomic_load_n(&v->entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&v->returned,__ATOMIC_ACQUIRE)+1 &&
       !p->active_epoch && !__atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE) &&
       __atomic_load_n(&p->probe.entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&p->probe.returned,__ATOMIC_ACQUIRE) &&
       v->frame_receipt==receipt && v->frame_epoch==p->epochs && v->frame_epoch &&
       !__atomic_load_n(&v->phase,__ATOMIC_ACQUIRE) && !__atomic_load_n(&v->sink->enabled,__ATOMIC_ACQUIRE) &&
       !__atomic_load_n(&v->sink->source.inflight,__ATOMIC_ACQUIRE) &&
       __atomic_load_n(&v->sink->source.entered,__ATOMIC_ACQUIRE)==__atomic_load_n(&v->sink->source.returned,__ATOMIC_ACQUIRE))
        __atomic_store_n(&v->command->constructed,receipt>>2,__ATOMIC_RELEASE);
}
int anim_display_visibility_framed(void *connection,u64 force,void *begin,void *end,
        struct display_visibility *v,display_original_fn original,u64 native_fp) {
    if(!display_visibility_valid(v))return original(connection,force,begin,end);
    struct display_pair *p=v->sink->source.pair;u64 caller=0;
    if(display_pair_live(p) && p->thread_self && p->stack_top && p->stack_size) {
        void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
        if(size>=4096 && size<=0x40000000ULL && top>=size)
            caller=display_pair_framed_caller(p,(u64)__builtin_frame_address(0),native_fp,top-size,top);
    }
    u64 receipt=display_visibility_entry_begin(v,caller);
    if(receipt && !p->active_epoch && __atomic_load_n(&v->inflight,__ATOMIC_ACQUIRE)==1)
        __atomic_store_n(&p->revision,receipt>>4,__ATOMIC_RELEASE);
    int result=display_pair_dispatch(connection,force,begin,end,p,original,caller,0,0);
    display_visibility_construction_end(v,receipt,result);
    display_visibility_entry_end(v,receipt);return result;
}
void anim_display_visibility_frame(void *mctx,void *display,void *third,struct display_visibility *v) {
    if(!display_visibility_valid(v))return;
    display_pair_frame_dispatch(mctx,display,third,v->sink->source.pair,
                                (u64)__builtin_frame_address(0),0,v);
}
unsigned anim_display_visibility_size(void){return sizeof(struct display_visibility);}
unsigned anim_display_visibility_command_size(void){return sizeof(struct display_visibility_command);}
