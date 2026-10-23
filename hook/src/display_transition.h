// A-unfenced, ordinary-only full-footprint qualifier. Old Pair/Source/Sink and
// capture ABIs remain unchanged. No production/exclusive fallback is implied.
#define DISPLAY_TRANSITION_MAGIC 0x31525444574d5748ULL
struct display_transition {
    u64 magic;u32 size,version;
    struct display_source_sink *sink;
    struct display_damage damage;
    struct rgba_view *view;
    void *scheduler,*display_vtable;
    rect footprint,display_bounds;
    u32 display,pad;
    int (*contains)(void *,void *);
    u64 capture_witness;
    u64 entry_display,frame_epoch,frame_word,covered_frames,uncovered_frames;
};
static int display_transition_valid(struct display_transition *t) {
    return t && t->magic==DISPLAY_TRANSITION_MAGIC && t->size==sizeof(*t) &&
        t->version==1 && !t->pad && display_source_sink_valid(t->sink);
}
static int display_transition_configured(struct display_transition *t) {
    return display_transition_valid(t) && display_damage_configured(&t->damage) &&
        t->view && t->scheduler &&
        t->display_vtable && t->display && t->contains;
}
static int display_transition_ready(struct display_transition *t) {
    return display_transition_configured(t) && t->damage.region;
}
// The caller's current shared_ptr vector owns each display during this entry.
// Only the pinned concrete type authorizes these scalar layout reads.
static int display_transition_display(struct display_transition *t,void *object) {
    if(!object || __builtin_ptrauth_strip(*(void **)object,2)!=t->display_vtable)return 0;
    char *d=object;
    if(*(u32 *)(d+0x1e8)!=t->display || *(float *)(d+0x53c)!=2 ||
       *(int *)(d+0x540) || (*(unsigned char *)(d+0x76f)&16) ||
       !rgba_view_same(*(rect *)(d+0x240),t->display_bounds))return 0;
    double x=t->display_bounds.x,y=t->display_bounds.y;
    const double expected[4][6]={{2,0,0,2,0,0},{.5,0,0,.5,0,0},
                               {1,0,0,1,-x,-y},{1,0,0,1,x,y}};
    const unsigned offset[4]={0x330,0x360,0x390,0x3c0};
    for(unsigned i=0;i<4;i++)for(unsigned j=0;j<6;j++)
        if(((double *)(d+offset[i]))[j]!=expected[i][j])return 0;
    return 1;
}
static void *display_transition_selected(struct display_transition *t,void *begin,void *end) {
    u64 a=(u64)begin,b=(u64)end;
    if(!a || b<=a || ((b-a)&15) || b-a>16384)return 0;
    for(u64 at=a;at<b;at+=16) {
        void *object=*(void **)at;
        if(display_transition_display(t,object))return object;
    }
    return 0;
}
static int display_transition_owned(struct display_transition *t,struct display_pair *p) {
    struct display_source_sink *q=t->sink;
    struct rgba_view *v=t->view;struct rgba_capture *g=v->capture;
    if(q->source.pair!=p || q->a_unfenced!=1 || q->profile_verified!=1 ||
       q->workspace.phase || q->workspace.head || !display_pair_window(p,0) ||
       p->identity[1].creator || !p->identity[0].creator ||
       !rgba_view_valid(v,g) || g->destroyed || g->pc.dead ||
       g->pc.engine!=p->probe.engine || v->retired || !v->prepared || !v->shown ||
       g->pc.source!=p->identity[0].window || g->pc.wid!=p->identity[0].wid ||
       g->pc.creator!=p->identity[0].creator || g->pc.pid_version!=p->identity[0].pid_version ||
       !t->capture_witness || g->pc.capture_witness!=t->capture_witness ||
       g->pc.stage!=3 || g->pc.gpu_status!=4 || g->pc.gpu_pending || g->clear_status!=4 ||
       g->pc.command || g->pc.active_command || g->pc.command_sequence!=g->pc.command_ack ||
       !g->pc.texture_ref || v->texture!=g->pc.texture_ref ||
       v->active || v->command || v->sequence!=v->ack || v->pre_display ||
       v->window!=display_pair_window(p,1) || v->display!=t->display ||
       !rgba_view_same(v->current,t->footprint) || !rgba_view_same(v->target,t->footprint) ||
       !rgba_view_same(v->display_bounds,t->display_bounds) ||
       !rgba_view_contains(t->display_bounds,t->footprint) ||
       v->current_alpha!=1 || !rgba_view_native_alpha(v,1))return 0;
    char *w=v->window;struct ctx *c=p->probe.engine;
    if(!c->rgn || !c->bbox || c->shape_off!=0x170 || !*(void **)(w+c->shape_off) ||
       !rgba_view_same(c->bbox(*(void **)(w+c->shape_off)),t->footprint))return 0;
    return !*(void **)(w+0x428) && !*(void **)(w+0x488) &&
        !*(void **)(w+0x878) && !*(void **)(w+0x880) && !*(void **)(w+0x8b0);
}
static void display_transition_before(struct display_transition *t,struct display_pair *p,
                                      struct display_probe_step s,void *begin,void *end) {
    if(!display_transition_valid(t) || t->sink->source.pair!=p)return;
    // Only this new wrapper controls this sink; default between entries is OFF.
    __atomic_store_n(&t->sink->enabled,0,__ATOMIC_RELEASE);
    if(!__atomic_load_n(&t->damage.enabled,__ATOMIC_ACQUIRE) ||
       !display_transition_configured(t) || !display_pair_live(p) ||
       s.kind || s.state || s.active || !s.sampled ||
       __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)!=1 ||
       !display_transition_owned(t,p))return;
    char *scheduler=*(char **)((char *)p->session+0x138);
    if(scheduler!=t->scheduler || (*(u32 *)(scheduler+0x148)&128) ||
       *(int *)(scheduler+0xb0)>0)return;
    void *display=display_transition_selected(t,begin,end);if(!display)return;
    if(!t->damage.region) {
        // Allocate on this positively admitted native MAIN turn. Never run a
        // CF allocator on an arbitrary debugger-stopped thread. This one region
        // has the permanent control-map lifetime, including OFF/quarantine.
        if(t->damage.phase || t->damage.epoch || t->damage.entry_word)return;
        t->damage.phase=DISPLAY_DAMAGE_PREPARING;
        struct ctx *c=p->probe.engine;
        t->damage.region=c->rgn(t->footprint); // Save custody before any further call.
        if(!t->damage.region || !rgba_view_same(c->bbox(t->damage.region),t->footprint)) {
            t->damage.phase=DISPLAY_DAMAGE_PREPARE_FAILED;
            t->damage.reason=DISPLAY_DAMAGE_INVALID;t->damage.refused++;return;
        }
        t->damage.phase=DISPLAY_DAMAGE_IDLE;
    }
    u64 word=display_damage_begin(&t->damage,p->active_epoch,1);if(!word)return;
    t->entry_display=(u64)display;t->frame_epoch=0;t->frame_word=0;
    p->active_revision=word>>1;t->sink->revision=word>>1;
    __atomic_store_n(&t->sink->enabled,(u32)(word&1),__ATOMIC_RELEASE);
}
static void display_transition_observe(struct display_transition *t,struct display_pair *p,
                                       const struct display_pair_record *r,char *redraw) {
    if(!display_transition_ready(t) || t->sink->source.pair!=p ||
       t->damage.phase!=DISPLAY_DAMAGE_ACTIVE || t->damage.epoch!=p->active_epoch ||
       !t->damage.entry_word || r->reason || !redraw || r->redraw!=(u64)redraw ||
       r->display!=t->entry_display || r->epoch!=t->damage.epoch ||
       r->revision!=(t->damage.entry_word>>1) ||
       !display_transition_display(t,(void *)r->display))return;
    // Exact current R was recovered/validated by the synchronous Pair callback.
    // It owns this borrowed clip through this call. No R/clip pointer is saved.
    void *clip=*(void **)(redraw+0x58);
    int covered=0;
    if(clip) {
        t->damage.phase=DISPLAY_DAMAGE_OBSERVING;
        covered=t->contains(clip,t->damage.region)&1;
        t->damage.phase=DISPLAY_DAMAGE_ACTIVE;
    }
    if(covered)t->covered_frames++;else t->uncovered_frames++;
    u32 expected=(t->damage.entry_word&1)?1:3;
    if(covered && r->found_mask==expected) {
        t->frame_epoch=r->epoch;t->frame_word=t->damage.entry_word;
    }
    struct display_pair_record proof;
    for(unsigned i=0;i<sizeof(proof);i++)
        ((volatile unsigned char *)&proof)[i]=((const unsigned char *)r)[i];
    proof.event=DISPLAY_PAIR_DAMAGE;proof.native_result=covered;
    display_pair_publish(p,&proof);
}
static void display_transition_after(struct display_transition *t,struct display_pair *p,int result) {
    if(!display_transition_valid(t) || t->sink->source.pair!=p)return;
    __atomic_store_n(&t->sink->enabled,0,__ATOMIC_RELEASE);
    if(!display_transition_ready(t))return;
    if(t->sink->workspace.phase || t->sink->workspace.head ||
       t->sink->source.inflight || t->sink->source.entered!=t->sink->source.returned)return;
    u64 word=t->damage.entry_word;
    if(t->damage.epoch==p->active_epoch && word) {
        int matched=t->frame_epoch==p->active_epoch && t->frame_word==word;
        display_damage_end(&t->damage,p->active_epoch,word,result,matched);
        if(t->damage.phase==DISPLAY_DAMAGE_IDLE)t->entry_display=0;
    }
}
int anim_display_transition_framed(void *connection,u64 force,void *begin,void *end,
        struct display_transition *t,display_original_fn original,u64 native_fp) {
    if(!display_transition_valid(t))return original(connection,force,begin,end);
    struct display_pair *p=t->sink->source.pair;u64 caller=0;
    if(display_pair_live(p) && p->thread_self && p->stack_top && p->stack_size) {
        void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
        if(size>=4096 && size<=0x40000000ULL && top>=size)
            caller=display_pair_framed_caller(p,(u64)__builtin_frame_address(0),native_fp,top-size,top);
    }
    return display_pair_dispatch(connection,force,begin,end,p,original,caller,t,0);
}
void anim_display_transition_frame(void *mctx,void *display,void *third,struct display_transition *t) {
    if(!display_transition_valid(t))return;
    display_pair_frame_dispatch(mctx,display,third,t->sink->source.pair,
                                (u64)__builtin_frame_address(0),t,0);
}
unsigned anim_display_transition_size(void){return sizeof(struct display_transition);}
