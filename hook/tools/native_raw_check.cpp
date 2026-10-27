#include "normal-layout.h"
#include <ptrauth.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <fstream>
#include <iterator>
#include <vector>
#include <cassert>
#include <cstring>
#include <cstdio>
#include <cstdint>
extern "C" void __register_frame(const void *);
extern "C" int __gxx_personality_v0(int,int,uint64_t,void *,void *);
extern "C" void *__cxa_begin_catch(void *) noexcept;
extern "C" void __cxa_end_catch() noexcept;
static uintptr_t sign(uintptr_t p){return (uintptr_t)__builtin_ptrauth_sign_unauthenticated((void*)p,0,0);}
static uintptr_t address(void*p){return (uintptr_t)__builtin_ptrauth_strip(p,0);}
static unsigned calls,unlocks,original_fault,main_fault,main_calls;
static void *original(void*a,void*b,void*c,void**d){assert(a==(void*)1&&b==(void*)2&&c==(void*)3&&d==(void**)4);calls++;if(original_fault)throw 7;return (void*)0x1234;}
static int main_thread(){if(++main_calls==main_fault){main_fault=0;throw 11;}return 1;}
static int unlock(void*c){assert(c==(void*)0x5678);unlocks++;return 0;}
static void put(void*base,size_t off,uint64_t value,unsigned size=8){memcpy((char*)base+off,&value,size);}
static uint64_t get(void*base,size_t off,unsigned size=8){uint64_t v=0;memcpy(&v,(char*)base+off,size);return v;}
static bool begin_result=true,begin_flag=true;
static unsigned begin_calls,begin_native_fault;
static bool begin_original(void *w,void *state,bool flag){assert(w==(void*)1&&state==(void*)2&&flag==begin_flag);begin_calls++;if(begin_native_fault)throw 17;return begin_result;}
static unsigned close_lookup_calls;
static void *close_byid_throw(unsigned){close_lookup_calls++;throw 43;}
static unsigned tx_depth,tx_closed,tx_fault;
static void *source_window;
static void *fake_byid(unsigned wid){assert(wid==77);if(tx_fault==1)throw 23;return source_window;}
static void fake_ctor(void *tx,unsigned flag){assert(flag==1&&tx_depth==0);if(tx_fault==2)throw 24;put(tx,0,0x7478);tx_depth++;}
static void fake_add(void *tx,void *context){assert(get(tx,0)==0x7478&&context==(void*)0x1111&&tx_depth==1);throw 25;}
static void fake_dtor(void *tx){assert(get(tx,0)==0x7478&&tx_depth==1);tx_depth--;tx_closed++;}
static unsigned draw_calls,draw_fault;
static void *draw_original(void *w,unsigned flag){assert(w==(void*)1&&flag==0x1234);draw_calls++;if(draw_fault)throw 41;return (void*)0x4567;}
static unsigned ingest_calls,ingest_fault;
static void ingest_original(void *w,void *outer,void *tx){assert(w==(void*)1&&outer==(void*)2&&tx==(void*)3);ingest_calls++;if(ingest_fault)throw 43;}
static unsigned timer_calls;
static void *timer_engine;
static void timer_original(void*c,double now){assert(c==timer_engine&&now==17.25);timer_calls++;}
static unsigned scene_calls,scene_throw,clone_inits,clone_updates,clone_dtors;
static void *scene_binding;
static void *scene_original(void*a,void*b,void*c,void*d){
 assert(a==(void*)1&&b==(void*)2&&c==(void*)3&&d==(void*)4);scene_calls++;
 if(scene_binding)assert(get(scene_binding,OFF_rgba_carrier_depth,4)==1);
 if(scene_throw)throw 31;return (void*)0x789a;
}
static unsigned char clone_args[48];
static void clone_init(void*scope,void*begin,void*end,long count){assert(begin==clone_args&&end==clone_args+48&&count==3);clone_inits++;put(scope,0,0x1133);}
static void *clone_update(void*a,void*b,void*scope){assert(a==(void*)1&&b==(void*)2&&get(scope,0)==0x1133);clone_updates++;if(scene_throw)throw 37;return (void*)0x5566;}
static void clone_destroy(void*scope){assert(get(scope,0)==0x1133);clone_dtors++;}
int main(int argc,char**argv){
 assert(argc==2);std::ifstream f(argv[1],std::ios::binary);std::vector<char>b((std::istreambuf_iterator<char>(f)),{});assert(!b.empty());
 void*image=mmap(0,b.size(),PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(image!=MAP_FAILED);memcpy(image,b.data(),b.size());
 const char *runtime[]={"__gxx_personality_v0","__cxa_begin_catch","__cxa_end_catch","__cxa_rethrow","_ZSt9terminatev","_Unwind_Resume","abort"};
 for(unsigned i=0;i<7;i++){void *fn=dlsym(RTLD_DEFAULT,runtime[i]);assert(fn);put(image,SYMBOL_rgba_normal_runtime_slots+8*i,sign(address(fn)));}
 put(image,SECTION___normal_got,(uintptr_t)__builtin_ptrauth_sign_unauthenticated((void*)((uintptr_t)image+SYMBOL_rgba_normal_personality),0,(uintptr_t)image+SECTION___normal_got));
 alignas(16) unsigned char guard_page[0x1000]={};uint64_t guard=0x123456789a,guard_pointer=(uintptr_t)&guard;
 put(guard_page,0xe48,(uintptr_t)&guard_pointer);
 put(image,SYMBOL_display_native_clone_slots,(uintptr_t)guard_page);
 put(image,SYMBOL_display_native_clone_slots+8,sign(address((void*)&clone_init)));
 put(image,SYMBOL_display_native_clone_slots+16,sign(address((void*)&clone_update)));
 put(image,SYMBOL_display_native_clone_slots+24,sign(address((void*)&clone_destroy)));
 assert(mprotect(image,b.size(),PROT_READ|PROT_EXEC)==0);sys_icache_invalidate(image,b.size());
 unsigned fdes=0;for(size_t off=EH_OFFSET;off<EH_OFFSET+EH_SIZE;){unsigned size=get(image,off,4);if(!size)break;assert(off+4+size<=EH_OFFSET+EH_SIZE);if(get(image,off+4,4)){__register_frame((char*)image+off);fdes++;}off+=4+size;}
 using Original=void *(*)(void*,void*,void*,void**);using Prepare=void *(*)(void*,void*,void*,void**,void*,Original);
 auto prepare=(Prepare)sign((uintptr_t)image+SYMBOL_anim_rgba_normal_prepare);
 fprintf(stderr,"CHECK_FORWARD\n");
 assert(prepare((void*)1,(void*)2,(void*)3,(void**)4,0,original)==(void*)0x1234&&calls==1);
 fprintf(stderr,"CHECK_ORIGINAL_THROW\n");
 calls=0;original_fault=1;bool propagated=false;try{prepare((void*)1,(void*)2,(void*)3,(void**)4,0,original);}catch(int tag){assert(tag==7);propagated=true;}assert(propagated&&calls==1);original_fault=0;
 alignas(16) unsigned char capture[65536]={},binding[SIZE_NORMAL]={};
 put(capture,0,0x31484341434d5748ULL);put(capture,8,720,4);put(capture,12,1,4);
 put(capture,OFF_rgba_capture_magic,0x31414247524d5748ULL);put(capture,OFF_rgba_capture_size,SIZE_RGBA,4);put(capture,OFF_rgba_capture_version,5,4);put(capture,OFF_rgba_capture_content_mode,3,4);
 put(capture,OFF_pc_capture_is_main,sign(address((void*)&main_thread)));put(capture,OFF_pc_capture_stage,1,4);put(capture,OFF_pc_capture_update,0x9876);
 put(capture,OFF_pc_capture_client_context,0x5678);put(capture,OFF_rgba_capture_locked_client,0x5678);put(capture,OFF_rgba_capture_api+OFF_rgba_render_api_unlock_context,sign(address((void*)&unlock)));
 put(binding,0,0x314c414d524f4e52ULL);put(binding,8,SIZE_NORMAL,4);put(binding,12,1,4);put(binding,OFF_rgba_normal_binding_capture,(uintptr_t)capture);put(binding,OFF_rgba_normal_binding_inflight,1);
 fprintf(stderr,"CHECK_OWN_THROW\n");
 calls=0;main_calls=0;main_fault=1;assert(prepare((void*)1,(void*)2,(void*)3,(void**)4,binding,original)==(void*)0x1234);
 assert(calls==1&&unlocks==1&&!get(capture,OFF_rgba_capture_locked_client)&&get(capture,OFF_rgba_capture_quarantined,4)==1);
 assert(get(binding,OFF_rgba_normal_binding_dead,4)==1&&!get(binding,OFF_rgba_normal_binding_inflight)&&!get(capture,OFF_pc_capture_update)&&get(capture,OFF_pc_capture_reason,4)==248);
 using Begin=bool(*)(void*,void*,bool,void*,bool(*)(void*,void*,bool));
 auto begin=(Begin)sign((uintptr_t)image+SYMBOL_anim_rgba_begin_prepare);
 unsigned char *bb=capture+57344;
 auto reset_begin=[&](){memset(bb,0,SIZE_BEGIN);put(bb,0,0x314e494745425252ULL);put(bb,8,SIZE_BEGIN,4);put(bb,12,1,4);put(bb,OFF_rgba_begin_binding_capture,(uintptr_t)capture);main_calls=0;main_fault=0;begin_calls=0;};
 fprintf(stderr,"CHECK_BEGIN_FORWARD_BOOL\n");
 for(unsigned r=0;r<2;r++)for(unsigned flag=0;flag<2;flag++){begin_result=r;begin_flag=flag;begin_calls=0;assert(begin((void*)1,(void*)2,flag,nullptr,begin_original)==bool(r)&&begin_calls==1);}
 fprintf(stderr,"CHECK_BEGIN_ORIGINAL_THROW\n");
 reset_begin();begin_native_fault=1;propagated=false;try{begin((void*)1,(void*)2,begin_flag,bb,begin_original);}catch(int tag){assert(tag==17);propagated=true;}assert(propagated&&begin_calls==1&&get(bb,OFF_rgba_begin_binding_dead,4));begin_native_fault=0;
 fprintf(stderr,"CHECK_BEGIN_OWN_BEFORE_AFTER_THROW\n");
 for(unsigned point=1;point<=2;point++){reset_begin();main_fault=point;begin_result=true;assert(begin((void*)1,(void*)2,begin_flag,bb,begin_original));assert(begin_calls==1&&get(bb,OFF_rgba_begin_binding_dead,4));}
 fprintf(stderr,"CHECK_ACTUAL_C_TRANSACTION_UNWIND\n");
 std::vector<unsigned char>ctx(0x8000),ch(SIZE_CH),win(0x930),owner(0x300),cwc(0x600);
 source_window=win.data();put(win.data(),0,77,4);put(win.data(),4,5,4);put(win.data(),0x18,(uintptr_t)cwc.data());put(win.data(),0x30,(uintptr_t)owner.data());put(owner.data(),0x268,99);
 put(cwc.data(),0x38,0x1111);put(cwc.data(),0x98,0x2222);
 put(capture,OFF_pc_capture_engine,(uintptr_t)ctx.data());put(ctx.data(),OFF_ctx_ch,(uintptr_t)ch.data());put(ctx.data(),OFF_ctx_by_id,sign(address((void*)&fake_byid)));
 put(ctx.data(),OFF_ctx_tx_ctor,sign(address((void*)&fake_ctor)));put(ctx.data(),OFF_ctx_tx_add,sign(address((void*)&fake_add)));put(ctx.data(),OFF_ctx_tx_dtor,sign(address((void*)&fake_dtor)));
 put(ch.data(),OFF_ch_win+OFF_ch_win_wid,77,4);put(ch.data(),OFF_ch_win+OFF_ch_win_used,1,4);
 unsigned char *m=capture+ORDINARY_SLOTS;put(m,OFF_rgba_inplace_on,1,4);put(m,OFF_rgba_inplace_presenting,1,4);put(m,OFF_rgba_inplace_wid,77,4);
 put(m,OFF_rgba_inplace_window,(uintptr_t)win.data());put(m,OFF_rgba_inplace_creator,(uintptr_t)owner.data());put(m,OFF_rgba_inplace_pid_version,99);put(m,OFF_rgba_inplace_context,0x1111);put(m,OFF_rgba_inplace_host,0x2222);
 using Restore=void(*)(void*,unsigned long long*);auto restore=(Restore)sign((uintptr_t)image+SYMBOL_anim_rgba_begin_restore);
 unsigned long long ticket[6]={1};
 for(tx_fault=1;tx_fault<=3;tx_fault++){reset_begin();propagated=false;tx_depth=tx_closed=0;try{restore(bb,ticket);}catch(int tag){assert(tag==int(22+tx_fault));propagated=true;}assert(propagated&&tx_depth==0&&tx_closed==(tx_fault==3?1u:0u));}
 fprintf(stderr,"CHECK_SCENE_FOUR_ARGS_AND_DEPTH\n");
 using SceneOriginal=void*(*)(void*,void*,void*,void*);using Scene=void*(*)(void*,void*,void*,void*,void*,SceneOriginal);
 auto scene=(Scene)sign((uintptr_t)image+SYMBOL_anim_rgba_scene_prepare);
 unsigned char *cb=capture+10240;memset(cb,0,SIZE_CARRIER);put(cb,0,0x3152454952524143ULL);put(cb,8,SIZE_CARRIER,4);put(cb,12,1,4);put(cb,OFF_rgba_carrier_capture,(uintptr_t)capture);
 // Before work intentionally declines invalid stack API; original forwarding
 // and depth custody remain live on this exact raw executable image.
 scene_binding=cb;main_fault=0;
 assert(scene((void*)1,(void*)2,(void*)3,(void*)4,cb,scene_original)==(void*)0x789a&&scene_calls==1&&!get(cb,OFF_rgba_carrier_depth,4));
 scene_throw=1;propagated=false;try{scene((void*)1,(void*)2,(void*)3,(void*)4,cb,scene_original);}catch(int tag){assert(tag==31);propagated=true;}assert(propagated&&scene_calls==2&&!get(cb,OFF_rgba_carrier_depth,4));scene_throw=0;
 fprintf(stderr,"CHECK_SCENE_OWN_THROW_BEFORE_NATIVE\n");
 main_calls=0;main_fault=1;put(m,OFF_rgba_inplace_presenting,0,4);
 assert(scene((void*)1,(void*)2,(void*)3,(void*)4,cb,scene_original)==(void*)0x789a&&scene_calls==3&&get(cb,OFF_rgba_carrier_dead,4)&&!get(cb,OFF_rgba_carrier_depth,4));
 fprintf(stderr,"CHECK_ACTUAL_156_BYTE_CLONE_FOUR_ARGS\n");
 auto clone=(SceneOriginal)sign((uintptr_t)image+SYMBOL_display_native_clone);
 assert(scene((void*)1,(void*)2,clone_args,clone_args+48,cb,clone)==(void*)0x5566&&clone_inits==1&&clone_updates==1&&clone_dtors==1&&!get(cb,OFF_rgba_carrier_depth,4));
 scene_throw=1;propagated=false;try{scene((void*)1,(void*)2,clone_args,clone_args+48,cb,clone);}catch(int tag){assert(tag==37);propagated=true;}assert(propagated&&clone_inits==2&&clone_updates==2&&clone_dtors==1&&!get(cb,OFF_rgba_carrier_depth,4));
 fprintf(stderr,"CHECK_CLOSE_GATE_EXCEPTION_NATIVE_FALLBACK\n");
 std::vector<unsigned char> close_slots(32*SIZE_CLOSE_SLOT),image_source(0x2d0),fallback_source(0x2d0),image_meta(0x30);
 unsigned char *close=capture+6144,*cs=close_slots.data(),*cv=cs+OFF_rgba_close_slot_view;
 memset(close,0,SIZE_CLOSE);put(close,0,0x3145534f4c434752ULL);put(close,8,SIZE_CLOSE,4);put(close,12,1,4);
 put(close,OFF_rgba_close_capture,(uintptr_t)capture);put(close,OFF_rgba_close_slots,(uintptr_t)cs);
 put(cs,OFF_rgba_close_slot_clone_wid,88,4);put(cs,OFF_rgba_close_slot_source_wid,77,4);put(cs,OFF_rgba_close_slot_source,0xaaa);put(cs,OFF_rgba_close_slot_clone,0xbbb);
 double close_stamp=1;memcpy(cs+OFF_rgba_close_slot_stamp,&close_stamp,8);
 put(cv,OFF_rgba_view_window,(uintptr_t)win.data());put(cv,OFF_rgba_view_wid,99,4);put(cv,OFF_rgba_view_shown,1,4);put(cv,OFF_rgba_view_active,1);
 put(image_source.data(),0x180,10,4);put(image_source.data(),0x268,99,4);put(image_source.data(),0x48,(uintptr_t)image_meta.data());put(image_meta.data(),0,(uintptr_t)win.data());
 put(fallback_source.data(),0x268,88,4);put(fallback_source.data(),0x174,0xffffffff,4);float source_alpha=1;memcpy(image_source.data()+0x188,&source_alpha,4);memcpy(fallback_source.data()+0x188,&source_alpha,4);
 // Exact P8 identity reaches a throwing native lookup. The independent own
 // boundary leaves B disabled and the real fallback multiplier unchanged.
 put(ctx.data(),0x800,88,4);put(ctx.data(),0x804,77,4);memcpy(ctx.data()+0x808,&close_stamp,8);put(ctx.data(),0x810,1,4);put(ctx.data(),0xb00,0xaaa);
 put(ctx.data(),OFF_ctx_by_id,sign(address((void*)&close_byid_throw)));
 void *close_nodes[2]={image_source.data(),fallback_source.data()};
 using CloseGate=void(*)(void*,void**,unsigned,int);auto close_gate=(CloseGate)sign((uintptr_t)image+SYMBOL_rgba_normal_close_gate);
 close_gate(capture,close_nodes,2,1);assert(close_lookup_calls==1);float result_alpha=-1;memcpy(&result_alpha,image_source.data()+0x188,4);assert(result_alpha==0);memcpy(&result_alpha,fallback_source.data()+0x188,4);assert(result_alpha==1);
 put(ctx.data(),OFF_ctx_by_id,sign(address((void*)&fake_byid)));memset(close,0,SIZE_CLOSE);
 fprintf(stderr,"CHECK_REFUSED_TIMER_ORIGINAL_ONCE\n");
 using Timer=void(*)(void*,double);auto timer=(Timer)sign((uintptr_t)image+SYMBOL_anim_rgba_normal_present_dispatch);
 timer_engine=ctx.data();put(ctx.data(),0x6e0,(uintptr_t)capture);put(ctx.data(),0x6e8,sign(address((void*)&timer_original)));
 timer(ctx.data(),17.25);assert(timer_calls==1);
 fprintf(stderr,"CHECK_DRAW_GETTER_FORWARD_AND_NATIVE_UNWIND\n");
 using Draw=void*(*)(void*,unsigned,void*,void*(*)(void*,unsigned),unsigned);
 auto draw=(Draw)sign((uintptr_t)image+SYMBOL_anim_rgba_draw_shape_prepare);
 for(unsigned kind=0;kind<2;kind++){draw_calls=0;assert(draw((void*)1,0x1234,nullptr,draw_original,kind)==(void*)0x4567&&draw_calls==1);}
 draw_calls=0;draw_fault=1;propagated=false;try{draw((void*)1,0x1234,nullptr,draw_original,0);}catch(int tag){assert(tag==41);propagated=true;}assert(propagated&&draw_calls==1);draw_fault=0;
 fprintf(stderr,"CHECK_DRAW_INGESTION_FORWARD_AND_NATIVE_UNWIND\n");
 using Ingest=void(*)(void*,void*,void*,void*,void(*)(void*,void*,void*));
 auto ingest=(Ingest)sign((uintptr_t)image+SYMBOL_anim_rgba_draw_ingest_prepare);
 ingest((void*)1,(void*)2,(void*)3,nullptr,ingest_original);assert(ingest_calls==1);
 ingest_fault=1;propagated=false;try{ingest((void*)1,(void*)2,(void*)3,nullptr,ingest_original);}catch(int tag){assert(tag==43);propagated=true;}assert(propagated&&ingest_calls==2);ingest_fault=0;
 fprintf(stderr,"CHECK_GEOMETRY_ABORT_KEEPS_OUTER_LOCK\n");
 unsigned char *db=capture+11264;memset(db,0,SIZE_DRAWING);put(db,0,0x31474e4957415244ULL);put(db,8,SIZE_DRAWING,4);put(db,12,1,4);put(db,OFF_rgba_drawing_capture,(uintptr_t)capture);
 put(capture,OFF_rgba_capture_locked_client,0x5678);put(capture,OFF_pc_capture_client_context,0x5678);
 auto pre_abort=(void(*)(void*))sign((uintptr_t)image+SYMBOL_anim_rgba_normal_before_abort);
 unsigned outer_unlocks=unlocks;pre_abort(binding);
 assert(unlocks==outer_unlocks&&get(capture,OFF_rgba_capture_locked_client)==0x5678&&get(db,OFF_rgba_drawing_dead,4));
 fprintf(stderr,"CHECK_PREFLIGHT_EXCEPTION_KEEPS_OUTER_LOCK\n");
 put(db,OFF_rgba_drawing_dead,0,4);main_calls=0;main_fault=1;
 auto commands=(void(*)(void*))sign((uintptr_t)image+SYMBOL_rgba_normal_draw_commands);
 commands(ctx.data());
 assert(unlocks==outer_unlocks&&get(capture,OFF_rgba_capture_locked_client)==0x5678&&get(db,OFF_rgba_drawing_dead,4));
 put(capture,OFF_rgba_capture_locked_client,0);
 printf("NORMAL_RAW_UNWIND PASS close_gate_exception_preserves_fallback preflight_exception_preserves_outer_lock geometry_abort_preserves_outer_lock draw_getter_forward_unwind ingestion_forward_unwind refused_timer_original_once scene_four_args scene_depth_native_throw actual_native_clone own_scene_throw original_once original_throw_propagated own_throw_caught exact_lock_release quarantined begin_bool begin_original_throw before_after_own_throw actual_C_scope_unwind fdes=%u\n",fdes);
}
