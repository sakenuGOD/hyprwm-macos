// Headless transition checks. Native objects/APIs are fakes; this does not prove
// compositor pixels, frame timing, or a client post-configure buffer commit.
#include "../src/anim4.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>

_Alignas(16) static unsigned char engine_bytes[0x4000];
static struct ch channel;
static struct birth_state state;
static unsigned char source[0x1000],shell[0x1000],creator[0x300],cwc[0x600],context[0x80];
static unsigned char client_context[0x140];
static unsigned char managed_space[0x30];
static void *list_node[2];
static rect bounds={12,44,720,900},empty_region={0},crop_region;
static int shell_live,source_alpha_writes,source_clip_writes,released_shells,space_moves;
static int source_alpha_held,retained_releases,gpu_status;
static double native_alpha;
static struct ctx *engine(void){return (void *)engine_bytes;}
static int main_thread(void){return 1;}
static void *lookup(unsigned wid){return wid==1?source:wid==2 && shell_live?shell:0;}
static rect bounding_box(void *p){return *(rect *)p;}
static void *region(rect r){crop_region=r;return &crop_region;}
static void release_region(void *p){(void)p;}
static void clip(void *owner,void *r,unsigned *wids,unsigned count){
    (void)owner;assert(count==1);char *w=lookup(*wids);assert(w);
    *(void **)(w+0x160)=r;if(*wids==1)source_clip_writes++;
}
static void alpha(void *owner,void *win,float value,float duration){
    (void)owner;(void)duration;
    if(win==source){native_alpha=value;source_alpha_writes++;source_alpha_held=*(void **)(source+0x160)==state.empty_clip;}
}
static void transform(void *owner,unsigned *wids,unsigned *key,double *m){(void)owner;(void)wids;(void)key;(void)m;}
static void order(void *owner,unsigned wid,int op,unsigned relative){(void)owner;(void)wid;(void)op;(void)relative;}
static void level(void *win,void *owner,int value,short sub){(void)owner;*(int *)((char *)win+0x20)=value;*(short *)((char *)win+0x28)=sub;}
static void destroy_window(void *owner,void *win){(void)owner;assert(win==shell);shell_live=0;released_shells++;}
static void remove_callback(void *fn,unsigned type,void *p){(void)fn;(void)type;(void)p;}
static u64 message(void *obj,void *selector){(void)obj;(void)selector;return (u64)gpu_status;}
static void release_object(void *obj){(void)obj;retained_releases++;}
static void *space_lookup(u64 id){assert(id==55);return managed_space;}
static void *window_list(void *owner,const unsigned *wids,unsigned count){assert(owner==creator && count==1 && *wids==1);return list_node;}
static void move_space(void *owner,void *list,void *managed){assert(owner==creator && list==list_node && managed==(void *)0x1240);space_moves++;}
static void free_list(void *p){assert(p==list_node);}

static void reset(void){
    memset(engine_bytes,0,sizeof(engine_bytes));memset(&channel,0,sizeof(channel));memset(&state,0,sizeof(state));
    memset(source,0,sizeof(source));memset(shell,0,sizeof(shell));memset(creator,0,sizeof(creator));
    memset(cwc,0,sizeof(cwc));memset(context,0,sizeof(context));memset(managed_space,0,sizeof(managed_space));
    shell_live=1;source_alpha_writes=source_clip_writes=released_shells=space_moves=retained_releases=0;
    source_alpha_held=0;native_alpha=1;gpu_status=4;
    struct ctx *c=engine();c->ch=&channel;c->by_id=lookup;c->bbox=bounding_box;c->shape_off=0x170;
    c->set_alpha=alpha;c->clip=clip;c->rgn=region;c->release=release_region;c->set_xform=transform;
    c->order=order;c->set_level=level;c->rel_win=destroy_window;c->rm_cb=remove_callback;c->msg=(void *)message;
    c->space_for_id=space_lookup;c->wlist=window_list;c->wmove=move_space;c->xfree=free_list;
    channel.h.magic=CH_MAGIC;channel.h.size=sizeof(channel);channel.h.now=1;
    state.magic=BIRTH_MAGIC;state.size=sizeof(state);state.version=1;state.engine=c;state.is_main=main_thread;
    state.enabled=state.registered=1;state.uid=501;state.generation=3;state.policy_epoch=9;state.authority_until=100;
    state.empty_clip=&empty_region;
    *(void **)(engine_bytes+BIRTH_STATE_OFFSET)=&state;
    *(u32 *)source=1;*(u32 *)(source+4)=5;*(void **)(source+0x30)=creator;*(void **)(source+0x18)=cwc;
    *(void **)(source+0x170)=&bounds;*(void **)(cwc+0x30)=context;*(float *)(cwc+0x174)=1;
    *(void **)(cwc+0x48)=client_context;*(u32 *)(cwc+0x50)=77;
    *(u64 *)(creator+0x268)=((u64)7<<32)|42;
    *(u32 *)(creator+0x274)=*(u32 *)(creator+0x27c)=501;*(u32 *)(creator+0x284)=42;*(u32 *)(creator+0x28c)=7;
    *(u32 *)shell=2;*(void **)(shell+0x170)=&bounds;*(void **)(shell+0x8b0)=(void *)0x1300;
    *(void **)(managed_space+0x18)=(void *)0x1240;
    state.capture_api.is_main=main_thread;state.capture_api.status_selector=(void *)1;
    state.capture_api.release_obj=release_object;
}
static struct birth_window *hold(void){
    struct birth_window *w=birth_reserve(&state,(char *)source);assert(w);
    birth_first_order(&state,w,1);assert(w->holding && w->phase==BIRTH_HELD);
    *(u64 *)(source+0x928)|=1ULL<<44;return w;
}
static unsigned ready_capture(struct birth_window *w){
    unsigned index=birth_pool(&state,w);assert(index<BIRTH_CAPTURES);
    struct pc_capture *v=&state.captures[index].pixels;
    v->stage=PC_GPU_COMPLETE;v->gpu_status=4;v->capture_witness=v->source_unchanged=v->present_unchanged=1;
    v->baked_alpha=1;v->context=(u64)context;v->changed_seed=1;
    v->client_context=(u64)client_context;v->client_id=77;v->client_included=1;v->client_commit_sequence=20;
    v->texture_ref=(void *)0x1310;v->command_buffer=(void *)0x1320;
    v->clone=shell;v->clone_wid=2;v->capture=(void *)0x1300;return index;
}
static struct birth_window *adopt(double opacity){
    struct birth_window *w=hold();w->target=bounds;w->pool=ready_capture(w);birth_phase(w,BIRTH_READY);
    struct ch_cmd command={.op=OP_BIRTH,.wid=1,.flags=BIRTH_CLAIM,.cpos=CH_INSTANT,.csize=CH_INSTANT,.calpha=CH_INSTANT,
        .x=12,.y=44,.w=720,.h=900,.fx=12,.fy=44,.fw=720,.fh=900,.a=opacity,.fa=opacity};
    assert(birth_adopt(&state,w,&command,1));assert(w->phase==BIRTH_PRESENTING);
    return w;
}
static struct ch_cmd request(struct birth_window *w,u32 action){
    return (struct ch_cmd){.op=OP_BIRTH,.wid=w->wid,.flags=action,.pad0=(u32)w->token,.pad1=(u32)(w->token>>32)};
}
static void test_stale_and_identity(void){
    reset();struct birth_window *w=hold();struct ch_cmd k=request(w,BIRTH_CLAIM);k.pad0++;
    unsigned clips=source_clip_writes;assert(birth_command(engine(),&k,1.1));
    assert(source_alpha_writes==0 && source_clip_writes==(int)clips && w->phase==BIRTH_HELD);
    *(u32 *)(creator+0x274)=502;assert(!birth_source(&state,w));*(u32 *)(creator+0x274)=501;
    *(u32 *)(creator+0x28c)=8;assert(!birth_source(&state,w));*(u32 *)(creator+0x28c)=7;
    assert(birth_source(&state,w)==(char *)source);
}
static void test_event_replay_and_full_ring(void){
    reset();struct birth_window *w=hold();channel.h.evt_head=CH_NEVT;channel.h.evt_tail=0;
    assert(!birth_event(&state,w,1.1));assert(channel.h.evt_head==CH_NEVT && !w->acknowledged);
    channel.h.evt_tail=1;assert(birth_event(&state,w,1.2));
    struct ch_evt *e=&channel.evt[0];assert(e->type==EV_BIRTH && e->wid==1 && e->x==(u32)w->token && e->y==(u32)(w->token>>32));
    struct ch_cmd ack=request(w,BIRTH_ACK);ack.x=BIRTH_READY;birth_command(engine(),&ack,1.2);assert(!w->acknowledged);
    ack.x=BIRTH_HELD;birth_command(engine(),&ack,1.2);assert(w->acknowledged && w->holding);
}
static void test_alpha_before_reveal(void){
    for(unsigned i=0;i<2;i++) {
        double opacity=i?0:.6;
        reset();struct birth_window *w=adopt(opacity);struct ch_win *sw=slot(&channel,1,0);
        assert(native_alpha==1 && sw->cur_alpha==opacity);
        w->fresh=ready_capture(w);assert(birth_retire_cover(engine(),w->p8,0,1.1));
        assert(!w->holding && w->phase==BIRTH_REVEALED && source_alpha_held);
        assert(dabs(native_alpha-opacity)<.001 && released_shells==1 && !P8_TAB(engine())[0].live);
    }
}
static void test_stop_and_quarantine(void){
    reset();struct birth_window *w=adopt(.6);w->fresh=ready_capture(w);
    struct pc_capture *v=&state.captures[w->fresh].pixels;v->stage=PC_ENCODED;v->gpu_pending=1;v->clone=0;v->clone_wid=0;v->capture=0;
    gpu_status=3;channel.h.stop=1;birth_tick(engine(),1.1,0);birth_tick(engine(),1.1,1);
    assert(!w->holding && !shell_live && !state.empty_clip && !slot(&channel,1,0));
    assert(native_alpha==1 && !state.registered && v->gpu_pending && v->command_buffer);
    assert(*(void **)(source+0x160)==0);
}
static void test_invalid_channel_cleanup(void){
    reset();struct birth_window *w=adopt(.6);struct ch_win before=*slot(&channel,1,0);
    channel.h.size=1;channel.h.stop=1;anim_tick(engine(),1.1);
    assert(!w->holding && !shell_live && !state.empty_clip && *(void **)(source+0x160)==0);
    assert(memcmp(&channel.win[0],&before,sizeof(before))==0 && source_alpha_writes==0);
}
static void test_space_and_snapshot(void){
    reset();struct birth_window *w=adopt(.6);struct ch_cmd k={.op=OP_SNAP,.wid=1};
    assert(birth_command(engine(),&k,1.1) && w->holding);
    k=(struct ch_cmd){.op=OP_SPACE,.wid=1,.x=55};apply_cmd(engine(),&k,1.1);
    assert(space_moves==1 && !w->holding && !shell_live && !slot(&channel,1,0));
}
static void test_role_and_foreign_masks(void){
    reset();struct birth_window *w=adopt(.6);*(int *)(source+0x20)=3;
    birth_tick(engine(),1.1,0);assert(!w->holding && !shell_live && !slot(&channel,1,0));
    reset();w=adopt(.6);*(void **)(source+0x148)=(void *)0x1500;*(void **)(source+0x8d8)=(void *)0x1510;
    birth_tick(engine(),1.1,0);assert(!w->holding && w->phase==BIRTH_CONFLICT && !shell_live);
    assert(*(void **)(source+0x160)==0 && *(void **)(source+0x148)==(void *)0x1500 && *(void **)(source+0x8d8)==(void *)0x1510);
    assert(source_alpha_writes==0);
    reset();w=adopt(.6);*(void **)(source+0x160)=(void *)0x1520;unsigned clips=source_clip_writes;
    birth_tick(engine(),1.1,0);assert(!w->holding && !shell_live && source_clip_writes==(int)clips);
    assert(*(void **)(source+0x160)==(void *)0x1520 && source_alpha_writes==0);
}
static void test_reused_wid_raw_pointer_aba(void){
    reset();struct birth_window *old=adopt(.6);u64 token=old->token;unsigned clips=source_clip_writes;
    struct birth_window *next=birth_reserve(&state,(char *)source);
    assert(next && next!=old && next->token!=token && old->superseded && !birth_source(&state,old));
    assert(!slot(&channel,1,0) && !shell_live && !source_alpha_writes && source_clip_writes==(int)clips);
    assert(channel.h.evt_head==0); // No old EV_GONE may be attributed to the new WID.
    *(void **)(source+0x160)=0;*(u64 *)(source+0x928)&=~(1ULL<<44);birth_first_order(&state,next,1);
    assert(next->holding && birth_find(&state,1)==next);
    struct ch_cmd old_cancel=request(old,BIRTH_CANCEL);birth_command(engine(),&old_cancel,1.1);assert(next->holding);
    reset();old=adopt(.6);old->fresh=ready_capture(old);birth_retire_cover(engine(),old->p8,0,1.1);
    // Model completed resource cleanup and terminal ACK, leaving normal source ownership.
    old->pool=old->fresh=BIRTH_NONE;old->acknowledged=1;birth_reap(old);assert(!old->wid && slot(&channel,1,0));
    source_alpha_writes=0;clips=source_clip_writes;next=birth_reserve(&state,(char *)source);
    assert(next && !slot(&channel,1,0) && !source_alpha_writes && source_clip_writes==(int)clips);
}
static void test_ack_before_gpu_retirement(void){
    reset();struct birth_window *w=hold();w->target=bounds;w->pool=ready_capture(w);
    struct pc_capture *v=&state.captures[w->pool].pixels;
    v->clone=0;v->clone_wid=0;v->capture=0;v->stage=PC_ENCODED;v->gpu_pending=1;
    birth_cancel(&state,w);struct ch_cmd ack=request(w,BIRTH_ACK);ack.x=BIRTH_CANCELLED;birth_command(engine(),&ack,1.1);
    assert(w->wid==1 && w->acknowledged);gpu_status=3;birth_tick(engine(),1.1,1);assert(w->wid==1);
    gpu_status=4;birth_tick(engine(),1.2,1);assert(w->wid==0 && retained_releases==2);
}
static void test_redraw_and_failed_capture_retry(void){
    reset();struct birth_window *w=hold();w->target=bounds;w->pool=ready_capture(w);
    *(u32 *)(context+0x2c)=100;assert(birth_capture_ready(&state,w,w->pool));
    state.captures[w->pool].retiring=1;assert(!birth_capture_ready(&state,w,w->pool));
    state.captures[w->pool].retiring=0;state.captures[w->pool].pixels.stage=PC_GPU_ERROR;
    state.captures[w->pool].pixels.clone=0;state.captures[w->pool].pixels.clone_wid=0;state.captures[w->pool].pixels.capture=0;
    birth_phase(w,BIRTH_PREPARING);birth_tick(engine(),1.1,1);assert(state.captures[w->pool].retiring);
    birth_tick(engine(),1.2,1);assert(w->pool==BIRTH_NONE);
    birth_tick(engine(),1.3,0);assert(w->pool<BIRTH_CAPTURES && state.captures[w->pool].pixels.stage==PC_EMPTY);
}
static void test_client_update_provenance(void){
    reset();struct birth_window *w=hold();w->target=bounds;w->pool=ready_capture(w);
    struct pc_capture *v=&state.captures[w->pool].pixels;
    _Alignas(16) unsigned char update[0x148]={0},outer_entry[0x40]={0},client_entry[0x40]={0},local_state[0xe0]={0};
    *(void **)(update+0x140)=outer_entry;*(void **)outer_entry=client_entry;
    *(void **)(outer_entry+8)=context;*(u32 *)(outer_entry+0x18)=99;
    *(void **)(client_entry+8)=client_context;*(u32 *)(client_entry+0x18)=20;*(u32 *)(local_state+0xdc)=11;
    assert(pc_client_commit(v,update,(char *)cwc,(char *)local_state));
    assert(v->client_commit_sequence==20 && v->client_transaction_seed==11 && v->client_id==77);
    *(u32 *)(client_context+0x40)=21;assert(birth_capture_ready(&state,w,w->pool)); // Later commit preserves immutable pixels.
    *(u32 *)(cwc+0x50)=78;assert(!birth_capture_ready(&state,w,w->pool));*(u32 *)(cwc+0x50)=77;
    *(void **)outer_entry=0;assert(!pc_client_commit(v,update,(char *)cwc,(char *)local_state));
    assert(!birth_capture_ready(&state,w,w->pool)); // Outer wrapper alone is insufficient.
}
static void test_frame_callback_ownership(void){
    reset();struct pc_node foreign={0,(void *)0x2100,(void *)0x2110},*head=&foreign;
    state.metal_callbacks=&head;state.frame_callback=(void *)0x2120;
    assert(birth_frame_node(&state,1) && head==&state.node && state.node.next==&foreign);
    assert(birth_frame_node(&state,1) && state.node.next==&foreign); // No duplicate link/cycle.
    assert(birth_frame_node(&state,0) && head==&foreign && !state.node_linked);
    assert(foreign.fn==(void *)0x2100 && foreign.ctx==(void *)0x2110);
    assert(birth_frame_node(&state,1));state.node.ctx=0;
    assert(!birth_frame_node(&state,0) && head==&state.node && state.node_conflict);
}
int main(void){
    test_stale_and_identity();test_event_replay_and_full_ring();test_alpha_before_reveal();
    test_stop_and_quarantine();test_invalid_channel_cleanup();test_space_and_snapshot();
    test_role_and_foreign_masks();test_reused_wid_raw_pointer_aba();test_ack_before_gpu_retirement();
    test_redraw_and_failed_capture_retry();
    test_client_update_provenance();test_frame_callback_ownership();
    puts("PASS: 12 native birth transition groups (fakes; no GUI/pixel claims)");return 0;
}
