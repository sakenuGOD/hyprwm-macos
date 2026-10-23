// CPU fault/custody checks; native committed B/pixels require the live qualifier.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static _Alignas(16) unsigned char arena[16384],engine_arena[4096];
static struct ctx *c;static struct rgba_capture *g;static struct rgba_view *v;
static struct ch channel;static struct display_present bridge;
static int schedules,originals,display_reads;static u32 display_id=17;
static void *display_table[8],*display_object[2],*displays[2];
static int is_main(void){return 1;}
static void schedule(void *connection,void *window){assert(!connection&&window==(void *)0x1000);schedules++;}
static void tick(struct ctx *ctx,double now){assert(ctx==c&&now==1);originals++;}
static u32 get_display(void *display){assert(display==display_object);display_reads++;return display_id;}
static int native(void *connection,u64 force,void *begin,void *end){
 assert(connection==(void *)0x100 && force==0x123456789abcdef0ULL && begin==(void *)0x200 && end==(void *)0x230);
 originals++;return -17;
}
static void reset(void){
 memset(arena,0,sizeof(arena));memset(engine_arena,0,sizeof(engine_arena));memset(&channel,0,sizeof(channel));memset(&bridge,0,sizeof(bridge));
 c=(void *)engine_arena;g=(void *)arena;v=(void *)(arena+RGBA_VIEW_OFFSET);
 g->magic=RGBA_MAGIC;g->size=sizeof(*g);g->version=RGBA_VERSION;
 g->pc.magic=PC_MAGIC;g->pc.size=sizeof(g->pc);g->pc.version=1;g->pc.engine=c;g->pc.is_main=is_main;
 g->pc.wid=42;g->pc.creator=0x1234;g->pc.pid_version=0x5678;g->pc.capture_witness=91;
 v->magic=RGBA_VIEW_MAGIC;v->size=sizeof(*v);v->version=RGBA_VIEW_VERSION;v->capture=g;
 v->source_wid=42;v->source_creator=g->pc.creator;v->source_pid_version=g->pc.pid_version;
 v->window=(void *)0x1000;v->pre_display=1;v->prepared=1;v->display=17;
 v->active=1;v->sequence=v->claimed=7;
 c->ch=&channel;channel.h.magic=CH_MAGIC;channel.h.size=sizeof(channel);c->sched_win=schedule;
 *(void **)(engine_arena+PC_CONTROL_PTR)=g;*(void (**)(struct ctx *,double))(engine_arena+PC_ORIGINAL_TICK)=tick;
 bridge.magic=DISPLAY_PRESENT_MAGIC;bridge.size=sizeof(bridge);bridge.version=1;bridge.armed=1;bridge.view=v;bridge.capture_witness=91;
 bridge.probe.magic=DISPLAY_PROBE_MAGIC;bridge.probe.size=sizeof(bridge.probe);bridge.probe.version=1;bridge.probe.engine=c;
 schedules=originals=display_reads=0;display_id=17;
 display_table[5]=(void *)get_display;display_object[0]=display_table;displays[0]=display_object;displays[1]=0;
#if __has_feature(ptrauth_calls)
 display_table[5]=__builtin_ptrauth_sign_unauthenticated(__builtin_ptrauth_strip((void *)get_display,0),0,
    __builtin_ptrauth_blend_discriminator(&display_table[5],0x1608));
 display_object[0]=__builtin_ptrauth_sign_unauthenticated((void *)display_table,2,
    __builtin_ptrauth_blend_discriminator((void *)display_object,0xc333));
#endif
}
static struct display_present_work before(struct display_probe_step s){return display_present_before(&bridge,s,displays,displays+2);}
int main(void){
 struct display_probe_step ready={.sampled=1,.kind=0};
 reset();v->active=0;v->command=1;anim_rgba_present_dispatch(c,1);
 assert(originals==1&&schedules==1&&v->active==1&&v->claimed==7&&v->ack==0&&!v->mutations);
 reset();v->active=0;v->command=1;v->prepared=0;anim_rgba_present_dispatch(c,1);
 assert(originals==1&&!schedules&&!v->active&&v->ack==7&&v->result==-1&&!v->mutations);
 reset();assert(!before((struct display_probe_step){0}).sequence&&!display_reads);
 assert(!before((struct display_probe_step){.sampled=1,.state=1}).sequence&&!display_reads);
 assert(!before((struct display_probe_step){.sampled=1,.active=1}).sequence&&!display_reads);
 assert(!before((struct display_probe_step){.sampled=1,.kind=1}).sequence&&bridge.unsupported==1&&!display_reads);
 bridge.armed=0;assert(!before(ready).sequence&&!display_reads);
 reset();g->pc.capture_witness++;assert(!before(ready).sequence&&bridge.stale==1&&!display_reads);
 reset();v->version=2;assert(!before(ready).sequence&&bridge.stale==1&&!display_reads);
 reset();v->version=3;assert(!before(ready).sequence&&bridge.stale==1&&!display_reads);
 reset();g->destroyed=1;assert(!before(ready).sequence&&bridge.stale==1&&!display_reads);
 reset();v->sequence++;assert(!before(ready).sequence&&bridge.stale==1&&!display_reads);
 reset();display_id++;assert(!before(ready).sequence&&bridge.not_in_display==1&&display_reads==1);
 assert(!display_present_includes(v,0,0)&&!display_present_includes(v,displays,(char *)displays+1));
 reset();struct display_present_work failed=before(ready); // Real pose refuses missing native API.
 assert(failed.sequence==7&&failed.result==-1&&!v->ack&&v->active==1);
 display_present_after(&bridge,failed,10);assert(!v->ack&&v->active==1);
 display_present_after(&bridge,failed,0);assert(v->ack==7&&!v->active&&v->result==-1);
 reset();struct display_present_work applied={7,1};display_present_after(&bridge,applied,10);assert(!v->ack&&v->active==1);
 display_present_after(&bridge,applied,0);assert(v->ack==7&&!v->active&&v->result==1&&bridge.acknowledged==1);
 reset();g->pc.capture_witness++;display_present_after(&bridge,applied,0);assert(!v->ack&&v->active==1&&bridge.stale==1);
 reset();v->retired=1;display_present_after(&bridge,applied,0);assert(!v->ack&&v->active==1);
 reset();v->sequence++;display_present_after(&bridge,applied,0);assert(!v->ack&&v->active==1);
 reset();bridge.magic=0;
 assert(anim_rgba_display_entry((void *)0x100,0x123456789abcdef0ULL,(void *)0x200,(void *)0x230,&bridge,native)==-17&&originals==1&&!bridge.probe.entered);
 puts("Pre-display timer-no-pose/fresh-state/cohort/display/epoch/version/native-result/ACK/exact-forward fault contracts PASS");
 return 0;
}
