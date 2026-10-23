// The passive hook must forward once on every refusal as well as qualification.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static struct ctx engine;
static struct ch channel;
static struct display_probe probe;
static int main_thread,queries,originals;
static u32 state;
static void *get_class(const char *name){assert(!strcmp(name,"CATransaction"));return (void *)1;}
static void *get_sel(const char *name){assert(!strcmp(name,"currentState"));return (void *)2;}
static u32 get_state(void *cls,void *sel){assert(cls==(void *)1 && sel==(void *)2);queries++;return state;}
static int is_main(void){return main_thread;}
static int original(void *c,u64 force,void *begin,void *end){
    assert(c==(void *)0x100 && force==0x123456789abcdef0ULL && begin==(void *)0x200 && end==(void *)0x230);
    originals++;return -17;
}
static void reset(void){
    memset(&engine,0,sizeof(engine));memset(&channel,0,sizeof(channel));memset(&probe,0,sizeof(probe));
    engine.ch=&channel;channel.h.magic=CH_MAGIC;engine.cls=get_class;engine.sel=get_sel;engine.msg=(void *)get_state;
    probe.magic=DISPLAY_PROBE_MAGIC;probe.size=sizeof(probe);probe.version=1;probe.engine=&engine;probe.is_main=is_main;probe.enabled=1;
    main_thread=1;queries=originals=0;state=0;
}
static void call(void){assert(anim_display_probe_entry((void *)0x100,0x123456789abcdef0ULL,(void *)0x200,(void *)0x230,&probe,original)==-17);}
int main(void){
    reset();call();assert(originals==1 && queries==1 && probe.entered==1 && probe.returned==1 && !probe.inflight);
    assert(probe.kinds[3]==1 && probe.kind_zero[3]==1 && probe.states[0]==1 && probe.last_displays==3);
    state=0x1f;call();assert(originals==2 && queries==2 && probe.states[31]==1 && probe.kind_zero[3]==1);
    state=0x40;call();assert(probe.states[32]==1);
    reset();probe.enabled=0;call();assert(originals==1 && !queries && probe.entered==probe.returned);
    reset();main_thread=0;call();assert(originals==1 && !queries && probe.nonmain==1);
    reset();probe.inflight=1;call();assert(originals==1 && !queries && probe.reentrant==1 && probe.inflight==1);
    reset();channel.h.stop=1;call();assert(originals==1 && !queries && probe.unavailable==1);
    reset();engine.dead=1;call();assert(originals==1 && !queries && probe.unavailable==1);
    reset();probe.magic=0;call();assert(originals==1 && !queries && !probe.entered && !probe.returned);
    puts("Display entry passive query/refusal/exact-forward ABI PASS");return 0;
}
