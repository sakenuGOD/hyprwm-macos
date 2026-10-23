// Reuse the exact paired source fixture; native text/trampoline installation is
// deliberately outside this CPU contract test.
#define main paired_contract_main
#include "display_pair_test.c"
#undef main
static struct display_source source;
static int generates;
static int generate(void *r,void *w){assert(r==(void *)1 && w==(void *)2);generates++;return -19;}
static void setup(void) {
    reset();memset(&source,0,sizeof(source));generates=0;
    source.magic=DISPLAY_SOURCE_MAGIC;source.size=sizeof(source);source.version=1;source.pair=&pair;
    source.normal_return=0x186e13244;source.enabled=1;
    pair.enabled=1;pair.active_epoch=11;pair.active_revision=73;pair.probe.inflight=1;
    pair.update_return[0]=501;pair.update_return[1]=502;((u64 *)(stack+0x3000))[1]=501;
}
static struct display_source_step before(u64 caller,void *r,void *w) {
    return display_source_before(&source,caller,(u64)(stack+0x3000),(u64)stack,(u64)(stack+sizeof(stack)),r,w);
}
int main(void) {
    setup();void *r=stack+0x3000-0xb40;
    struct display_source_step s=before(source.normal_return,r,windows[0]);
    assert(s.epoch==11 && s.revision==73 && s.role==0);
    assert(s.head==(void **)(stack+0x3000-0xb88));
    *s.head=sources[0];display_source_graph(&pair,s,r,-19);
    assert(pair.published==1 && pair.records[0].event==DISPLAY_PAIR_GENERATED_A &&
           pair.records[0].found_mask==3 && pair.records[0].native_result==-19);
    // A successful empty construction is distinct from a malformed graph.
    *s.head=0;s.role=1;display_source_graph(&pair,s,r,0);
    assert(pair.records[1].event==DISPLAY_PAIR_GENERATED_B && !pair.records[1].reason && !pair.records[1].found_mask);
    *s.head=sources[0];*(void **)sources[1]=sources[0];display_source_graph(&pair,s,r,0);
    assert(pair.records[2].reason==DISPLAY_PAIR_GRAPH && !pair.records[2].found_mask && !pair.records[2].source[0].window);
    // Revoked scope must refuse BEFORE touching even the head cell.
    s.head=(void **)1;s.epoch++;display_source_graph(&pair,s,r,0);assert(pair.published==3);
    s.epoch--;s.revision++;display_source_graph(&pair,s,r,0);assert(pair.published==3);
    s.revision--;pair.probe.inflight=2;display_source_graph(&pair,s,r,0);assert(pair.published==3);
    setup();
    s=before(source.normal_return,r,windows[1]);assert(s.epoch==11 && s.role==1);
    assert(!before(source.normal_return+4,r,windows[0]).epoch);
    assert(!before(source.normal_return,(char *)r+16,windows[0]).epoch);
    assert(!before(source.normal_return,r,(void *)1).epoch);
    ++*(u64 *)(creator+0x268);assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();++*(u32 *)(cwcs[1]+0x50);assert(!before(source.normal_return,r,windows[1]).epoch);
    setup();pair.probe.inflight=2;assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();pair.enabled=0;assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();pair.active_epoch=0;assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();((u64 *)(stack+0x3000))[1]=503;assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();engine.in_cb=1;assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();main_thread=0;assert(!before(source.normal_return,r,windows[0]).epoch);
    setup();u64 fp=(u64)(stack+0x2700),gfp=(u64)(stack+0x2800);
    *(u64 *)fp=gfp;*(u64 *)gfp=(u64)(stack+0x3000);
    ((u64 *)gfp)[1]=(u64)__builtin_ptrauth_sign_unauthenticated((void *)source.normal_return,1,gfp+16);
    assert(display_source_framed_parent(&source,fp,gfp,(u64)stack,(u64)(stack+sizeof(stack)))==(u64)(stack+0x3000));
    assert(before(source.normal_return,r,windows[0]).epoch==11);
    ((u64 *)gfp)[1]^=1;assert(!display_source_framed_parent(&source,fp,gfp,(u64)stack,(u64)(stack+sizeof(stack))));
    ((u64 *)gfp)[1]=(u64)__builtin_ptrauth_sign_unauthenticated((void *)source.normal_return,1,gfp+32);
    assert(!display_source_framed_parent(&source,fp,gfp,(u64)stack,(u64)(stack+sizeof(stack))));
    assert(!display_source_framed_parent(&source,fp,gfp+1,(u64)stack,(u64)(stack+sizeof(stack))));
    assert(!display_source_framed_parent(&source,fp,fp,(u64)stack,(u64)(stack+sizeof(stack))));
    assert(!display_source_framed_parent(&source,fp,gfp,(u64)stack,gfp+8));
    *(u64 *)fp=0;assert(!display_source_framed_parent(&source,fp,gfp,(u64)stack,(u64)(stack+sizeof(stack))));
    // Capture/unknown callers must forward without inspecting their R/window,
    // even when the observer control is invalid or has no usable pair pointer.
    setup();assert(anim_display_source_entry((void *)1,(void *)2,&source,generate)==-19);
    assert(generates==1 && source.entered==1 && source.returned==1 && !source.inflight && !pair.published);
    source.enabled=0;source.pair=(void *)1;
    assert(anim_display_source_entry((void *)1,(void *)2,&source,generate)==-19 && generates==2);
    source.enabled=1;source.inflight=1;
    assert(anim_display_source_entry((void *)1,(void *)2,&source,generate)==-19 && generates==3);
    assert(source.inflight==1);source.inflight=0;
    source.magic=0;assert(anim_display_source_entry((void *)1,(void *)2,&source,generate)==-19 && generates==4);
    assert(source.entered==3 && source.returned==3 && !source.inflight);
    assert(anim_display_source_entry((void *)1,(void *)2,0,generate)==-19 && generates==5);
    assert(anim_display_source_framed((void *)1,(void *)2,0,generate,1)==-19 && generates==6);
    setup();source.enabled=0;source.pair=(void *)1;
    assert(anim_display_source_framed((void *)1,(void *)2,&source,generate,1)==-19 && generates==1);
    puts("Normal generator exact-callsite/epoch/identity/refusal/unchanged-output contracts PASS");return 0;
}
