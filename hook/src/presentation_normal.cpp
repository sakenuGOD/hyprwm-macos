// Native original exceptions propagate unchanged. Only isolated OWN capture
// failures are caught; the C abort closes its exact lock and quarantines output.
using Original=void *(*)(void *,void *,void *,void **);
extern "C" void anim_rgba_normal_capture(void *,void *,void *,void **,void *,void *,unsigned long long);
extern "C" void anim_rgba_normal_abort(void *) noexcept;
extern "C" void anim_rgba_normal_before(void *,void *,void *,void **,void *,unsigned long long);
extern "C" void anim_rgba_normal_before_abort(void *) noexcept;
extern "C" __attribute__((noinline)) void *anim_rgba_normal_prepare(
        void *compositor,void *head,void *destination,void **shape,void *binding,Original original) {
    try {
        anim_rgba_normal_before(compositor,head,destination,shape,binding,
            (unsigned long long)__builtin_frame_address(0));
    } catch(...) {anim_rgba_normal_before_abort(binding);}
    void *prepared=original(compositor,head,destination,shape);
    try {
        anim_rgba_normal_capture(compositor,head,destination,shape,binding,prepared,
            (unsigned long long)__builtin_frame_address(0));
    } catch(...) {
        anim_rgba_normal_abort(binding);
    }
    return prepared;
}

extern "C" void anim_rgba_close_gate(void *,void **,unsigned,int);
extern "C" void rgba_normal_close_gate(void *capture,void **nodes,unsigned count,int promote) noexcept {
    try {anim_rgba_close_gate(capture,nodes,count,promote);}catch(...) {}
}

using ShapeOriginal=void *(*)(void *,unsigned);
extern "C" void anim_rgba_draw_commands(void *);
extern "C" void anim_rgba_draw_commands_abort(void *) noexcept;
extern "C" __attribute__((noinline)) void rgba_normal_draw_commands(void *context) noexcept {
    try {anim_rgba_draw_commands(context);}
    catch(...) {anim_rgba_draw_commands_abort(context);}
}
extern "C" void *anim_rgba_draw_shape(void *,unsigned,void *,unsigned long long,unsigned);
extern "C" void anim_rgba_draw_release(void *,void *);
extern "C" void anim_rgba_draw_failed(void *) noexcept;
extern "C" __attribute__((noinline)) void *anim_rgba_draw_shape_prepare(
        void *window,unsigned flag,void *binding,ShapeOriginal original,unsigned kind) {
    void *native=original(window,flag);
    try {
        void *replacement=anim_rgba_draw_shape(window,flag,binding,
            (unsigned long long)__builtin_frame_address(0),kind);
        if(replacement){anim_rgba_draw_release(binding,native);return replacement;}
    }catch(...) {anim_rgba_draw_failed(binding);}
    return native;
}
using IngestionOriginal=void (*)(void *,void *,void *);
extern "C" void anim_rgba_draw_ingest_before(void *,void *,void *,void *,unsigned long long,unsigned long long *);
extern "C" void anim_rgba_draw_ingested(void *,void *,void *,void *,unsigned long long,unsigned long long *);
extern "C" __attribute__((noinline)) void anim_rgba_draw_ingest_prepare(
        void *window,void *outer,void *transaction,void *binding,IngestionOriginal original) {
    unsigned long long ticket[5]={};
    const auto frame=(unsigned long long)__builtin_frame_address(0);
    try {anim_rgba_draw_ingest_before(window,outer,transaction,binding,frame,ticket);}
    catch(...) {anim_rgba_draw_failed(binding);}
    try {original(window,outer,transaction);}
    catch(...) {anim_rgba_draw_failed(binding);throw;}
    try {anim_rgba_draw_ingested(window,outer,transaction,binding,frame,ticket);}
    catch(...) {anim_rgba_draw_failed(binding);}
}

using BeginOriginal=bool (*)(void *,void *,bool);
extern "C" void anim_rgba_begin_before(void *,void *,unsigned,void *,unsigned long long,unsigned long long *);
extern "C" void anim_rgba_begin_after(void *,void *,unsigned,void *,unsigned long long,unsigned long long *);
extern "C" void anim_rgba_begin_restore(void *,unsigned long long *);
extern "C" void anim_rgba_begin_failed(void *) noexcept;
extern "C" __attribute__((noinline)) bool anim_rgba_begin_prepare(
        void *window,void *state,bool flag,void *binding,BeginOriginal original) {
    unsigned long long ticket[6]={};
    const auto frame=(unsigned long long)__builtin_frame_address(0);
    try {anim_rgba_begin_before(window,state,flag,binding,frame,ticket);}
    catch(...) {
        // Restore before the native function can snapshot a failed publication.
        // B was completed before H0, so even recovery failure retains coverage.
        try {anim_rgba_begin_restore(binding,ticket);}catch(...) {}
        anim_rgba_begin_failed(binding);
    }
    bool result;
    try {result=original(window,state,flag);}
    catch(...) {
        // The observer cannot infer a completed cohort from an exceptional
        // native return. Preserve the original exception and its cleanup.
        anim_rgba_begin_failed(binding);throw;
    }
    try {anim_rgba_begin_after(window,state,result,binding,frame,ticket);}
    catch(...) {anim_rgba_begin_failed(binding);}
    return result;
}

extern "C" int anim_rgba_carrier_pose_work(void *,void *,void *);
extern "C" int anim_rgba_carrier_drop_work(void *,void *);
extern "C" void anim_rgba_carrier_recover(void *,void *);
extern "C" void anim_rgba_carrier_failed(void *) noexcept;
extern "C" void anim_rgba_carrier_close_work(void *,double);
extern "C" void anim_rgba_carrier_close(void *g,double now) noexcept {
    try {anim_rgba_carrier_close_work(g,now);}catch(...) {anim_rgba_carrier_failed(g);}
}
extern "C" void anim_rgba_viewport_tick(void *);
extern "C" void anim_rgba_viewport_failed(void *) noexcept;
extern "C" void anim_rgba_viewport_restore_at(void *,unsigned);
extern "C" int anim_rgba_viewport_drop_work(void *);
extern "C" int rgba_normal_viewport_drop(void *g) noexcept {
    try {return anim_rgba_viewport_drop_work(g);}
    catch(...) {anim_rgba_viewport_failed(g);return 0;}
}
extern "C" void rgba_normal_viewport_tick(void *g) noexcept {
    try {anim_rgba_viewport_tick(g);}catch(...) {
        for(unsigned i=0;i<64;i++)try {anim_rgba_viewport_restore_at(g,i);}catch(...) {}
        anim_rgba_viewport_failed(g);
    }
}
extern "C" int anim_rgba_carrier_pose(void *g,void *m,void *w) noexcept {
    try {return anim_rgba_carrier_pose_work(g,m,w);}
    catch(...) {
        try {anim_rgba_carrier_recover(g,m);}catch(...) {}
        anim_rgba_carrier_failed(g);return 1;
    }
}
extern "C" int anim_rgba_carrier_drop(void *g,void *m) noexcept {
    try {return anim_rgba_carrier_drop_work(g,m);}
    catch(...) {anim_rgba_carrier_failed(g);return 0;}
}
using SceneOriginal=void *(*)(void *,void *,void *,void *);
extern "C" void anim_rgba_scene_before(void *,unsigned long long);
extern "C" void anim_rgba_scene_enter(void *) noexcept;
extern "C" void anim_rgba_scene_leave(void *) noexcept;
extern "C" void anim_rgba_scene_failed(void *) noexcept;
extern "C" void anim_rgba_scene_recover_at(void *,unsigned);
extern "C" __attribute__((noinline)) void *anim_rgba_scene_prepare(
        void *a,void *b,void *begin,void *end,void *binding,SceneOriginal original) {
    try {anim_rgba_scene_before(binding,(unsigned long long)__builtin_frame_address(0));}
    catch(...) {
        // Recover each exact still-owned source BEFORE this native display can
        // snapshot it. One failing source must not skip the remaining rows.
        for(unsigned i=0;i<64;i++)try {anim_rgba_scene_recover_at(binding,i);}catch(...) {}
        anim_rgba_scene_failed(binding);
    }
    // This covers the complete native scope constructor, UpdateDisplays and
    // destructor, including reentrant MAIN timer callbacks from notifications.
    anim_rgba_scene_enter(binding);
    try {
        void *result=original(a,b,begin,end);
        anim_rgba_scene_leave(binding);return result;
    }catch(...) {anim_rgba_scene_leave(binding);throw;}
}
