// Actual product entry/body qualification, OWN process/memory only.
#include "fixtures/display_unwind/fixture.h"
#include "display_unwind.h"
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>
#include <pthread.h>
#include <ptrauth.h>
#include <libunwind.h>
#include <unwind.h>
using U=uint64_t;
using PairEntry=int(*)(void*,du64,void*,void*,display_unwind_bridge*,du_pair_original,du64);
using SourceEntry=int(*)(void*,void*,display_unwind_bridge*,du_source_original,du64);
using TimerEntry=void(*)(ctx*,double,display_unwind_bridge*,du_timer_original);
extern "C" void anim_display_unwind_frame(void*,void*,void*,display_unwind_bridge*);
extern "C" int own_pair_call(void*,du64,void*,void*,display_unwind_bridge*,du_pair_original,PairEntry);
extern "C" int own_source_mirror(void*,void*,display_unwind_bridge*,du_source_original,SourceEntry);
extern "C" void own_frame_call(OwnCase*,OwnFrame);
extern "C" unsigned char own_pair_call_return[],own_source_normal_return[],own_update_return[];
extern "C" unsigned char own_cohort_0[],own_cohort_1[],own_cohort_3[],own_cohort_4[];
template<class F>static U raw(F p){return (U)ptrauth_strip(p,ptrauth_key_function_pointer);}
static U ia0(U address){return (U)ptrauth_sign_unauthenticated((void*)address,ptrauth_key_function_pointer,0);}
struct Bindings {PairEntry pair;SourceEntry source;TimerEntry timer;OwnFrame frame;U pair_body,source_body,timer_mutation;};
static Bindings functions;
static constexpr du64 force=0x123456789abcdef0ULL;
enum Fault {NONE,TIMER_ORIGINAL,PAIR_ORIGINAL,PAIR_AFTER_FRAME,SOURCE_ORIGINAL,SOURCE_OBSERVER,PROBE_GETTER,PROFILE_GETTER,PREPARE,BBOX,ALPHA_BEFORE,ALPHA_AFTER,ALPHA_VERIFY,ORDER_BEFORE,ORDER_AFTER,INVALIDATE_BEFORE,INVALIDATE_AFTER,CONTAINS_BEFORE,CONTAINS_AFTER,POLICY_CHECK_BEFORE,POLICY_CHECK_AFTER,POLICY_APPLY_BEFORE,POLICY_APPLY_AFTER,POLICY_REVOKE_BEFORE,POLICY_REVOKE_AFTER};
struct Marker {unsigned point;};
struct Run {OwnCase*c;Fault fault=NONE;bool retry=false,chain=false,nested=false,in_nested=false,caught_source=false,caught_pair=false,in_caught=false;unsigned timer_calls=0,pair_calls=0,source_calls=0,reads=0,mutations=0,walks=0,outer=0,pair_depth=0,source_depth=0;U watch_ack=0,reads_at_caught=0;unsigned tokens[3][2]{},token_states[3][2]{};unsigned token_counts[3]{};};
static Run*active;static std::vector<Run*>retained;static unsigned total_throws=0,total_walks=0;
static display_unwind_bridge*b(){return (display_unwind_bridge*)own_case_unwind(active->c);}
static OwnVisibilitySnapshot snap(){OwnVisibilitySnapshot s{};own_case_visibility_snapshot(active->c,&s);return s;}
static void assert_balance(){
 auto*d=b();for(unsigned i=0;i<3;i++)assert(du_balanced(d->entry_entered[i],d->entry_returned[i],d->entry_unwound[i],d->entry_inflight[i]));
 U*roles[4][3]{};own_case_role_storage(active->c,roles);
 for(unsigned i=0;i<4;i++)assert(du_balanced(*roles[i][0],*roles[i][1],d->role_unwound[i],*roles[i][2]));
}
static void no_after_ack_getter(){active->reads++;if(active->watch_ack)assert(snap().constructed!=active->watch_ack);}
static void walk(unsigned kind){
 unw_context_t context;unw_cursor_t cursor;assert(!unw_getcontext(&context)&&!unw_init_local(&cursor,&context));
 U entry=kind==DU_PAIR?raw(functions.pair):kind==DU_SOURCE?raw(functions.source):raw(functions.timer);
 U body=kind==DU_PAIR?functions.pair_body:kind==DU_SOURCE?functions.source_body:0;
 U entry_fp=0,entry_sp=0,body_fp=0;bool seen=false;
 for(unsigned depth=0;depth<70;depth++){
  unw_proc_info_t info{};assert(!unw_get_proc_info(&cursor,&info));unw_word_t fp=0,sp=0;
  if(info.start_ip==entry&&!seen){
   assert(info.unwind_info&&info.lsda&&info.handler);assert(!unw_get_reg(&cursor,UNW_ARM64_FP,&fp)&&!unw_get_reg(&cursor,UNW_REG_SP,&sp));entry_fp=fp;entry_sp=sp;seen=true;}
  if(body&&info.start_ip==body&&!body_fp){
   assert(info.unwind_info);assert(!unw_get_reg(&cursor,UNW_ARM64_FP,&fp));body_fp=fp;}
  int step=unw_step(&cursor);assert(step>=0);if(!step)break;
 }
 assert(seen&&entry_fp&&entry_sp<=entry_fp);
 if(body){
  assert(body_fp&&body_fp<entry_fp&&*(U*)body_fp==entry_fp);du_local*local=nullptr;
  if(kind==DU_PAIR){assert(body_fp+16==entry_sp);memcpy(&local,(void*)(body_fp+16),sizeof(local));}
  else{
   assert(entry_fp-entry_sp<=16384);
   for(U pos=(entry_sp+7)&~7ULL;pos+sizeof(du_local)<=entry_fp;pos+=8){
    du_local value;memcpy(&value,(void*)pos,sizeof(value));
    if(value.bridge==b()&&value.generation==b()->generation&&value.entry_fp==entry_fp&&value.entry_kind==kind){assert(!local);local=(du_local*)pos;}
   }
  }
  assert(local&&(U)local>=entry_sp&&(U)local+sizeof(*local)<=entry_fp);
  assert(local->entry_fp==entry_fp&&local->native_fp==*(U*)entry_fp&&local->count<=2);
  active->token_counts[kind]=local->count;
  for(unsigned i=0;i<local->count;i++){active->tokens[kind][i]=local->token[i].role;active->token_states[kind][i]=local->token[i].state;assert(local->token[i].state==DU_OPEN||local->token[i].state==DU_CLOSED);}
  // Pair's ninth argument is read only while this real OWN C9 frame is live.

 }
 active->walks++;total_walks++;
}
static void point(Fault f){if(active->fault==f){for(unsigned kind=0;kind<3;kind++)if(b()->entry_inflight[kind])walk(kind);throw Marker{(unsigned)f};}}
static int main_thread(){no_after_ack_getter();if(b()->entry_inflight[DU_PAIR]&&snap().pair_inflight)point(PROBE_GETTER);return pthread_main_np();}
static void*thread_self(){no_after_ack_getter();return (void*)pthread_self();}
static void*stack_top(void*p){no_after_ack_getter();return pthread_get_stackaddr_np((pthread_t)p);}
static U stack_size(void*p){no_after_ack_getter();return pthread_get_stacksize_np((pthread_t)p);}
static void getter(unsigned phase){no_after_ack_getter();if(phase==1)point(PROFILE_GETTER);if(phase==3)point(ALPHA_VERIFY);}
static void prepare(){no_after_ack_getter();point(PREPARE);}
static void bbox(){no_after_ack_getter();point(BBOX);}
static int alpha(float value,unsigned stage){assert(value==0||value==1);active->mutations+=!stage;point(stage?ALPHA_AFTER:ALPHA_BEFORE);return 0;}
static int order(unsigned stage){active->mutations+=!stage;point(stage?ORDER_AFTER:ORDER_BEFORE);return 0;}
static void policy(unsigned phase,unsigned stage){no_after_ack_getter();point((Fault)((phase==1?POLICY_CHECK_BEFORE:phase==3?POLICY_APPLY_BEFORE:POLICY_REVOKE_BEFORE)+!!stage));}
static void invalidate(void*a,void*c,void*r){assert(!a&&!c&&r==own_case_region(active->c));active->mutations++;point(INVALIDATE_BEFORE);assert(*(unsigned*)r==0x5245474e);point(INVALIDATE_AFTER);}
static int contains(void*a,void*c){no_after_ack_getter();assert(a==own_case_dirty(active->c)&&c==own_case_region(active->c));point(CONTAINS_BEFORE);assert(*(unsigned*)a==0x44495254&&*(unsigned*)c==0x5245474e);point(CONTAINS_AFTER);return 1;}
static void source_observer(){no_after_ack_getter();point(SOURCE_OBSERVER);}
static int invoke_pair();
static int source_original(void*r,void*w){
 assert(w==own_case_B_window(active->c));active->source_calls++;if(active->retry)return 0;
 if(active->caught_source&&!active->in_caught){
  active->in_caught=true;auto old=active->fault;active->fault=SOURCE_ORIGINAL;
  try{own_source_mirror(r,w,b(),source_original,functions.source);assert(false);}catch(const Marker&m){assert(m.point==SOURCE_ORIGINAL);active->reads_at_caught=active->reads;}
  active->fault=old;active->in_caught=false;
 }else point(SOURCE_ORIGINAL);
 // Sets only a fixture scalar used to inject a helper throw in the real
 // post-original Source observer. No native pointer retained by this hook.
 own_case_source_returned(active->c,1);return 0;
}
static int pair_original(void*c,du64 f,void*begin,void*end){
 assert(c==active->c&&f==force&&begin==own_case_vector(active->c)&&end==own_case_vector_end(active->c));active->pair_calls++;active->pair_depth++;
 struct Depth{~Depth(){active->pair_depth--;}}depth;
 if(!active->retry)point(PAIR_ORIGINAL);
 if(active->caught_pair&&!active->in_caught){
  active->in_caught=true;auto old=active->fault;active->fault=PAIR_ORIGINAL;
  try{invoke_pair();assert(false);}catch(const Marker&m){assert(m.point==PAIR_ORIGINAL);active->reads_at_caught=active->reads;}
  active->fault=old;active->in_caught=false;
 }
 own_frame_call(active->c,functions.frame);
 if(active->nested&&!active->in_nested){active->in_nested=true;U prior=snap().constructed;invoke_pair();assert(snap().constructed==prior);active->in_nested=false;}
 if(!active->retry)point(PAIR_AFTER_FRAME);return 0;
}
static void timer_original(ctx*c,double now){assert(c==own_case_engine(active->c)&&now==1.25);active->timer_calls++;if(!active->retry)point(TIMER_ORIGINAL);if(active->chain)invoke_pair();}
static int invoke_pair(){return own_pair_call(active->c,force,own_case_vector(active->c),own_case_vector_end(active->c),b(),pair_original,functions.pair);}
static void invoke_timer(){functions.timer((ctx*)own_case_engine(active->c),1.25,b(),timer_original);}
struct Outer {~Outer(){active->outer++;}};
static Run*new_run(){
 auto*r=new Run{};active=r;retained.push_back(r);
 const U cohort[5]={(U)own_cohort_0,(U)own_cohort_1,0x3000,(U)own_cohort_3,(U)own_cohort_4};const U updates[2]={(U)own_update_return,0x4000};
 OwnCallbacks cb{main_thread,thread_self,stack_top,stack_size,invalidate,contains,prepare,bbox,alpha,order,getter,policy,source_observer};
 r->c=own_case_new(&cb,(U)own_pair_call_return,cohort,updates);own_case_host_order(r->c);
 own_case_source_binding(r->c,(void*)ia0(raw(functions.source)),(void*)ia0(raw(source_original)));
 // C fixture sets the known normal-return label, without a source snapshot.
 own_case_source_return_address(r->c,(U)own_source_normal_return);return r;
}
static void normal_cases(){
 auto*r=new_run();for(U word:{4ULL,9ULL,14ULL}){
  own_case_request(r->c,word);invoke_timer();assert(snap().completed==word);
  r->watch_ack=word;invoke_pair();r->watch_ack=0;assert(snap().constructed==word);assert_balance();
 }
 for(unsigned i=0;i<3;i++)assert(b()->entry_entered[i]==3&&b()->entry_returned[i]==3&&!b()->entry_unwound[i]&&!b()->entry_inflight[i]);
 for(unsigned i=0;i<4;i++)assert(!b()->role_unwound[i]);
 assert(own_case_local_alpha(r->c)==1&&b()->quarantine_generation==0);own_case_assert_A(r->c);
 r=new_run();invoke_timer();r->nested=true;invoke_pair();assert(snap().constructed==4&&b()->entry_entered[DU_PAIR]==2);assert_balance();
 r=new_run();own_case_du_enabled(r->c,0);own_case_workspace_sentinel(r->c);invoke_pair();invoke_timer();assert(!snap().completed&&!snap().constructed);assert_balance();
 puts("OWN product normal/nested/OFF, no getter after construction ACK, Source localalpha independent PASS");
}
static void throw_cases(){
 const Fault faults[]={TIMER_ORIGINAL,PAIR_ORIGINAL,PAIR_AFTER_FRAME,SOURCE_ORIGINAL,SOURCE_OBSERVER,PROBE_GETTER,PROFILE_GETTER,PREPARE,BBOX,ALPHA_BEFORE,ALPHA_AFTER,ALPHA_VERIFY,ORDER_BEFORE,ORDER_AFTER,INVALIDATE_BEFORE,INVALIDATE_AFTER,CONTAINS_BEFORE,CONTAINS_AFTER,POLICY_CHECK_BEFORE,POLICY_CHECK_AFTER,POLICY_APPLY_BEFORE,POLICY_APPLY_AFTER,POLICY_REVOKE_BEFORE,POLICY_REVOKE_AFTER};
 for(Fault fault:faults){
  auto*r=new_run();bool pair=fault==PAIR_ORIGINAL||fault==PAIR_AFTER_FRAME||fault==SOURCE_ORIGINAL||fault==SOURCE_OBSERVER||fault==PROBE_GETTER||fault==CONTAINS_BEFORE||fault==CONTAINS_AFTER;
  if(pair)invoke_timer();
  if(fault==ORDER_BEFORE||fault==ORDER_AFTER||fault==POLICY_REVOKE_BEFORE||fault==POLICY_REVOKE_AFTER)own_case_request(r->c,6);
  if(fault==POLICY_APPLY_BEFORE||fault==POLICY_APPLY_AFTER)own_case_request(r->c,9);
  if(fault>=POLICY_CHECK_BEFORE)own_case_policy(r->c,1);
  r->fault=fault;auto prior=snap();auto priorDu=*b();bool caught=false;
  try{Outer outer;if(pair)invoke_pair();else invoke_timer();}catch(const Marker&m){assert(m.point==(unsigned)fault);caught=true;}
  // Mutation exceptions are contained at the actual void C++ timer boundary;
  // original exceptions propagate. Neither path records a normal group return.
  assert(caught==(pair||fault==TIMER_ORIGINAL));assert(r->outer==1);total_throws++;
  auto before=snap();assert(before.completed==prior.completed&&before.constructed==prior.constructed&&before.committed==prior.committed);
  assert(b()->quarantine_generation==b()->generation&&b()->pending_generation==b()->generation);assert_balance();
  assert(!before.pair_inflight&&!before.source_inflight&&!before.inflight&&!before.timer_inflight);
  U expected_bits=0;for(unsigned i=0;i<3;i++)if(b()->entry_unwound[i]>priorDu.entry_unwound[i])expected_bits|=DU_FAIL_ENTRY(i);
  for(unsigned i=0;i<4;i++)if(b()->role_unwound[i]>priorDu.role_unwound[i])expected_bits|=DU_FAIL_ROLE(i);
  bool unknown=fault==PROBE_GETTER||fault==SOURCE_OBSERVER;
  bool original=pair?fault!=PROBE_GETTER:fault==TIMER_ORIGINAL;
  U provenance=(unknown?DU_FAIL_UNKNOWN:0)|(original?DU_FAIL_ORIGINAL:0)|(!pair&&fault!=TIMER_ORIGINAL?DU_FAIL_MUTATION:0);
  assert(b()->failure_roles==(expected_bits|provenance));
  assert(b()->original_threw==(original?(fault==SOURCE_ORIGINAL?2:1):0));
  assert(b()->mutation_threw==(!pair&&fault!=TIMER_ORIGINAL?1:0));

  U reads=r->reads,mutations=r->mutations;auto flags=b()->failure_roles;auto generation=b()->quarantine_generation;
  r->fault=NONE;r->retry=true;own_case_du_poison(r->c);own_case_request(r->c,17);
  for(unsigned i=0;i<2;i++){invoke_timer();invoke_pair();assert_balance();}
  assert(r->reads==reads&&r->mutations==mutations&&b()->failure_roles==flags&&b()->quarantine_generation==generation);
  assert(snap().completed==before.completed&&snap().constructed==before.constructed);own_case_assert_A(r->c);

 }
}
static void chain_cases(){
 auto*r=new_run();r->chain=true;r->fault=SOURCE_ORIGINAL;own_case_workspace_sentinel(r->c);bool caught=false;
 try{Outer outer;invoke_timer();}catch(const Marker&m){assert(m.point==SOURCE_ORIGINAL);caught=true;}assert(caught);
 assert_balance();for(unsigned kind=0;kind<3;kind++)assert(b()->entry_entered[kind]==1&&b()->entry_unwound[kind]==1&&!b()->entry_returned[kind]&&!b()->entry_inflight[kind]);
 for(unsigned role=0;role<4;role++)assert(b()->role_unwound[role]==1);
 assert(r->token_counts[DU_PAIR]==2&&r->tokens[DU_PAIR][0]==DU_VIS_ENTRY&&r->tokens[DU_PAIR][1]==DU_PROBE);
 assert(r->token_counts[DU_SOURCE]==1&&r->tokens[DU_SOURCE][0]==DU_SOURCE_ROLE);
 assert(!snap().completed&&!snap().constructed&&snap().workspace_phase==3&&own_case_workspace_head(r->c)==own_case_region(r->c));
 U sentinel=(U)own_case_workspace_head(r->c),reads=r->reads,mutations=r->mutations;auto flags=b()->failure_roles;r->fault=NONE;r->retry=true;own_case_du_poison(r->c);
 for(unsigned i=0;i<2;i++){invoke_timer();assert_balance();}
 assert((U)own_case_workspace_head(r->c)==sentinel&&snap().workspace_phase==3&&r->reads==reads&&r->mutations==mutations&&b()->failure_roles==flags);
 printf("OWN token acquisition Pair[%u,%u] Source[%u]; reverse unwind all4 U1; private phase3/head scalar retained +poisoned retry PASS\n",r->tokens[DU_PAIR][0],r->tokens[DU_PAIR][1],r->tokens[DU_SOURCE][0]);
 for(bool source:{false,true}){
  r=new_run();r->chain=true;r->caught_source=source;r->caught_pair=!source;invoke_timer();assert_balance();
  assert(b()->quarantine_generation&&b()->entry_returned[DU_TIMER]==1&&!snap().completed&&!snap().constructed&&r->reads_at_caught&&r->reads==r->reads_at_caught);
 }
 puts("OWN product Timer->Pair->Source all3 group/all4 legacy unwind; caught-inner checkpoints and retained workspace sentinel PASS");
}
static void setup_host(){
 functions={anim_display_unwind_pair,anim_display_unwind_source,anim_display_unwind_timer,(OwnFrame)anim_display_unwind_frame,raw(anim_display_unwind_pair_body),raw(anim_display_unwind_source_body),raw(anim_display_unwind_timer_mutation)};
}
int main(){setbuf(stdout,nullptr);assert(pthread_main_np()==1);
setup_host();

normal_cases();throw_cases();
chain_cases();
 for(auto*r:retained){active=r;assert_balance();own_case_assert_A(r->c);}
 printf("OWN integrated actual product stage PASS cases%zu throws%u walks%u headless synthetic fixtures only\n",retained.size(),total_throws,total_walks);
}
