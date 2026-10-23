// Dormant one-lease qualifier. Source A remains native-visible in this phase.
// Ordinary entry only; deferred/special callers transparently forward unchanged.
#define DISPLAY_PRESENT_MAGIC 0x31525044574d5748ULL
struct display_present {
    u64 magic;u32 size,version;
    struct display_probe probe;
    struct rgba_view *view;
    u64 capture_witness;
    u32 armed,pad;
    u64 applied,acknowledged,waiting,stale,unsupported,not_in_display;
};
struct display_present_work { u64 sequence;int result; };
static int display_present_valid(struct display_present *p) {
    return p && p->magic==DISPLAY_PRESENT_MAGIC && p->size==sizeof(*p) &&
        p->version==1 && p->pad==0 && p->armed<=1 && display_probe_valid(&p->probe);
}
// The vector's lifetime is held by the original native caller. Require its
// exact display to be in this update before mutating the owned presentation.
static int display_present_includes(struct rgba_view *v,void *begin,void *end) {
    u64 a=(u64)begin,b=(u64)end;
    if(!a || b<=a || ((b-a)&15) || b-a>16384)return 0;
    for(u64 i=a;i<b;i+=16) {
        void *display=*(void **)i;if(!display)continue;
        void **table=*(void ***)display;
#if __has_feature(ptrauth_calls)
        table=__builtin_ptrauth_auth(table,2,__builtin_ptrauth_blend_discriminator(display,0xc333));
        void *fn=__builtin_ptrauth_auth_and_resign(table[0x28/8],0,
            __builtin_ptrauth_blend_discriminator(&table[0x28/8],0x1608),0,0);
#else
        void *fn=table[0x28/8];
#endif
        if(((u32 (*)(void *))fn)(display)==v->display)return 1;
    }
    return 0;
}
static struct display_present_work display_present_before(struct display_present *p,
                                struct display_probe_step s,void *begin,void *end) {
    struct display_present_work work={0};
    if(!p->armed || !s.sampled || s.state || s.active)return work;
    if(s.kind!=0){p->unsupported++;return work;}
    struct rgba_view *v=p->view;struct rgba_capture *g=v?v->capture:0;
    if(!rgba_view_valid(v,g) || !v->pre_display || v->retired || g->destroyed || g->pc.dead ||
       g->pc.engine!=p->probe.engine || !p->capture_witness ||
       g->pc.capture_witness!=p->capture_witness) {p->stale++;return work;}
    if(v->active!=1 || !v->prepared)return work;
    u64 sequence=__atomic_load_n(&v->sequence,__ATOMIC_ACQUIRE);
    if(sequence!=v->claimed || sequence==v->ack){p->stale++;return work;}
    if(!display_present_includes(v,begin,end)){p->not_in_display++;return work;}
    work.sequence=sequence;work.result=rgba_view_pose(v,1);
    if(work.result>0)p->applied++;else if(!work.result)p->waiting++;
    return work;
}
static void display_present_after(struct display_present *p,struct display_present_work work,
                                 int native_result) {
    if(!work.sequence || !work.result || native_result!=0)return;
    struct rgba_view *v=p->view;struct rgba_capture *g=v?v->capture:0;
    if(!p->armed || !rgba_view_valid(v,g) || !v->pre_display || !v->prepared ||
       v->retired || g->destroyed || g->pc.dead || g->pc.engine!=p->probe.engine ||
       g->pc.capture_witness!=p->capture_witness || v->active!=1 ||
       v->claimed!=work.sequence || __atomic_load_n(&v->sequence,__ATOMIC_ACQUIRE)!=work.sequence) {
        p->stale++;return;
    }
    v->result=work.result;v->active=0;p->acknowledged++;
    __atomic_store_n(&v->ack,work.sequence,__ATOMIC_RELEASE);
}
int anim_rgba_display_entry(void *connection,u64 force,void *begin,void *end,
                           struct display_present *p,display_original_fn original) {
    if(!display_present_valid(p))return original(connection,force,begin,end);
    u64 caller=pc_address(__builtin_extract_return_addr(__builtin_return_address(0)));
    struct display_probe_step s=display_probe_begin(&p->probe,caller,begin,end);
    struct display_present_work work=display_present_before(p,s,begin,end);
    int result=original(connection,force,begin,end);
    display_present_after(p,work,result);display_probe_end(&p->probe,s,result);
    return result;
}
unsigned anim_rgba_display_size(void){return sizeof(struct display_present);}
