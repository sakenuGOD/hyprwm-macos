#include "fixture-api.h"
#include <cassert>
#include <initializer_list>
#include <cstdio>
#include <libunwind.h>
#include <ptrauth.h>
using Entry=int(*)(void*,void*,display_private_source*,du_source_original,du64);
extern "C" int ps_update_mirror(void*,display_private_source*,du_source_original,Entry);
extern "C" int fixture_core_entry(void*,void*,display_private_source*,du_source_original,du64);
static unsigned selected_call,selected_mode,throws_count,inner_catches,walks,raii;
struct Marker{unsigned call;};struct Outer{~Outer(){raii++;}};
static int nested_payload(void*,void*){throws_count++;throw Marker{777};}
static void walk(){
 unw_context_t context;unw_cursor_t cursor;assert(!unw_getcontext(&context)&&!unw_init_local(&cursor,&context));
 bool entry=false,body=false,update=false;
 auto raw=[](auto f){return (du64)ptrauth_strip(f,ptrauth_key_function_pointer);};
 for(unsigned i=0;i<40;i++){
  unw_proc_info_t p{};assert(!unw_get_proc_info(&cursor,&p));
  if(p.start_ip==raw(anim_display_private_source)||p.start_ip==raw(fixture_core_entry)){
   assert(p.unwind_info&&p.lsda&&p.handler&&p.format==0x03000000);entry=true;}
  if(p.start_ip==raw(anim_display_private_source_body)||p.start_ip==raw(fixture_core_body))body=true;
  if(p.start_ip==raw(ps_update_mirror))update=true;
  int n=unw_step(&cursor);assert(n>=0);if(!n)break;
 }
 assert(entry&&body&&update);walks++;
}
extern "C" void fixture_fault(unsigned call){
 if(call!=selected_call||!selected_mode)return;
 walk();
 if(selected_mode==1){throws_count++;throw Marker{call};}
 if(selected_mode==2){
  try{anim_display_unwind_source((void*)0x100,(void*)0x200,&fixture_trial()->bridge,nested_payload,0);assert(false);}
  catch(const Marker&m){assert(m.call==777);inner_catches++;}
 }else if(selected_mode==3){
  auto*b=&fixture_trial()->bridge;__atomic_store_n(&b->quarantine_generation,b->generation,__ATOMIC_RELEASE);
  __atomic_store_n(&b->pending_generation,b->generation,__ATOMIC_RELEASE);
 }
}
static void run(unsigned call,unsigned mode,bool core=false){
 selected_call=call;selected_mode=mode;fixture_reset(call,mode);
 unsigned outcome=mode==1?2:mode?1:0;
 try{Outer guard;int result=ps_update_mirror(fixture_window(),fixture_trial(),fixture_original,
      core?fixture_core_entry:anim_display_private_source);assert(mode!=1&&result==0);}
 catch(const Marker&m){assert(mode==1&&m.call==call);}
 fixture_check(outcome,call,mode);
}
int main(){setbuf(stdout,nullptr);
 run(0,0);
 // Six generic core callback boundaries. OBSERVE callback uses the explicit OWN test observer.
 const unsigned boundary[]={PS_CALL_RETAIN,PS_CALL_GENERATE,PS_CALL_OBSERVE,
  PS_CALL_FREE_LAYERS,PS_CALL_RELEASE_OPAQUE,PS_CALL_RELEASE_ENUMERATOR};
 for(unsigned call:boundary)for(unsigned mode=1;mode<=3;mode++)run(call,mode,call==PS_CALL_OBSERVE);
 // Transitive controlled observer helpers, including a poisonous by_id return after inner catch.
 for(unsigned call:{PS_CALL_OBSERVE_MAIN,PS_CALL_OBSERVE_A,PS_CALL_OBSERVE_B,PS_CALL_OBSERVE_CLOCK})
  for(unsigned mode=1;mode<=3;mode++)run(call,mode);
 // Scope refusals stay passive and never touch private helper/custody.
 for(unsigned c=1;c<=6;c++){
  selected_call=selected_mode=0;fixture_reset(0,0);fixture_set_case(c);
  assert(ps_update_mirror(fixture_window(),fixture_trial(),fixture_original,anim_display_private_source)==-191);
  fixture_check(3,0,0);
 }
 for(unsigned c:{7U,8U,9U}){selected_call=selected_mode=0;fixture_reset(0,0);fixture_set_case(c);
  assert(ps_update_mirror(fixture_window(),fixture_trial(),fixture_original,anim_display_private_source)==0);fixture_check(0,0,0);}
 for(unsigned c:{10U,11U}){selected_call=selected_mode=0;fixture_reset(0,0);fixture_set_case(c);
  assert(ps_update_mirror(fixture_window(),fixture_trial(),fixture_original,anim_display_private_source)==-191);fixture_check(3,0,0);}
 assert(throws_count==20&&inner_catches==10&&walks==30);
 printf("OWN controlled prototype PASS: six boundaries +4 observer getters x3 modes, 8 passive cases +3 optional-output cases; walks=%u realThrows=%u innerCaught=%u outerRAII=%u. No WS/native helpers/copy-image claim.\n",walks,throws_count,inner_catches,raii);
}
