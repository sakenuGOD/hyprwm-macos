// Passive current-normal-source observer. OFF by default, separate versioned
// storage: no channel, capture or presenter ABI change. This observes source
// construction, not prepared texture selection, drawing or physical presentation.
#define DISPLAY_PAIR_MAGIC 0x31524941504d5748ULL
#define DISPLAY_PAIR_RECORDS 64
struct display_pair_identity {
    u64 window,creator,pid_version,local_context;
    u32 wid,client_id;
};
struct display_pair_source {
    u64 window,cwc,source,descriptor,update;
    rect bounds;
    double matrix[16];
    float alpha,divisor;
    u32 wid,context,flags,pad;
};
struct display_pair_record {
    u64 stamp,epoch,revision,tick,session,channel,display,redraw,head;
    u32 event,kind,state,reason,nodes,found_mask;
    int native_result;u32 pad;
    struct display_pair_source source[2];
};
struct display_pair {
    u64 magic;u32 size,version;
    struct pc_node node;
    struct display_probe probe;
    void *(*thread_self)(void);
    void *(*stack_top)(void *);
    u64 (*stack_size)(void *);
    void *session_control;
    struct ch *channel;
    void *session;
    u64 cohort_pc[5],update_return[2];
    struct display_pair_identity identity[2];
    // Installer verifies the pinned UpdateDisplays prolog/layout before enable.
    // Configuration/identities stay immutable until disabled AND drained on the
    // stopped main thread outside entry/callback. Only revision is entry-latched.
    u32 enabled,layout_verified;
    u64 revision,epochs,active_epoch,active_revision;
    void *active_begin,*active_end;
    u32 active_kind,active_state;
    u64 callbacks,qualified,unavailable,published;
    struct display_pair_record records[DISPLAY_PAIR_RECORDS];
};
enum { DISPLAY_PAIR_FRAME=1, DISPLAY_PAIR_RETURN=2, DISPLAY_PAIR_GENERATE=3,
       DISPLAY_PAIR_GENERATED_A=4, DISPLAY_PAIR_GENERATED_B=5,
       DISPLAY_PAIR_PRIVATE_B=6,DISPLAY_PAIR_DAMAGE=7,DISPLAY_PAIR_VISIBILITY=8 };
enum { DISPLAY_PAIR_OK, DISPLAY_PAIR_COHORT, DISPLAY_PAIR_STACK,
       DISPLAY_PAIR_NATIVE, DISPLAY_PAIR_IDENTITY, DISPLAY_PAIR_GRAPH,
       DISPLAY_PAIR_SOURCE };
struct display_transition;
struct display_visibility;
static void display_visibility_observe(struct display_visibility *,struct display_pair *,
                                       const struct display_pair_record *,char *);
static void display_transition_before(struct display_transition *,struct display_pair *,
                                      struct display_probe_step,void *,void *);
static void display_transition_after(struct display_transition *,struct display_pair *,int);
static void display_transition_observe(struct display_transition *,struct display_pair *,
                                       const struct display_pair_record *,char *);
static int display_pair_valid(struct display_pair *p) {
    return p && p->magic==DISPLAY_PAIR_MAGIC && p->size==sizeof(*p) &&
        p->version==1 && display_probe_valid(&p->probe);
}
static int display_pair_live(struct display_pair *p) {
    if(!display_pair_valid(p) || !__atomic_load_n(&p->enabled,__ATOMIC_ACQUIRE) ||
       p->layout_verified!=1 || !p->probe.is_main || p->probe.is_main()!=1)return 0;
    struct ctx *c=p->probe.engine;
    if(!c || c->dead || c->in_cb || !c->by_id || !c->ch || c->ch!=p->channel ||
       c->session!=p->session || !p->session || !p->session_control ||
       c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=sizeof(struct ch) || c->ch->h.stop)return 0;
    char *control=*(char **)p->session_control;
    return control && *(void **)(control+0x20)==p->session;
}
static void display_pair_zero(void *object,unsigned size) {
    volatile unsigned char *bytes=object;
    for(unsigned i=0;i<size;i++)bytes[i]=0;
}
// Only plain scalar diagnostics are published. Addresses in records carry no
// ownership and MUST NOT be used by a reader to traverse native objects later.
static void display_pair_publish(struct display_pair *p,struct display_pair_record *r) {
    u64 n=p->published+1;if(!n || n>0x7fffffffffffffffULL)return;
    struct display_pair_record *out=&p->records[(n-1)%DISPLAY_PAIR_RECORDS];
    __atomic_store_n(&out->stamp,2*n-1,__ATOMIC_SEQ_CST);
    for(unsigned i=8;i<sizeof(*r);i++)
        ((volatile unsigned char *)out)[i]=((const unsigned char *)r)[i];
    __atomic_store_n(&out->stamp,2*n,__ATOMIC_RELEASE);
    __atomic_store_n(&p->published,n,__ATOMIC_RELEASE);
}
static int display_pair_range(u64 at,u64 length,u64 bottom,u64 top) {
    return at>=bottom && at<=top && length<=top-at;
}
// Pinned stack recovery is intentionally restricted to the existing REAL Metal
// callback. A synthetic capture generator has no authority to supply this R.
static unsigned display_pair_redraw(struct display_pair *p,u64 fp,u64 bottom,u64 top,
                                    char **redraw,void ***head) {
    unsigned phase=0;
    for(unsigned i=0;i<40;i++) {
        if((fp&15) || !display_pair_range(fp,16,bottom,top))return DISPLAY_PAIR_STACK;
        u64 *frame=(u64 *)fp,next=frame[0],pc=pc_address((void *)frame[1]);
        if(phase==0 && pc==p->cohort_pc[0])phase=1;
        else if(phase==1 && (pc==p->cohort_pc[1] || pc==p->cohort_pc[2]))phase=2;
        else if(phase==2 && pc==p->cohort_pc[3])phase=3;
        else if(phase==3 && pc==p->cohort_pc[4]) {
            // next is UpdateDisplays FP, whose prolog/layout is pinned by HOST.
            if((next&15) || next<=fp || next<0xb88 ||
               !display_pair_range(next,16,bottom,top) ||
               !display_pair_range(next-0xb40,0xb8,bottom,top) ||
               !display_pair_range(next-0xb88,8,bottom,top))return DISPLAY_PAIR_STACK;
            u64 ret=pc_address((void *)((u64 *)next)[1]);
            if(ret!=p->update_return[0] && ret!=p->update_return[1])return DISPLAY_PAIR_COHORT;
            *redraw=(char *)(next-0xb40);*head=(void **)(next-0xb88);
            return DISPLAY_PAIR_OK;
        }
        if(next<=fp)return DISPLAY_PAIR_STACK;fp=next;
    }
    return DISPLAY_PAIR_COHORT;
}
static char *display_pair_window(struct display_pair *p,unsigned index) {
    struct display_pair_identity *id=&p->identity[index];
    if(!id->wid || !id->window)return 0;
    char *w=p->probe.engine->by_id(id->wid);
    if(!w || (u64)w!=id->window || *(u32 *)w!=id->wid || *(u32 *)(w+4)!=5 ||
       *(u64 *)(w+0x30)!=id->creator)return 0;
    if(id->creator && *(u64 *)((char *)id->creator+0x268)!=id->pid_version)return 0;
    if(!id->creator) {
        char *cwc=*(char **)(w+0x18);
        if(id->pid_version || !id->local_context || !id->client_id || !cwc ||
           *(u64 *)(cwc+0x58)!=id->local_context || *(u32 *)(cwc+0x50)!=id->client_id)return 0;
    }
    return w;
}
static int display_pair_source(struct display_pair_record *r,unsigned index,char *s,char *w) {
    char *q=*(char **)(s+0x48),*cwc=*(char **)(w+0x18);
    if(!q || !cwc || *(char **)q!=w || *(void **)(q+8) ||
       !*(void **)(q+0x10) || *(void **)(s+0x28)!=*(void **)(q+0x10) ||
       *(void **)(s+0x30)!=*(void **)(q+0x10) ||
       *(u32 *)(q+0x28)!=*(u32 *)(cwc+0x40))return 0;
    struct display_pair_source *v=&r->source[index];
    v->window=(u64)w;v->cwc=(u64)cwc;v->source=(u64)s;v->descriptor=(u64)q;
    v->update=*(u64 *)(q+0x10);v->wid=*(u32 *)w;v->context=*(u32 *)(q+0x28);
    v->bounds=*(rect *)(s+0xc8);v->alpha=*(float *)(s+0x188);v->divisor=*(float *)(s+0x18c);
    v->flags=*(u32 *)(s+0x218);__builtin_memcpy(v->matrix,s+0xf0,sizeof(v->matrix));
    if(!rgba_view_rect(v->bounds) || !__builtin_isfinite(v->alpha) ||
       !__builtin_isfinite(v->divisor))return 0;
    for(unsigned i=0;i<16;i++)if(!__builtin_isfinite(v->matrix[i]))return 0;
    return 1;
}
static unsigned display_pair_graph(struct display_pair *p,void *head,struct display_pair_record *r) {
    char *windows[2]={0};
    for(unsigned i=0;i<2;i++)if(p->identity[i].wid) {
        windows[i]=display_pair_window(p,i);if(!windows[i])return DISPLAY_PAIR_IDENTITY;
    }
    if(p->identity[0].wid && p->identity[0].wid==p->identity[1].wid)return DISPLAY_PAIR_IDENTITY;
    char *pending[64],*seen[512];unsigned count=0,n=0;if(head)pending[n++]=head;
    while(n) {
        char *s=pending[--n];
        if((u64)s&7)return DISPLAY_PAIR_GRAPH;
        for(unsigned i=0;i<count;i++)if(seen[i]==s)return DISPLAY_PAIR_GRAPH;
        if(count==512)return DISPLAY_PAIR_GRAPH;seen[count++]=s;
        char *next=*(char **)s,*child=*(char **)(s+0x10);
        if(next){if(n==64)return DISPLAY_PAIR_GRAPH;pending[n++]=next;}
        if(child){if(n==64)return DISPLAY_PAIR_GRAPH;pending[n++]=child;}
        for(unsigned i=0;i<2;i++)if(windows[i] && *(u32 *)(s+0x268)==p->identity[i].wid) {
            if((r->found_mask&(1u<<i)) || *(u32 *)(s+0x180)!=10 ||
               !display_pair_source(r,i,s,windows[i]))return DISPLAY_PAIR_SOURCE;
            r->found_mask|=1u<<i;
        }
    }
    r->nodes=count;return DISPLAY_PAIR_OK;
}
static __attribute__((always_inline)) inline void display_pair_frame_dispatch(
        void *mctx,void *display,void *third,struct display_pair *p,u64 fp,
        struct display_transition *transition,struct display_visibility *visibility) {
    if(!display_pair_live(p) || !p->active_epoch ||
       __atomic_load_n(&p->probe.inflight,__ATOMIC_ACQUIRE)!=1)return;
    p->callbacks++;
    struct display_pair_record r;display_pair_zero(&r,sizeof(r));
    char *redraw=0;void **head=0;
    r.event=DISPLAY_PAIR_FRAME;r.epoch=p->active_epoch;
    r.revision=p->active_revision;r.kind=p->active_kind;r.state=p->active_state;
    r.session=(u64)p->session;r.channel=(u64)p->channel;
    struct ctx *c=p->probe.engine;r.tick=c->mabs?c->mabs():0;
    r.reason=DISPLAY_PAIR_COHORT;
    if(third || !mctx || !p->thread_self || !p->stack_top || !p->stack_size)goto done;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size){r.reason=DISPLAY_PAIR_STACK;goto done;}
    u64 bottom=top-size;
    r.reason=display_pair_redraw(p,fp,bottom,top,&redraw,&head);
    if(r.reason)goto done;
    if(!display_pair_range((u64)display,16,bottom,top)) {r.reason=DISPLAY_PAIR_STACK;goto done;}
    void *object=*(void **)display;
    u64 a=(u64)p->active_begin,b=(u64)p->active_end;unsigned included=0;
    if(a && b>a && !((b-a)&15) && b-a<=16384)
        for(u64 at=a;at<b;at+=16)if(*(void **)at==object && object)included=1;
    char *compositor=*(char **)redraw;
    if(!included || !compositor || *(void **)(compositor+0x10)!=mctx) {
        r.reason=DISPLAY_PAIR_NATIVE;goto done;
    }
    r.display=(u64)object;r.redraw=(u64)redraw;r.head=(u64)*head;
    r.reason=display_pair_graph(p,*head,&r);
done:
    // Never publish a partial graph as an absence/presence proof.
    if(r.reason){r.found_mask=0;display_pair_zero(r.source,sizeof(r.source));p->unavailable++;}
    else p->qualified++;
    display_pair_publish(p,&r);
    if(transition)display_transition_observe(transition,p,&r,redraw);
    if(visibility)display_visibility_observe(visibility,p,&r,redraw);
}
void anim_display_pair_frame(void *mctx,void *display,void *third,struct display_pair *p) {
    display_pair_frame_dispatch(mctx,display,third,p,(u64)__builtin_frame_address(0),0,0);
}
static u64 display_pair_framed_caller(struct display_pair *p,u64 fp,u64 native_fp,
                                      u64 bottom,u64 top) {
    if((fp&15) || (native_fp&15) || native_fp<=fp ||
       !display_pair_range(fp,16,bottom,top) ||
       !display_pair_range(native_fp,16,bottom,top) || *(u64 *)fp!=native_fp)return 0;
    for(unsigned i=0;i<3;i++) {
        u64 caller=p->probe.callers[i];
        if(caller && ((u64 *)native_fp)[1]==(u64)__builtin_ptrauth_sign_unauthenticated(
                                                    (void *)caller,1,native_fp+16))return caller;
    }
    return 0;
}
static __attribute__((always_inline)) inline int display_pair_dispatch(
              void *connection,u64 force,void *begin,void *end,
              struct display_pair *p,display_original_fn original,u64 caller,
              struct display_transition *transition,struct du_local *local) {
    if(!display_pair_valid(p))return original(connection,force,begin,end);
    if(local && du_forward_only(local->bridge)) {
        u64 prior;int tracked=display_probe_valid(&p->probe) &&
            du_legacy_enter(local,DU_PROBE,&p->probe.entered,&p->probe.returned,&p->probe.inflight,&prior);
        if(tracked)__atomic_fetch_add(&p->probe.kinds[3],1,__ATOMIC_RELAXED);
        local->stage=DU_STAGE_ORIGINAL;
        int result=original(connection,force,begin,end);local->stage=DU_STAGE_ENTRY;
        if(tracked) {
            __atomic_store_n(&p->probe.last_result,result,__ATOMIC_RELAXED);
            du_legacy_close(local,DU_PROBE);
        }
        return result;
    }
    struct display_probe_step s=display_probe_begin_owned(&p->probe,caller,begin,end,local);
    int active=caller && !s.active && s.sampled && display_pair_live(p);
    if(active) {
        p->active_epoch=++p->epochs;p->active_revision=__atomic_load_n(&p->revision,__ATOMIC_ACQUIRE);
        p->active_begin=begin;p->active_end=end;p->active_kind=s.kind;p->active_state=s.state;
        if(local){local->owned_epoch=p->active_epoch;local->owned_revision=p->active_revision;}
        if(transition)display_transition_before(transition,p,s,begin,end);
    }
    if(local)local->stage=DU_STAGE_ORIGINAL;
    int result=original(connection,force,begin,end);
    if(local)local->stage=DU_STAGE_ENTRY;
    if(active) {
        int observe=!local || !du_forward_only(local->bridge);
        if(observe && transition)display_transition_after(transition,p,result);
        struct display_pair_record r;display_pair_zero(&r,sizeof(r));
        r.event=DISPLAY_PAIR_RETURN;r.epoch=p->active_epoch;
        r.revision=p->active_revision;r.kind=s.kind;r.state=s.state;r.native_result=result;
        if(!local) {
            p->active_epoch=0;p->active_revision=0;p->active_begin=0;p->active_end=0;
        } else if(p->active_epoch==local->owned_epoch && p->active_revision==local->owned_revision) {
            p->active_revision=0;p->active_begin=0;p->active_end=0;
            __atomic_store_n(&p->active_epoch,0,__ATOMIC_RELEASE);
            local->owned_epoch=local->owned_revision=0;
        } else du_quarantine(local,DU_FAIL_UNKNOWN|DU_FAIL_ENTRY(DU_PAIR));
        if(observe)display_pair_publish(p,&r);
    }
    if(local && s.tracked) {
        __atomic_store_n(&p->probe.last_result,result,__ATOMIC_RELAXED);
        du_legacy_close(local,DU_PROBE);
    } else display_probe_end(&p->probe,s,result);
    return result;
}
int anim_display_pair_entry(void *connection,u64 force,void *begin,void *end,
                            struct display_pair *p,display_original_fn original) {
    return display_pair_dispatch(connection,force,begin,end,p,original,
                   pc_address(__builtin_extract_return_addr(__builtin_return_address(0))),0,0);
}
int anim_display_pair_framed(void *connection,u64 force,void *begin,void *end,
                            struct display_pair *p,display_original_fn original,u64 native_fp) {
    u64 caller=0;
    if(display_pair_live(p) && p->thread_self && p->stack_top && p->stack_size) {
        void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
        if(size>=4096 && size<=0x40000000ULL && top>=size)
            caller=display_pair_framed_caller(p,(u64)__builtin_frame_address(0),native_fp,top-size,top);
    }
    return display_pair_dispatch(connection,force,begin,end,p,original,caller,0,0);
}
unsigned anim_display_pair_size(void){return sizeof(struct display_pair);}
