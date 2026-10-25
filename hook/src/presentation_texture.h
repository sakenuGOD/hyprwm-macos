// OWN immutable RGBA texture -> OWN native local-context window. Dormant in
// ordinary production. The private qualifier reserves a separate control block
// after the unchanged capture sidecar; neither source nor channel fields change.
#define RGBA_VIEW_MAGIC 0x31574549564d5748ULL
#define RGBA_VIEW_VERSION 5
enum { RGBA_VIEW_ORDINARY, RGBA_VIEW_SNAPSHOT };
#define RGBA_VIEW_OFFSET 4096
struct rgba_view_api {
    void *(*create)(void *,u32,void *,u32);
    void (*bind_local)(void *,void *,int,int);
    int (*shape)(void *,void *,void *,u32);
    void *(*empty_region)(void);
    void (*event_shape)(void *,void *);
    void (*no_shadow)(void *);
    void (*depth)(void *,int);
    void (*resolution)(void *,double);
    int (*order)(void *,u32,int,u32);
    u32 (*display_id)(void *);
    void *(*manager)(void);
    u32 (*geometry_seed)(void *);
    u32 (*changed_seed)(void *);
    const void *manager_vtable;
    u64 (*layer_id)(void *);
    void *(*lookup_handle)(void *,u64,u32,int,u32 *);
    float (*effective_alpha)(void *);
};
struct rgba_view {
    u64 magic;u32 size,version;
    struct rgba_capture *capture;
    struct rgba_view_api api;
    void *window,*context,*root,*body,*texture;
    u32 wid,context_id,bound,prepared,shown,retired,reason,qualified;
    rect target,current,display_bounds;
    double alpha,current_alpha,source_w,source_h,scale;
    u32 display,geometry_seed,changed_seed,suspended;
    u64 observations,mutations,source_creator,source_pid_version;
    u32 source_wid,presentation_mode;
    u64 command,sequence,claimed,ack,active;
    int result;u32 pre_display;
    u64 commit_checks;
    u32 commit_sequence,committed,render_seed,commit_pad;
};
_Static_assert(sizeof(struct rgba_capture)<=RGBA_VIEW_OFFSET,"private capture partition");
_Static_assert(sizeof(struct rgba_view)<=4096,"private presenter partition");
static int rgba_view_valid(struct rgba_view *v,struct rgba_capture *g) {
    return v && rgba_valid(g) && v->magic==RGBA_VIEW_MAGIC && v->size==sizeof(*v) &&
        v->version==RGBA_VIEW_VERSION && v->pre_display<=1 && v->presentation_mode<=RGBA_VIEW_SNAPSHOT && v->capture==g && v->source_creator==g->pc.creator &&
        v->source_pid_version==g->pc.pid_version && v->source_wid==g->pc.wid;
}
static int rgba_view_api_ready(const struct rgba_view_api *a) {
    return a && a->create && a->bind_local && a->shape && a->empty_region &&
        a->event_shape && a->no_shadow && a->depth && a->resolution && a->order &&
        a->display_id && a->manager && a->geometry_seed && a->changed_seed && a->manager_vtable &&
        a->layer_id && a->lookup_handle && a->effective_alpha;
}
static void *rgba_view_manager(struct rgba_view *v) {
    void *m=v->api.manager();
    return m && __builtin_ptrauth_strip(*(void **)m,2)==v->api.manager_vtable?m:0;
}
static int rgba_view_rect(rect r) {
    return __builtin_isfinite(r.x) && __builtin_isfinite(r.y) &&
        __builtin_isfinite(r.w) && __builtin_isfinite(r.h) &&
        r.w>0 && r.h>0 && r.w<=16384 && r.h<=16384 &&
        r.x>=-100000 && r.x<=100000 && r.y>=-100000 && r.y<=100000;
}
static int rgba_view_contains(rect outer,rect inner) {
    return rgba_view_rect(outer) && rgba_view_rect(inner) && inner.x>=outer.x &&
        inner.y>=outer.y && inner.x+inner.w<=outer.x+outer.w && inner.y+inner.h<=outer.y+outer.h;
}
static int rgba_view_same(rect a,rect b) {
    return a.x==b.x && a.y==b.y && a.w==b.w && a.h==b.h;
}
static void *rgba_view_get(struct ctx *c,void *o,const char *name) {
    return ((void *(*)(void *,void *))c->msg)(o,c->sel(name));
}
static void rgba_view_object(struct ctx *c,void *o,const char *name,void *value) {
    ((void (*)(void *,void *,void *))c->msg)(o,c->sel(name),value);
}
static void rgba_view_bool(struct ctx *c,void *o,const char *name,int value) {
    ((void (*)(void *,void *,unsigned char))c->msg)(o,c->sel(name),(unsigned char)!!value);
}
static void rgba_view_bounds(struct ctx *c,void *o,const char *name,rect value) {
    ((void (*)(void *,void *,rect))c->msg)(o,c->sel(name),value);
}
static void rgba_view_point(struct ctx *c,void *o,const char *name,double x,double y) {
    struct {double x,y;} p={x,y};
    ((void (*)(void *,void *,__typeof__(p)))c->msg)(o,c->sel(name),p);
}
static void *rgba_view_string(struct ctx *c,const char *value) {
    return ((void *(*)(void *,void *,const char *))c->msg)(
        c->cls("NSString"),c->sel("stringWithUTF8String:"),value);
}
static int rgba_view_allocation(struct rgba_view *v) {
    struct ctx *c=v->capture->pc.engine;
    if(!v->window || !v->wid || !c->by_id || c->by_id(v->wid)!=v->window)return 0;
    char *w=v->window;
    if(*(u32 *)w!=v->wid || *(u32 *)(w+4)!=5 || *(void **)(w+0x30))return 0;
    return 1;
}
static int rgba_view_owned(struct rgba_view *v) {
    if(!rgba_view_allocation(v))return 0;
    char *w=v->window;
    if(v->bound) {
        char *cwc=*(char **)(w+0x18);
        if(!cwc || *(u32 *)(cwc+0x50)!=v->context_id || *(void **)(cwc+0x58)!=v->context)return 0;
    }
    return 1;
}
// Only OUR native window carries the logical alpha. Refuse external attenuation
// or an existing native fade instead of rewriting its factors/completion owner.
static int rgba_view_native_ready(struct rgba_view *v) {
    if(!rgba_view_owned(v) || !v->capture->pc.engine->set_alpha || !v->api.effective_alpha)return 0;
    char *w=v->window;float current=*(float *)(w+0x1d8),requested=*(float *)(w+0x1e4);
    return __builtin_isfinite(current) && current>=0 && current<=1 &&
        __builtin_isfinite(requested) && requested>=0 && requested<=1 &&
        *(float *)(w+0x1dc)==1 && *(float *)(w+0x1e0)==1 &&
        !*(void **)(w+0x888) && !*(void **)(w+0x1f0) &&
        !!(*(u64 *)(w+0x928)&(1ULL<<44))==!!v->shown && v->api.effective_alpha(w)==current;
}
static int rgba_view_native_alpha(struct rgba_view *v,double alpha) {
    if(!rgba_view_native_ready(v))return 0;
    return *(float *)((char *)v->window+0x1d8)==(float)alpha &&
        *(float *)((char *)v->window+0x1e4)==(float)alpha;
}
static int rgba_view_pixels(struct rgba_view *v) {
    struct rgba_capture *g=v->capture;struct pc_capture *p=&g->pc;
    anim_rgba_poll(g);
    if(p->stage!=PC_GPU_COMPLETE || p->reason || p->gpu_pending || !p->capture_witness ||
       !p->texture_ref || !p->command_buffer || g->clear_status!=4 || p->gpu_status!=4 ||
       (v->texture && v->texture!=p->texture_ref))return 0;
    if(g->content_mode==RGBA_CLIENT_DOMAIN_MODE && !rgba_client_domain_ready(g))return 0;
    if(rgba_view_get(p->engine,p->command_buffer,"error"))return 0;
    return rgba_send0(g,p->texture_ref,g->sel.device)==g->device &&
        rgba_send0(g,g->queue,g->sel.device)==g->device;
}
// Inspect the OWN committed render model, not just the ObjC properties whose
// transaction may still be nested. All pointers are borrowed under its lock.
static int rgba_view_render_matches_alpha(struct rgba_view *v,char *root,char *body,double alpha) {
    rect local={0,0,v->current.w,v->current.h};
    if(!root || !body || !rgba_view_same(*(rect *)(root+0x48),local) ||
       !rgba_view_same(*(rect *)(body+0x48),local))return 0;
    unsigned opacity=*(unsigned char *)(root+0x24);
    if(!__builtin_isfinite(alpha) || alpha<0 || alpha>1 ||
       (alpha==1?opacity!=255:alpha==0?opacity!=0:__builtin_fabs((double)opacity/255-alpha)>1.0/255) ||
       *(unsigned char *)(body+0x24)!=255)return 0;
    void *children=*(void **)(root+0x70);
    if(*(u32 *)(root+0xc)&(1U<<13)) {if(children!=body)return 0;}
    else {
        char *a=children;
        if(!a || (unsigned char)a[0xc]!=1 || (a[0xd]&1) || *(u32 *)(a+0x10)!=1 ||
           *(void **)(a+0x18)!=body)return 0;
    }
    char *texture=*(char **)(body+0x68);
    if(!texture || (unsigned char)texture[0xc]!=0x24 || *(void **)(texture+0x70)!=v->texture)return 0;
    char *ext=*(char **)(body+0x88),*uv=ext?*(char **)(ext+0x28):0;
    if(v->presentation_mode>RGBA_VIEW_SNAPSHOT ||
       !rgba_view_rect((rect){0,0,v->source_w,v->source_h}))return 0;
    double width=v->presentation_mode==RGBA_VIEW_SNAPSHOT?1:local.w/v->source_w;
    double height=v->presentation_mode==RGBA_VIEW_SNAPSHOT?1:local.h/v->source_h;
    if(!uv)return width==1 && height==1;
    return (unsigned char)uv[0xc]==0x3e && *(u32 *)(uv+0x10)==4 &&
        *(double *)(uv+0x18)==0 && *(double *)(uv+0x20)==1-height &&
        *(double *)(uv+0x28)==width && *(double *)(uv+0x30)==1;
}
static int rgba_view_render_matches(struct rgba_view *v,char *root,char *body) {
    return rgba_view_render_matches_alpha(v,root,body,1);
}
static int rgba_view_committed(struct rgba_view *v) {
    struct rgba_capture *g=v->capture;struct ctx *c=g->pc.engine;
    v->committed=0;v->commit_checks++;
    void *context=rgba_view_get(c,v->context,"renderContext");
    if(!context)return 0;
    u64 root_id=v->api.layer_id(v->root),body_id=v->api.layer_id(v->body);
    u32 model_before=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
    if(!root_id || !body_id || root_id==body_id || g->api.lock_context(context)!=0)return 0;
    char *root=g->api.root(context);
    char *rh=v->api.lookup_handle(context,root_id,0,0,0);
    char *bh=v->api.lookup_handle(context,body_id,0,0,0);
    if(root && *(u64 *)((char *)context+0x110)==root_id && rh && bh && rh!=bh &&
       *(void **)(rh+0x18)==context && *(void **)(bh+0x18)==context && *(void **)(rh+0x10)==root &&
       rgba_view_render_matches(v,root,*(char **)(bh+0x10))) {
        v->commit_sequence=*(u32 *)((char *)context+0x40);
        v->render_seed=*(u32 *)((char *)context+0x28);v->committed=1;
    }
    g->api.unlock_context(context);
    // Native commit locks model then render context; never call an ObjC model
    // getter while holding the render lock in the opposite order.
    u32 model_after=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
    if(model_before!=model_after || model_after!=v->commit_sequence)v->committed=0;
    return v->committed;
}
static void rgba_view_layers(struct rgba_view *v) {
    struct ctx *c=v->capture->pc.engine;rect local={0,0,v->target.w,v->target.h};
    RGBA_LAYER_SCOPE(c,scope);c->tx_add(scope,v->context);
    rgba_view_bounds(c,v->root,"setBounds:",local);rgba_view_point(c,v->root,"setPosition:",0,0);
    rgba_view_bounds(c,v->body,"setBounds:",local);rgba_view_point(c,v->body,"setPosition:",0,0);
    rgba_view_object(c,v->body,"setContents:",v->suspended?0:v->texture);
    // Sample the immutable image at its actual texture extent. Mode3 additionally
    // binds its canvas to the accepted client domain; old capture modes alone
    // do not establish complete client-frame coverage. Ordinary UV preserves
    // texel scale; opening/close snapshots explicitly map the complete frame.
    double width=v->presentation_mode==RGBA_VIEW_SNAPSHOT?1:local.w/v->source_w;
    double height=v->presentation_mode==RGBA_VIEW_SNAPSHOT?1:local.h/v->source_h;
    rgba_view_bounds(c,v->body,"setContentsRect:",(rect){0,1-height,width,height});
    // Captured RGBA stays unchanged. Native B alpha attenuates the whole window
    // once, including the wrapper above this local context.
    ((void (*)(void *,void *,float))c->msg)(v->root,c->sel("setOpacity:"),1.0f);
    ((void (*)(void *,void *,float))c->msg)(v->body,c->sel("setOpacity:"),1.0f);
    RGBA_LAYER_END(scope);v->current=v->target;v->current_alpha=v->alpha;v->mutations++;
}
// Capture a CURRENT per-display consumer witness only in a real serialized
// metalCallbacks frame. Never retain a borrowed Display/M/QC pointer.
static void rgba_view_observe(struct rgba_view *v,void *mctx,void *shared_display) {
    struct rgba_capture *g=v->capture;struct pc_capture *p=&g->pc;
    if(!v->prepared || v->retired || !pc_main(p) || !p->engine || p->engine->in_cb ||
       !pc_normal_frame(p) || !shared_display || !mctx || !rgba_view_owned(v))return;
    void *display=*(void **)shared_display;if(!display)return;
    void **table=*(void ***)display;
#if __has_feature(ptrauth_calls)
    table=__builtin_ptrauth_auth(table,2,__builtin_ptrauth_blend_discriminator(display,0xc333));
    void *id_fn=__builtin_ptrauth_auth_and_resign(table[0x28/8],0,
        __builtin_ptrauth_blend_discriminator(&table[0x28/8],0x1608),0,0);
    void *bounds_fn=__builtin_ptrauth_auth_and_resign(table[0xa8/8],0,
        __builtin_ptrauth_blend_discriminator(&table[0xa8/8],0x79ac),0,0);
#else
    void *id_fn=table[0x28/8],*bounds_fn=table[0xa8/8];
#endif
    u32 id=((u32 (*)(void *))id_fn)(display);
    if(id!=v->api.display_id(v->window))return;
    v->qualified=0;void *manager=rgba_view_manager(v);if(!manager)return;
    rect bounds=((rect (*)(void *))bounds_fn)(display);
    char *r=*(char **)((char *)mctx+0x90),*qc=r?*(char **)r:0;
    if(!qc || !rgba_view_contains(bounds,v->current) ||
       *(void **)((char *)mctx+0x80)!=g->device || *(void **)(qc+0xee8)!=g->device ||
       !rgba_view_pixels(v))return;
    v->display=id;v->display_bounds=bounds;v->geometry_seed=v->api.geometry_seed(manager);
    v->changed_seed=v->api.changed_seed(manager);v->qualified=1;v->observations++;
}
// Allocation also serves retained close images. Its image/extent/color inputs
// are owned values; it never consults a producer's transient Update or capture.
static int rgba_view_create_image(struct rgba_view *v,void *image,double width,double height,double scale,void *color) {
    struct rgba_capture *g=v->capture;struct pc_capture *p=&g->pc;struct ctx *c=p->engine;
    if(v->window || v->context || v->retired || !image ||
       !rgba_view_api_ready(&v->api) || !rgba_view_rect(v->target) ||
       !__builtin_isfinite(v->alpha) || v->alpha<0 || v->alpha>1 ||
       !c->rgn || !c->release || !c->get_id || !c->by_id || !c->rel_win ||
       !c->set_level || !c->set_alpha || !c->sched_win || !c->tx_ctor || !c->tx_add || !c->tx_dtor)return -1;
    v->scale=scale;v->source_w=width;v->source_h=height;
    if(!__builtin_isfinite(v->scale) || v->scale<=0 || v->scale>8 ||
       !rgba_view_rect((rect){0,0,v->source_w,v->source_h}))return -1;
    void *region=c->rgn(v->target);if(!region)return -1;
    RGBA_CALLBACK_SCOPE(c);
    struct rgba_layer_scope scope_scope __attribute__((cleanup(rgba_layer_scope_cleanup)))={0};
    v->window=v->api.create(0,5,region,0x1801);c->release(region);
    if(!v->window)goto failed;
    v->wid=c->get_id(v->window);if(!rgba_view_owned(v))goto failed;
    v->api.no_shadow(v->window);v->api.depth(v->window,4);v->api.resolution(v->window,v->scale);
    region=v->api.empty_region();if(!region)goto failed;
    v->api.event_shape(v->window,region);c->release(region);
    // SkyLight tracks local-context changes to refresh its prepared host tree.
    // Suppressing these notifications can leave an older texture pose visible.
    void *disabled=((void *(*)(void *,void *,unsigned char))c->msg)(c->cls("NSNumber"),c->sel("numberWithBool:"),0);
    void *key=rgba_view_string(c,"disablesChangeNotifications");if(!disabled || !key)goto failed;
    void *options=((void *(*)(void *,void *,void *,void *))c->msg)(c->cls("NSDictionary"),
        c->sel("dictionaryWithObject:forKey:"),disabled,key);
    if(!options)goto failed;
    void *context=((void *(*)(void *,void *,void *))c->msg)(c->cls("CAContext"),c->sel("localContextWithOptions:"),options);
    if(!context)goto failed;v->context=p->retain_obj(context);
    v->context_id=((u32 (*)(void *,void *))c->msg)(context,c->sel("contextId"));if(!v->context_id)goto failed;
    v->api.bind_local(v->window,v->context,1,0);v->bound=1;
    if(!rgba_view_owned(v)){v->bound=0;goto failed;}
    region=c->rgn(v->target);if(!region)goto failed;
    int shape_result=v->api.shape(v->window,region,0,0);c->release(region);if(shape_result!=0)goto failed;
    c->set_level(v->window,0,0,0); // This qualifier captures ordinary level-zero sources.
    v->root=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    v->body=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    if(!v->root || !v->body)goto failed;
    unsigned char supports=((unsigned char (*)(void *,void *,void *))c->msg)(
        v->body,c->sel("respondsToSelector:"),c->sel("setContentsScaling:"));
    if(!supports)goto failed;
    v->texture=p->retain_obj(image);if(!v->texture)goto failed;
    rgba_layer_scope_begin(&scope_scope,c);u64 *scope=scope_scope.tx;c->tx_add(scope,v->context);
    rgba_view_point(c,v->root,"setAnchorPoint:",0,0);rgba_view_bool(c,v->root,"setMasksToBounds:",1);
    rgba_view_bool(c,v->root,"setOpaque:",0);rgba_view_object(c,v->root,"setBackgroundColor:",0);
    rgba_view_point(c,v->body,"setAnchorPoint:",0,0);rgba_view_bool(c,v->body,"setOpaque:",0);
    rgba_view_bool(c,v->body,"setContentsOpaque:",0);rgba_view_object(c,v->body,"setBackgroundColor:",0);
    ((void (*)(void *,void *,double))c->msg)(v->body,c->sel("setContentsScale:"),v->scale);
    rgba_view_object(c,v->body,"setContentsGravity:",rgba_view_string(c,"resize"));
    rgba_view_object(c,v->body,"setContentsScaling:",rgba_view_string(c,"stretch"));
    rgba_view_bounds(c,v->body,"setContentsCenter:",(rect){0,0,1,1});
    rgba_view_object(c,v->body,"setContents:",v->texture);
    rgba_view_object(c,v->root,"addSublayer:",v->body);rgba_view_object(c,v->context,"setLayer:",v->root);
    void *owned_color=0;
    if(!color)color=*g->api.geometry.native_display_rgb;
    if(!color){owned_color=g->api.geometry.display_rgb();color=owned_color;}
    if(color)rgba_view_object(c,v->context,"setColorSpace:",color);
    if(owned_color)c->release(owned_color);
    RGBA_LAYER_END(scope);
    rgba_view_layers(v);v->prepared=1;v->qualified=0;c->sched_win(0,v->window);return 0;
failed:
    v->reason=401;return -1;
}
static int rgba_view_create(struct rgba_view *v) {
    if(!rgba_view_pixels(v))return -1;
    struct pc_capture *p=&v->capture->pc;
    void *color=p->capture?*(void **)((char *)p->capture+0x60):0;
    return rgba_view_create_image(v,p->texture_ref,(double)p->width/p->scale,(double)p->height/p->scale,p->scale,color);
}
// A failed rollback aborts this OWN experiment. Source A is still native-visible;
// hiding B here is failure containment, never an atomic presentation success.
static int rgba_view_abort_pose(struct rgba_view *v) {
    v->qualified=0;v->suspended=1;v->reason=403;
    if(rgba_view_allocation(v) && v->api.order(0,v->wid,0,0)==0)v->shown=0;
    else v->reason=404;
    return -1;
}
static int rgba_view_restore_pose(struct rgba_view *v,rect previous,double alpha,int native_changed) {
    struct ctx *c=v->capture->pc.engine;
    if(!rgba_view_native_ready(v))return rgba_view_abort_pose(v);
    if(v->shown) {
        float actual=*(float *)((char *)v->window+0x1d8),requested=*(float *)((char *)v->window+0x1e4);
        if((actual!=(float)alpha && actual!=(float)v->alpha) ||
           (requested!=(float)alpha && requested!=(float)v->alpha))return rgba_view_abort_pose(v);
        if(!rgba_view_native_alpha(v,alpha))c->set_alpha(0,v->window,(float)alpha,0);
        if(!rgba_view_native_alpha(v,alpha))return rgba_view_abort_pose(v);
    }
    if(native_changed) {
        void *region=c->rgn(previous);
        if(!region)return rgba_view_abort_pose(v);
        int result=v->api.shape(v->window,region,0,0);c->release(region);
        if(result!=0)return rgba_view_abort_pose(v);
    }
    rect requested=v->target;double requested_alpha=v->alpha;
    v->target=previous;v->alpha=alpha;rgba_view_layers(v);
    int restored=rgba_view_committed(v);
    v->target=requested;v->alpha=requested_alpha;
    void *manager=rgba_view_manager(v);
    if(!manager || v->api.changed_seed(manager)!=v->changed_seed ||
       v->api.display_id(v->window)!=v->display)return rgba_view_abort_pose(v);
    if(restored)v->geometry_seed=v->api.geometry_seed(manager);
    return restored?0:rgba_view_abort_pose(v);
}
static int rgba_view_apply_alpha(struct rgba_view *v,double previous) {
    struct ctx *c=v->capture->pc.engine;
    if(!rgba_view_native_ready(v) || (v->shown && !rgba_view_native_alpha(v,previous)))return 0;
    if(!v->shown && (*(float *)((char *)v->window+0x1d8)!=1 ||
                    *(float *)((char *)v->window+0x1e4)!=1))return 0;
    c->set_alpha(0,v->window,(float)v->alpha,0);
    if(!v->shown) {
        // The guarded native first-order path applies this requested alpha
        // before inserting B into the ordered list, including a cold alpha0.
        if(!rgba_view_native_ready(v) || *(float *)((char *)v->window+0x1e4)!=(float)v->alpha ||
           v->api.order(0,v->wid,1,0)!=0)return 0;
        v->shown=1;
    }
    return rgba_view_native_alpha(v,v->alpha);
}
// -1 refused, 0 waiting with previous stable B restored, 1 shown.
static int rgba_view_pose(struct rgba_view *v,int force_commit) {
    struct rgba_capture *g=v->capture;struct ctx *c=g->pc.engine;
    if(v->retired || (v->pre_display && (v->reason==403 || v->reason==404)) ||
       !rgba_view_api_ready(&v->api) || !rgba_view_pixels(v) ||
       !rgba_view_rect(v->target) || !__builtin_isfinite(v->alpha) || v->alpha<0 || v->alpha>1)return -1;
    if(!v->prepared)return rgba_view_create(v);
    if(!rgba_view_owned(v))return -1;
    void *manager=rgba_view_manager(v);
    if(!manager || !v->qualified || v->api.changed_seed(manager)!=v->changed_seed ||
       v->api.geometry_seed(manager)!=v->geometry_seed) {c->sched_win(0,v->window);return 0;}
    if(!rgba_view_contains(v->display_bounds,v->target))return -1;
    if(!rgba_view_native_ready(v) || (v->shown && !rgba_view_native_alpha(v,v->current_alpha)))return -1;
    u32 changed=v->api.changed_seed(manager),was=c->in_cb;c->in_cb=1;
    rect previous=v->current;double previous_alpha=v->current_alpha;
    int resume=v->suspended;
    if(v->pre_display) {
        v->suspended=0;rgba_view_layers(v);
        if(!rgba_view_committed(v)) {
            int result=rgba_view_restore_pose(v,previous,previous_alpha,0);
            c->sched_win(0,v->window);c->in_cb=was;return result;
        }
        if(rgba_view_manager(v)!=manager || v->api.changed_seed(manager)!=changed ||
           v->api.geometry_seed(manager)!=v->geometry_seed || v->api.display_id(v->window)!=v->display) {
            rgba_view_restore_pose(v,previous,previous_alpha,0);
            c->sched_win(0,v->window);c->in_cb=was;return -1;
        }
    }
    if(!rgba_view_same(previous,v->target)) {
        void *region=c->rgn(v->target);
        if(!region){if(v->pre_display)rgba_view_restore_pose(v,previous,previous_alpha,0);c->in_cb=was;return -1;}
        int result=v->api.shape(v->window,region,0,0);c->release(region);
        if(result!=0){if(v->pre_display)rgba_view_restore_pose(v,previous,previous_alpha,1);c->in_cb=was;return -1;}
        if(v->api.changed_seed(manager)!=changed || v->api.display_id(v->window)!=v->display) {
            if(v->pre_display) {
                rgba_view_restore_pose(v,previous,previous_alpha,1);
                c->sched_win(0,v->window);c->in_cb=was;return -1;
            }
            // Native geometry already changed. Detach only OUR texture and
            // synchronize local B before returning refusal; never leave old
            // local pixels visible inside a different native window shape.
            v->qualified=0;v->suspended=1;v->reason=402;
            if(v->api.order(0,v->wid,0,0)==0)v->shown=0;
            rgba_view_layers(v);c->sched_win(0,v->window);c->in_cb=was;return -1;
        }
    }
    v->suspended=0;
    if(!v->pre_display) {
        if(force_commit || resume || !rgba_view_same(v->current,v->target) || v->current_alpha!=v->alpha)rgba_view_layers(v);
        if(!rgba_view_committed(v)) {
            v->current_alpha=previous_alpha; // The native carrier has not changed yet.
            c->sched_win(0,v->window);c->in_cb=was;return 0;
        }
    }
    int was_shown=v->shown;
    if(!rgba_view_apply_alpha(v,previous_alpha) || rgba_view_manager(v)!=manager ||
       v->api.changed_seed(manager)!=changed || v->api.display_id(v->window)!=v->display) {
        if(was_shown)rgba_view_restore_pose(v,previous,previous_alpha,!rgba_view_same(previous,v->target));
        else rgba_view_abort_pose(v);
        c->sched_win(0,v->window);c->in_cb=was;return -1;
    }
    // Both shape and crossing native alpha1 can invalidate this seed.
    v->geometry_seed=v->api.geometry_seed(manager);
    c->sched_win(0,v->window);c->in_cb=was;return 1;
}
static int rgba_view_retire(struct rgba_view *v) {
    if(v->retired)return 1;
    struct pc_capture *p=&v->capture->pc;struct ctx *c=p->engine;
    // The exact allocation remains ours even if its bind postcondition failed.
    if(v->window && !rgba_view_allocation(v))return 0;
    RGBA_CALLBACK_SCOPE(c);
    if(v->window && v->api.order(0,v->wid,0,0)!=0){return 0;}
    if(v->context) {
        RGBA_LAYER_SCOPE(c,scope);c->tx_add(scope,v->context);
        if(v->body)rgba_view_object(c,v->body,"setContents:",0);
        rgba_view_object(c,v->context,"setLayer:",0);RGBA_LAYER_END(scope);
    }
    if(v->window) {
        u32 wid=v->wid;c->rel_win(0,v->window);
        if(c->by_id(wid)){return 0;}
        v->window=0;
    }
    if(v->context)((void (*)(void *,void *))c->msg)(v->context,c->sel("invalidate"));
    if(v->body)p->release_obj(v->body);if(v->root)p->release_obj(v->root);
    if(v->context)p->release_obj(v->context);if(v->texture)p->release_obj(v->texture);
    v->body=v->root=v->context=v->texture=0;v->shown=v->qualified=0;v->retired=1;return 1;
}
void anim_rgba_present_frame(void *mctx,void *display,void *third,struct rgba_capture *g) {
    anim_rgba_frame(mctx,display,third,g);if(!rgba_valid(g))return;
    struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    if(rgba_view_valid(v,g))rgba_view_observe(v,mctx,display);
}
static int rgba_view_before_capture_destroy(struct rgba_capture *g) {
    struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    if(!rgba_view_valid(v,g) || !rgba_view_retire(v))return 0;
    // OFF cancels an outstanding pose; this is a refusal ACK, not a presented
    // frame. The single producer stops publication before requesting capture OFF.
    u64 sequence=__atomic_load_n(&v->sequence,__ATOMIC_ACQUIRE);
    __atomic_store_n(&v->command,0,__ATOMIC_RELEASE);v->active=0;
    if(sequence!=v->ack) {
        v->claimed=sequence;v->result=-1;__atomic_store_n(&v->ack,sequence,__ATOMIC_RELEASE);
    }
    return 1;
}
static void rgba_present_dispatch_control(struct ctx *c,double now,
        int (*prepare)(struct rgba_capture *),int (*before_destroy)(struct rgba_capture *)) {
    rgba_dispatch_control(c,now,before_destroy,prepare);
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!rgba_valid(g) || g->destroyed || g->pc.dead || g->pc.active_command==4)return;
    struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    if(!rgba_view_valid(v,g) || !g->pc.is_main || g->pc.is_main()!=1 || c->in_cb || pc_normal_frame(&g->pc))return;
    u64 command=v->active;
    if(!command) {
        u64 sequence=__atomic_load_n(&v->sequence,__ATOMIC_ACQUIRE);if(sequence==v->ack)return;
        command=__atomic_exchange_n(&v->command,0,__ATOMIC_ACQ_REL);if(!command)return;
        if(__atomic_load_n(&v->sequence,__ATOMIC_ACQUIRE)!=sequence) {
            u64 empty=0;__atomic_compare_exchange_n(&v->command,&empty,command,0,__ATOMIC_RELEASE,__ATOMIC_RELAXED);return;
        }
        v->claimed=sequence;v->active=command;
    }
    int result=-1;
    if(command==1 && !v->retired && !c->dead && c->ch && c->ch->h.magic==CH_MAGIC && !c->ch->h.stop) {
        if(v->pre_display) {
            // The timer may allocate a hidden local-context window. It must
            // leave every visible pose to the qualified pre-display entry.
            result=v->prepared?0:rgba_view_create(v);
            if(!result)c->sched_win(0,v->window);
        } else result=rgba_view_pose(v,1);
    }
    else if(command==2)result=rgba_view_retire(v)?1:0;
    if(result) {v->result=result;v->active=0;__atomic_store_n(&v->ack,v->claimed,__ATOMIC_RELEASE);}
}
void anim_rgba_present_dispatch(struct ctx *c,double now) {
    rgba_present_dispatch_control(c,now,0,rgba_view_before_capture_destroy);
}

unsigned anim_rgba_present_size(void){return sizeof(struct rgba_view);}
unsigned anim_rgba_present_offset(void){return RGBA_VIEW_OFFSET;}
