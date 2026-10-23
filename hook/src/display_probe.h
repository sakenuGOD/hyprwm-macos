// Dormant, passive normal-display entry qualifier. The native original is an
// immutable sixth argument supplied by the OWN executable island, independent
// of mutable probe validity/enabled state. No window/layer/geometry changes.
#define DISPLAY_PROBE_MAGIC 0x31425044574d5748ULL
typedef int (*display_original_fn)(void *,u64,void *,void *);
struct display_probe {
    u64 magic;u32 size,version;
    struct ctx *engine;
    int (*is_main)(void);
    u64 callers[3];
    u32 enabled,pad;
    u64 entered,returned,inflight,reentrant,nonmain,unavailable;
    u64 kinds[4],states[33],kind_zero[4];
    u64 last_caller,last_displays;
    u32 last_state;int last_result;
};
static int display_probe_valid(struct display_probe *p) {
    return p && p->magic==DISPLAY_PROBE_MAGIC && p->size==sizeof(*p) && p->version==1;
}
static unsigned display_probe_kind(struct display_probe *p,u64 caller) {
    for(unsigned i=0;i<3;i++)if(caller==p->callers[i])return i;
    return 3;
}
struct display_probe_step { u64 active;unsigned kind,state,tracked,sampled; };
static void display_probe_sample(struct display_probe *p,struct display_probe_step *s) {
    if(!__atomic_load_n(&p->enabled,__ATOMIC_ACQUIRE))return;
    if(!p->is_main || p->is_main()!=1) {__atomic_fetch_add(&p->nonmain,1,__ATOMIC_RELAXED);return;}
    if(s->active) {__atomic_fetch_add(&p->reentrant,1,__ATOMIC_RELAXED);return;}
    struct ctx *c=p->engine;
    if(!c || c->dead || c->in_cb || !c->msg || !c->cls || !c->sel ||
       !c->ch || c->ch->h.magic!=CH_MAGIC || c->ch->h.stop) {
        __atomic_fetch_add(&p->unavailable,1,__ATOMIC_RELAXED);return;
    }
    // This exact native getter reads transaction state without beginning one.
    void *cls=c->cls("CATransaction"),*sel=c->sel("currentState");
    if(!cls || !sel){__atomic_fetch_add(&p->unavailable,1,__ATOMIC_RELAXED);return;}
    u32 state=((u32 (*)(void *,void *))c->msg)(cls,sel);
    __atomic_store_n(&p->last_state,state,__ATOMIC_RELAXED);
    __atomic_fetch_add(&p->states[state<32?state:32],1,__ATOMIC_RELAXED);
    if(!state)__atomic_fetch_add(&p->kind_zero[s->kind],1,__ATOMIC_RELAXED);
    s->sampled=1;s->state=state;
}
static struct display_probe_step display_probe_begin(struct display_probe *p,u64 caller,
                                                     void *begin,void *end) {
    struct display_probe_step s={0};s.tracked=display_probe_valid(p);
    if(s.tracked) {
        s.kind=display_probe_kind(p,caller);
        __atomic_fetch_add(&p->entered,1,__ATOMIC_RELAXED);
        __atomic_fetch_add(&p->kinds[s.kind],1,__ATOMIC_RELAXED);
        s.active=__atomic_fetch_add(&p->inflight,1,__ATOMIC_ACQ_REL);
        __atomic_store_n(&p->last_caller,caller,__ATOMIC_RELAXED);
        u64 a=(u64)begin,b=(u64)end;
        if(b>=a && !((b-a)&15) && b-a<=16384)
            __atomic_store_n(&p->last_displays,(b-a)/16,__ATOMIC_RELAXED);
        display_probe_sample(p,&s);
    }
    return s;
}
// New C++ entries acquire their local token before the first native getter.
// Legacy exports keep their original accounting when no ledger is supplied.
static struct display_probe_step display_probe_begin_owned(struct display_probe *p,u64 caller,
        void *begin,void *end,struct du_local *local) {
    if(!local)return display_probe_begin(p,caller,begin,end);
    struct display_probe_step s={0};s.tracked=display_probe_valid(p);
    if(s.tracked) {
        s.kind=display_probe_kind(p,caller);
        if(!du_legacy_enter(local,DU_PROBE,&p->entered,&p->returned,&p->inflight,&s.active)) {
            s.tracked=0;return s;
        }
        __atomic_fetch_add(&p->kinds[s.kind],1,__ATOMIC_RELAXED);
        __atomic_store_n(&p->last_caller,caller,__ATOMIC_RELAXED);
        u64 a=(u64)begin,b=(u64)end;
        if(b>=a && !((b-a)&15) && b-a<=16384)
            __atomic_store_n(&p->last_displays,(b-a)/16,__ATOMIC_RELAXED);
        display_probe_sample(p,&s);
    }
    return s;
}
static void display_probe_end(struct display_probe *p,struct display_probe_step s,int result) {
    if(s.tracked) {
        __atomic_store_n(&p->last_result,result,__ATOMIC_RELAXED);
        __atomic_fetch_add(&p->returned,1,__ATOMIC_RELAXED);
        __atomic_fetch_sub(&p->inflight,1,__ATOMIC_RELEASE);
    }
}
int anim_display_probe_entry(void *connection,u64 force,void *begin,void *end,
                             struct display_probe *p,display_original_fn original) {
    u64 caller=pc_address(__builtin_extract_return_addr(__builtin_return_address(0)));
    struct display_probe_step s=display_probe_begin(p,caller,begin,end);
    // Preserve all four native arguments, the return value and exactly one
    // invocation even for disabled/invalid/recursive/non-main qualification.
    int result=original(connection,force,begin,end);
    display_probe_end(p,s,result);
    return result;
}
unsigned anim_display_probe_size(void){return sizeof(struct display_probe);}
