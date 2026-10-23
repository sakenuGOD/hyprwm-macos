// Normal-Update policy is the native witness. These CPU fakes deliberately make
// unrelated window/CWC bytes disagree, to catch wrong-object policy reads.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static struct rgba_capture g;
static _Alignas(16) char normal[0x500],own[0x500],cwc[0x800],state[0x190],win[0x1000],entry[0x20];
static void *display[1],*vtable[0x5c0/8+1];
static int begins,added,locked,bad_time;static void *context=(void *)0x1000,*root=(void *)0x2000,*interface=(void *)0x3000;
static void *display_interface(void *d){assert(d==display);return interface;}
static double get_time(void *u){return *(double *)((char *)u+0x40)+((u==own && bad_time)?1e-6:0);}
static void *begin(void *scratch,u64 size,const void *stamp,double time,u32 seed,u32 previous,const rect *bounds,u32 flags){
 assert(!scratch && size==0x1fe4 && !stamp && !seed && !previous && bounds==(rect *)(state+0x78) && flags==0);
 begins++;memset(own,0,sizeof(own));*(double *)(own+0x40)=time;return own;
}
static void boolean(void *u,int b){assert(u==own && (b==0 || b==1));}
static void attributes_from_state(void *out,const void *s){assert(s==state);memset(out,0x7b,0x3c);}
static void attributes(void *u,const void *a){assert(u==own && *(const unsigned char *)a==0x7b);}
static void scalar(void *u,double value){assert(u==own);(void)value;}
static void displays(void *u,void **d,int count){assert(u==own && count==1 && d[0]==interface);}
static u64 get_protection(void *u){assert(u==normal);return 0x40;}
static void protection(void *u,u64 value){assert(u==own && value==0x40);}
static u32 get_flags(void *u){assert(u==normal);return 0x123;}
static void flags(void *u,u32 value){assert(u==own && value==0x123);}
static void policy(void *u,int value,unsigned bit){
 assert(u==own && (value==0 || value==1));u64 *p=(u64 *)(own+0x4e8);
 *p=(*p&~(1ULL<<bit))|((u64)value<<bit);
}
static void greedy(void *u,int value){
 int old=(int)((*(u64 *)(own+0x4e8)>>54)&1);policy(u,value,54);
 if(old!=value)*(double *)(own+0x40)+=value?1e-9:-1e-9;
}
static void ignore(void *u,int value){policy(u,value,50);}
static void flatten(void *u,int value){policy(u,value,51);}
static void create(void *u,int value){policy(u,value,52);}
static int lock(void *ctx){assert(ctx==context && !locked);locked=1;return 0;}
static int unlock(void *ctx){assert(ctx==context && locked);locked=0;return 0;}
static void *get_root(void *ctx){assert(ctx==context && locked);return root;}
static void *assign(void **cell,void *value){assert(cell==&g.root && !*cell && value==root && locked);*cell=value;return cell;}
static void add(void *u,void *ctx,void *r,const void *transform){
 assert(u==own && ctx==context && r==root && !transform && locked);added++;
 assert(get_time(u)==get_time(normal));u64 mask=(1ULL<<50)|(1ULL<<51)|(1ULL<<52)|(1ULL<<54);
 assert((*(u64 *)(own+0x4e8)&mask)==(*(u64 *)(normal+0x4e8)&mask));
}
static void reset(void){
 memset(&g,0,sizeof(g));memset(normal,0,sizeof(normal));memset(own,0,sizeof(own));memset(cwc,0,sizeof(cwc));
 memset(state,0,sizeof(state));memset(win,0,sizeof(win));memset(entry,0,sizeof(entry));begins=added=locked=bad_time=0;
 g.pc.source=(u64)win;g.pc.update=(u64)normal;g.pc.context=(u64)context;g.pc.client_included=1;
 *(void **)(normal+0x140)=entry;*(void **)(entry+8)=context;*(u32 *)(entry+0x18)=42;
 *(void **)(state+0xe8)=display;*(double *)(normal+0x40)=123456.125;
 *(u64 *)(normal+0x4e8)=(1ULL<<51)|(1ULL<<52)|(1ULL<<54);
 win[0x7a0]=(char)0xe0; // Window blur radius must not be read as CWC mode flags.
 *(u32 *)(cwc+0x2e8)=0xffffffff; // Unrelated rectangle bytes, not outer updater policy.
 vtable[0x5c0/8]=(void *)__builtin_ptrauth_sign_unauthenticated((void *)pc_address((void *)display_interface),0,
     __builtin_ptrauth_blend_discriminator(&vtable[0x5c0/8],0x3c32));
 display[0]=__builtin_ptrauth_sign_unauthenticated((void *)vtable,2,__builtin_ptrauth_blend_discriminator((void *)display,0xc333));
 struct rgba_render_api *a=&g.api;
 a->get_time=get_time;a->begin_update=begin;a->isolated=boolean;a->hosted=boolean;a->skip_backdrops=boolean;
 a->attributes_from_state=attributes_from_state;a->attributes=attributes;a->use_skylight_attributes=boolean;
 a->vbl_time=scalar;a->interval=scalar;a->displays=displays;a->get_protection=get_protection;a->protection=protection;
 a->get_flags=get_flags;a->add_flags=flags;a->greedy=greedy;a->ignore_flatten_cache=ignore;a->flatten_backdrops=flatten;a->create_flatten_surface=create;
 a->lock_context=lock;a->unlock_context=unlock;a->root=get_root;a->assign_root=assign;a->add_context=add;
}
int main(void){
 reset();assert(rgba_update(&g,cwc,state) && begins==1 && added==1 && !locked && g.normal_wrapper_sequence==42);
 reset();cwc[0x7a0]=0x20;assert(!rgba_update(&g,cwc,state) && !begins);
 reset();*(u64 *)(normal+0x4e8)|=1ULL<<8;assert(!rgba_update(&g,cwc,state) && !begins);
 reset();*(u64 *)(normal+0x4e8)|=1ULL<<16;assert(!rgba_update(&g,cwc,state) && !begins);
 reset();*(u64 *)(normal+0x4e8)|=1ULL<<32;assert(!rgba_update(&g,cwc,state) && !begins);
 reset();*(u64 *)(normal+0x4e8)&=~(1ULL<<54);assert(rgba_update(&g,cwc,state) && added==1);
 reset();bad_time=1;assert(!rgba_update(&g,cwc,state) && begins==1 && !added && !g.root && !locked);
 puts("RGBA normal policy/wrong-object/greedy-time/unsupported-mode CPU contracts PASS");return 0;
}
