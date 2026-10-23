/* Included after the frozen unwind/Source bodies; no new native API. */
#include "display_private_source.h"
struct ps_context { struct display_private_source*t;struct du_local*l;u64 epoch,revision; };
static int ps_checkpoint(struct ps_context*o) {
 struct display_private_source*t=o->t;struct display_unwind_bridge*b=&t->bridge;
 t->checkpoints++;
 return ps_valid(t) && display_unwind_local(b,o->l,DU_SOURCE) &&
  __atomic_load_n(&t->enabled,__ATOMIC_ACQUIRE)==1 && !du_forward_only(b) && o->l->generation==b->generation &&
  b->pair->active_epoch==o->epoch && b->pair->active_revision==o->revision &&
  t->revision==o->revision &&
  __atomic_load_n(&b->pair->probe.inflight,__ATOMIC_ACQUIRE)==1 &&
  __atomic_load_n(&b->sink->source.inflight,__ATOMIC_ACQUIRE)==1;
}
static void ps_pre(struct ps_context*o,unsigned call) {
 o->t->active_call=call;
 o->l->stage=call==PS_CALL_GENERATE?DU_STAGE_ORIGINAL:DU_STAGE_MUTATION;
}
static int ps_post(struct ps_context*o,unsigned call) {
 o->t->returned_call=call;o->l->stage=DU_STAGE_ENTRY;return ps_checkpoint(o);
}
static int ps_abort(struct ps_context*o) {
 o->t->reason=PS_QUARANTINE;o->t->aborted++;
 du64 roles=DU_FAIL_ENTRY(DU_SOURCE);
 if(!__atomic_load_n(&o->t->bridge.quarantine_generation,__ATOMIC_ACQUIRE) &&
    !__atomic_load_n(&o->t->bridge.pending_generation,__ATOMIC_ACQUIRE))roles|=DU_FAIL_UNKNOWN;
 du_quarantine(o->l,roles);
 anim_display_unwind_abort(o->l);return PS_ABORTED;
}
static int ps_live_state(struct ps_context*o) {
 struct display_pair*p=o->t->bridge.pair;struct ctx*c=p->probe.engine;
 if(!p->enabled || p->layout_verified!=1 || !c || c->dead || c->in_cb || !c->by_id ||
  !c->ch || c->ch!=p->channel || c->session!=p->session || !p->session || !p->session_control ||
  c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=sizeof(struct ch) || c->ch->h.stop)return 0;
 char*control=*(char**)p->session_control;
 return control && *(void**)(control+0x20)==p->session;
}
/* Observe is already MAIN-owned; check native getter before further reads. */
static int ps_live(struct ps_context*o,unsigned call) {
 struct display_pair*p=o->t->bridge.pair;
 if(!ps_checkpoint(o)||!p->probe.is_main)return 0;
 ps_pre(o,call);int main=p->probe.is_main();
 return ps_post(o,call)&&main==1&&ps_live_state(o);
}
static char*ps_window(struct ps_context*o,unsigned i,unsigned call) {
 struct display_pair*p=o->t->bridge.pair;struct display_pair_identity*id=&p->identity[i];
 if(!ps_checkpoint(o)||!id->wid||!id->window)return 0;
 ps_pre(o,call);char*w=p->probe.engine->by_id(id->wid);
 if(!ps_post(o,call))return 0; /* Never dereference after caught-inner quarantine. */
 if(!w || (u64)w!=id->window || *(u32*)w!=id->wid || *(u32*)(w+4)!=5 ||
  *(u64*)(w+0x30)!=id->creator)return 0;
 if(id->creator && *(u64*)((char*)id->creator+0x268)!=id->pid_version)return 0;
 if(!id->creator) {
  char*cwc=*(char**)(w+0x18);
  if(id->pid_version || !id->local_context || !id->client_id || !cwc ||
   *(u64*)(cwc+0x58)!=id->local_context || *(u32*)(cwc+0x50)!=id->client_id)return 0;
 }
 return w;
}
/* Exact old pure graph parser, with already checked windows; no by_id inside. */
static unsigned ps_graph(void*head,struct display_pair_record*r,char**windows) {
 char*pending[64],*seen[512];unsigned count=0,n=0;if(head)pending[n++]=head;
 while(n){char*s=pending[--n];if((u64)s&7)return DISPLAY_PAIR_GRAPH;
  for(unsigned i=0;i<count;i++)if(seen[i]==s)return DISPLAY_PAIR_GRAPH;
  if(count==512)return DISPLAY_PAIR_GRAPH;seen[count++]=s;
  char*next=*(char**)s,*child=*(char**)(s+0x10);
  if(next){if(n==64)return DISPLAY_PAIR_GRAPH;pending[n++]=next;}
  if(child){if(n==64)return DISPLAY_PAIR_GRAPH;pending[n++]=child;}
  for(unsigned i=0;i<2;i++)if(windows[i]&&*(u32*)(s+0x268)==*(u32*)windows[i]){
   if((r->found_mask&(1u<<i))||*(u32*)(s+0x180)!=10||!display_pair_source(r,i,s,windows[i]))return DISPLAY_PAIR_SOURCE;
   r->found_mask|=1u<<i;
  }
 }
 r->nodes=count;return DISPLAY_PAIR_OK;
}
static int ps_observe(struct ps_context*o,void*redraw,void*head,int result) {
 struct display_pair*p=o->t->bridge.pair;
 if(!ps_live(o,PS_CALL_OBSERVE_MAIN))return !ps_checkpoint(o)?PS_ABORTED:PS_COMPLETE;
 char*windows[2]={0};
 for(unsigned i=0;i<2;i++)if(p->identity[i].wid){
  windows[i]=ps_window(o,i,i?PS_CALL_OBSERVE_B:PS_CALL_OBSERVE_A);
  if(!ps_checkpoint(o))return PS_ABORTED;
  if(!windows[i])return PS_COMPLETE; /* no positive graph witness */
 }
 struct display_pair_record r;display_pair_zero(&r,sizeof(r));
 r.event=DISPLAY_PAIR_PRIVATE_B;r.epoch=o->epoch;r.revision=o->revision;
 r.kind=p->active_kind;r.state=p->active_state;r.redraw=(u64)redraw;r.head=(u64)head;
 r.native_result=result;r.session=(u64)p->session;r.channel=(u64)p->channel;
 if(p->probe.engine->mabs){ps_pre(o,PS_CALL_OBSERVE_CLOCK);r.tick=p->probe.engine->mabs();
  if(!ps_post(o,PS_CALL_OBSERVE_CLOCK))return PS_ABORTED;}
 if(!ps_checkpoint(o))return PS_ABORTED;
 r.reason=ps_graph(head,&r,windows);
 if(r.reason){r.found_mask=0;display_pair_zero(r.source,sizeof(r.source));}
 if(!ps_checkpoint(o))return PS_ABORTED;
 display_pair_publish(p,&r);return PS_COMPLETE;
}
static int ps_run(struct ps_context*o,const void*redraw,void*window,display_generate_fn original,
                  int (*observe)(struct ps_context*,void*,void*,int)) {
 struct display_private_source*t=o->t;struct display_source_sink*q=t->bridge.sink;
 struct display_sink*s=&q->workspace;const struct display_sink_api*a=&q->api;
 if(!s||!a||!redraw||!window||((u64)s&15)||((u64)redraw&7)||s->phase||s->head||
  !original||!a->retain||!a->release||!a->free_layers||!a->release_enumerator)return PS_REFUSED_BEFORE_CUSTODY;
 u64 base=(u64)s,input=(u64)redraw;
 if((input>=base&&input-base<sizeof(*s))||(base>=input&&base-input<0xb8)||
  display_sink_get(redraw,0x80)||!ps_checkpoint(o))return PS_REFUSED_BEFORE_CUSTODY;
 s->phase=DISPLAY_SINK_RETAIN;t->attempted++;t->epoch=o->epoch;t->entry_revision=o->revision;
 t->original_state=PS_ORIGINAL_NOT_STARTED;t->native_result_valid=0;t->reason=PS_OK;
 for(unsigned i=0;i<0xb8;i++)s->redraw[i]=((const unsigned char*)redraw)[i];
 for(unsigned i=0xb8;i<0xc0;i++)s->redraw[i]=0;
 display_sink_put(s->redraw,0x68,0);display_sink_put(s->redraw,0x78,&s->head);display_sink_put(s->redraw,0x80,0);
 void*opaque=display_sink_get(s->redraw,0x60);
 if(opaque){ps_pre(o,PS_CALL_RETAIN);a->retain(opaque);if(!ps_post(o,PS_CALL_RETAIN))return ps_abort(o);}
 if(!ps_checkpoint(o))return ps_abort(o);
 s->phase=DISPLAY_SINK_GENERATE;t->original_state=PS_ORIGINAL_STARTED;ps_pre(o,PS_CALL_GENERATE);
 s->native_result=original(s->redraw,window);t->native_result=s->native_result;
 t->native_result_valid=1;t->original_state=PS_ORIGINAL_RETURNED;
 if(!ps_post(o,PS_CALL_GENERATE))return ps_abort(o);
 ps_pre(o,PS_CALL_OBSERVE);int observed=observe?observe(o,(void*)redraw,s->head,s->native_result):PS_COMPLETE;
 if(!ps_post(o,PS_CALL_OBSERVE)||observed==PS_ABORTED)return ps_abort(o);
 s->phase=DISPLAY_SINK_LAYERS;void*head=s->head;s->head=0;
 if(head){ps_pre(o,PS_CALL_FREE_LAYERS);a->free_layers(head);if(!ps_post(o,PS_CALL_FREE_LAYERS))return ps_abort(o);}
 if(!ps_checkpoint(o))return ps_abort(o);
 s->phase=DISPLAY_SINK_OPAQUE;opaque=display_sink_get(s->redraw,0x60);display_sink_put(s->redraw,0x60,0);
 if(opaque){ps_pre(o,PS_CALL_RELEASE_OPAQUE);a->release(opaque);if(!ps_post(o,PS_CALL_RELEASE_OPAQUE))return ps_abort(o);}
 if(!ps_checkpoint(o))return ps_abort(o);
 s->phase=DISPLAY_SINK_ENUMERATOR;void*enumerator=display_sink_get(s->redraw,0x68);display_sink_put(s->redraw,0x68,0);
 if(enumerator){ps_pre(o,PS_CALL_RELEASE_ENUMERATOR);a->release_enumerator(enumerator);if(!ps_post(o,PS_CALL_RELEASE_ENUMERATOR))return ps_abort(o);}
 if(!ps_checkpoint(o))return ps_abort(o);
 s->phase=DISPLAY_SINK_IDLE;t->active_call=PS_CALL_NONE;t->completed++;return PS_COMPLETE;
}
static int ps_forward(void*r,void*w,display_generate_fn original,struct du_local*l) {
 l->stage=DU_STAGE_ORIGINAL;int result=original(r,w);l->stage=DU_STAGE_ENTRY;
 du_legacy_close(l,DU_SOURCE_ROLE);return result;
}
int anim_display_private_source_body(void*redraw,void*window,struct display_private_source*t,
 display_generate_fn original,u64 entry_fp,u64 native_fp,struct du_local*l) {
 if(!ps_valid(t)||!display_unwind_local(&t->bridge,l,DU_SOURCE))return original(redraw,window);
 struct display_unwind_bridge*b=&t->bridge;struct display_pair*p=b->pair;
 /* OFF and non-B roles retain the frozen passive observer and explicit FP ABI. */
 if((u64)window!=p->identity[1].window || du_forward_only(b) ||
    __atomic_load_n(&t->enabled,__ATOMIC_ACQUIRE)!=1 ||
    !__atomic_load_n(&b->sink->source.enabled,__ATOMIC_ACQUIRE))
  return anim_display_unwind_source_body(redraw,window,b,original,entry_fp,native_fp,l);
 struct display_source*s=&b->sink->source;u64 prior;
 if(!du_legacy_enter(l,DU_SOURCE_ROLE,&s->entered,&s->returned,&s->inflight,&prior))return original(redraw,window);
 if(du_forward_only(b)||__atomic_load_n(&t->enabled,__ATOMIC_ACQUIRE)!=1||prior||!p->probe.is_main)
  return ps_forward(redraw,window,original,l);
 /* No shared PS diagnostics or sampled epoch reads until actual MAIN proof. */
 l->stage=DU_STAGE_MUTATION;int main=p->probe.is_main();l->stage=DU_STAGE_ENTRY;
 if(du_forward_only(b)||main!=1)return ps_forward(redraw,window,original,l);
 t->active_call=t->returned_call=PS_CALL_ADMIT_MAIN;
 if(!p->active_epoch||p->active_kind||p->active_state||
  t->revision!=p->active_revision||!p->thread_self||!p->stack_top||!p->stack_size)
  return ps_forward(redraw,window,original,l);
 struct ps_context o={t,l,p->active_epoch,p->active_revision};
 ps_pre(&o,PS_CALL_ADMIT_THREAD);void*thread=p->thread_self();if(!ps_post(&o,PS_CALL_ADMIT_THREAD))return ps_forward(redraw,window,original,l);
 ps_pre(&o,PS_CALL_ADMIT_TOP);u64 top=(u64)p->stack_top(thread);if(!ps_post(&o,PS_CALL_ADMIT_TOP))return ps_forward(redraw,window,original,l);
 ps_pre(&o,PS_CALL_ADMIT_SIZE);u64 size=p->stack_size(thread);if(!ps_post(&o,PS_CALL_ADMIT_SIZE))return ps_forward(redraw,window,original,l);
 if(size<4096||size>0x40000000ULL||top<size)return ps_forward(redraw,window,original,l);
 u64 bottom=top-size,parent=display_source_framed_parent(s,entry_fp,native_fp,bottom,top);
 if(!parent || parent<0xb88 || !display_pair_range(parent,16,bottom,top)||
  !display_pair_range(parent-0xb40,0xb8,bottom,top)||!display_pair_range(parent-0xb88,8,bottom,top)||
  (u64)redraw!=parent-0xb40)return ps_forward(redraw,window,original,l);
 u64 ret=pc_address((void*)((u64*)parent)[1]);
 if(ret!=p->update_return[0]&&ret!=p->update_return[1])return ps_forward(redraw,window,original,l);
 __atomic_fetch_add(&s->normal,1,__ATOMIC_RELAXED);
 if(!ps_checkpoint(&o)||!ps_live_state(&o))return ps_forward(redraw,window,original,l);
 char*w=ps_window(&o,1,PS_CALL_ADMIT_B);
 if(!w||w!=window||!ps_checkpoint(&o)||p->identity[1].creator||!p->identity[0].creator||
  b->sink->a_unfenced!=1||b->sink->profile_verified!=1||
  *(void**)(w+0x428)||*(void**)(w+0x488)||*(void**)(w+0x878)||*(void**)(w+0x880)||
  *(void**)(w+0x8b0)||*(void**)(w+0x7a0))return ps_forward(redraw,window,original,l);
 int status=ps_run(&o,redraw,window,original,ps_observe);
 switch(status){
  case PS_REFUSED_BEFORE_CUSTODY:t->refused++;return ps_forward(redraw,window,original,l);
  case PS_COMPLETE:__atomic_fetch_add(&s->selected,1,__ATOMIC_RELAXED);du_legacy_close(l,DU_SOURCE_ROLE);return 0;
  case PS_ABORTED:du_legacy_close(l,DU_SOURCE_ROLE);return 0;
 }
 __builtin_unreachable();
}
