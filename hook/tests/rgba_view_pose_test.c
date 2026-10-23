// Faults at the local-commit/native-shape boundary, without GUI/native calls.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static struct ctx engine;
static struct rgba_capture capture;
static struct rgba_view view;
static _Alignas(16) unsigned char window[0x940],rc[512],root[160],body[160];
static _Alignas(16) unsigned char rh[40],bh[40],texture[136],ext[64],uv[64];
static void *manager_words[2];
static int shapes,hides,shows,schedules,commits,shape_failure,hide_failure,alphas,alpha_failure,getter_failure,order_failure;
static float alpha_at_publication;
static unsigned proof_failures;
static int configuration_change;
static u32 current_seed,geometry_seed_value;
static rect native_shape,region_value;
static void *by_id(u32 wid){return wid==42?window:0;}
static int main_thread(void){return 1;}
static void *selector(const char *s){return (void *)s;}
static void *message(void *object,void *sel){
 const char *name=sel;(void)object;
 if(!strcmp(name,"status"))return (void *)4;
 if(!strcmp(name,"device"))return (void *)0x1122;
 if(!strcmp(name,"renderContext"))return (proof_failures && view.commit_checks && (proof_failures&(1U<<(view.commit_checks-1))))?0:rc;
 if(!strcmp(name,"commitId"))return (void *)(u64)commits;
 return 0;
}
static void *manager(void){return manager_words;}
static u32 seed(void *m){assert(m==manager_words);return current_seed;}
static u32 geometry_seed(void *m){assert(m==manager_words);return geometry_seed_value;}
static float effective_alpha(void *w){
 assert(w==window);
 if(getter_failure){getter_failure--;return .123f;}
 return *(float *)(window+0x1d8)**(float *)(window+0x1dc)**(float *)(window+0x1e0);
}
static void set_alpha(void *connection,void *w,float alpha,float duration){
 assert(!connection&&w==window&&!duration);alphas++;
 *(float *)(window+0x1e4)=alpha;
 if(alpha_failure==1){alpha_failure=0;return;} // Refuse after requested alpha changed.
 float previous=*(float *)(window+0x1d8);
 if(*(u64 *)(window+0x928)&(1ULL<<44))*(float *)(window+0x1d8)=alpha;
 if(previous!=alpha && (previous==1 || alpha==1))geometry_seed_value++;
 if(alpha_failure==2){alpha_failure=0;getter_failure=2;}
 if(alpha_failure==3){alpha_failure=0;*(float *)(window+0x1d8)=.7f;}
}
static u32 display(void *w){assert(w==window);return 17;}
static void *region(rect r){region_value=r;return (void *)0x2233;}
static void release(void *r){assert(r==(void *)0x2233);}
static int shape(void *w,void *r,void *a,u32 b){
 assert(w==window&&r==(void *)0x2233&&!a&&!b);shapes++;native_shape=region_value;
 // Deliberately model a refusal AFTER native mutation: rollback must undo it.
 if(shape_failure){shape_failure=0;return -1;}return 0;
}
static int order(void *a,u32 wid,int direction,u32 relative){
 assert(!a&&wid==42&&!relative);
 if(direction){
  shows++;*(float *)(window+0x1d8)=*(float *)(window+0x1e4);
  alpha_at_publication=*(float *)(window+0x1d8);*(u64 *)(window+0x928)|=1ULL<<44;
  if(order_failure){order_failure=0;return -1;}
 }else {hides++;if(!hide_failure)*(u64 *)(window+0x928)&=~(1ULL<<44);}
 return hide_failure?-1:0;
}
static void schedule(void *a,void *w){assert(!a&&w==window);schedules++;}
static void ctor(void *scope,u32 flags){assert(scope&&flags==1);}
static void add(void *scope,void *context){assert(scope&&context==view.context);}
static void dtor(void *scope){
 assert(scope);commits++;
 if(configuration_change)current_seed=8;
 *(rect *)(root+0x48)=*(rect *)(body+0x48)=(rect){0,0,view.target.w,view.target.h};
 root[0x24]=body[0x24]=255;
 *(double *)(uv+0x20)=1-view.target.h/view.source_h;
 *(double *)(uv+0x28)=view.target.w/view.source_w;
 *(u32 *)(rc+0x40)=commits;*(u32 *)(rc+0x28)=commits;
}
static int lock(void *c){assert(c==rc);return 0;}
static int unlock(void *c){assert(c==rc);return 0;}
static void *get_root(void *c){assert(c==rc);return root;}
static u64 layer_id(void *l){assert(l==view.root||l==view.body);return l==view.root?11:22;}
static void *lookup(void *c,u64 id,u32 a,int b,u32 *d){assert(c==rc&&!a&&!b&&!d);return id==11?rh:bh;}
static void unused(void){}
static void reset(void){
 memset(&engine,0,sizeof(engine));memset(&capture,0,sizeof(capture));memset(&view,0,sizeof(view));
 memset(window,0,sizeof(window));memset(rc,0,sizeof(rc));memset(root,0,sizeof(root));memset(body,0,sizeof(body));
 capture.magic=RGBA_MAGIC;capture.size=sizeof(capture);capture.version=RGBA_VERSION;
 capture.pc.magic=PC_MAGIC;capture.pc.size=sizeof(capture.pc);capture.pc.version=1;
 capture.pc.engine=&engine;capture.pc.is_main=main_thread;capture.pc.stage=PC_GPU_COMPLETE;
 capture.pc.capture_witness=1;capture.pc.command_buffer=(void *)0x3344;capture.pc.texture_ref=(void *)0x4455;
 capture.pc.status_selector="status";capture.clear_status=4;capture.device=(void *)0x1122;capture.queue=(void *)0x5566;capture.sel.device="device";
 capture.api.lock_context=lock;capture.api.unlock_context=unlock;capture.api.root=get_root;
 engine.by_id=by_id;engine.msg=(void *)message;engine.sel=selector;
 engine.rgn=region;engine.release=release;engine.sched_win=schedule;
 engine.tx_ctor=ctor;engine.tx_add=add;engine.tx_dtor=dtor;
 engine.set_alpha=set_alpha;
 *(u32 *)window=42;*(u32 *)(window+4)=5;manager_words[0]=(void *)0x6677;
 view.capture=&capture;view.window=window;view.wid=42;view.context=(void *)0x7788;
 view.root=(void *)0x8899;view.body=(void *)0x99aa;view.texture=capture.pc.texture_ref;
 view.pre_display=view.prepared=view.shown=view.qualified=1;view.display=17;
 view.current=(rect){10,10,100,100};view.target=(rect){50,50,110,110};view.display_bounds=(rect){0,0,1000,1000};
 view.source_w=view.source_h=100;view.alpha=.5;view.current_alpha=1;view.geometry_seed=view.changed_seed=7;
 view.api=(struct rgba_view_api){.create=(void *)unused,.bind_local=(void *)unused,.shape=shape,.empty_region=(void *)unused,
  .event_shape=(void *)unused,.no_shadow=(void *)unused,.depth=(void *)unused,.resolution=(void *)unused,.order=order,
  .display_id=display,.manager=manager,.geometry_seed=geometry_seed,.changed_seed=seed,.manager_vtable=(void *)0x6677,
  .layer_id=layer_id,.lookup_handle=lookup,.effective_alpha=effective_alpha};
 *(u64 *)(rc+0x110)=11;*(u32 *)(root+0xc)=1U<<13;*(void **)(root+0x70)=body;
 *(void **)(body+0x68)=texture;texture[0xc]=0x24;*(void **)(texture+0x70)=view.texture;
 *(void **)(body+0x88)=ext;*(void **)(ext+0x28)=uv;uv[0xc]=0x3e;*(u32 *)(uv+0x10)=4;
 *(double *)(uv+0x18)=0;*(double *)(uv+0x30)=1;
 *(void **)(rh+0x18)=*(void **)(bh+0x18)=rc;*(void **)(rh+0x10)=root;*(void **)(bh+0x10)=body;
 shapes=hides=shows=schedules=commits=shape_failure=hide_failure=configuration_change=0;
 alphas=alpha_failure=getter_failure=order_failure=0;alpha_at_publication=-1;
 *(float *)(window+0x1d8)=*(float *)(window+0x1dc)=*(float *)(window+0x1e0)=*(float *)(window+0x1e4)=1;
 *(u64 *)(window+0x928)=1ULL<<44;
 proof_failures=0;current_seed=geometry_seed_value=7;native_shape=view.current;
}
static void original_tick(struct ctx *c,double now){assert(c && now==1);}
static void mode_only_dispatch(void){
 reset();view.pre_display=0;view.target=view.current;view.alpha=view.current_alpha=1;
 view.presentation_mode=RGBA_VIEW_SNAPSHOT;
 *(double *)(uv+0x20)=0;*(double *)(uv+0x28)=1;
 static _Alignas(16) unsigned char arena[16384];static struct ch channel;
 memset(arena,0,sizeof(arena));
 struct rgba_capture *g=(void *)arena;*g=capture;
 struct rgba_view *v=(void *)(arena+RGBA_VIEW_OFFSET);*v=view;
 v->magic=RGBA_VIEW_MAGIC;v->size=sizeof(*v);v->version=RGBA_VIEW_VERSION;v->capture=g;
 static _Alignas(16) unsigned char engine_arena[16384];
 memset(engine_arena,0,sizeof(engine_arena));
 struct ctx *c=(void *)engine_arena;*c=engine;g->pc.engine=c;
 channel.h.magic=CH_MAGIC;c->ch=&channel;
 *(void **)((char *)c+PC_CONTROL_PTR)=g;
 *(void (**)(struct ctx *,double))((char *)c+PC_ORIGINAL_TICK)=original_tick;
 v->command=1;v->sequence=1;
 anim_rgba_present_dispatch(c,1);
 assert(v->ack==1 && v->result==1 && !v->active && commits==1 && !shapes);
 assert(rgba_view_same(native_shape,v->current) && effective_alpha(window)==1);
}
int main(void){
 mode_only_dispatch();
 reset();rect old=view.current,requested=view.target;proof_failures=1;
 assert(rgba_view_pose(&view,1)==0&&!shapes&&!hides&&view.shown&&view.committed&&commits==2);
 assert(rgba_view_same(native_shape,old)&&rgba_view_same(view.current,old)&&view.current_alpha==1);
 assert(rgba_view_same(view.target,requested)&&view.alpha==.5&&!engine.in_cb);
 assert(rgba_view_pose(&view,1)==1&&shapes==1&&rgba_view_same(native_shape,requested)&&view.current_alpha==.5);
 assert(effective_alpha(window)==.5f&&root[0x24]==255&&body[0x24]==255&&view.geometry_seed==geometry_seed_value);
 view.alpha=0;assert(rgba_view_pose(&view,1)==1&&effective_alpha(window)==0&&view.shown&&!hides);
 reset();old=view.current;requested=view.target;shape_failure=1;
 assert(rgba_view_pose(&view,1)==-1&&shapes==2&&!hides&&view.shown&&view.committed&&commits==2);
 assert(rgba_view_same(native_shape,old)&&rgba_view_same(view.current,old)&&view.current_alpha==1);
 assert(rgba_view_same(view.target,requested)&&view.alpha==.5&&!engine.in_cb);
 reset();proof_failures=3;
 assert(rgba_view_pose(&view,1)==-1&&!shapes&&hides==1&&!view.shown&&view.reason==403);
 assert(rgba_view_pose(&view,1)==-1&&hides==1&&commits==2); // Abort requires retirement, not auto-resume.
 reset();proof_failures=3;hide_failure=1;
 assert(rgba_view_pose(&view,1)==-1&&!shapes&&hides==1&&view.shown&&view.reason==404);
 assert(rgba_view_pose(&view,1)==-1&&hides==1&&commits==2);
 reset();view.target=view.current;configuration_change=1;
 assert(rgba_view_pose(&view,1)==-1&&!shapes&&hides==1&&!view.shown&&view.reason==403);
 reset();old=view.current;alpha_failure=1;
 assert(rgba_view_pose(&view,1)==-1&&alphas==2&&view.shown&&!hides&&view.committed);
 assert(rgba_view_same(native_shape,old)&&rgba_view_same(view.current,old)&&view.current_alpha==1&&effective_alpha(window)==1);
 reset();alpha_failure=2;
 assert(rgba_view_pose(&view,1)==-1&&hides==1&&!view.shown&&view.reason==403);
 reset();alpha_failure=3;
 assert(rgba_view_pose(&view,1)==-1&&alphas==1&&hides==1&&*(float *)(window+0x1d8)==.7f);
 reset();*(float *)(window+0x1dc)=.5f;
 assert(rgba_view_pose(&view,1)==-1&&!alphas&&!commits&&!shapes&&!hides);
 reset();*(void **)(window+0x888)=(void *)0x1234;
 assert(rgba_view_pose(&view,1)==-1&&!alphas&&!commits&&!shapes&&!hides);
 reset();view.shown=0;*(u64 *)(window+0x928)=0;view.alpha=0;
 assert(rgba_view_pose(&view,1)==1&&view.shown&&shows==1&&alphas==1&&alpha_at_publication==0&&effective_alpha(window)==0);
 reset();view.shown=0;*(u64 *)(window+0x928)=0;view.alpha=0;order_failure=1;
 assert(rgba_view_pose(&view,1)==-1&&shows==1&&hides==1&&!view.shown&&view.reason==403);
 reset();view.pre_display=0;proof_failures=1;
 assert(rgba_view_pose(&view,1)==0&&shapes==1&&!alphas&&view.current_alpha==1&&effective_alpha(window)==1);
 assert(rgba_view_pose(&view,1)==1&&shapes==1&&alphas==1&&view.current_alpha==.5&&effective_alpha(window)==.5f&&!hides);
 puts("Pre-display commit/shape/native-alpha rollback, foreign-alpha/fade refusal, cold-alpha0 order and abort custody PASS");return 0;
}
