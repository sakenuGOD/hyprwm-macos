// Dormant generator observer. The immutable original is supplied separately by
// the executable island. ALL callers retain their native source output/result;
// only the pinned normal callsite may publish a diagnostic epoch record.
#define DISPLAY_SOURCE_MAGIC 0x31435253574d5748ULL
typedef int (*display_generate_fn)(void *,void *);
struct display_source {
    u64 magic;u32 size,version;
    struct display_pair *pair;
    u64 normal_return;
    u32 enabled,pad;
    u64 entered,returned,inflight,normal,selected,unavailable;
};
struct display_source_step { u64 epoch,revision;void **head;unsigned role; };
struct display_source_sink;
static int display_source_call(void *,void *,display_generate_fn,struct display_source *,
                               struct display_source_step,struct display_source_sink *);
static int display_source_valid(struct display_source *s) {
    return s && s->magic==DISPLAY_SOURCE_MAGIC && s->size==sizeof(*s) &&
        s->version==1 && !s->pad;
}
// This is BEFORE composite. Do not use pc_normal_frame's future composite stack
// here. The exact native callsite, current UpdateDisplays FP/R and outer entry
// epoch establish the scope; cached CWC/RenderUpdate pointers are never followed.
static struct display_source_step display_source_before(struct display_source *s,
              u64 caller,u64 native_fp,u64 bottom,u64 top,void *redraw,void *window) {
    struct display_source_step step={0};
    if(caller!=s->normal_return || !display_pair_live(s->pair))return step;
    struct display_pair *p=s->pair;
    if(!p->active_epoch || __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)!=1 ||
       (native_fp&15) || native_fp<0xb88 ||
       !display_pair_range(native_fp,16,bottom,top) ||
       !display_pair_range(native_fp-0xb40,0xb8,bottom,top) ||
       !display_pair_range(native_fp-0xb88,8,bottom,top) ||
       (u64)redraw!=native_fp-0xb40)return step;
    u64 ret=pc_address((void *)((u64 *)native_fp)[1]);
    if(ret!=p->update_return[0] && ret!=p->update_return[1])return step;
    for(unsigned i=0;i<2;i++)if(p->identity[i].wid &&
          window==(void *)p->identity[i].window && window==display_pair_window(p,i)) {
        step.epoch=p->active_epoch;step.revision=p->active_revision;step.role=i;
        step.head=(void **)(native_fp-0xb88);
        return step;
    }
    return step;
}
// The head cell belongs to this still-live UpdateDisplays invocation. Its range
// was checked before the synchronous original call. Inspect only after that
// call returned and the enclosing entry still owns the same epoch/revision.
// This is construction NOW, distinct from the later composite FRAME event and
// from texture readiness or physical presentation. No borrowed pointer escapes
// the synchronous call except as a scalar diagnostic in the ring.
static void display_source_graph(struct display_pair *p,struct display_source_step step,
                                  void *redraw,int result) {
    if(!step.epoch || !step.head || step.role>1 || !display_pair_live(p) ||
       p->active_epoch!=step.epoch || p->active_revision!=step.revision ||
       __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)!=1)return;
    struct display_pair_record r;display_pair_zero(&r,sizeof(r));
    r.event=step.role?DISPLAY_PAIR_GENERATED_B:DISPLAY_PAIR_GENERATED_A;
    r.epoch=step.epoch;r.revision=step.revision;r.kind=p->active_kind;r.state=p->active_state;
    r.redraw=(u64)redraw;r.head=(u64)*step.head;r.native_result=result;
    r.session=(u64)p->session;r.channel=(u64)p->channel;
    struct ctx *c=p->probe.engine;r.tick=c->mabs?c->mabs():0;
    r.reason=display_pair_graph(p,*step.head,&r);
    if(r.reason){r.found_mask=0;display_pair_zero(r.source,sizeof(r.source));}
    display_pair_publish(p,&r);
}
// The framed island starts AFTER the complete native generator prolog. Its FP
// is the C frame's direct parent; native PACIBSP signed LR with entry SP=FP+16.
// Compare against the expected signed return, rather than stripping an AUT
// failure's poison bits. Unknown callers still forward without interpretation.
static u64 display_source_framed_parent(struct display_source *s,u64 fp,u64 generator_fp,
                                        u64 bottom,u64 top) {
    if((fp&15) || (generator_fp&15) || generator_fp<=fp ||
       !display_pair_range(fp,16,bottom,top) ||
       !display_pair_range(generator_fp,16,bottom,top) ||
       *(u64 *)fp!=generator_fp)return 0;
    u64 expected=(u64)__builtin_ptrauth_sign_unauthenticated(
                         (void *)s->normal_return,1,generator_fp+16);
    return ((u64 *)generator_fp)[1]==expected ? *(u64 *)generator_fp : 0;
}
static __attribute__((always_inline)) inline int display_source_dispatch(
              void *redraw,void *window,struct display_source *s,display_generate_fn original,
              u64 caller,u64 fp,u64 generator_fp,struct display_source_sink *sink,
              struct du_local *local) {
    if(!display_source_valid(s))return original(redraw,window);
    u64 active;
    if(local) {
        if(!du_legacy_enter(local,DU_SOURCE_ROLE,&s->entered,&s->returned,&s->inflight,&active))
            return original(redraw,window);
    } else {
        active=__atomic_fetch_add(&s->inflight,1,__ATOMIC_ACQ_REL);
        __atomic_fetch_add(&s->entered,1,__ATOMIC_RELAXED);
    }
    if(local && du_forward_only(local->bridge)) {
        local->stage=DU_STAGE_ORIGINAL;int result=original(redraw,window);
        local->stage=DU_STAGE_ENTRY;du_legacy_close(local,DU_SOURCE_ROLE);return result;
    }
    struct display_source_step step={0};
    if(caller && caller==s->normal_return)__atomic_fetch_add(&s->normal,1,__ATOMIC_RELAXED);
    struct display_pair *p=s->pair;
    if(!active && __atomic_load_n(&s->enabled,__ATOMIC_ACQUIRE) &&
       (generator_fp || caller==s->normal_return) && display_pair_live(p)) {
        if(p->thread_self && p->stack_top && p->stack_size) {
            void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
            if(size>=4096 && size<=0x40000000ULL && top>=size &&
               !(fp&15) && display_pair_range(fp,16,top-size,top)) {
                u64 parent;
                if(generator_fp) {
                    parent=display_source_framed_parent(s,fp,generator_fp,top-size,top);
                    if(parent) {
                        caller=s->normal_return;
                        __atomic_fetch_add(&s->normal,1,__ATOMIC_RELAXED);
                    }
                } else parent=*(u64 *)fp;
                if(parent)step=display_source_before(s,caller,parent,top-size,top,redraw,window);
            }
        }
        if(!step.epoch)__atomic_fetch_add(&s->unavailable,1,__ATOMIC_RELAXED);
    }
    // A private sink includes helpers before/after the immutable generator.
    // A throw crossing this composite operation has unknown origin.
    if(local)local->stage=sink?DU_STAGE_ENTRY:DU_STAGE_ORIGINAL;
    int result=display_source_call(redraw,window,original,s,step,sink);
    if(local)local->stage=DU_STAGE_ENTRY;
    if(local && du_forward_only(local->bridge)) {
        du_legacy_close(local,DU_SOURCE_ROLE);return result;
    }
    if(step.epoch && display_pair_live(p) && p->active_epoch==step.epoch &&
       p->active_revision==step.revision &&
       __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)==1) {
        struct display_pair_record r;display_pair_zero(&r,sizeof(r));
        r.event=DISPLAY_PAIR_GENERATE;r.epoch=step.epoch;r.revision=step.revision;
        r.kind=p->active_kind;r.state=p->active_state;r.redraw=(u64)redraw;
        r.session=(u64)p->session;r.channel=(u64)p->channel;r.native_result=result;
        // This event proves an original generator CALL, not a constructed S or
        // a selected texture. found_mask stays zero; FRAME events own that field.
        r.source[step.role].window=(u64)window;r.source[step.role].wid=p->identity[step.role].wid;
        struct ctx *c=p->probe.engine;r.tick=c->mabs?c->mabs():0;
        display_pair_publish(p,&r);__atomic_fetch_add(&s->selected,1,__ATOMIC_RELAXED);
        display_source_graph(p,step,redraw,result);
    }
    if(local)du_legacy_close(local,DU_SOURCE_ROLE);
    else {
        __atomic_fetch_add(&s->returned,1,__ATOMIC_RELAXED);
        __atomic_fetch_sub(&s->inflight,1,__ATOMIC_RELEASE);
    }
    return result;
}
int anim_display_source_entry(void *redraw,void *window,struct display_source *s,
                              display_generate_fn original) {
    return display_source_dispatch(redraw,window,s,original,
        pc_address(__builtin_extract_return_addr(__builtin_return_address(0))),
        (u64)__builtin_frame_address(0),0,0,0);
}
int anim_display_source_framed(void *redraw,void *window,struct display_source *s,
                              display_generate_fn original,u64 generator_fp) {
    // No frame parsing occurs for disabled, nonmain, recursive or stale epochs.
    return display_source_dispatch(redraw,window,s,original,0,
                                   (u64)__builtin_frame_address(0),generator_fp,0,0);
}
unsigned anim_display_source_size(void){return sizeof(struct display_source);}
