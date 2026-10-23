#include "../../src/anim4.c"
#include "fixture-api.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
static struct display_private_source trial;
static struct display_source_sink sink;
static struct display_pair pair;
static struct display_visibility visibility;
static struct ctx engine;
static struct ch channel;
static _Alignas(16) unsigned char windows[2][0xa00],cwcs[2][0x600],creator[0x300];
static _Alignas(16) unsigned char node[0x280],descriptor[0x40],update[16],session_control[64];
static void *session_pointer=session_control;
static int old_ref,new_ref,enum_ref,head_frees,normal_verified,case_kind;
static unsigned calls[32],target,mode,original_private,original_normal;
static unsigned char expected_redraw[0xb8];
static void*normal_redraw,*normal_head;

static void hit(unsigned id){calls[id]++;fixture_fault(id);}
static int is_main(void){hit(trial.active_call);return case_kind==4?0:1;}
static void*thread_self(void){hit(trial.active_call);return pthread_self();}
static void*stack_top(void*t){hit(trial.active_call);return pthread_get_stackaddr_np(t);}
static u64 stack_size(void*t){hit(trial.active_call);return pthread_get_stacksize_np(t);}
static void*by_id(u32 id){unsigned idcall=trial.active_call;hit(idcall);
 if(mode==2&&target==idcall)return (void*)1; /* poison must not be dereferenced */
 return id==41?windows[0]:id==42?windows[1]:0;
}
static u64 mabs(void){hit(trial.active_call);return 1234;}
static void*retain_mock(void*p){assert(p==&old_ref);old_ref++;hit(PS_CALL_RETAIN);return p;}
static void free_mock(void*p){assert(p==node&&!sink.workspace.head);head_frees++;hit(PS_CALL_FREE_LAYERS);}
static void release_mock(void*p){assert(p==&new_ref&&!display_sink_get(sink.workspace.redraw,0x60));new_ref--;hit(PS_CALL_RELEASE_OPAQUE);}
static void enum_mock(void*p){assert(p==&enum_ref&&!display_sink_get(sink.workspace.redraw,0x68));enum_ref--;hit(PS_CALL_RELEASE_ENUMERATOR);}
int fixture_original(void*r,void*w){assert(w==windows[1]);
 if(r!=sink.workspace.redraw){original_normal++;assert(r==normal_redraw);return -191;}
 original_private++;assert(sink.workspace.phase==DISPLAY_SINK_GENERATE);
 if(display_sink_get(r,0x60))old_ref--;display_sink_put(r,0x60,&new_ref);
 if(case_kind!=8)display_sink_put(r,0x68,&enum_ref);
 if(case_kind!=9)*(void**)display_sink_get(r,0x78)=node;hit(PS_CALL_GENERATE);return 17;
}
int fixture_nested_throw(void*r,void*w){(void)r;(void)w;return 0;}
struct display_private_source*fixture_trial(void){return &trial;}
void*fixture_window(void){return windows[1];}
void fixture_set_case(unsigned c){case_kind=c;
 if(c==1)trial.enabled=0;
 if(c==2)trial.bridge.enabled=0;
 if(c==3)sink.source.normal_return+=4;
 if(c==5){sink.source.entered=1;sink.source.inflight=1;}
 if(c==6){sink.workspace.phase=DISPLAY_SINK_GENERATE;sink.workspace.head=node;}
 if(c==11)trial.revision++;
}
int fixture_state_call(void){return trial.active_call;}
void fixture_reset(unsigned f,unsigned m){
 memset(&trial,0,sizeof(trial));memset(&sink,0,sizeof(sink));memset(&pair,0,sizeof(pair));
 memset(&visibility,0,sizeof(visibility));memset(&engine,0,sizeof(engine));memset(&channel,0,sizeof(channel));
 memset(windows,0,sizeof(windows));memset(cwcs,0,sizeof(cwcs));memset(creator,0,sizeof(creator));
 memset(node,0,sizeof(node));memset(descriptor,0,sizeof(descriptor));memset(session_control,0,sizeof(session_control));
 memset(calls,0,sizeof(calls));old_ref=1;new_ref=1;enum_ref=1;head_frees=0;normal_verified=0;case_kind=0;
 target=f;mode=m;original_private=0;original_normal=0;
 engine.ch=&channel;engine.session=(void*)0x4000;engine.by_id=by_id;engine.mabs=mabs;
 channel.h.magic=CH_MAGIC;channel.h.size=sizeof(channel);*(void**)(session_control+0x20)=engine.session;
 pair.magic=DISPLAY_PAIR_MAGIC;pair.size=sizeof(pair);pair.version=1;pair.enabled=1;pair.layout_verified=1;
 pair.session_control=&session_pointer;pair.session=engine.session;pair.channel=&channel;
 pair.thread_self=thread_self;pair.stack_top=stack_top;pair.stack_size=stack_size;
 pair.probe.magic=DISPLAY_PROBE_MAGIC;pair.probe.size=sizeof(pair.probe);pair.probe.version=1;
 pair.probe.engine=&engine;pair.probe.is_main=is_main;pair.probe.entered=1;pair.probe.inflight=1;
 pair.active_epoch=11;pair.active_revision=7;
 *(u64*)(creator+0x268)=123;
 for(unsigned i=0;i<2;i++){
  *(u32*)windows[i]=41+i;*(u32*)(windows[i]+4)=5;*(void**)(windows[i]+0x18)=cwcs[i];
  *(void**)(windows[i]+0x30)=i?0:creator;
  pair.identity[i].window=(u64)windows[i];pair.identity[i].wid=41+i;
  pair.identity[i].creator=i?0:(u64)creator;pair.identity[i].pid_version=i?0:123;
  if(i){pair.identity[i].local_context=0x5511;pair.identity[i].client_id=91;
   *(u64*)(cwcs[i]+0x58)=0x5511;*(u32*)(cwcs[i]+0x50)=91;}
 }
 *(u32*)(cwcs[1]+0x40)=77;*(void**)descriptor=windows[1];*(void**)(descriptor+0x10)=update;
 *(u32*)(descriptor+0x28)=77;*(void**)(node+0x48)=descriptor;
 *(void**)(node+0x28)=update;*(void**)(node+0x30)=update;*(u32*)(node+0x180)=10;
 *(u32*)(node+0x268)=42;*(rect*)(node+0xc8)=(rect){0,0,480,300};
 *(float*)(node+0x188)=1;*(float*)(node+0x18c)=1;
 sink.magic=DISPLAY_SOURCE_SINK_MAGIC;sink.size=sizeof(sink);sink.version=1;
 sink.source.magic=DISPLAY_SOURCE_MAGIC;sink.source.size=sizeof(sink.source);sink.source.version=1;
 sink.source.pair=&pair;sink.source.normal_return=0;sink.source.enabled=1;
 sink.profile_verified=1;sink.a_unfenced=1;sink.api.retain=retain_mock;sink.api.release=release_mock;
 sink.api.free_layers=free_mock;sink.api.release_enumerator=enum_mock;
 visibility.magic=DISPLAY_VISIBILITY_MAGIC;visibility.size=sizeof(visibility);visibility.version=DISPLAY_VISIBILITY_VERSION;
 visibility.sink=&sink;
 trial.bridge.magic=DU_MAGIC;trial.bridge.size=sizeof(trial.bridge);trial.bridge.version=1;trial.bridge.generation=9;
 trial.bridge.pair=&pair;trial.bridge.sink=&sink;trial.bridge.visibility=&visibility;trial.bridge.enabled=1;
 trial.magic=PS_MAGIC;trial.size=sizeof(trial);trial.version=1;trial.enabled=1;trial.revision=7;
}
void fixture_fill(void*r,void**h,u64 fp,u64 normal_return){
 sink.source.normal_return=normal_return+(case_kind==3?4:0);
 memset(r,0,0xb8);*h=0;normal_head=*h;normal_redraw=r;
 if(case_kind!=7)display_sink_put(r,0x60,&old_ref);display_sink_put(r,0x78,h);
 if(case_kind==10)display_sink_put(r,0x80,(void*)0x8888);
 memcpy(expected_redraw,r,0xb8);
 pair.update_return[0]=pc_address((void*)((u64*)fp)[1]);
}
void fixture_verify(void*r,void**h){assert(r==normal_redraw&&!memcmp(r,expected_redraw,0xb8)&&*h==normal_head);normal_verified++;}
static int injected_observe(struct ps_context*o,void*r,void*h,int result){hit(PS_CALL_OBSERVE);return ps_observe(o,r,h,result);}
int fixture_core_body(void*r,void*w,struct display_private_source*t,du_source_original original,
 u64 entry_fp,u64 native_fp,struct du_local*l){
 assert(*(u64*)entry_fp==native_fp);u64 prior;
 assert(du_legacy_enter(l,DU_SOURCE_ROLE,&sink.source.entered,&sink.source.returned,&sink.source.inflight,&prior)&&!prior);
 struct ps_context o={t,l,pair.active_epoch,pair.active_revision};
 int status=ps_run(&o,r,w,original,injected_observe);
 if(status==PS_REFUSED_BEFORE_CUSTODY){t->refused++;return ps_forward(r,w,original,l);}
 assert(status==PS_COMPLETE||status==PS_ABORTED);du_legacy_close(l,DU_SOURCE_ROLE);return 0;
}
void fixture_check(unsigned outcome,unsigned fault,unsigned how){
 assert(!sink.enabled&&trial.bridge.entry_inflight[DU_SOURCE]==0);
 unsigned unwind=outcome==2?1:0;
 if(how==2)unwind=1; /* nested Source unwound; outer returned normally */
 assert(trial.bridge.entry_unwound[DU_SOURCE]==unwind);
 assert(trial.bridge.entry_entered[DU_SOURCE]==(how==2?2:1));
 assert(trial.bridge.entry_returned[DU_SOURCE]==(outcome==2?0:1));
 assert(!sink.source.inflight||case_kind==5);
 assert(trial.bridge.role_unwound[DU_SOURCE_ROLE]==unwind);
 assert(sink.source.returned==(outcome==2?0:1));
 if(how==1){assert(trial.bridge.original_threw==(fault==PS_CALL_GENERATE));assert(trial.bridge.mutation_threw==(fault!=PS_CALL_GENERATE));}
 if(how==2){assert(trial.bridge.original_threw==1&&!trial.bridge.mutation_threw);}
 if(how==3){assert(!trial.bridge.original_threw&&!trial.bridge.mutation_threw);}
 if(outcome==0){assert(trial.completed==1&&!trial.aborted&&original_private==1&&!original_normal);
  assert(!sink.workspace.phase&&!sink.workspace.head&&old_ref==1&&new_ref==0&&enum_ref==(case_kind==8?1:0)&&head_frees==(case_kind==9?0:1));
  assert(pair.published==1&&pair.records[0].event==DISPLAY_PAIR_PRIVATE_B&&pair.records[0].found_mask==(case_kind==9?0:2));}
 else if(outcome==3){if(case_kind==4)assert(!trial.checkpoints&&!trial.active_call);
  assert(original_normal==1&&!original_private&&!trial.completed&&!trial.aborted);
  assert(!calls[PS_CALL_RETAIN]&&!calls[PS_CALL_GENERATE]&&!calls[PS_CALL_FREE_LAYERS]);}
 else {
  assert(trial.bridge.quarantine_generation==9&&trial.bridge.pending_generation==9&&!trial.completed);
  assert(sink.workspace.phase);assert(outcome==2?!trial.aborted:trial.aborted==1);
  assert(original_normal==0&&original_private<2);
  if(fault==PS_CALL_RETAIN)assert(original_private==0&&!calls[PS_CALL_GENERATE]);
  else assert(original_private==1);
  if(fault<=PS_CALL_OBSERVE||fault>=PS_CALL_OBSERVE_MAIN)assert(!calls[PS_CALL_FREE_LAYERS]&&!calls[PS_CALL_RELEASE_OPAQUE]&&!calls[PS_CALL_RELEASE_ENUMERATOR]);
  if(fault==PS_CALL_FREE_LAYERS)assert(!calls[PS_CALL_RELEASE_OPAQUE]&&!calls[PS_CALL_RELEASE_ENUMERATOR]&&!sink.workspace.head);
  if(fault==PS_CALL_RELEASE_OPAQUE)assert(!calls[PS_CALL_RELEASE_ENUMERATOR]&&!display_sink_get(sink.workspace.redraw,0x60));
  if(fault==PS_CALL_RELEASE_ENUMERATOR)assert(!display_sink_get(sink.workspace.redraw,0x68));
  assert(!pair.published||fault==PS_CALL_FREE_LAYERS||fault==PS_CALL_RELEASE_OPAQUE||fault==PS_CALL_RELEASE_ENUMERATOR);
 }
 assert(outcome==2?!normal_verified:normal_verified==1);
 printf("case outcome=%u fault=%u mode=%u private=%u forward=%u phase=%u abort=%llu E/R/U=%llu/%llu/%llu rolesR/U=%llu/%llu PASS\n",
  outcome,fault,how,original_private,original_normal,sink.workspace.phase,trial.aborted,
  trial.bridge.entry_entered[DU_SOURCE],trial.bridge.entry_returned[DU_SOURCE],trial.bridge.entry_unwound[DU_SOURCE],
  sink.source.returned,trial.bridge.role_unwound[DU_SOURCE_ROLE]);
}
