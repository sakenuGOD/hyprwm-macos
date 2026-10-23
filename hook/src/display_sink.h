// Dormant pinned ordinary-source sink. Admission and paired A/B selection belong
// to the caller; this primitive does not establish either. Never pass capture R.
// The workspace must outlive native unwinding and MUST NOT be stack allocated.
// An interrupted call stays quarantined; there is intentionally no reset API.
// Surviving storage does NOT retain borrowed native objects/arenas. After unwind
// never traverse or destroy saved pointers: they are diagnostics only. Blocking
// the lease and restoring paired presentation still require the outer controller.
struct display_sink_api {
    int (*generate)(void *,void *);
    void *(*retain)(void *);
    void (*release)(void *);
    void (*free_layers)(void *); // Called only with a nonnull head.
    void (*release_enumerator)(void *);
};
struct display_sink {
    _Alignas(16) unsigned char redraw[0xc0];
    void *head;
    unsigned phase;
    int native_result;
};
enum { DISPLAY_SINK_IDLE, DISPLAY_SINK_RETAIN, DISPLAY_SINK_GENERATE,
       DISPLAY_SINK_LAYERS, DISPLAY_SINK_OPAQUE, DISPLAY_SINK_ENUMERATOR };
// Status is separate from the generator result: refusal means no original call
// happened. It is NOT permission to forward one role after a pair was selected.
enum { DISPLAY_SINK_REFUSED=-1, DISPLAY_SINK_COMPLETE=0 };
static void *display_sink_get(const void *r,unsigned offset) {
    return *(void *const *)((const unsigned char *)r+offset);
}
static void display_sink_put(void *r,unsigned offset,void *value) {
    *(void **)((unsigned char *)r+offset)=value;
}
static int display_sink_run_observed(struct display_sink *s,const struct display_sink_api *a,
                            const void *redraw,void *window,
                            void (*observe)(void *,void *,int),void *observation) {
    if(!s || !a || !redraw || !window ||
       ((unsigned long long)s&15) || ((unsigned long long)redraw&7) || s->phase || s->head ||
       !a->generate || !a->retain || !a->release || !a->free_layers ||
       !a->release_enumerator)return DISPLAY_SINK_REFUSED;
    unsigned long long base=(unsigned long long)s,input=(unsigned long long)redraw;
    if((input>=base && input-base<sizeof(*s)) ||
       (base>=input && base-input<0xb8))return DISPLAY_SINK_REFUSED;
    if(display_sink_get(redraw,0x80))return DISPLAY_SINK_REFUSED;
    // Native initializes only b8 bytes. Never read the eight adjacent bytes.
    for(unsigned i=0;i<0xb8;i++)s->redraw[i]=((const unsigned char *)redraw)[i];
    for(unsigned i=0xb8;i<0xc0;i++)s->redraw[i]=0;
    display_sink_put(s->redraw,0x68,0);
    display_sink_put(s->redraw,0x78,&s->head);
    display_sink_put(s->redraw,0x80,0);
    s->phase=DISPLAY_SINK_RETAIN;
    void *opaque=display_sink_get(s->redraw,0x60);
    if(opaque)a->retain(opaque);
    s->phase=DISPLAY_SINK_GENERATE;
    s->native_result=a->generate(s->redraw,window);
    // Synchronous scalar diagnostics only, while native output custody is live.
    // If observation throws, the persistent GENERATE phase stays quarantined.
    if(observe)observe(observation,s->head,s->native_result);
    // Clear custody before each destructor. If it throws, quarantine prevents
    // a second destructor or generator invocation with ambiguous ownership.
    s->phase=DISPLAY_SINK_LAYERS;
    void *head=s->head;s->head=0;if(head)a->free_layers(head);
    s->phase=DISPLAY_SINK_OPAQUE;
    opaque=display_sink_get(s->redraw,0x60);display_sink_put(s->redraw,0x60,0);
    if(opaque)a->release(opaque);
    s->phase=DISPLAY_SINK_ENUMERATOR;
    void *enumerator=display_sink_get(s->redraw,0x68);display_sink_put(s->redraw,0x68,0);
    if(enumerator)a->release_enumerator(enumerator);
    s->phase=DISPLAY_SINK_IDLE;
    return DISPLAY_SINK_COMPLETE;
}
static int display_sink_run(struct display_sink *s,const struct display_sink_api *a,
                            const void *redraw,void *window) {
    return display_sink_run_observed(s,a,redraw,window,0,0);
}
