// Transaction/authority CPU checks, not proof of native dirty coverage or pixels.
#define main paired_contract_main
#include "display_pair_test.c"
#undef main
#include <setjmp.h>

static struct display_source_sink sink;
static struct display_transition transition;
static struct display_damage_command command;
static struct rgba_capture capture;
static struct rgba_view view;
static _Alignas(16) char session[0x200],scheduler[0x180],display_object[0x800];
static void *vector[2];
static int full_region,dirty_region,native_shape,vtable_token;
static unsigned invalidations,contains_calls,generated,flip_request,coverage,expected_mode;
static unsigned wrong_shape,throw_contains,caught_fault,create_calls,create_action;
static jmp_buf interrupted;
static rect bounds(void *r) {
    assert(r==&native_shape || r==&full_region);
    if(r==&full_region && create_action==4)longjmp(interrupted,1);
    rect b=transition.footprint;
    if((r==&native_shape && wrong_shape) || (r==&full_region && create_action==2))b.x++;
    return b;
}
static void *create_region(rect r) {
    assert(rgba_view_same(r,transition.footprint));
    assert(transition.damage.phase==DISPLAY_DAMAGE_PREPARING && pair.active_epoch &&
           pair.probe.inflight==1 && !sink.enabled);
    create_calls++;
    if(create_action==3)longjmp(interrupted,1);
    return create_action==1?0:&full_region;
}
static float alpha(void *w) {assert(w==windows[1]);return *(float *)(windows[1]+0x1d8);}
static void unused_alpha(void *c,void *w,float a,float duration){(void)c;(void)w;(void)a;(void)duration;assert(0);}
static void invalidate_region(void *connection,void *window,void *r) {
    assert(!connection && !window && r==&full_region);
    assert(transition.damage.phase==DISPLAY_DAMAGE_INVALIDATING && !sink.enabled);
    invalidations++;
}
static int contains_region(void *container,void *target) {
    assert(container==&dirty_region && target==&full_region);
    assert(transition.damage.phase==DISPLAY_DAMAGE_OBSERVING);
    contains_calls++;
    if(throw_contains)longjmp(interrupted,1);
    return (int)coverage;
}
static void *retain_region(void *p){return p;}
static void release_region(void *p){(void)p;}
static int generate(void *r,void *w){(void)r;assert(w==windows[0] || w==windows[1]);generated++;return 23;}
static int original_transition(void *connection,u64 force,void *begin,void *end) {
    assert(connection==(void *)0x100 && force==0 && begin==vector && end==vector+2);
    u64 word=transition.damage.entry_word;
    int admitted=word && pair.probe.inflight==1 && transition.damage.phase==DISPLAY_DAMAGE_ACTIVE &&
        transition.damage.epoch==pair.active_epoch;
    if(admitted) {
        assert(sink.enabled==(word&1) && (word&1)==expected_mode);
        assert(pair.active_revision==(word>>1));
        if(flip_request)__atomic_store_n(&command.request,6,__ATOMIC_RELEASE);
    } else if(pair.probe.inflight==1)assert(!sink.enabled);
    unsigned char *r=(unsigned char *)(stack+0x3000-0xb40);
    struct display_source_step step={.epoch=pair.active_epoch,.revision=pair.active_revision,
                                    .head=(void **)(stack+0x3000-0xb88),.role=0};
    assert(display_source_call(r,windows[0],generate,&sink.source,step,&sink)==23);
    step.role=1;
    assert(display_source_call(r,windows[1],generate,&sink.source,step,&sink)==(admitted && sink.enabled?0:23));
    if(admitted) {
        struct display_pair_record record={.event=DISPLAY_PAIR_FRAME,.epoch=pair.active_epoch,
            .revision=pair.active_revision,.redraw=(u64)r,.display=(u64)display_object,
            .found_mask=sink.enabled?1:3};
        display_transition_observe(&transition,&pair,&record,(char *)r);
        // Model native catching an interruption after a positive callback.
        if(caught_fault==1) {sink.source.inflight=1;sink.source.entered=1;}
        if(caught_fault==2)sink.workspace.phase=1;
    }
    return 0;
}
static void setup(void) {
    reset();memset(&sink,0,sizeof(sink));memset(&transition,0,sizeof(transition));
    memset(&command,0,sizeof(command));memset(&capture,0,sizeof(capture));memset(&view,0,sizeof(view));
    memset(session,0,sizeof(session));memset(scheduler,0,sizeof(scheduler));memset(display_object,0,sizeof(display_object));
    invalidations=contains_calls=generated=flip_request=expected_mode=wrong_shape=throw_contains=caught_fault=0;coverage=1;
    create_calls=create_action=0;
    engine.session=pair.session=session;*(void **)(control+0x20)=session;
    *(void **)(session+0x138)=scheduler;
    pair.enabled=1;pair.probe.callers[0]=100;pair.probe.callers[1]=101;
    sink.magic=DISPLAY_SOURCE_SINK_MAGIC;sink.size=sizeof(sink);sink.version=1;
    sink.source.magic=DISPLAY_SOURCE_MAGIC;sink.source.size=sizeof(sink.source);sink.source.version=1;
    sink.source.pair=&pair;sink.source.enabled=1;sink.source.normal_return=0x186e13244;
    sink.profile_verified=sink.a_unfenced=1;
    sink.api=(struct display_sink_api){0,retain_region,release_region,release_region,release_region};
    capture.magic=RGBA_MAGIC;capture.size=sizeof(capture);capture.version=RGBA_VERSION;
    capture.pc.magic=PC_MAGIC;capture.pc.size=sizeof(capture.pc);capture.pc.version=1;capture.pc.engine=&engine;
    capture.pc.source=pair.identity[0].window;capture.pc.wid=pair.identity[0].wid;
    capture.pc.creator=pair.identity[0].creator;capture.pc.pid_version=pair.identity[0].pid_version;
    capture.pc.capture_witness=1;capture.pc.stage=3;capture.pc.gpu_status=capture.clear_status=4;
    capture.pc.texture_ref=(void *)0x777;
    view.magic=RGBA_VIEW_MAGIC;view.size=sizeof(view);view.version=RGBA_VIEW_VERSION;view.capture=&capture;
    view.window=windows[1];view.wid=42;view.context=(void *)pair.identity[1].local_context;
    view.context_id=pair.identity[1].client_id;view.bound=view.prepared=view.shown=1;
    view.api.effective_alpha=alpha;view.current_alpha=view.alpha=1;
    view.source_wid=capture.pc.wid;view.source_creator=capture.pc.creator;
    view.source_pid_version=capture.pc.pid_version;view.texture=capture.pc.texture_ref;
    view.current=view.target=(rect){538,318,720,446};view.display_bounds=(rect){0,0,1470,956};view.display=77;
    *(u64 *)(windows[1]+0x928)=1ULL<<44;
    *(float *)(windows[1]+0x1d8)=*(float *)(windows[1]+0x1dc)=1;
    *(float *)(windows[1]+0x1e0)=*(float *)(windows[1]+0x1e4)=1;
    *(void **)(windows[1]+0x170)=&native_shape;engine.shape_off=0x170;engine.bbox=bounds;
    engine.set_alpha=unused_alpha;engine.rgn=create_region;
    transition.magic=DISPLAY_TRANSITION_MAGIC;transition.size=sizeof(transition);transition.version=1;
    transition.sink=&sink;transition.view=&view;transition.scheduler=scheduler;
    transition.footprint=view.current;transition.display_bounds=view.display_bounds;transition.display=77;
    transition.display_vtable=&vtable_token;transition.contains=contains_region;
    transition.capture_witness=1;
    struct display_damage *d=&transition.damage;
    d->magic=DISPLAY_DAMAGE_MAGIC;d->size=sizeof(*d);d->version=1;d->enabled=1;
    d->region=&full_region;d->invalidate=invalidate_region;d->command=&command;
    command.magic=DISPLAY_DAMAGE_COMMAND_MAGIC;command.size=sizeof(command);command.version=1;command.request=2;
    *(void **)display_object=&vtable_token;*(u32 *)(display_object+0x1e8)=77;
    *(rect *)(display_object+0x240)=view.display_bounds;*(float *)(display_object+0x53c)=2;
    const double matrix[4][6]={{2,0,0,2,0,0},{.5,0,0,.5,0,0},{1,0,0,1,0,0},{1,0,0,1,0,0}};
    const unsigned offset[4]={0x330,0x360,0x390,0x3c0};
    for(unsigned i=0;i<4;i++)memcpy(display_object+offset[i],matrix[i],sizeof(matrix[i]));
    vector[0]=display_object;vector[1]=0;
    *(void **)(stack+0x3000-0xb40+0x58)=&dirty_region;
}
static void invoke(u64 caller) {
    assert(display_pair_dispatch((void *)0x100,0,vector,vector+2,&pair,original_transition,caller,&transition,0)==0);
    assert(!sink.enabled && !pair.active_epoch && !pair.probe.inflight);
}
#ifndef DISPLAY_TRANSITION_TEST_NAME
#define DISPLAY_TRANSITION_TEST_NAME main
#endif
int DISPLAY_TRANSITION_TEST_NAME(void) {
    setup();invoke(100);
    assert(invalidations==1 && contains_calls==1 && generated==2 && command.completed==2);
    assert(transition.damage.phase==DISPLAY_DAMAGE_IDLE && !transition.entry_display);
    invoke(100);assert(invalidations==1 && command.completed==2);
    command.request=5;expected_mode=1;flip_request=1;invoke(100);
    assert(invalidations==2 && command.request==6 && command.completed==5 && sink.completed==1);
    flip_request=0;expected_mode=0;invoke(100);
    assert(invalidations==3 && command.completed==6 && sink.completed==1);

    setup();coverage=0;invoke(100);
    assert(!command.completed && invalidations==1 && transition.uncovered_frames==1);
    coverage=1;invoke(100);assert(command.completed==2 && invalidations==2);
    setup();transition.damage.region=0;invoke(100);
    assert(create_calls==1 && command.completed==2 && transition.damage.region==&full_region);
    invoke(100);assert(create_calls==1 && invalidations==1);
    for(unsigned i=1;i<=2;i++) {
        setup();transition.damage.region=0;create_action=i;invoke(100);
        assert(create_calls==1 && !invalidations && !contains_calls && !command.completed);
        assert(transition.damage.phase==DISPLAY_DAMAGE_PREPARE_FAILED);
        assert(transition.damage.region==(i==1?0:&full_region));
        invoke(100);assert(create_calls==1 && !invalidations && !command.completed);
    }
    for(unsigned i=3;i<=4;i++) {
        setup();transition.damage.region=0;create_action=i;
        if(!setjmp(interrupted)) {invoke(100);assert(!"preparation interruption returned");}
        assert(create_calls==1 && transition.damage.phase==DISPLAY_DAMAGE_PREPARING);
        assert(transition.damage.region==(i==3?0:&full_region) && !command.completed);
        assert(display_pair_dispatch((void *)0x100,0,vector,vector+2,&pair,
                                     original_transition,100,&transition,0)==0);
        assert(create_calls==1 && !invalidations && !command.completed);
        assert(transition.damage.phase==DISPLAY_DAMAGE_PREPARING);
    }
    setup();invoke(101);assert(!invalidations && !contains_calls && !command.completed);
    setup();main_thread=0;invoke(100);assert(!invalidations && !contains_calls);
    for(unsigned i=0;i<20;i++) {
        setup();
        switch(i) {
        case 0:*(u32 *)(scheduler+0x148)=128;break;
        case 1:*(int *)(scheduler+0xb0)=1;break;
        case 2:transition.scheduler=(void *)1;break;
        case 3:*(int *)(display_object+0x540)=90;break;
        case 4:*(float *)(display_object+0x53c)=1;break;
        case 5:*(double *)(display_object+0x330)=3;break;
        case 6:*(unsigned char *)(display_object+0x76f)=16;break;
        case 7:wrong_shape=1;break;
        case 8:*(float *)(windows[1]+0x1d8)=.5;break;
        case 9:sink.a_unfenced=0;break;
        case 10:++*(u32 *)(cwcs[1]+0x50);break;
        case 11:view.command=1;break;
        case 12:view.target.x++;break;
        case 13:transition.damage.enabled=0;break;
        case 14:capture.pc.source++;break;
        case 15:capture.pc.capture_witness++;break;
        case 16:capture.pc.gpu_status=3;break;
        case 17:capture.pc.command=1;break;
        case 18:view.texture=(void *)0x778;break;
        case 19:capture.pc.pid_version++;break;
        }
        invoke(100);assert(!invalidations && !contains_calls && !command.completed);
    }
    for(unsigned i=1;i<=2;i++) {
        setup();caught_fault=i;invoke(100);
        assert(transition.frame_epoch && transition.frame_word==2);
        assert(invalidations==1 && contains_calls==1 && !command.completed);
        assert(transition.damage.phase==DISPLAY_DAMAGE_ACTIVE && transition.damage.entry_word==2);
        assert(transition.entry_display && !sink.enabled);
        invoke(100);assert(invalidations==1 && contains_calls==1 && !command.completed);
        assert(transition.damage.phase==DISPLAY_DAMAGE_ACTIVE);
    }
    setup();throw_contains=1;
    if(!setjmp(interrupted)) {invoke(100);assert(!"predicate interruption returned");}
    assert(transition.damage.phase==DISPLAY_DAMAGE_OBSERVING && !command.completed);
    assert(pair.probe.inflight==1 && contains_calls==1);
    // A subsequent nested entry cannot run another mutation or reset quarantine.
    throw_contains=0;assert(display_pair_dispatch((void *)0x100,0,vector,vector+2,&pair,
                              original_transition,100,&transition,0)==0);
    assert(invalidations==1 && contains_calls==1 && transition.damage.phase==DISPLAY_DAMAGE_OBSERVING);
    puts("display_transition authority, immutable A/B latch, current coverage and quarantine: PASS");
    return 0;
}
