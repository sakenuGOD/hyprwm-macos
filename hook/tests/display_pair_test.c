// CPU ownership/refusal tests. Native stack layout and actual current source
// membership require the separate live observer; no presentation claim here.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static struct display_pair pair;
static struct ctx engine;
static struct ch channel;
static _Alignas(16) char windows[2][0xa00],cwcs[2][0x600],creator[0x300],control[64];
static _Alignas(16) char sources[2][0x280],descriptors[2][0x40],stack[16384];
static void *control_ptr=control;
static int originals,main_thread,queries,recurse;
static void *by_id(u32 wid){return wid>=41 && wid<=42?windows[wid-41]:0;}
static int is_main(void){return main_thread;}
static void *find(const char *name){(void)name;return (void *)1;}
static u32 state(void *cls,void *sel){(void)cls;(void)sel;queries++;return 0;}
static int original(void *c,u64 force,void *begin,void *end) {
    assert(c==(void *)0x100 && force==0x123456789abcdef0ULL && begin==(void *)0x200 && end==(void *)0x230);
    originals++;
    if(recurse) {
        recurse=0;u64 epoch=pair.active_epoch;
        assert(anim_display_pair_entry(c,force,begin,end,&pair,original)==-17);
        assert(pair.active_epoch==epoch);
    }
    return -17;
}
static void reset(void) {
    memset(&pair,0,sizeof(pair));memset(&engine,0,sizeof(engine));memset(&channel,0,sizeof(channel));
    memset(windows,0,sizeof(windows));memset(cwcs,0,sizeof(cwcs));memset(creator,0,sizeof(creator));
    memset(sources,0,sizeof(sources));memset(descriptors,0,sizeof(descriptors));memset(stack,0,sizeof(stack));
    main_thread=1;originals=queries=recurse=0;
    engine.ch=&channel;engine.session=(void *)0x8000;engine.by_id=by_id;engine.cls=find;engine.sel=find;engine.msg=(void *)state;
    channel.h.magic=CH_MAGIC;channel.h.size=sizeof(channel);*(void **)(control+0x20)=engine.session;
    pair.magic=DISPLAY_PAIR_MAGIC;pair.size=sizeof(pair);pair.version=1;pair.session=engine.session;pair.channel=&channel;
    pair.session_control=&control_ptr;pair.layout_verified=1;pair.revision=73;
    pair.probe.magic=DISPLAY_PROBE_MAGIC;pair.probe.size=sizeof(pair.probe);pair.probe.version=1;
    pair.probe.engine=&engine;pair.probe.is_main=is_main;pair.probe.enabled=1;
    *(u64 *)(creator+0x268)=0x100000023ULL;
    for(unsigned i=0;i<2;i++) {
        char *w=windows[i],*s=sources[i],*q=descriptors[i];
        *(u32 *)w=41+i;*(u32 *)(w+4)=5;*(void **)(w+0x18)=cwcs[i];
        *(void **)(w+0x30)=i?0:creator;
        pair.identity[i]=(struct display_pair_identity){.window=(u64)w,.creator=i?0:(u64)creator,
            .pid_version=i?0:*(u64 *)(creator+0x268),.wid=41+i};
        if(i) {
            pair.identity[i].local_context=0x99000;pair.identity[i].client_id=345;
            *(u64 *)(cwcs[i]+0x58)=0x99000;*(u32 *)(cwcs[i]+0x50)=345;
        }
        *(u32 *)(cwcs[i]+0x40)=91+i;*(u32 *)(s+0x180)=10;*(u32 *)(s+0x268)=41+i;
        *(void **)(s+0x48)=q;*(void **)q=w;*(u64 *)(q+0x10)=0x80000+0x100*i;
        *(u64 *)(s+0x28)=*(u64 *)(s+0x30)=*(u64 *)(q+0x10);*(u32 *)(q+0x28)=91+i;
        *(rect *)(s+0xc8)=(rect){0,0,480,300};*(float *)(s+0x188)=1;*(float *)(s+0x18c)=1;
    }
    *(void **)sources[0]=sources[1];
}
static void call(void) {assert(anim_display_pair_entry((void *)0x100,0x123456789abcdef0ULL,(void *)0x200,(void *)0x230,&pair,original)==-17);}
static void entry_contract(void) {
    reset();call();assert(originals==1 && !pair.epochs && !pair.published && !pair.active_epoch);
    pair.enabled=1;recurse=1;call();assert(originals==3 && pair.epochs==1 && pair.published==1 && !pair.active_epoch);
    assert(!pair.active_begin && !pair.active_end && !pair.active_revision && !pair.probe.inflight);
    assert(pair.records[0].epoch==1 && pair.records[0].revision==73 && pair.records[0].native_result==-17);
    assert(pair.records[0].event==DISPLAY_PAIR_RETURN && pair.probe.reentrant==1 && pair.probe.entered==pair.probe.returned);
    reset();pair.enabled=1;main_thread=0;call();assert(originals==1 && !queries && !pair.epochs);
    reset();pair.enabled=1;pair.layout_verified=0;call();assert(originals==1 && !pair.epochs);
    reset();pair.enabled=1;engine.dead=1;call();assert(originals==1 && !pair.epochs);
    reset();pair.enabled=1;channel.h.stop=1;call();assert(originals==1 && !pair.epochs);
    reset();pair.enabled=1;pair.session=(void *)1;call();assert(originals==1 && !pair.epochs);
    reset();pair.magic=0;call();assert(originals==1 && !queries && !pair.probe.entered);
}
static void graph_contract(void) {
    reset();struct display_pair_record r={0};char before[sizeof(sources)];memcpy(before,sources,sizeof(sources));
    assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_OK && r.found_mask==3 && r.nodes==2);
    assert(r.source[0].update==0x80000 && r.source[1].context==92 && !memcmp(before,sources,sizeof(sources)));
    ++*(u64 *)(creator+0x268);r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_IDENTITY);
    reset();*(void **)sources[1]=sources[0];r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_GRAPH);
    reset();*(void **)(sources[0]+0x10)=sources[1];r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_GRAPH);
    reset();++*(u64 *)(descriptors[1]+0x10);r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_SOURCE);
    reset();++*(u32 *)(descriptors[1]+0x28);r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_SOURCE);
    reset();++*(u32 *)(cwcs[1]+0x50);r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_IDENTITY);
    reset();*(void **)(descriptors[1]+8)=(void *)1;r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_SOURCE);
    reset();pair.identity[1].wid=0;r=(struct display_pair_record){0};assert(display_pair_graph(&pair,sources[0],&r)==DISPLAY_PAIR_OK && r.found_mask==1);
    reset();r=(struct display_pair_record){0};assert(display_pair_graph(&pair,0,&r)==DISPLAY_PAIR_OK && !r.found_mask && !r.nodes);
}
static void stack_contract(void) {
    reset();for(unsigned i=0;i<5;i++)pair.cohort_pc[i]=101+i;
    pair.update_return[0]=501;pair.update_return[1]=502;
    unsigned indices[]={0,1,3,4};
    for(unsigned i=0;i<4;i++) {u64 *f=(u64 *)(stack+0x1000+0x20*i);f[0]=(u64)(stack+(i==3?0x3000:0x1020+0x20*i));f[1]=pair.cohort_pc[indices[i]];}
    ((u64 *)(stack+0x3000))[1]=501;char *r=0;void **h=0;
    assert(display_pair_redraw(&pair,(u64)(stack+0x1000),(u64)stack,(u64)(stack+sizeof(stack)),&r,&h)==DISPLAY_PAIR_OK);
    assert(r==stack+0x3000-0xb40 && h==(void **)(stack+0x3000-0xb88));
    ((u64 *)(stack+0x3000))[1]=503;
    assert(display_pair_redraw(&pair,(u64)(stack+0x1000),(u64)stack,(u64)(stack+sizeof(stack)),&r,&h)==DISPLAY_PAIR_COHORT);
    ((u64 *)(stack+0x1000))[0]=(u64)(stack+0x1000);
    assert(display_pair_redraw(&pair,(u64)(stack+0x1000),(u64)stack,(u64)(stack+sizeof(stack)),&r,&h)==DISPLAY_PAIR_STACK);
    assert(display_pair_redraw(&pair,(u64)(stack+0x1001),(u64)stack,(u64)(stack+sizeof(stack)),&r,&h)==DISPLAY_PAIR_STACK);
}
static void framed_contract(void) {
    reset();u64 fp=(u64)(stack+0x2700),nf=(u64)(stack+0x2800);
    *(u64 *)fp=nf;
    for(unsigned i=0;i<3;i++) {
        pair.probe.callers[i]=100+i;
        ((u64 *)nf)[1]=(u64)__builtin_ptrauth_sign_unauthenticated((void *)(100ULL+i),1,nf+16);
        assert(display_pair_framed_caller(&pair,fp,nf,(u64)stack,(u64)(stack+sizeof(stack)))==100+i);
    }
    ((u64 *)nf)[1]^=1;assert(!display_pair_framed_caller(&pair,fp,nf,(u64)stack,(u64)(stack+sizeof(stack))));
    ((u64 *)nf)[1]=(u64)__builtin_ptrauth_sign_unauthenticated((void *)102,1,nf+32);
    assert(!display_pair_framed_caller(&pair,fp,nf,(u64)stack,(u64)(stack+sizeof(stack))));
    assert(!display_pair_framed_caller(&pair,fp,nf,(u64)stack,nf+8));
    *(u64 *)fp=0;assert(!display_pair_framed_caller(&pair,fp,nf,(u64)stack,(u64)(stack+sizeof(stack))));
    reset();assert(anim_display_pair_framed((void *)0x100,0x123456789abcdef0ULL,(void *)0x200,(void *)0x230,&pair,original,1)==-17);
    assert(originals==1 && !pair.epochs && !pair.probe.inflight);
    pair.magic=0;assert(anim_display_pair_framed((void *)0x100,0x123456789abcdef0ULL,(void *)0x200,(void *)0x230,&pair,original,1)==-17);
    assert(originals==2 && !pair.epochs);
}
int main(void) {
    entry_contract();graph_contract();stack_contract();framed_contract();
    reset();struct display_pair_record r={.epoch=3};
    for(unsigned i=0;i<DISPLAY_PAIR_RECORDS+3;i++)display_pair_publish(&pair,&r);
    assert(pair.published==DISPLAY_PAIR_RECORDS+3 && pair.records[2].stamp==2*pair.published);
    puts("Passive paired entry/current-source identity/graph/stack/refusal/exact-forward contracts PASS");return 0;
}
