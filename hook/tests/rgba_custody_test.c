// Fault/ownership contracts only. Native pixel/parity and actual CB submission
// require the separate one-OWN-window qualifier; these objects are CPU fakes.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>

struct fake_cb {u64 status;int refs;};
static struct rgba_capture g;
static struct ctx c;
static _Alignas(16) unsigned char metal[0x1520];
static void *renderer_cell;
static struct fake_cb clear_cb,draw_cb,texture;
static int flushes,finishes,root_releases,renderer_destroys,objc_releases;
static void *wrapped=(void *)0x1010,*client=(void *)0x1020;
static int is_main(void){return 1;}
static u64 status(void *obj,void *selector){assert(selector==(void *)1);return ((struct fake_cb *)obj)->status;}
static void *retain(void *obj){((struct fake_cb *)obj)->refs++;return obj;}
static void release(void *obj){assert(((struct fake_cb *)obj)->refs>0);((struct fake_cb *)obj)->refs--;objc_releases++;}
static void get_state(void *renderer,struct rgba_metal_state *s){
 assert(renderer==&renderer_cell);s->cb=*(void **)(metal+0xf00);s->owner=s->cb?metal:0;
 *(void **)(metal+0xf00)=0;
}
static void set_state(void *renderer,struct rgba_metal_state *s){
 assert(renderer==&renderer_cell && !*(void **)(metal+0xf00));*(void **)(metal+0xf00)=s->cb;
}
static void flush(void *m,int wait){
 assert(m==metal && wait==0);flushes++;*(void **)(metal+0xef8)=*(void **)(metal+0xf00);*(void **)(metal+0xf00)=0;
}
static void finish(void *u){assert(u==wrapped);finishes++;}
static void *assign_root(void **cell,void *root){assert(root==0 && *cell==client);*cell=0;root_releases++;return cell;}
static void destroy_renderer(void *r){assert(r==&renderer_cell && finishes==1 && root_releases==1);renderer_destroys++;}
static void reset(void){
 memset(&g,0,sizeof(g));memset(&c,0,sizeof(c));memset(metal,0,sizeof(metal));renderer_cell=metal;
 g.magic=RGBA_MAGIC;g.size=sizeof(g);g.version=RGBA_VERSION;
 g.pc.magic=PC_MAGIC;g.pc.size=sizeof(g.pc);g.pc.version=1;g.pc.engine=&c;g.pc.is_main=is_main;g.pc.status_selector=(void *)1;
 g.pc.retain_obj=retain;g.pc.release_obj=release;c.msg=(void *)status;
 g.renderer=&renderer_cell;g.metal=metal;g.clear_buffer=&clear_cb;g.clear_submitted=1;
 clear_cb=(struct fake_cb){4,1};draw_cb=(struct fake_cb){2,1};texture=(struct fake_cb){0,1};
 g.pc.texture_ref=&texture;g.pc.stage=PC_ENCODED;g.render_called=g.inclusion=1;
 g.api.get_state=get_state;g.api.set_state=set_state;g.api.flush=flush;
 g.api.finish_update=finish;g.api.assign_root=assign_root;g.api.destroy_renderer=destroy_renderer;
 g.update=wrapped;g.root=client;*(void **)(metal+0xf00)=&draw_cb;
 flushes=finishes=root_releases=renderer_destroys=objc_releases=0;
}
static void terminal_custody(void){
 reset();rgba_seal(&g);assert(flushes==1 && g.command_buffer_bound && g.pc.capture_witness && draw_cb.refs==2);
 rgba_seal(&g);assert(flushes==1 && draw_cb.refs==2); // No double transfer/submit.
 draw_cb.status=4;clear_cb.status=2;
 assert(anim_rgba_poll(&g)==0 && g.pc.stage==PC_ENCODED && g.pc.gpu_pending);
 assert(!anim_rgba_destroy(&g) && !finishes && !renderer_destroys && texture.refs==1);
 clear_cb.status=4;assert(anim_rgba_poll(&g)==4 && g.pc.stage==PC_GPU_COMPLETE);
 assert(anim_rgba_destroy(&g));
 assert(finishes==1 && root_releases==1 && renderer_destroys==1 && clear_cb.refs==0 && draw_cb.refs==1 && texture.refs==0);
 assert(anim_rgba_destroy(&g));assert(finishes==1 && root_releases==1 && renderer_destroys==1 && objc_releases==3);
}
static void gpu_error(void){
 reset();rgba_seal(&g);draw_cb.status=5;
 assert(anim_rgba_poll(&g)==5 && g.pc.stage==PC_GPU_ERROR && !g.pc.gpu_pending);
 assert(anim_rgba_destroy(&g) && finishes==1 && renderer_destroys==1);
 reset();rgba_seal(&g);draw_cb.status=4;clear_cb.status=5;
 assert(anim_rgba_poll(&g)==5 && g.pc.stage==PC_GPU_ERROR);
}
static void null_or_unsubmitted(void){
 reset();*(void **)(metal+0xf00)=0;rgba_seal(&g);
 assert(!g.pc.command_buffer && !g.pc.capture_witness && g.pc.reason==215 && !flushes);
 assert(anim_rgba_poll(&g)!=4 && g.pc.stage!=PC_GPU_COMPLETE);
 reset();*(void **)(metal+0x1338)=(void *)1;rgba_seal(&g);
 assert(!flushes && !g.pc.capture_witness && *(void **)(metal+0xf00)==&draw_cb);
 draw_cb.status=4;assert(!anim_rgba_poll(&g) && g.pc.gpu_pending && !anim_rgba_destroy(&g) && !finishes);
 reset();*(void **)(metal+0xfa0)=(void *)1;rgba_seal(&g);
 assert(!flushes && g.pc.reason==215 && !anim_rgba_destroy(&g));
 reset();g.clear_buffer=0;rgba_seal(&g);draw_cb.status=4;
 assert(!anim_rgba_poll(&g) && g.pc.gpu_pending && !anim_rgba_destroy(&g));
}
static void included_identity(void){
 _Alignas(16) char u[0x500]={0},a[0x20]={0},b[0x20]={0};u32 seq=0;
 *(void **)(u+0x140)=a;*(void **)(a+8)=wrapped;*(u32 *)(a+0x18)=31;
 *(void **)a=b;*(void **)(b+8)=client;*(u32 *)(b+0x18)=42;
 assert(rgba_included(u,wrapped,&seq) && seq==31);assert(rgba_included(u,client,&seq) && seq==42);
 *(void **)(b+8)=wrapped;assert(!rgba_included(u,wrapped,&seq));
 *(void **)(b+8)=client;*(void **)b=a;assert(!rgba_included(u,wrapped,&seq));
 *(void **)b=0;assert(!rgba_included(u,(void *)0x1030,&seq));
}
static void bound_surface_quarantine(void){
 reset();rgba_seal(&g);draw_cb.status=4;
 *(void **)(metal+0x2d8)=(void *)0x1040;
 assert(!anim_rgba_destroy(&g) && !finishes && !root_releases && !renderer_destroys);
 *(void **)(metal+0x2d8)=0;
 assert(anim_rgba_destroy(&g) && finishes==1 && renderer_destroys==1);
}
static void distinct_latest_submission(void){
 struct fake_cb latest={2,1};
 reset();rgba_seal(&g);draw_cb.status=4;
 *(void **)(metal+0xef8)=&latest;
 // A late identity mismatch revokes an earlier witness permanently.
 assert(!anim_rgba_poll(&g) && g.pc.gpu_pending && g.pc.stage==PC_ENCODED);
 assert(!g.command_buffer_bound && !g.pc.capture_witness && g.pc.reason==215);
 assert(!anim_rgba_destroy(&g) && !finishes && !renderer_destroys);
 latest.status=0;
 assert(!anim_rgba_poll(&g) && !anim_rgba_destroy(&g));
 latest.status=4;
 assert(anim_rgba_poll(&g)!=4 && g.pc.stage!=PC_GPU_COMPLETE);
 assert(anim_rgba_destroy(&g) && finishes==1 && renderer_destroys==1);
 reset();rgba_seal(&g);draw_cb.status=4;latest.status=5;
 *(void **)(metal+0xef8)=&latest;
 assert(anim_rgba_poll(&g)==5 && g.pc.stage==PC_GPU_ERROR && !g.pc.gpu_pending);
 assert(anim_rgba_destroy(&g) && finishes==1 && renderer_destroys==1);
}
static void nested_client_cohort(void){
 _Alignas(16) char normal[0x150]={0},own[0x150]={0},n[3][0x20]={{0}},o[2][0x20]={{0}};
 reset();g.pc.update=(u64)normal;g.update=own;
 *(void **)(normal+0x140)=n[0];*(void **)(own+0x140)=o[0];
 for(unsigned i=0;i<3;i++) {
  *(void **)(n[i]+8)=(void *)(0x1000UL+i*0x10);*(u32 *)(n[i]+0x18)=31+i;
  if(i<2)*(void **)n[i]=n[i+1];
 }
 for(unsigned i=0;i<2;i++) {
  *(void **)(o[i]+8)=*(void **)(n[i+1]+8);*(u32 *)(o[i]+0x18)=32+i;
  if(i<1)*(void **)o[i]=o[i+1];
 }
 assert(rgba_client_cohort(&g) && g.cohort_contexts==2);
 *(u32 *)(o[1]+0x18)=34;assert(!rgba_client_cohort(&g));*(u32 *)(o[1]+0x18)=33;
 *(void **)(o[1]+8)=(void *)0x2000;assert(!rgba_client_cohort(&g));
 *(void **)(o[1]+8)=*(void **)(o[0]+8);*(u32 *)(o[1]+0x18)=32;
 assert(!rgba_client_cohort(&g));
 *(void **)(o[1]+8)=(void *)0x1020;*(u32 *)(o[1]+0x18)=33;*(void **)o[1]=o[0];
 assert(!rgba_client_cohort(&g));
}
static void model_clock_witness(void){
 _Alignas(16) char normal[0x150]={0},own[0x150]={0},contexts[3][0x290]={{0}},n[3][0x20]={{0}},o[2][0x20]={{0}};
 struct rgba_model_clock clocks[256];u32 count=0;struct rgba_model_control model_control={0};
 reset();g.pc.update=(u64)normal;g.update=own;g.model=&model_control;
 *(void **)(normal+0x140)=n[0];*(void **)(own+0x140)=o[0];
 for(unsigned i=0;i<3;i++) {
  *(void **)(n[i]+8)=contexts[i];*(u32 *)(n[i]+0x18)=31+i;
  *(double *)(contexts[i]+0x288)=17.25+i;if(i<2)*(void **)n[i]=n[i+1];
 }
 for(unsigned i=0;i<2;i++) {
  *(void **)(o[i]+8)=contexts[i+1];*(u32 *)(o[i]+0x18)=32+i;if(i<1)*(void **)o[i]=o[i+1];
 }
 assert(rgba_model_clocks(normal,clocks,&count)&&count==3);
 assert(rgba_model_clock_proof(&g,clocks,count)&&model_control.clock_contexts==2);
 // Both lists still point at the SAME mutable Context. A post-OWN read from
 // each list would agree tautologically; the pre-OWN copied scalar must fail.
 *(double *)(contexts[2]+0x288)+=.125;assert(!rgba_model_clock_proof(&g,clocks,count));
 *(double *)(contexts[2]+0x288)-=.125;(*(u32 *)(o[1]+0x18))++;
 assert(!rgba_model_clock_proof(&g,clocks,count));(*(u32 *)(o[1]+0x18))--;
 *(void **)n[2]=n[0];assert(!rgba_model_clocks(normal,clocks,&count));*(void **)n[2]=0;
 *(void **)(n[2]+8)=contexts[0];assert(!rgba_model_clocks(normal,clocks,&count));
}
static void model_root_copy_witness(void){
 _Alignas(16) char update[0x150]={0},nodes[2][0x30]={{0}};void *copy=(void *)0x8010;
 char *head=update+0xd8;*(void **)head=nodes[0];*(void **)(head+8)=nodes[0];
 *(void **)nodes[0]=head;*(void **)(nodes[0]+8)=head;*(void **)(nodes[0]+0x20)=copy;
 assert(rgba_model_root_node(update,copy));assert(!rgba_model_root_node(update,(void *)0x8020));
 *(void **)nodes[0]=nodes[1];*(void **)(nodes[1]+8)=nodes[0];*(void **)nodes[1]=head;
 *(void **)(head+8)=nodes[1];*(void **)(nodes[1]+0x20)=copy;assert(!rgba_model_root_node(update,copy));
 *(void **)(nodes[1]+0x20)=0;assert(rgba_model_root_node(update,copy));
 *(void **)nodes[1]=nodes[0];assert(!rgba_model_root_node(update,copy));
 *(void **)nodes[1]=head;*(void **)(nodes[1]+8)=head;assert(!rgba_model_root_node(update,copy));
}
static void *lookup_result;
static void *lookup(void *context,u64 id,u32 seed,int create,u32 *out){
 assert(context==(void *)0x9010&&id==71&&!seed&&!create&&out);*out=9;return lookup_result;
}
static void model_lookup_identity(void){
 _Alignas(16) char handle[0x30]={0},layer[0xa0]={0};struct rgba_model_control control={0};control.lookup_handle=lookup;
 lookup_result=handle;*(void **)(handle+0x18)=(void *)0x9010;*(void **)(handle+0x10)=layer;*(void **)(layer+0x98)=handle;
 assert(rgba_model_lookup(&control,(void *)0x9010,71)==layer);
 assert(!rgba_model_lookup(&control,(void *)0x9010,0));
 *(void **)(handle+0x18)=(void *)0x9020;assert(!rgba_model_lookup(&control,(void *)0x9010,71));
 *(void **)(handle+0x18)=(void *)0x9010;*(void **)(layer+0x98)=0;assert(!rgba_model_lookup(&control,(void *)0x9010,71));
 *(void **)(handle+0x10)=0;assert(!rgba_model_lookup(&control,(void *)0x9010,71));
 lookup_result=0;assert(!rgba_model_lookup(&control,(void *)0x9010,71));
}
static _Alignas(16) char retry_source[0x940],retry_owner[0x270],retry_control[0x28],retry_update[0x500];
static struct ch retry_channel;
static void *retry_control_ptr;
static void *retry_byid(u32 wid){return wid==99?retry_source:0;}
static void retry_finish(void *u){assert(u==retry_update);finishes++;}
static void retry_setup(void){
 reset();memset(retry_source,0,sizeof(retry_source));memset(retry_owner,0,sizeof(retry_owner));
 memset(retry_control,0,sizeof(retry_control));memset(retry_update,0,sizeof(retry_update));memset(&retry_channel,0,sizeof(retry_channel));
 g.content_mode=RGBA_CLIENT_DOMAIN_MODE;g.renderer=g.metal=g.queue=g.device=g.clear_buffer=g.root=0;
 g.clear_submitted=g.render_called=g.inclusion=0;g.pc.texture_ref=g.pc.command_buffer=0;
 g.update=retry_update;g.api.finish_update=retry_finish;
 g.pc.stage=PC_INVALID;g.pc.reason=234;g.client_reason=235;
 g.pc.source_unchanged=g.pc.present_unchanged=1;
 g.pc.source=(u64)retry_source;g.pc.creator=(u64)retry_owner;g.pc.pid_version=77;g.pc.wid=99;
 *(u32 *)retry_source=99;*(u32 *)(retry_source+4)=5;*(void **)(retry_source+0x30)=retry_owner;
 *(u64 *)(retry_owner+0x268)=77;*(u64 *)(retry_source+0x928)=1ULL<<44;
 c.by_id=retry_byid;c.ch=&retry_channel;c.session=(void *)0x8888;
 retry_channel.h.magic=CH_MAGIC;retry_channel.h.size=sizeof(retry_channel);
 retry_control_ptr=retry_control;g.pc.session_control=&retry_control_ptr;*(void **)(retry_control+0x20)=c.session;
 struct ch_win *w=slot(&retry_channel,99,1);w->geo=1;
 g.pc.capture_rect=(rect){100,40,400,300};w->pos.v[0]=100;w->pos.v[1]=40;w->size.v[0]=400;w->size.v[1]=300;
 *(u64 *)(retry_update+0x4e8)=(1ULL<<21)|4;
}
static void overtaken_client_retry(void){
 retry_setup();g.pc.update=g.pc.update_after=123;g.pc.client_context=456;g.pc.client_included=1;
 assert(anim_rgba_poll(&g)==0 && finishes==1 && !g.update && g.pc.stage==PC_ARMED);
 assert(!g.pc.reason && !g.client_reason && !g.pc.client_context && !g.pc.update && !g.pc.client_included);
 assert(!g.pc.gpu_pending && !g.pc.source_unchanged && !g.pc.present_unchanged);
 assert(anim_rgba_poll(&g)==1 && finishes==1); // One empty attempt is disposed once.
 assert(anim_rgba_destroy(&g) && g.destroyed && g.pc.dead && finishes==1);
 // A copied root, an added-context list/count, or missing skip-backdrop policy
 // cannot be mistaken for the pre-copy empty attempt.
 for(unsigned fault=0;fault<10;fault++){
  retry_setup();
  if(fault==0)g.root=client;
  if(fault==1)*(void **)(retry_update+0x140)=client;
  if(fault==2)*(u64 *)(retry_update+0x2c0)=1;
  if(fault==3)*(u64 *)(retry_update+0x4e8)=0;
  if(fault==4)*(u64 *)(retry_owner+0x268)=78;
  if(fault==5)g.pc.depth_after=1;
  if(fault==6)g.pc.reason=206;
  if(fault==7)*(void **)(retry_update+0x280)=client;
  if(fault==8)*(void **)(retry_update+0x468)=client;
  if(fault==9)*(u64 *)(retry_update+0x4e8)=1ULL<<21;
  assert(anim_rgba_poll(&g)==1 && !finishes && g.update==retry_update && g.pc.stage==PC_INVALID);
 }
 retry_setup();g.clear_buffer=&clear_cb;g.clear_submitted=1;clear_cb.status=2;
 assert(anim_rgba_poll(&g)==0 && g.pc.gpu_pending && !finishes && g.update==retry_update);
}
int main(void){
 terminal_custody();gpu_error();null_or_unsubmitted();included_identity();bound_surface_quarantine();distinct_latest_submission();nested_client_cohort();model_clock_witness();model_root_copy_witness();model_lookup_identity();overtaken_client_retry();
 puts("RGBA terminal/error/NULL/unsubmitted/private-wait/identity custody and MODEL pre-OWN clock/exact copied root witnesses PASS");return 0;
}
