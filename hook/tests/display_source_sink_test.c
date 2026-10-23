// B-only qualifier contract. Native cleanup and visible recomposition require
// separate live evidence; these tests do not authorize excluding A.
#define main paired_contract_main
#include "display_pair_test.c"
#undef main
static struct display_source_sink trial;
static unsigned char *normal_r;
static int forwarded,sunk,cleaned,retained,released,bad_graph;
static int opaque_token;
static void *sink_retain(void *p){assert(p==&opaque_token);retained++;return p;}
static void sink_release(void *p){assert(p==&opaque_token);released++;}
static void sink_free(void *p){
    assert(p==sources[1] && pair.published);
    struct display_pair_record *r=&pair.records[(pair.published-1)%DISPLAY_PAIR_RECORDS];
    assert(r->event==DISPLAY_PAIR_PRIVATE_B && r->native_result==23);
    if(bad_graph)assert(r->reason==DISPLAY_PAIR_GRAPH && !r->found_mask &&
                       !r->source[0].window && !r->source[1].window);
    else assert(!r->reason && r->found_mask==2 && r->source[1].window==(u64)windows[1]);
    cleaned++;
}
static void sink_enum(void *p){(void)p;assert(0);}
static int sink_generate(void *r,void *w) {
    if(r!=trial.workspace.redraw){forwarded++;return 23;}
    assert(w==windows[1]);sunk++;
    assert(display_sink_get(r,0x60)==&opaque_token);
    assert(display_sink_get(r,0x78)==&trial.workspace.head);
    assert(!display_sink_get(r,0x68) && !display_sink_get(r,0x80));
    *(void **)display_sink_get(r,0x78)=sources[1];
    ((unsigned char *)r)[0x93]^=1;
    return 23;
}
static struct display_source_step sink_setup(void) {
    reset();memset(&trial,0,sizeof(trial));
    forwarded=sunk=cleaned=retained=released=bad_graph=0;
    trial.magic=DISPLAY_SOURCE_SINK_MAGIC;trial.size=sizeof(trial);trial.version=1;
    struct display_source *s=&trial.source;
    s->magic=DISPLAY_SOURCE_MAGIC;s->size=sizeof(*s);s->version=1;s->pair=&pair;
    s->normal_return=0x186e13244;s->enabled=1;
    pair.enabled=1;pair.active_epoch=11;pair.active_revision=73;pair.probe.inflight=1;
    pair.update_return[0]=501;((u64 *)(stack+0x3000))[1]=501;
    trial.enabled=trial.profile_verified=trial.a_unfenced=1;
    trial.revision=73;
    trial.api=(struct display_sink_api){(void *)1,sink_retain,sink_release,sink_free,sink_enum};
    normal_r=(unsigned char *)(stack+0x3000-0xb40);
    display_sink_put(normal_r,0x60,&opaque_token);
    return display_source_before(s,s->normal_return,(u64)(stack+0x3000),
                                 (u64)stack,(u64)(stack+sizeof(stack)),normal_r,windows[1]);
}
static int invoke(struct display_source_step step,void *w) {
    return display_source_call(normal_r,w,sink_generate,&trial.source,step,&trial);
}
int main(void) {
    struct display_source_step step=sink_setup();unsigned char saved[0xb8];
    memcpy(saved,normal_r,sizeof(saved));
    assert(invoke(step,windows[1])==0 && sunk==1 && !forwarded);
    assert(cleaned==1 && retained==1 && released==1 && !trial.workspace.phase);
    assert(trial.workspace.native_result==23 && trial.completed==1 && trial.attempted==1);
    assert(pair.published==1 && pair.records[0].event==DISPLAY_PAIR_PRIVATE_B &&
           pair.records[0].found_mask==2 && !pair.records[0].reason &&
           pair.records[0].native_result==23 && !trial.workspace.head);
    assert(!memcmp(saved,normal_r,sizeof(saved)));
    // Both call orders keep A native; neither can select it for exclusion.
    step.role=0;assert(invoke(step,windows[0])==23 && forwarded==1 && sunk==1);
    step.role=1;assert(invoke(step,windows[1])==0 && sunk==2 && forwarded==1);
    step=sink_setup();bad_graph=1;*(void **)sources[1]=sources[1];
    assert(invoke(step,windows[1])==0 && cleaned==1 && !trial.workspace.phase);
    // Refusal is before original, which is then forwarded exactly once ONLY
    // because this capsule's explicit contract keeps A unfenced.
    step=sink_setup();trial.workspace.phase=DISPLAY_SINK_GENERATE;
    assert(invoke(step,windows[1])==23 && forwarded==1 && !sunk && trial.refused==1);
    step=sink_setup();display_sink_put(normal_r,0x80,(void *)1);
    assert(invoke(step,windows[1])==23 && forwarded==1 && !sunk && trial.refused==1);
    for(unsigned i=0;i<5;i++) {
        static const unsigned offsets[]={0x428,0x488,0x878,0x880,0x8b0};
        step=sink_setup();*(void **)(windows[1]+offsets[i])=(void *)1;
        assert(invoke(step,windows[1])==23 && forwarded==1 && !sunk && !trial.attempted);
    }
    for(unsigned i=0;i<14;i++) {
        step=sink_setup();
        switch(i) {
        case 0:trial.enabled=0;trial.source.pair=(void *)1;break;
        case 1:trial.a_unfenced=0;break;
        case 2:trial.profile_verified=0;break;
        case 3:trial.revision++;break;
        case 4:step.epoch++;break;
        case 5:step.revision++;break;
        case 6:pair.active_kind=1;break;
        case 7:pair.active_state=1;break;
        case 8:pair.probe.inflight=2;break;
        case 9:*(u32 *)(cwcs[1]+0x50)^=1;break;
        case 10:pair.identity[1].creator=1;break;
        case 11:pair.identity[0].creator=0;break;
        case 12:main_thread=0;break;
        case 13:trial.pad=1;break;
        }
        assert(invoke(step,windows[1])==23 && forwarded==1 && !sunk);
    }
    step=sink_setup();step.epoch=0;normal_r=(void *)1;
    assert(invoke(step,(void *)2)==23 && forwarded==1 && !sunk);
    assert(anim_display_source_sink_framed((void *)1,(void *)2,0,sink_generate,1)==23);
    trial.magic=0;
    assert(anim_display_source_sink_framed((void *)1,(void *)2,&trial,sink_generate,1)==23);
    assert(forwarded==3 && !sunk);
    puts("B-only ordinary sink preserves native A, private R, exact-once/refusal contracts PASS");
    return 0;
}
