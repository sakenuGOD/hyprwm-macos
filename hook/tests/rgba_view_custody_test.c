// Fault contracts for the projector's native allocation and shared capture OFF.
// These CPU fakes do not qualify visible alpha/UV/device pixels.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static _Alignas(16) unsigned char arena[16384],window[0x940];
static _Alignas(16) unsigned char context_arena[4096];
static struct ctx *c;
static struct rgba_capture *g;
static struct rgba_view *v;
static int main_thread,live,release_refused,lookups,releases,orders,originals;
static int is_main(void){return main_thread;}
static void *by_id(u32 wid){assert(wid==91);lookups++;return live?window:0;}
static void release_window(void *connection,void *win){
 assert(!connection && win==window && live && !g->destroyed);releases++;
 if(!release_refused)live=0;
}
static int order(void *connection,u32 wid,int operation,u32 relative){
 assert(!connection && wid==91 && operation==0 && !relative && live);orders++;return 0;
}
static void original(struct ctx *ctx,double now){
 assert(ctx==c && now==1);originals++;
 // Publish AFTER the outer wrapper has already entered the original tick.
 if(!g->pc.command_sequence) {
  __atomic_store_n(&g->pc.command,4,__ATOMIC_RELEASE);
  __atomic_store_n(&g->pc.command_sequence,1,__ATOMIC_RELEASE);
 }
}
static void reset(void){
 memset(arena,0,sizeof(arena));memset(window,0,sizeof(window));memset(context_arena,0,sizeof(context_arena));
 c=(void *)context_arena;
 g=(void *)arena;v=(void *)(arena+RGBA_VIEW_OFFSET);
 g->magic=RGBA_MAGIC;g->size=sizeof(*g);g->version=RGBA_VERSION;
 g->pc.magic=PC_MAGIC;g->pc.size=sizeof(g->pc);g->pc.version=1;g->pc.engine=c;g->pc.is_main=is_main;
 g->pc.wid=42;g->pc.creator=0x1234;g->pc.pid_version=0x5678;
 v->magic=RGBA_VIEW_MAGIC;v->size=sizeof(*v);v->version=RGBA_VIEW_VERSION;v->capture=g;
 v->source_wid=42;v->source_creator=g->pc.creator;v->source_pid_version=g->pc.pid_version;
 v->window=window;v->wid=91;*(u32 *)window=91;*(u32 *)(window+4)=5;v->api.order=order;
 c->by_id=by_id;c->rel_win=release_window;
 *(void **)(context_arena+PC_CONTROL_PTR)=g;
 *(void (**)(struct ctx *,double))(context_arena+PC_ORIGINAL_TICK)=original;
 main_thread=live=1;release_refused=lookups=releases=orders=originals=0;
}
static void failed_bind_allocation(void){
 reset();v->bound=1;v->context_id=77;v->context=(void *)0x1000;
 assert(!rgba_view_owned(v)); // No matching native CWC/binding was established.
 v->context=0; // This case tests window allocation custody only.
 assert(rgba_view_retire(v) && v->retired && !v->window && !live && releases==1);
}
static void refused_release(void){
 reset();release_refused=1;
 assert(!rgba_view_retire(v) && !v->retired && v->window==window && live && releases==1);
 release_refused=0;
 assert(rgba_view_retire(v) && v->retired && !v->window && !live && releases==2);
 assert(rgba_view_retire(v) && releases==2);
}
static void callback_boundary(void){
 reset();v->prepared=1;main_thread=0;
 rgba_view_observe(v,0,0);assert(!lookups && !releases);
 main_thread=1;c->in_cb=1;rgba_view_observe(v,0,0);assert(!lookups);
 c->in_cb=0;rgba_view_observe(v,0,0);assert(!lookups); // Missing normal-frame witnesses.
}
static void capture_off_during_original(void){
 reset();release_refused=1;
 v->pre_display=v->prepared=1;v->active=1;v->sequence=v->claimed=7;
 anim_rgba_present_dispatch(c,1);
 assert(originals==1 && releases==1 && live && !v->retired && !g->destroyed);
 assert(v->active==1 && !v->ack);
 assert(g->pc.active_command==4 && g->pc.command_ack==0);
 release_refused=0;anim_rgba_present_dispatch(c,1);
 assert(originals==2 && releases==2 && !live && v->retired && g->destroyed);
 assert(g->pc.command_ack==1 && !g->pc.active_command);
 assert(!v->active && v->ack==7 && v->result==-1);
 reset();v->magic=0;anim_rgba_present_dispatch(c,1);
 assert(originals==1 && !releases && !g->destroyed && g->pc.active_command==4 && !g->pc.command_ack);
}
static void committed_fingerprint(void){
 reset();
 _Alignas(16) unsigned char root[0xa0]={0},body[0xa0]={0},texture[0x88]={0};
 _Alignas(16) unsigned char ext[0x40]={0},uv[0x40]={0},array[0x28]={0};
 v->current=(rect){150,120,64,48};v->source_w=64;v->source_h=48;
 v->current_alpha=0.5;v->texture=(void *)0x1000;
 *(rect *)(root+0x48)=*(rect *)(body+0x48)=(rect){0,0,64,48};
 root[0x24]=body[0x24]=255;*(u32 *)(root+0xc)=1U<<13;*(void **)(root+0x70)=body;
 *(void **)(body+0x68)=texture;texture[0xc]=0x24;*(void **)(texture+0x70)=v->texture;
 assert(rgba_view_render_matches(v,(void *)root,(void *)body));
 *(rect *)(body+0x48)=(rect){0,0,63,48};assert(!rgba_view_render_matches(v,(void *)root,(void *)body));
 *(rect *)(body+0x48)=*(rect *)(root+0x48);
 v->current.w=80;*(rect *)(body+0x48)=*(rect *)(root+0x48)=(rect){0,0,80,48};
 assert(!rgba_view_render_matches(v,(void *)root,(void *)body)); // Old identity UV is not committed B.
 *(void **)(body+0x88)=ext;*(void **)(ext+0x28)=uv;uv[0xc]=0x3e;*(u32 *)(uv+0x10)=4;
 *(double *)(uv+0x28)=1.25;*(double *)(uv+0x30)=1;
 assert(rgba_view_render_matches(v,(void *)root,(void *)body));
 *(u32 *)(root+0xc)=0;*(void **)(root+0x70)=array;
 array[0xc]=1;*(u32 *)(array+0x10)=1;*(void **)(array+0x18)=body;
 assert(rgba_view_render_matches(v,(void *)root,(void *)body));
 array[0xd]=1;assert(!rgba_view_render_matches(v,(void *)root,(void *)body));array[0xd]=0;
 body[0x24]=128;assert(!rgba_view_render_matches(v,(void *)root,(void *)body));body[0x24]=255;
 root[0x24]=128;body[0x24]=255;
 assert(!rgba_view_render_matches(v,(void *)root,(void *)body)); // Logical alpha must not attenuate the texture twice.
 root[0x24]=body[0x24]=255;
 v->current.h=64;*(rect *)(body+0x48)=*(rect *)(root+0x48)=(rect){0,0,80,64};
 assert(!rgba_view_render_matches(v,(void *)root,(void *)body)); // Old bottom-anchored UV.
 *(double *)(uv+0x20)=1-64.0/48.0;
 assert(rgba_view_render_matches(v,(void *)root,(void *)body));
 *(void **)(texture+0x70)=(void *)0x2000;assert(!rgba_view_render_matches(v,(void *)root,(void *)body));
 *(void **)(texture+0x70)=v->texture;
 // Snapshot/pop-in policy alone maps the whole frame to the animated box.
 v->presentation_mode=RGBA_VIEW_SNAPSHOT;
 assert(!rgba_view_render_matches(v,(void *)root,(void *)body));
 *(double *)(uv+0x20)=0;*(double *)(uv+0x28)=1;
 assert(rgba_view_render_matches(v,(void *)root,(void *)body));
 v->presentation_mode=RGBA_VIEW_ORDINARY;
 assert(!rgba_view_render_matches(v,(void *)root,(void *)body));
 v->presentation_mode=2;
 assert(!rgba_view_render_matches(v,(void *)root,(void *)body));
}
int main(void){
 failed_bind_allocation();refused_release();callback_boundary();capture_off_during_original();committed_fingerprint();
 puts("RGBA view failed-bind/refused-release/cohort/late-capture-OFF/committed-pixels custody PASS");return 0;
}
