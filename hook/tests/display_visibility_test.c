// Normal-return native control and interruption custody, not pixel evidence.
#define DISPLAY_TRANSITION_TEST_NAME transition_contract_main
#include "display_transition_test.c"
static struct display_visibility visibility;
static struct display_visibility_command visibility_command;
static _Alignas(16) unsigned char visibility_engine[0x4000];
static struct ctx *ve=(void *)visibility_engine;
static unsigned timer_calls,alpha_calls,order_calls,fail_alpha,fail_order,control_fault,reenter,host_publish;
static unsigned policy_case,policy_calls,change_policy;
static int policy_key,policy_dictionary;
static int native_policy(void *dictionary,const void *key,unsigned char *value) {
    assert(dictionary==&policy_dictionary && key==&policy_key && value && *value==0xa5);
    assert(visibility.phase==DISPLAY_VISIBILITY_CHECKING || visibility.phase==DISPLAY_VISIBILITY_APPLYING ||
           visibility.phase==DISPLAY_VISIBILITY_REVOKING);
    policy_calls++;
    if(control_fault==7)longjmp(interrupted,1);
    if(policy_case==0)return 0;
    if(policy_case==3)return 2;
    *value=policy_case==1?0:policy_case==2?1:2;return 1;
}
static int visibility_contains(void *clip,void *region) {
    assert(clip==&dirty_region && region==&full_region && visibility.phase==DISPLAY_VISIBILITY_OBSERVING);
    contains_calls++;
    if(control_fault==5)longjmp(interrupted,1);
    return coverage;
}
static u32 native_display(void *w){assert(w==windows[1]);return view.display;}
static void native_invalidate(void *a,void *b,void *r) {
    assert(!a && !b && r==&full_region && visibility.phase==DISPLAY_VISIBILITY_INVALIDATING);
    invalidations++;
    if(control_fault==4)longjmp(interrupted,1);
}
static void native_alpha(void *connection,void *w,float a,float duration) {
    assert(!connection && !duration && w==windows[1] && !ve->in_cb);
    assert(visibility.phase==DISPLAY_VISIBILITY_APPLYING);alpha_calls++;
    if(host_publish)visibility_command.request=9;
    if(reenter) {
        u64 receipt=display_visibility_entry_begin(&visibility,0);
        assert(receipt==visibility.committed && receipt!=(visibility_command.request<<2));
        display_visibility_entry_end(&visibility,receipt);
    }
    if(control_fault==1)longjmp(interrupted,1);
    if(!fail_alpha)*(float *)(windows[1]+0x1d8)=*(float *)(windows[1]+0x1e4)=a;
    if(change_policy)policy_case=2;
}
static int native_order(void *connection,u32 wid,int order,u32 relative) {
    assert(!connection && wid==42 && !order && !relative && !ve->in_cb);
    assert(visibility.phase==DISPLAY_VISIBILITY_REVOKING);order_calls++;
    if(control_fault==2)longjmp(interrupted,1);
    if(fail_order)return 1;
    anim_will_release(0x3ea,0,0,ve);assert(!ve->in_cb);
    *(u64 *)(windows[1]+0x928)&=~(1ULL<<44);return 0;
}
static void *native_region(rect r) {
    assert(rgba_view_same(r,visibility.footprint) && visibility.phase==DISPLAY_VISIBILITY_PREPARING);
    create_calls++;
    if(control_fault==3)longjmp(interrupted,1);
    return create_action==1?0:&full_region;
}
static void timer(struct ctx *c,double now) {
    assert(c==ve && now==1.25);timer_calls++;
    if(control_fault==6)longjmp(interrupted,1);
}
static void visibility_setup(void) {
    setup();memset(&visibility,0,sizeof(visibility));memset(&visibility_command,0,sizeof(visibility_command));
    timer_calls=alpha_calls=order_calls=fail_alpha=fail_order=control_fault=reenter=host_publish=0;
    visibility.magic=DISPLAY_VISIBILITY_MAGIC;visibility.size=sizeof(visibility);visibility.version=DISPLAY_VISIBILITY_VERSION;
    visibility.sink=&sink;visibility.view=&view;visibility.command=&visibility_command;
    visibility.invalidate=native_invalidate;visibility.footprint=view.current;
    visibility.capture_witness=1;visibility.enabled=1;
    visibility.get_boolean=native_policy;visibility.fade_on_order_out_key=&policy_key;
    policy_case=policy_calls=change_policy=0;*(void **)(windows[1]+0x88)=&policy_dictionary;
    visibility.profile=&transition;transition.contains=visibility_contains;
    visibility_command.magic=DISPLAY_VISIBILITY_COMMAND_MAGIC;
    visibility_command.size=sizeof(visibility_command);visibility_command.version=1;visibility_command.request=4;
    engine.set_alpha=native_alpha;engine.rgn=native_region;view.api.order=native_order;
    view.api.display_id=native_display;capture.pc.is_main=is_main;
    *(void **)(windows[0]+0x170)=&native_shape;capture.pc.capture_rect=view.current;
    memset(visibility_engine,0,sizeof(visibility_engine));memcpy(ve,&engine,sizeof(engine));
    pair.probe.engine=ve;capture.pc.engine=ve;
}
static void run_control(void){anim_display_visibility_dispatch(ve,1.25,&visibility,timer);}
int main(void) {
    u64 receipt;
    visibility_setup();run_control();
    assert(timer_calls==1 && alpha_calls==1 && !order_calls && invalidations==1 && create_calls==1);
    assert(visibility_command.completed==4 && visibility.committed==17 && !visibility.phase);
    assert(view.current_alpha==0 && !ve->in_cb);
    run_control();assert(timer_calls==2 && alpha_calls==1 && invalidations==1);
    visibility_command.request=9;run_control();
    assert(visibility_command.completed==9 && visibility.committed==38 && view.current_alpha==1 && create_calls==1);
    visibility_command.request=14;run_control();
    assert(visibility_command.completed==14 && visibility.committed==59 && visibility.terminal && !view.shown);
    visibility_command.request=17;run_control();assert(alpha_calls==2 && order_calls==1);

    visibility_setup();host_publish=1;run_control();
    assert(visibility_command.request==9 && visibility_command.completed==4 && visibility.committed==17);
    host_publish=0;run_control();assert(visibility_command.completed==9 && visibility.committed==38);
    // Pending mailbox changes cannot change a committed entry receipt.
    visibility_command.request=12;
    for(unsigned kind=0;kind<4;kind++) {
        u64 receipt=display_visibility_entry_begin(&visibility,kind==3?0:100+kind);
        assert(receipt==38 && visibility.entry_receipt==38);
        display_visibility_entry_end(&visibility,receipt);
    }
    assert(visibility.entered==4 && visibility.returned==4 && visibility.unknown==1 && visibility.last_receipt==38);
    u64 outer=display_visibility_entry_begin(&visibility,100);
    u64 inner=display_visibility_entry_begin(&visibility,101);
    display_visibility_entry_end(&visibility,inner);assert(visibility.entry_receipt==38);
    display_visibility_entry_end(&visibility,outer);assert(!visibility.inflight && !visibility.entry_receipt);
    main_thread=0;u64 nonmain_receipt=display_visibility_entry_begin(&visibility,100);
    assert(!nonmain_receipt);display_visibility_entry_end(&visibility,nonmain_receipt);main_thread=1;
    assert(visibility.nonmain==1 && !visibility.inflight);

    // Positive outer frame -> nested normal return -> outer fault must never
    // publish construction. The latch alone carries no completion authority.
    visibility_setup();run_control();
    outer=display_visibility_entry_begin(&visibility,100);
    pair.active_epoch=pair.epochs=7;pair.probe.inflight=1;pair.probe.entered=1;
    visibility.frame_receipt=outer;visibility.frame_epoch=7;
    inner=display_visibility_entry_begin(&visibility,100);
    display_visibility_construction_end(&visibility,inner,0);
    assert(!visibility_command.constructed);
    display_visibility_entry_end(&visibility,inner);
    // A caught native/source interruption after the positive frame is sticky.
    pair.active_epoch=0;pair.probe.inflight=0;pair.probe.returned=1;sink.source.inflight=1;
    display_visibility_construction_end(&visibility,outer,0);assert(!visibility_command.constructed);
    sink.source.inflight=0;display_visibility_construction_end(&visibility,outer,7);
    assert(!visibility_command.constructed);
    display_visibility_construction_end(&visibility,outer,0);assert(visibility_command.constructed==4);
    display_visibility_entry_end(&visibility,outer);

    // Every pre-mutation imbalance refuses before even a native getter/region.
    for(unsigned bad=0;bad<8;bad++) {
        visibility_setup();
        if(bad==0)sink.source.inflight=1;
        if(bad==1)sink.source.entered=1;
        if(bad==2)pair.probe.inflight=1;
        if(bad==3)pair.probe.entered=1;
        if(bad==4)sink.workspace.phase=1;
        if(bad==5)sink.workspace.head=(void *)1;
        if(bad==6)visibility.inflight=1;
        if(bad==7)visibility.entered=1;
        run_control();assert(!alpha_calls && !order_calls && !create_calls && !visibility_command.completed);
    }
    // Terminal inverse does not read/reset quarantined private workspace data.
    visibility_setup();sink.workspace.phase=3;sink.workspace.head=(void *)1;
    visibility_command.request=6;run_control();
    assert(order_calls==1 && visibility.terminal && visibility_command.completed==6);
    assert(sink.workspace.phase==3 && sink.workspace.head==(void *)1);

    visibility_setup();fail_alpha=1;run_control();
    assert(order_calls==1 && visibility.terminal && visibility.committed==19 && visibility_command.completed==4);
    visibility_setup();visibility.refuse_word=4;run_control();
    assert(order_calls==1 && visibility.committed==19 && visibility.terminal);
    visibility_setup();fail_alpha=fail_order=1;run_control();
    assert(visibility.phase==DISPLAY_VISIBILITY_QUARANTINED && !visibility_command.completed);
    run_control();assert(alpha_calls==1 && order_calls==1);
    visibility_setup();reenter=1;run_control();
    assert(visibility.mutating_entries==1 && visibility.phase==DISPLAY_VISIBILITY_QUARANTINED && !visibility.committed);
    visibility_setup();reenter=fail_alpha=1;run_control();
    assert(visibility.mutating_entries==1 && !order_calls && !visibility.committed);
    for(unsigned quiet=0;quiet<4;quiet++) {
        visibility_setup();visibility_command.request=6;
        if(quiet==0)P8_TAB(ve)[0].live=1;
        if(quiet==1){channel.win[0].used=1;channel.win[0].wid=42;}
        if(quiet==2){channel.win[0].used=1;channel.win[0].wid=41;P8_ON(ve)[0]=1;}
        if(quiet==3)ve->in_cb=1;
        run_control();assert(!order_calls && !visibility.committed);
    }
    visibility_setup();channel.h.reserved[0]=1;
    channel.win[0].used=1;channel.win[0].geo=1;channel.win[0].wid=41;
    visibility_command.request=6;run_control();
    assert(order_calls==1 && !ve->in_cb && visibility.terminal && !P8_ON(ve)[0]);
    // Real C++ OWN unwind is a separate gate. Here longjmp models unreturned
    // helper custody and verifies no fabricated inverse/completion or retry.
    for(unsigned fault=1;fault<=4;fault++) {
        visibility_setup();control_fault=fault;if(fault==2)visibility_command.request=6;
        if(!setjmp(interrupted)){run_control();assert(0);}
        assert(visibility.phase && !visibility.committed && !visibility_command.completed && !ve->in_cb);
        unsigned before_alpha=alpha_calls,before_order=order_calls,before_create=create_calls;
        run_control();assert(alpha_calls==before_alpha && order_calls==before_order && create_calls==before_create);
        if(fault==1)assert(!order_calls);
        if(fault==3)assert(!visibility.region);
        if(fault==4)assert(visibility.region==&full_region);
    }
    visibility_setup();control_fault=6;
    if(!setjmp(interrupted)){run_control();assert(0);}
    assert(!visibility.phase && !visibility.claimed && !alpha_calls && !order_calls &&
           visibility.timer_inflight==1 && visibility.timer_entered==1 && !visibility.timer_returned);
    control_fault=0;run_control();assert(!alpha_calls && !visibility.committed);
    visibility_setup();create_action=1;run_control();
    assert(visibility.phase==DISPLAY_VISIBILITY_QUARANTINED && !alpha_calls && !visibility.committed);
    visibility_setup();*(u64 *)(windows[1]+0x928)|=1ULL<<23;policy_case=2;run_control();
    assert(!alpha_calls && !order_calls && visibility.reason==DISPLAY_VISIBILITY_PROFILE);
    for(unsigned policy=0;policy<=1;policy++) {
        visibility_setup();*(u64 *)(windows[1]+0x928)|=1ULL<<23;policy_case=policy;
        run_control();assert(alpha_calls==1 && policy_calls==1 && visibility_command.completed==4);
        visibility_command.request=9;run_control();assert(visibility_command.completed==9 && policy_calls==2);
        visibility_command.request=14;run_control();assert(order_calls==1 && visibility.terminal && visibility_command.completed==14);
    }
    for(unsigned policy=3;policy<=4;policy++) {
        visibility_setup();*(u64 *)(windows[1]+0x928)|=1ULL<<23;policy_case=policy;
        run_control();assert(!alpha_calls && !order_calls && !visibility.committed);
    }
    visibility_setup();*(u64 *)(windows[1]+0x928)|=1ULL<<23;fail_alpha=1;change_policy=1;
    run_control();assert(alpha_calls==1 && !order_calls && !visibility.committed);
    visibility_setup();*(u64 *)(windows[1]+0x928)|=1ULL<<23;control_fault=7;
    if(!setjmp(interrupted)){run_control();assert(0);}
    assert(visibility.phase==DISPLAY_VISIBILITY_CHECKING && visibility.timer_inflight==1 && !visibility.committed);
    visibility_setup();*(u64 *)(windows[1]+0x928)|=1ULL<<23;
    *(float *)(windows[1]+0x1d8)=*(float *)(windows[1]+0x1e4)=0;view.alpha=view.current_alpha=0;
    policy_case=2;visibility_command.request=6;run_control();
    assert(order_calls==1 && !policy_calls && visibility.terminal && visibility_command.completed==6);
    for(unsigned bad=0;bad<4;bad++) {
        visibility_setup();visibility_command.request=bad==0?0:bad==1?7:bad==2?(~0ULL):3;
        run_control();assert(!alpha_calls && !order_calls && !create_calls);
    }
    visibility_setup();visibility.enabled=0;run_control();assert(timer_calls==1 && !alpha_calls);
    visibility_setup();visibility.view=0;visibility.command=0;
    run_control();assert(timer_calls==1 && !alpha_calls);
    assert(display_visibility_valid(&visibility) && !display_visibility_configured(&visibility));
    receipt=display_visibility_entry_begin(&visibility,100);
    assert(!receipt && visibility.entered==1 && visibility.inflight==1);
    display_visibility_entry_end(&visibility,receipt);assert(visibility.returned==1 && !visibility.inflight);
    // Current prepared opacity + full borrowed R coverage, distinct from apply.
    visibility_setup();run_control();receipt=display_visibility_entry_begin(&visibility,100);
    pair.active_epoch=1;
    struct display_pair_record r={.event=DISPLAY_PAIR_FRAME,.epoch=1,.revision=1,
        .redraw=(u64)(stack+0x3000-0xb40),.display=(u64)display_object,.found_mask=3};
    // Whole-window opacity is zero while the captured local content stays 1.
    r.source[1].alpha=1;
    display_visibility_observe(&visibility,&pair,&r,(char *)r.redraw);
    assert(visibility.covered_frames==1 && visibility.frame_receipt==receipt && visibility.frame_epoch==1);
    assert(!visibility_command.constructed); // Observer alone never completes a full entry.
    *(float *)(cwcs[1]+0x174)=1;
    display_visibility_observe(&visibility,&pair,&r,(char *)r.redraw);assert(visibility.covered_frames==1);
    *(float *)(cwcs[1]+0x174)=0;coverage=0;
    display_visibility_observe(&visibility,&pair,&r,(char *)r.redraw);assert(visibility.uncovered_frames==1);
    coverage=1;control_fault=5;
    if(!setjmp(interrupted)){display_visibility_observe(&visibility,&pair,&r,(char *)r.redraw);assert(0);}
    assert(visibility.phase==DISPLAY_VISIBILITY_OBSERVING && !visibility_command.constructed);
    puts("display visibility CPU: PASS (A-unfenced native-control scope only)");return 0;
}
