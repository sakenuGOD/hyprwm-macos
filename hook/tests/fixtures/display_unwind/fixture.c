// Synthetic data and callbacks only. The actual product C bodies compile below.
// No window server, CA, native window, task port, or external process is used.
#ifndef DISPLAY_UNWIND_TEST_PRODUCT_C
#define DISPLAY_UNWIND_TEST_PRODUCT_C "../../../src/anim4.c"
#endif
#include DISPLAY_UNWIND_TEST_PRODUCT_C
#include "fixture.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
_Static_assert(DISPLAY_VISIBILITY_VERSION==2,"expected policy-qualified v2");
_Static_assert(sizeof(struct display_visibility)==320,"Visibility ABI320");
_Static_assert(__builtin_offsetof(struct display_visibility,get_boolean)==304,"getter304");
_Static_assert(__builtin_offsetof(struct display_visibility,fade_on_order_out_key)==312,"key312");
struct OwnCase {
 struct display_pair pair;
 struct ctx *engine;void *engine_arena;
 struct ch channel;
 struct display_source_sink sink;
 struct display_transition transition;
 struct display_damage_command command;
 struct rgba_capture capture;
 struct rgba_view view;
 _Alignas(16) char windows[2][0xa00],cwcs[2][0x600],creator[0x300],control[64];
 _Alignas(16) char sources[2][0x280],descriptors[2][0x40];
 _Alignas(16) char session[0x200],scheduler[0x180],display[0x800],compositor[64];
 void *control_ptr,*vector[2],*args[8],*region,*dirty;
 struct display_unwind_bridge du;
 void *source_entry,*source_original;unsigned source_returned;
 int shape,vtable,mctx;
 struct OwnCallbacks callbacks;
 struct display_visibility visibility;
 struct display_visibility_command visibility_command;
 unsigned policy_case;
 int policy_dictionary,policy_key;
 char A_window[0xa00],A_cwc[0x600],A_creator[0x300];
 int A_shape;
 rect A_bounds;
 void (*order_callback)(unsigned,void *,unsigned long,void *);
 u64 order_callbacks;
};
static struct OwnCase *active;
static void *own_by_id(u32 wid) {
 if(active && active->source_returned && active->du.entry_inflight[DU_SOURCE] && active->callbacks.source_observer)
  active->callbacks.source_observer();
 return active && wid>=0x7fff0001U && wid<=0x7fff0002U?active->windows[wid-0x7fff0001U]:0;
}
static void *own_lookup(const char *name){assert(name);return (void *)1;}
static u32 own_state(void *cls,void *sel){assert(cls && sel);return 0;}
static rect own_bbox(void *shape){
 assert(active && (shape==&active->shape || shape==active->region || shape==&active->A_shape));
 if(shape==&active->A_shape)return active->A_bounds;
 rect r=active->transition.footprint;
 if(shape==active->region){
  assert(active->visibility.region==active->region && active->visibility.phase==DISPLAY_VISIBILITY_PREPARING);
  active->callbacks.region_bbox();
 }
 return r;
}
static void *own_rgn(rect r){
 assert(active && active->visibility.phase==DISPLAY_VISIBILITY_PREPARING && !active->visibility.region);
 assert(rgba_view_same(r,active->transition.footprint));active->callbacks.prepare();
 return active->region;
}
static float own_alpha(void *window){
 assert(active && window==active->windows[1]);active->callbacks.getter(active->visibility.phase);
 return *(float *)(active->windows[1]+0x1d8);
}
static int own_policy(void *dictionary,const void *key,unsigned char *value){
 assert(active && dictionary==&active->policy_dictionary && key==&active->policy_key && value && *value==0xa5);
 unsigned phase=active->visibility.phase;
 assert(phase==DISPLAY_VISIBILITY_CHECKING || phase==DISPLAY_VISIBILITY_APPLYING || phase==DISPLAY_VISIBILITY_REVOKING);
 active->callbacks.policy(phase,0);
 int present=1;
 switch(active->policy_case){
  case 0:present=0;break; // Missing/non-Boolean: output deliberately untouched.
  case 1:*value=0;break;



  default:assert(0);
 }
 active->callbacks.policy(phase,1);
 return present;
}
static void own_native_alpha(void *connection,void *w,float a,float duration){
 assert(active && !connection && !duration && w==active->windows[1] && !active->engine->in_cb);
 assert(active->visibility.phase==DISPLAY_VISIBILITY_APPLYING);
 active->callbacks.alpha(a,0);
 {
  *(float *)(active->windows[1]+0x1d8)=*(float *)(active->windows[1]+0x1e4)=a;
  *(float *)(active->cwcs[1]+0x174)=a;
 }
 active->callbacks.alpha(a,1);
}
static int own_native_order(void *connection,u32 wid,int order,u32 relative){
 assert(active && !connection && wid==0x7fff0002U && !order && !relative && !active->engine->in_cb);
 assert(active->visibility.phase==DISPLAY_VISIBILITY_REVOKING);
 active->callbacks.order(0);
 {
  assert(active->order_callback);active->order_callbacks++;
  active->order_callback(0x3ea,0,0,active->engine);
  assert(!active->engine->in_cb);
  *(u64 *)(active->windows[1]+0x928)&=~(1ULL<<44);
 }
 active->callbacks.order(1);return 0;
}
static u32 own_native_display(void *w){assert(active && w==active->windows[1]);return active->view.display;}
OwnCase *own_case_new(const struct OwnCallbacks *cb,u64 caller,const u64 cohort[5],const u64 updates[2]) {
 struct OwnCase *c=calloc(1,sizeof(*c));assert(c);active=c;
 c->callbacks=*cb;
 c->engine_arena=mmap(0,0x4000,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(c->engine_arena!=MAP_FAILED);c->engine=c->engine_arena;
 c->region=mmap(0,16384,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(c->region!=MAP_FAILED);
 c->dirty=mmap(0,16384,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(c->dirty!=MAP_FAILED);
 *(unsigned *)c->region=0x5245474e;*(unsigned *)c->dirty=0x44495254;
 struct display_pair *p=&c->pair;struct ctx *e=c->engine;
 e->ch=&c->channel;e->session=c->session;e->by_id=own_by_id;
 e->cls=own_lookup;e->sel=own_lookup;e->msg=(void *)own_state;
 e->shape_off=0x170;e->bbox=own_bbox;e->set_alpha=own_native_alpha;e->rgn=own_rgn;
 c->channel.h.magic=CH_MAGIC;c->channel.h.size=sizeof(c->channel);
 c->channel.h.reserved[0]=1;
 c->channel.win[0].used=1;c->channel.win[0].geo=1;c->channel.win[0].wid=0x7fff0001U;
 c->control_ptr=c->control;*(void **)(c->control+0x20)=c->session;
 *(void **)(c->session+0x138)=c->scheduler;
 p->magic=DISPLAY_PAIR_MAGIC;p->size=sizeof(*p);p->version=1;
 p->probe.magic=DISPLAY_PROBE_MAGIC;p->probe.size=sizeof(p->probe);p->probe.version=1;
 p->probe.engine=e;p->probe.is_main=cb->is_main;p->probe.enabled=1;p->probe.callers[0]=caller;
 p->thread_self=cb->thread_self;p->stack_top=cb->stack_top;p->stack_size=cb->stack_size;
 p->session_control=&c->control_ptr;p->session=c->session;p->channel=&c->channel;
 p->enabled=p->layout_verified=1;p->revision=17;
 memcpy(p->cohort_pc,cohort,sizeof(p->cohort_pc));memcpy(p->update_return,updates,sizeof(p->update_return));
 *(u64 *)(c->creator+0x268)=0x100000023ULL;
 for(unsigned i=0;i<2;i++) {
  char *w=c->windows[i],*s=c->sources[i],*q=c->descriptors[i];
  *(u32 *)w=0x7fff0001U+i;*(u32 *)(w+4)=5;*(void **)(w+0x18)=c->cwcs[i];
  *(void **)(w+0x30)=i?0:c->creator;
  p->identity[i]=(struct display_pair_identity){.window=(u64)w,.creator=i?0:(u64)c->creator,
   .pid_version=i?0:*(u64 *)(c->creator+0x268),.wid=0x7fff0001U+i};
  if(i){p->identity[i].local_context=0x99000;p->identity[i].client_id=345;
   *(u64 *)(c->cwcs[i]+0x58)=0x99000;*(u32 *)(c->cwcs[i]+0x50)=345;}
  *(u32 *)(c->cwcs[i]+0x40)=91+i;*(u32 *)(s+0x180)=10;*(u32 *)(s+0x268)=0x7fff0001U+i;
  *(void **)(s+0x48)=q;*(void **)q=w;*(u64 *)(q+0x10)=0x80000+0x100*i;
  *(u64 *)(s+0x28)=*(u64 *)(s+0x30)=*(u64 *)(q+0x10);*(u32 *)(q+0x28)=91+i;
  *(rect *)(s+0xc8)=(rect){0,0,480,300};*(float *)(s+0x188)=1;*(float *)(s+0x18c)=1;
 }
 struct display_source_sink *q=&c->sink;
 q->magic=DISPLAY_SOURCE_SINK_MAGIC;q->size=sizeof(*q);q->version=1;q->profile_verified=q->a_unfenced=1;
 q->source.magic=DISPLAY_SOURCE_MAGIC;q->source.size=sizeof(q->source);q->source.version=1;
 q->source.pair=p;q->source.enabled=1;
 struct rgba_capture *g=&c->capture;
 g->magic=RGBA_MAGIC;g->size=sizeof(*g);g->version=RGBA_VERSION;
 g->pc.magic=PC_MAGIC;g->pc.size=sizeof(g->pc);g->pc.version=1;g->pc.engine=e;
 g->pc.is_main=cb->is_main;g->pc.thread_self=cb->thread_self;g->pc.stack_top=cb->stack_top;g->pc.stack_size=cb->stack_size;
 memcpy(g->pc.cohort_pc,cohort,sizeof(g->pc.cohort_pc));
 g->pc.source=p->identity[0].window;g->pc.wid=p->identity[0].wid;
 g->pc.creator=p->identity[0].creator;g->pc.pid_version=p->identity[0].pid_version;
 g->pc.capture_witness=1;g->pc.stage=3;g->pc.gpu_status=g->clear_status=4;g->pc.texture_ref=(void *)0x777;
 struct rgba_view *v=&c->view;
 v->magic=RGBA_VIEW_MAGIC;v->size=sizeof(*v);v->version=RGBA_VIEW_VERSION;v->capture=g;
 v->window=c->windows[1];v->wid=0x7fff0002U;v->context=(void *)p->identity[1].local_context;v->context_id=p->identity[1].client_id;
 v->bound=v->prepared=v->shown=1;v->api.effective_alpha=own_alpha;v->current_alpha=v->alpha=1;
 v->api.order=own_native_order;v->api.display_id=own_native_display;
 v->source_wid=g->pc.wid;v->source_creator=g->pc.creator;v->source_pid_version=g->pc.pid_version;v->texture=g->pc.texture_ref;
 v->current=v->target=(rect){538,318,720,446};v->display_bounds=(rect){0,0,1470,956};v->display=77;
 *(u64 *)(c->windows[1]+0x928)=(1ULL<<44)|(1ULL<<23);
 *(void **)(c->windows[1]+0x88)=&c->policy_dictionary;
 *(u64 *)(c->windows[0]+0x928)=1ULL<<44;P8_ON(e)[0]=1;
 *(float *)(c->windows[1]+0x1d8)=*(float *)(c->windows[1]+0x1dc)=1;
 *(float *)(c->windows[1]+0x1e0)=*(float *)(c->windows[1]+0x1e4)=1;
 *(float *)(c->cwcs[1]+0x174)=1;
 *(void **)(c->windows[1]+0x170)=&c->shape;
 *(void **)(c->windows[0]+0x170)=&c->A_shape;
 c->A_bounds=(rect){738,498,720,446};g->pc.capture_rect=c->A_bounds;
 struct display_transition *t=&c->transition;
 t->magic=DISPLAY_TRANSITION_MAGIC;t->size=sizeof(*t);t->version=1;t->sink=q;t->view=v;t->scheduler=c->scheduler;
 t->display_vtable=&c->vtable;t->footprint=v->current;t->display_bounds=v->display_bounds;t->display=77;
 t->contains=cb->contains;t->capture_witness=1;
 t->damage.magic=DISPLAY_DAMAGE_MAGIC;t->damage.size=sizeof(t->damage);t->damage.version=1;t->damage.enabled=1;
 t->damage.invalidate=cb->invalidate;t->damage.command=&c->command;
 c->command.magic=DISPLAY_DAMAGE_COMMAND_MAGIC;c->command.size=sizeof(c->command);c->command.version=1;c->command.request=2;
 *(void **)c->display=&c->vtable;*(u32 *)(c->display+0x1e8)=77;
 *(rect *)(c->display+0x240)=v->display_bounds;*(float *)(c->display+0x53c)=2;
 const double matrices[4][6]={{2,0,0,2,0,0},{.5,0,0,.5,0,0},{1,0,0,1,0,0},{1,0,0,1,0,0}};
 const unsigned offsets[4]={0x330,0x360,0x390,0x3c0};
 for(unsigned i=0;i<4;i++)memcpy(c->display+offsets[i],matrices[i],sizeof(matrices[i]));
 c->vector[0]=c->display;
 struct display_visibility *vis=&c->visibility;
 vis->magic=DISPLAY_VISIBILITY_MAGIC;vis->size=sizeof(*vis);vis->version=DISPLAY_VISIBILITY_VERSION;
 vis->sink=q;vis->view=v;vis->command=&c->visibility_command;vis->invalidate=cb->invalidate;
 vis->get_boolean=own_policy;vis->fade_on_order_out_key=&c->policy_key;
 vis->profile=t;vis->footprint=v->current;vis->capture_witness=1;vis->enabled=1;
 c->visibility_command.magic=DISPLAY_VISIBILITY_COMMAND_MAGIC;c->visibility_command.size=sizeof(c->visibility_command);
 c->visibility_command.version=1;c->visibility_command.request=4;
 c->du.magic=DU_MAGIC;c->du.size=sizeof(c->du);c->du.version=1;c->du.generation=0x102030405ULL;
 c->du.pair=p;c->du.sink=q;c->du.visibility=vis;c->du.enabled=1;

 memcpy(c->A_window,c->windows[0],sizeof(c->A_window));memcpy(c->A_cwc,c->cwcs[0],sizeof(c->A_cwc));memcpy(c->A_creator,c->creator,sizeof(c->A_creator));
 return c;
}

void *own_case_vector(OwnCase *c){return c->vector;}
void *own_case_vector_end(OwnCase *c){return c->vector+2;}
void *own_case_region(OwnCase *c){return c->region;}
void *own_case_dirty(OwnCase *c){return c->dirty;}
void own_case_request(OwnCase *c,u64 w){__atomic_store_n(&c->visibility_command.request,w,__ATOMIC_RELEASE);}

void **own_case_prepare_frame(OwnCase *c,u64 fp){
 assert(active==c && !(fp&15));char *r=(char *)(fp-0xb40);memset(r,0,0xb8);
 *(void **)r=c->compositor;*(void **)(c->compositor+0x10)=&c->mctx;*(void **)(r+0x58)=c->dirty;
 *(void **)(fp-0xb88)=c->sources[0];
 *(void **)c->sources[0]=(*(u64 *)(c->windows[1]+0x928)&(1ULL<<44))?c->sources[1]:0;
 // SourceItem local alpha is independent of native window/CWC alpha.
 // Preserve its OWN initialized value across every native visibility change.
 *(void **)(fp-0x100)=c->display;
 c->source_returned=0;
 c->args[4]=c->windows[1];c->args[5]=&c->du;c->args[6]=c->source_original;c->args[7]=c->source_entry;
 c->args[0]=&c->mctx;c->args[1]=(void *)(fp-0x100);c->args[2]=0;c->args[3]=&c->du;
 return c->args;
}

void *own_case_engine(OwnCase *c){return c->engine;}

void own_case_assert_A(OwnCase *c){
 assert(!memcmp(c->A_window,c->windows[0],sizeof(c->A_window)));
 assert(!memcmp(c->A_cwc,c->cwcs[0],sizeof(c->A_cwc)));
 assert(!memcmp(c->A_creator,c->creator,sizeof(c->A_creator)));
}
void own_case_visibility_snapshot(OwnCase *c,struct OwnVisibilitySnapshot *o){
 memset(o,0,sizeof(*o));struct display_visibility *v=&c->visibility;
 o->completed=c->visibility_command.completed;o->constructed=c->visibility_command.constructed;o->committed=v->committed;
 o->inflight=v->inflight;o->pair_inflight=c->pair.probe.inflight;o->source_inflight=c->sink.source.inflight;o->timer_inflight=v->timer_inflight;o->workspace_phase=c->sink.workspace.phase;
}

void own_case_policy(OwnCase *c,unsigned policy){assert(policy<=1);c->policy_case=policy;}

float own_case_local_alpha(OwnCase *c){return *(float *)(c->sources[1]+0x188);}

_Static_assert(sizeof(struct display_unwind_bridge)==272,"DU bridge272");
_Static_assert(sizeof(struct du_local)==160,"DU local160");
void *own_case_unwind(OwnCase *c){return &c->du;}
void own_case_du_enabled(OwnCase *c,unsigned enabled){c->du.enabled=enabled;}
void own_case_source_binding(OwnCase *c,void *entry,void *original){c->source_entry=entry;c->source_original=original;}
void *own_case_B_window(OwnCase *c){return c->windows[1];}
void own_case_source_returned(OwnCase *c,unsigned value){c->source_returned=value;}
void own_case_workspace_sentinel(OwnCase *c){c->sink.workspace.phase=3;c->sink.workspace.head=c->region;}
void own_case_du_poison(OwnCase *c){assert(!mprotect(c->region,16384,PROT_NONE));assert(!mprotect(c->dirty,16384,PROT_NONE));}
void own_case_host_order(OwnCase *c){c->order_callback=(void *)anim_will_release;}
void own_case_role_storage(OwnCase *c,u64 *out[4][3]){
 out[DU_PROBE][0]=&c->pair.probe.entered;out[DU_PROBE][1]=&c->pair.probe.returned;out[DU_PROBE][2]=&c->pair.probe.inflight;
 out[DU_SOURCE_ROLE][0]=&c->sink.source.entered;out[DU_SOURCE_ROLE][1]=&c->sink.source.returned;out[DU_SOURCE_ROLE][2]=&c->sink.source.inflight;
 out[DU_VIS_ENTRY][0]=&c->visibility.entered;out[DU_VIS_ENTRY][1]=&c->visibility.returned;out[DU_VIS_ENTRY][2]=&c->visibility.inflight;
 out[DU_VIS_TIMER][0]=&c->visibility.timer_entered;out[DU_VIS_TIMER][1]=&c->visibility.timer_returned;out[DU_VIS_TIMER][2]=&c->visibility.timer_inflight;
}

void own_case_source_return_address(OwnCase *c,u64 address){c->sink.source.normal_return=address;}

void *own_case_workspace_head(OwnCase *c){return c->sink.workspace.head;}
