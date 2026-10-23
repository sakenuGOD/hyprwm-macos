// OFF-default B-only native qualifier. A MUST remain unfenced throughout this
// experiment. Forwarding B on refusal is deliberately NOT a paired fallback.
// This capsule cannot select A for exclusion or establish exclusive presentation.
#define DISPLAY_SOURCE_SINK_MAGIC 0x314b5353574d5748ULL
struct display_source_sink {
    u64 magic;u32 size,version;
    struct display_source source;
    struct display_sink_api api;
    struct display_sink workspace;
    u32 enabled,profile_verified,a_unfenced,pad;
    u64 revision,attempted,completed,refused;
};
static int display_source_sink_valid(struct display_source_sink *q) {
    return q && q->magic==DISPLAY_SOURCE_SINK_MAGIC && q->size==sizeof(*q) &&
        q->version==1 && !q->pad && display_source_valid(&q->source);
}
static int display_source_sink_scope(struct display_source_sink *q,
                    struct display_source *s,struct display_source_step step,void *window) {
    if(!display_source_sink_valid(q) || s!=&q->source ||
       !__atomic_load_n(&q->enabled,__ATOMIC_ACQUIRE) || q->profile_verified!=1 ||
       q->a_unfenced!=1 || !step.epoch || step.role!=1 || !step.head ||
       !display_pair_live(s->pair))return 0;
    struct display_pair *p=s->pair;
    if(p->active_epoch!=step.epoch || p->active_revision!=step.revision ||
       q->revision!=step.revision || p->active_kind || p->active_state ||
       __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)!=1 ||
       p->identity[1].creator || !p->identity[0].creator ||
       window!=display_pair_window(p,1))return 0;
    // Restrict the first native experiment to an ordinary local type5 carrier.
    // No cached U/present traversal or manual native state writeback is allowed.
    char *w=window;
    return !*(void **)(w+0x428) && !*(void **)(w+0x488) &&
        !*(void **)(w+0x878) && !*(void **)(w+0x880) && !*(void **)(w+0x8b0);
}
struct display_source_sink_observation {
    struct display_pair *pair;
    struct display_source_step step;
    void *redraw;
};
static void display_source_sink_graph(void *data,void *head,int result) {
    struct display_source_sink_observation *o=data;struct display_pair *p=o->pair;
    if(!display_pair_live(p) || p->active_epoch!=o->step.epoch ||
       p->active_revision!=o->step.revision ||
       __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)!=1)return;
    struct display_pair_record r;display_pair_zero(&r,sizeof(r));
    r.event=DISPLAY_PAIR_PRIVATE_B;r.epoch=o->step.epoch;r.revision=o->step.revision;
    r.kind=p->active_kind;r.state=p->active_state;r.native_result=result;
    r.redraw=(u64)o->redraw;r.head=(u64)head;
    r.session=(u64)p->session;r.channel=(u64)p->channel;
    struct ctx *c=p->probe.engine;r.tick=c->mabs?c->mabs():0;
    r.reason=display_pair_graph(p,head,&r);
    if(r.reason){r.found_mask=0;display_pair_zero(r.source,sizeof(r.source));}
    display_pair_publish(p,&r);
}
static int display_source_call(void *redraw,void *window,display_generate_fn original,
                struct display_source *s,struct display_source_step step,
                struct display_source_sink *q) {
    if(!q || !display_source_sink_scope(q,s,step,window))return original(redraw,window);
    // The signed independent clone is an immutable island argument. Never call
    // a generator pointer supplied through mutable capsule storage.
    struct display_sink_api api=q->api;api.generate=original;
    struct display_source_sink_observation observation={s->pair,step,redraw};
    q->attempted++;
    if(display_sink_run_observed(&q->workspace,&api,redraw,window,
                               display_source_sink_graph,&observation)==DISPLAY_SINK_COMPLETE) {
        q->completed++;return 0; // Private opacity must not occlude lower windows.
    }
    q->refused++;
    return original(redraw,window); // Allowed only while native A is unfenced.
}
int anim_display_source_sink_framed(void *redraw,void *window,
                struct display_source_sink *q,display_generate_fn original,u64 generator_fp) {
    if(!display_source_sink_valid(q))return original(redraw,window);
    return display_source_dispatch(redraw,window,&q->source,original,0,
                                   (u64)__builtin_frame_address(0),generator_fp,q,0);
}
unsigned anim_display_source_sink_size(void){return sizeof(struct display_source_sink);}
