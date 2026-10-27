// A owns identity/input. B owns the complete drawing footprint; its native
// geometry stays fixed while visible, so shape notifications cannot split pose
// publication. Only the retained four-region client graph moves inside B.
#define RGBA_CARRIER_OFFSET 10240
#define RGBA_CARRIER_MAGIC 0x3152454952524143ULL
struct rgba_carrier_slot {
    struct rgba_view view;
    struct rgba_retained_frame displayed;
    struct rgba_retained_frame retiring;
    u64 window,creator,birth,space,root;
    rect envelope;
    double inset;
    u64 canvas_bytes;
    u64 excluded_commit;
    u32 idle_observed,pad;
};
struct rgba_carrier {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    void *storage;struct rgba_carrier_slot *slots;
    u64 slide;
    void *(*primary_space)(void *);
    void *(*copy_spaces)(void *);
    _Bool (*contains)(void *,void *);
    void (*add_space)(void *,void *);
    void (*remove_space)(void *,void *,void *);
    u32 depth,preparing,dead,before_slot;
    u64 passes,claims,restores,refused;
};
static struct rgba_carrier *rgba_carrier_control(struct rgba_capture *g) {
    struct rgba_carrier *b=(void *)((char *)g+RGBA_CARRIER_OFFSET);
    return b->magic==RGBA_CARRIER_MAGIC && b->size==sizeof(*b) && (b->version==1 || b->version==2) && b->capture==g?b:0;
}
static int rgba_carrier_active(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);return b && b->version==1;
}
static void rgba_carrier_finish_drop(struct rgba_capture *g) {
    if(rgba_draw_active(g)){rgba_draw_finish_drop(g);return;}
    struct rgba_carrier *b=rgba_carrier_control(g);if(!b || !b->slots)return;
    for(unsigned i=0;i<CH_NW;i++)if(b->slots[i].view.window)return;
    g->pc.release_obj(b->storage);b->storage=0;b->slots=0;
}
extern void anim_rgba_carrier_close(struct rgba_capture *,double);
void anim_rgba_carrier_close_work(struct rgba_capture *g,double now) {rgba_close_tick(g,now);}
static struct rgba_carrier_slot *rgba_carrier_row(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_carrier *b=rgba_carrier_control(g);unsigned i=rgba_begin_index(g,m);
    return b && b->version==1 && b->slots && i<CH_NW?&b->slots[i]:0;
}
static struct rgba_view *rgba_carrier_view(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);
    return s && s->view.window && s->root==(u64)m->root?&s->view:0;
}
// A MAIN callback can itself be nested inside native UpdateDisplays. Walk to
// the actual stack end, rejecting native display/capture frames and bad chains.
static int rgba_carrier_stack(struct rgba_capture *g,int timer) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct pc_capture *p=&g->pc;
    if(!b || b->depth || !pc_main(p) || !p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 bottom=top-size,fp=(u64)__builtin_frame_address(0);unsigned found=0;
    for(unsigned i=0;i<256;i++) {
        if((fp&15) || fp<bottom || fp>top-16)return 0;
        u64 ra=pc_address((void *)((u64 *)fp)[1]),native=ra-b->slide;
        if((native>=0x186e0f158ULL && native<0x186e2e830ULL) ||
           (native>=0x186d9b2fcULL && native<0x186d9b818ULL) ||
           (native>=0x18710d5bcULL && native<0x18710ebecULL))return 0;
        if(native==0x186da6ea4ULL)found|=1;
        if(native==0x186de8b78ULL && (found&1))found|=2;
        u64 next=*(u64 *)fp;
        if(!next)return !timer || found==3;
        if(next<=fp)return 0;fp=next;
    }
    return 0;
}
static int rgba_carrier_outside(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);
    return b && !b->depth && (b->preparing || rgba_carrier_stack(g,1));
}
static int rgba_carrier_timer_allowed(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);
    return b && !b->preparing && rgba_carrier_outside(g);
}
// This permit applies only to one already allocated B, before A's first-loop
// native Begin. It never makes a nested timer an outside-frame callback.
static int rgba_carrier_before_allowed(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct rgba_begin_binding *begin=rgba_begin_control(g);
    unsigned i=rgba_begin_index(g,m);
    return b && !b->dead && b->depth==1 && b->preparing==2 && i<CH_NW &&
        b->before_slot==i+1 && begin && !begin->dead && begin->claiming==i+1;
}
static u64 rgba_carrier_bytes(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);u64 bytes=0;
    if(b && b->slots)for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_carrier_slot *s=&b->slots[i];bytes+=s->canvas_bytes;
        if(s->displayed.texture)bytes+=(u64)s->displayed.pixel_width*s->displayed.pixel_height*4;
        if(s->retiring.texture)bytes+=(u64)s->retiring.pixel_width*s->retiring.pixel_height*4;
    }
    return bytes;
}
// Membership links and their Space payloads are borrowed only on MAIN. Keep a
// numeric SID across callbacks, never a borrowed PKGSpace or Workspace pointer.
static u64 rgba_carrier_space(struct rgba_capture *g,void *window) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct ctx *c=g->pc.engine;
    char *info=window?*(char **)((char *)window+0x248):0;
    char *node=info?*(char **)info:0,*workspace=node?*(char **)node:0;
    char *space=workspace?*(char **)(workspace+0x60):0;
    if(!b || !space || *(void **)(node+8) || !c->space_for_id ||
       *(u32 *)(space+0x28)!=0 || !*(u64 *)space)return 0;
    void *managed=*(void **)(space+0x18);
    if(!managed || *(void **)managed!=space || c->space_for_id(*(u64 *)space)!=space ||
       b->primary_space(window)!=space || !b->contains(space,window))return 0;
    return *(u64 *)space;
}
static int rgba_carrier_space_sync(struct rgba_capture *g,struct rgba_view *v,u64 sid) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct ctx *c=g->pc.engine;
    if(!c->space_for_id(sid))return 0;
    // Only the hidden OWN allocation changes membership.
    void *list=b->copy_spaces(v->window);unsigned count=0;int valid=1;u64 ids[64];
    while(list) {
        void *next=*(void **)((char *)list+8),*old=*(void **)list;
        if(count==64){valid=0;c->xfree(list);list=next;continue;}
        ids[count++]=old?*(u64 *)old:0;if(!old || !ids[count-1])valid=0;
        c->xfree(list);list=next;
    }
    if(!valid)return 0;
    for(unsigned i=0;i<count;i++)if(ids[i]!=sid) {
        void *old=c->space_for_id(ids[i]);if(old)b->remove_space(old,v->window,0);
    }
    void *space=c->space_for_id(sid);if(!space)return 0;
    if(!b->contains(space,v->window))b->add_space(space,v->window);
    return rgba_carrier_space(g,v->window)==sid;
}
static int rgba_carrier_ordered_windows(struct rgba_capture *g,void *source,void *own) {
    struct ctx *c=g->pc.engine;
    void *control=g->pc.session_control?*(void **)g->pc.session_control:0;
    if(!control || *(void **)((char *)control+0x20)!=c->session || !c->session)return 0;
    char *data=*(char **)((char *)c->session+0x90);if(!data)return 0;
    void **items=*(void ***)(data+0x20);int count=*(int *)(data+0x28),capacity=*(int *)(data+0x2c);
    if(!items || count<0 || count>4096 || count>capacity || capacity>0x8000)return 0;
    void *previous=0;unsigned found=0,a=0,b=0;
    for(int i=0;i<count;i++)if(items[i]) {
        if(items[i]==source)a++;
        if(items[i]==own){b++;if(previous==source)found++;}
        previous=items[i];
    }
    return found==1 && a==1 && b==1 && *(void **)g->pc.session_control==control &&
        *(void **)((char *)control+0x20)==c->session && *(char **)((char *)c->session+0x90)==data &&
        *(void ***)(data+0x20)==items && *(int *)(data+0x28)==count && *(int *)(data+0x2c)==capacity;
}
static int rgba_carrier_ordered(struct rgba_capture *g,struct rgba_carrier_slot *s,void *source) {
    return rgba_carrier_ordered_windows(g,source,s->view.window);
}
static void rgba_carrier_release_frame(struct rgba_capture *g,struct rgba_retained_frame *f) {
    void *texture=f->texture,*color=f->color;*f=(struct rgba_retained_frame){0};
    if(texture)g->pc.release_obj(texture);if(color)g->api.geometry.release_cf(color);
}
static void rgba_carrier_remember(struct rgba_capture *g,struct rgba_carrier_slot *s,struct rgba_inplace *m) {
    if(s->displayed.texture==m->texture)return;
    struct rgba_retained_frame next={g->pc.retain_obj(m->texture),m->source_w,m->source_h,
        (double)m->pixel_w/m->source_w,m->pixel_w,m->pixel_h,m->good_client_context,
        m->good_client_id,m->good_client_sequence,m->color?g->api.geometry.retain_cf(m->color):0};
    if(s->retiring.texture && m->adopted_texture==(u64)s->displayed.texture)rgba_carrier_release_frame(g,&s->retiring);
    s->retiring=s->displayed;s->displayed=next;
}
static int rgba_carrier_can_publish(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);if(!s || !s->retiring.texture)return 1;
    if(!m->presenting)return 1;
    if(m->adopted_texture!=(u64)s->displayed.texture)return 0;
    rgba_carrier_release_frame(g,&s->retiring);return 1;
}
static int rgba_carrier_prepare(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct ctx *c=g->pc.engine;
    if(!b || b->dead || b->preparing || !rgba_carrier_outside(g) || m->presenting)return 0;
    if(!rgba_close_reserve(g))return 0;
    if(!b->slots) {
        void *data=((void *(*)(void *,void *,u64))c->msg)(c->cls("NSMutableData"),c->sel("dataWithLength:"),CH_NW*sizeof(*b->slots));
        if(!data)return 0;b->storage=g->pc.retain_obj(data);b->slots=rgba_view_get(c,data,"mutableBytes");
        if(!b->slots){g->pc.release_obj(b->storage);b->storage=0;return 0;}
    }
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);if(!s)return 0;
    rect start={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]},goal={w->pos.g[0],w->pos.g[1],w->size.g[0],w->size.g[1]};
    if(!rgba_view_rect(start) || !rgba_view_rect(goal))return 0;
    double inset=SH_E+c->ch->deco.width;
    if(!finite(inset) || inset<0 || inset>512)return 0;
    rect both={start.x<goal.x?start.x:goal.x,start.y<goal.y?start.y:goal.y,0,0};
    double right=start.x+start.w>goal.x+goal.w?start.x+start.w:goal.x+goal.w;
    double bottom=start.y+start.h>goal.y+goal.h?start.y+start.h:goal.y+goal.h;
    both.w=right-both.x;both.h=bottom-both.y;
    // The configured spring overshoot fits a generous bounded union. Every
    // actual sample is still checked; overflow never expands a visible native B.
    rect envelope={both.x-both.w*.125-inset,both.y-both.h*.125-inset,
        both.w*1.25+2*inset,both.h*1.25+2*inset};
    // Native regions quantize the window origin/extent to whole points. Own
    // that exact integral envelope before allocation; keep the strict native
    // footprint equality instead of publishing against fractional model bounds.
    long left=(long)envelope.x,top=(long)envelope.y;
    double right_edge=envelope.x+envelope.w,bottom_edge=envelope.y+envelope.h;
    long right_point=(long)right_edge,bottom_point=(long)bottom_edge;
    if((double)left>envelope.x)left--;if((double)top>envelope.y)top--;
    if((double)right_point<right_edge)right_point++;if((double)bottom_point<bottom_edge)bottom_point++;
    envelope=(rect){left,top,right_point-left,bottom_point-top};
    double scale=(double)m->pixel_w/m->source_w;
    if(!rgba_view_rect(envelope) || !finite(inset) || inset<0 || inset>512 || !finite(scale) || scale<=0 || scale>8)return 0;
    u64 bytes=(u64)(envelope.w*scale+1)*(u64)(envelope.h*scale+1)*4;
    u64 old=s->canvas_bytes;s->canvas_bytes=bytes;
    if(!rgba_ordinary_capture_budget(g)){s->canvas_bytes=old;return 0;}
    u64 sid=rgba_carrier_space(g,m->window);if(!sid){s->canvas_bytes=old;return 0;}
    struct rgba_view *v=&s->view;
    if(v->window && s->window==(u64)m->window && s->creator==m->creator && s->birth==m->pid_version &&
       s->root==(u64)m->root && s->space==sid && rgba_view_owned(v) && rgba_view_native_alpha(v,1) &&
       rgba_view_contains(s->envelope,(rect){both.x-inset,both.y-inset,both.w+2*inset,both.h+2*inset}) &&
       rgba_carrier_space(g,v->window)==sid) {
        s->canvas_bytes=old;
        if(v->shown && rgba_carrier_ordered(g,s,m->window))return 1;
        RGBA_CALLBACK_SCOPE(c);
        if(v->api.order(0,v->wid,-1,m->wid)!=0)return 0;v->shown=1;return 1;
    }
    RGBA_CALLBACK_SCOPE(c);
    if(v->window) {
        if(!rgba_view_owned(v) || !rgba_view_native_alpha(v,1))return 0;
        if(v->shown && v->api.order(0,v->wid,0,0)!=0)return 0;v->shown=0;
    }else {
        struct rgba_view *template=(void *)((char *)g+RGBA_VIEW_OFFSET);
        v->capture=g;v->api=template->api;v->alpha=1;v->target=envelope;v->presentation_mode=RGBA_VIEW_SNAPSHOT;
        if(rgba_view_create_image(v,m->texture,m->source_w,m->source_h,scale,m->color)!=0)return 0;
        RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);c->tx_add(tx,m->context);
        rgba_view_get(c,v->body,"removeFromSuperlayer");rgba_view_object(c,v->body,"setContents:",0);
        g->pc.release_obj(v->body);g->pc.release_obj(v->texture);v->body=v->texture=0;
        rgba_view_get(c,m->root,"removeFromSuperlayer");
        ((void (*)(void *,void *,u64))c->msg)(m->root,c->sel("setAutoresizingMask:"),0);
        rgba_view_object(c,v->root,"addSublayer:",m->root);
        ((msgf_t)c->msg)(m->root,c->s_opacity,0);RGBA_LAYER_COMMIT(tx);
    }
    void *region=c->rgn(envelope);if(!region)return 0;
    int shaped=v->api.shape(v->window,region,0,0);c->release(region);if(shaped)return 0;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);
    rgba_view_bounds(c,v->root,"setBounds:",(rect){0,0,envelope.w,envelope.h});
    rgba_view_bool(c,v->root,"setMasksToBounds:",0);RGBA_LAYER_COMMIT(tx);
    if(!rgba_carrier_space_sync(g,v,sid))return 0;
    s->window=(u64)m->window;s->creator=m->creator;s->birth=m->pid_version;s->root=(u64)m->root;
    s->space=sid;s->envelope=envelope;s->inset=inset;v->target=v->current=envelope;
    // Reentrant notifications may render B0, with A/H still visible.
    // Keep native child/modal windows above the retained client image. H0
    // makes A's client transparent in the same transaction that presents B.
    if(v->api.order(0,v->wid,-1,m->wid)!=0)return 0;v->shown=1;
    return rgba_inplace_source(g,m)==m->window;
}
static int rgba_carrier_valid(struct rgba_capture *g,struct rgba_carrier_slot *s,struct rgba_inplace *m,rect target) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;
    if(s->window!=(u64)m->window || s->creator!=m->creator || s->birth!=m->pid_version || s->root!=(u64)m->root ||
       !rgba_inplace_source(g,m) || !rgba_view_owned(v) || !v->shown || !rgba_view_native_alpha(v,1) ||
       rgba_carrier_space(g,m->window)!=s->space || rgba_carrier_space(g,v->window)!=s->space ||
       !rgba_carrier_ordered(g,s,m->window))return 0;
    rect outer={target.x-s->inset,target.y-s->inset,target.w+2*s->inset,target.h+2*s->inset};
    if(!rgba_view_contains(s->envelope,outer) || !rgba_view_same(c->srr(v->window,(rect){0,0,s->envelope.w,s->envelope.h}),s->envelope))return 0;
    void *event=*(void **)((char *)v->window+0x100);
    return event && !*(void **)((char *)v->window+0x108) && g->api.geometry.region_empty(event);
}
void anim_rgba_carrier_recover(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);if(!s || !s->view.context)return;
    struct ctx *c=g->pc.engine;char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,s->view.context);
    if(cwc && *(void **)(cwc+0x38)==m->context && *(void **)(cwc+0x98)==m->host) {
        c->tx_add(tx,m->context);((msgf_t)c->msg)(m->host,c->s_opacity,(float)m->host_opacity);
        struct ch_win *w=slot(c->ch,m->wid,0);if(w)rgba_inplace_legacy(c,m,w,0);
    }
    if(m->root)((msgf_t)c->msg)(m->root,c->s_opacity,0);
    m->presenting=0;s->excluded_commit=0;s->idle_observed=0;RGBA_LAYER_COMMIT(tx);
    if(win)decoration_damage(c,win);decoration_damage(c,s->view.window);
    struct rgba_carrier *b=rgba_carrier_control(g);if(b)b->restores++;
}
int anim_rgba_carrier_drop_work(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);if(!s || !s->view.window)return 1;
    if(!rgba_carrier_outside(g))return 0;
    anim_rgba_carrier_recover(g,m);
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;RGBA_CALLBACK_SCOPE(c);
    if(!rgba_view_allocation(v) || v->api.order(0,v->wid,0,0)!=0)return 0;v->shown=0;
    RGBA_LAYER_SCOPE(c,tx);if(v->context)c->tx_add(tx,v->context);
    if(m->root)rgba_view_get(c,m->root,"removeFromSuperlayer");RGBA_LAYER_COMMIT(tx);
    if(!rgba_view_retire(v))return 0;
    rgba_carrier_release_frame(g,&s->displayed);
    rgba_carrier_release_frame(g,&s->retiring);
    for(unsigned i=0;i<sizeof(*s);i++)((volatile unsigned char *)s)[i]=0;
    return 1;
}
extern int anim_rgba_carrier_pose(struct rgba_capture *,struct rgba_inplace *,struct ch_win *);
extern int anim_rgba_carrier_drop(struct rgba_capture *,struct rgba_inplace *);
static int rgba_carrier_drop_slot(struct rgba_capture *g,struct rgba_inplace *m) {
    if(rgba_draw_active(g))return 1;return anim_rgba_carrier_drop(g,m);
}
static int rgba_carrier_pose(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w) {return anim_rgba_carrier_pose(g,m,w);}
static int rgba_carrier_model(struct rgba_capture *g,struct rgba_carrier_slot *s,struct rgba_inplace *m) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;
    void *context=rgba_view_get(c,v->context,"renderContext");
    void *front[7]={v->root,m->root,m->surface,m->body,m->patch[0],m->patch[1],m->patch[2]};
    u64 ids[7];for(unsigned i=0;i<7;i++){ids[i]=front[i]?v->api.layer_id(front[i]):0;if(!ids[i])return 0;}
    u32 commit=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
    if(!context || g->api.lock_context(context)!=0)return 0;
    int ready=*(u32 *)((char *)context+0x40)==commit;char *layers[7]={0};
    for(unsigned i=0;i<7;i++) {
        char *handle=v->api.lookup_handle(context,ids[i],0,0,0);
        layers[i]=handle && *(void **)(handle+0x18)==context?*(char **)(handle+0x10):0;
        if(!layers[i] || *(void **)(layers[i]+0x98)!=handle || *(void **)(layers[i]+0x90))ready=0;
    }
    if(ready) {
        ready=g->api.root(context)==layers[0] && rgba_inplace_render_child(layers[0],layers[1]) &&
            rgba_inplace_render_child(layers[1],layers[2]) && (unsigned char)layers[0][0x24]==255 &&
            (unsigned char)layers[2][0x24]==255 && !*(void **)(layers[0]+0x78) && !*(void **)(layers[1]+0x78);
        double alpha=(double)(unsigned char)layers[1][0x24]/255;
        if(dabs(alpha-m->alpha)>1.0/255 ||
           !rgba_view_same(*(rect *)(layers[0]+0x48),(rect){0,0,s->envelope.w,s->envelope.h}) ||
           !rgba_view_same(*(rect *)(layers[1]+0x48),(rect){0,0,m->current.w,m->current.h}) ||
           !rgba_view_same(*(rect *)(layers[2]+0x48),(rect){0,0,m->current.w,m->current.h}))ready=0;
        rect boxes[4],uv[4];rgba_inplace_regions_at(m,m->current,boxes,uv);
        for(unsigned i=0;i<4;i++)if(!rgba_inplace_region_matches(m,m->current,i,layers[3+i]) ||
            (boxes[i].w>0 && boxes[i].h>0 && (!rgba_inplace_render_child(layers[2],layers[3+i]) || *(void **)(layers[3+i]+0x78))))ready=0;
    }
    g->api.unlock_context(context);return ready;
}
static int rgba_carrier_host_alpha(struct rgba_capture *g,struct rgba_inplace *m,void *prepared,unsigned opacity) {
    char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    if(!cwc || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x98)!=m->host)return 0;
    struct ctx *c=g->pc.engine;struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    void *context=*(void **)(cwc+0x30);u32 sequence=0;
    if(prepared) {
        char *source=0;unsigned count=0;
        for(char *at=prepared;at && count++<256;at=*(char **)(at+8))
            if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==m->wid){if(source)return 0;source=at;}
        if(!source) {
            struct rgba_carrier_slot *s=rgba_carrier_row(g,m);
            return opacity==0 && s && s->excluded_commit && rgba_carrier_host_alpha(g,m,0,0);
        }
        char *meta=*(char **)(source+0x48),*update=meta?*(char **)(meta+0x10):0;
        if(!meta || *(void **)meta!=win || *(void **)(meta+8) || !update ||
           *(void **)(source+0x28)!=update || *(void **)(source+0x30)!=update ||
           !rgba_included(update,context,&sequence))return 0;
    }else sequence=((u32 (*)(void *,void *))c->msg)(m->context,c->sel("commitId"));
    u64 id=v->api.layer_id(m->host);if(!context || !id || g->api.lock_context(context)!=0)return 0;
    char *handle=v->api.lookup_handle(context,id,0,0,0);
    char *host=handle && *(void **)(handle+0x18)==context?*(char **)(handle+0x10):0;
    int ready=*(u32 *)((char *)context+0x40)==sequence && host && *(void **)(host+0x98)==handle &&
        !*(void **)(host+0x90) && (unsigned char)host[0x24]==opacity;
    g->api.unlock_context(context);
    if(ready && prepared && opacity==0) {
        struct rgba_carrier_slot *s=rgba_carrier_row(g,m);if(s)s->excluded_commit=sequence;
    }
    return ready;
}
static int rgba_carrier_host_zero(struct rgba_capture *g,struct rgba_inplace *m,void *prepared) {
    return rgba_carrier_host_alpha(g,m,prepared,0);
}
static void rgba_carrier_observe_idle(struct rgba_capture *g,struct rgba_inplace *m,void *prepared) {
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);if(!s || !s->view.window || s->idle_observed ||
       (!s->displayed.texture && !s->retiring.texture) || !rgba_view_owned(&s->view) ||
       !rgba_carrier_host_alpha(g,m,prepared,255))return;
    char *source=0;unsigned count=0;
    for(char *at=prepared;at && count++<256;at=*(char **)(at+8))
        if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==s->view.wid){if(source)return;source=at;}
    char *meta=source?*(char **)(source+0x48):0,*update=meta?*(char **)(meta+0x10):0;
    if(!meta || *(void **)meta!=s->view.window || *(void **)(meta+8) || !update ||
       *(void **)(source+0x28)!=update || *(void **)(source+0x30)!=update)return;
    void *context=rgba_view_get(g->pc.engine,s->view.context,"renderContext");u32 sequence=0;
    u64 id=s->view.api.layer_id(m->root);
    if(!context || !id || !rgba_included(update,context,&sequence) || g->api.lock_context(context)!=0)return;
    char *handle=s->view.api.lookup_handle(context,id,0,0,0);
    char *root=handle && *(void **)(handle+0x18)==context?*(char **)(handle+0x10):0;
    if(*(u32 *)((char *)context+0x40)==sequence && root && *(void **)(root+0x98)==handle &&
       !*(void **)(root+0x90) && (unsigned char)root[0x24]==0)s->idle_observed=1;
    g->api.unlock_context(context);
}
static void rgba_carrier_idle_cleanup(struct rgba_capture *g,struct rgba_carrier_slot *s,struct rgba_inplace *m) {
    if(!s->idle_observed || m->presenting)return;
    struct ctx *c=g->pc.engine;RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,s->view.context);
    for(unsigned i=0;i<4;i++)rgba_view_object(c,rgba_inplace_part(m,i),"setContents:",0);
    RGBA_LAYER_COMMIT(tx);m->displayed_texture=m->displayed_bytes=0;
    rgba_carrier_release_frame(g,&s->displayed);rgba_carrier_release_frame(g,&s->retiring);s->idle_observed=0;
}
static int rgba_carrier_source_excluded(struct rgba_capture *g,struct rgba_inplace *m,void *prepared) {
    return rgba_carrier_host_zero(g,m,prepared);
}
int anim_rgba_carrier_pose_work(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct ctx *c=g->pc.engine;
    if(!b)return 0;if(!rgba_carrier_outside(g) && !rgba_carrier_before_allowed(g,m))return 1;
    struct rgba_carrier_slot *row=rgba_carrier_row(g,m);
    if(row && row->view.window)rgba_carrier_idle_cleanup(g,row,m);
    char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    if(!w || !w->used || w->wid!=m->wid || !w->geo || w->geo==2 || !cwc ||
       *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x80)!=m->server_root || *(void **)(cwc+0x98)!=m->host)return 0;
    if(b->dead || !((*(u64 *)(win+0x928)>>44)&1) || *(int *)(win+0x20)!=0 ||
       *(void **)(cwc+0x70) || *(void **)(cwc+0x78) || *(u32 *)(cwc+0x150) || *(u32 *)(cwc+0x154) ||
       cover_index(c,m->wid,1)>=0 || birth_holds(c,m->wid) || c->ch->h.mask_flip!=1) {
        if(m->presenting)anim_rgba_carrier_recover(g,m);return 1;
    }
    int moving=(m->presenting && (w->held || w->wait)) ||
        (!m->opening && w->held && !w->wait) || (!w->held && !w->wait && (w->pos.active || w->size.active || w->alpha.active));
    if(!moving && m->presenting) {
        struct rect4 hb=((msgb_t)c->msg)(m->host,c->s_bounds);
        int ready=!w->settling && dabs(hb.w-m->source_w)<.5 && dabs(hb.h-m->source_h)<.5 &&
            dabs(w->aw-w->size.v[0])<=c->ch->h.settle_px && dabs(w->ah-w->size.v[1])<=c->ch->h.settle_px;
        if(!m->settle_started)m->settle_started=c->ch->h.now;
        if(!ready && c->ch->h.now-m->settle_started<.15)moving=1;
    }else if(moving)m->settle_started=0;
    if(!moving) {
        if(m->presenting)anim_rgba_carrier_recover(g,m);
        // Warm allocation has no H0; future native order notifications can only
        // observe the live application plus an empty B.
        if(!b->preparing)rgba_carrier_prepare(g,m,w);
        m->motion_started=m->settle_started=0;return 1;
    }
    rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
    double alpha=m->presenting && (w->held || w->wait)?m->alpha:w->cur_alpha;
    if(!rgba_view_rect(target) || !finite(alpha) || alpha<0 || alpha>1)return 0;
    struct rgba_carrier_slot *s=rgba_carrier_row(g,m);
    if(!m->presenting && !b->preparing){rgba_carrier_prepare(g,m,w);s=rgba_carrier_row(g,m);}
    if(!s || !s->view.window || !rgba_carrier_valid(g,s,m,target)) {
        if(m->presenting)anim_rgba_carrier_recover(g,m);b->refused++;
        if(rgba_begin_wait(g,m,w,win))return 1;
        return rgba_ordinary_native_fallback(g,m,w,win);
    }
    struct rgba_ordinary *o=rgba_ordinary_control(g);unsigned i=rgba_begin_index(g,m);
    if(!m->presenting && (!o || i>=CH_NW || m->opening || w->wait || w->cur_alpha!=1 ||
       !rgba_begin_takeover_ready(g,m,o->good_time[i]) || o->good_time[i]<o->native_time[i] ||
       m->good_client_context!=(u64)*(void **)(cwc+0x48) || m->good_client_id!=*(u32 *)(cwc+0x50))) {
        if(rgba_begin_wait(g,m,w,win))return 1;
        return rgba_ordinary_native_fallback(g,m,w,win);
    }
    if(s->retiring.texture && m->adopted_texture!=(u64)s->displayed.texture && m->texture!=s->displayed.texture)return 1;
    // Keep the baseline's 1:1 input translation and native crop. B's independent
    // drawing footprint does not require clearing any input-affecting A clip.
    if(dabs(w->m[0]-1)>1e-6 || dabs(w->m[1]-1)>1e-6) {
        if(m->presenting)anim_rgba_carrier_recover(g,m);return 1;
    }
    RGBA_CALLBACK_SCOPE(c);RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);c->tx_add(tx,s->view.context);
    m->current=m->target=target;m->alpha=alpha;m->logical_alpha=alpha;m->radius=w->radius;
    rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,target.w,target.h});
    rgba_view_point(c,m->root,"setPosition:",target.x-s->envelope.x,s->envelope.h-(target.y-s->envelope.y)-target.h);
    rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,target.w,target.h});
    rgba_view_point(c,m->surface,"setPosition:",0,0);
    ((msgd_t)c->msg)(m->surface,c->s_radius,m->radius);
    rgba_inplace_pixels(c,m,m->displayed_texture!=(u64)m->texture);rgba_inplace_border(c,m,w);
    ((msgf_t)c->msg)(m->root,c->s_opacity,(float)alpha);
    rgba_inplace_legacy(c,m,w,1);put_under(c,w,0,0,0,0,0,0,0,0);
    ((msgf_t)c->msg)(m->host,c->s_opacity,0);RGBA_LAYER_COMMIT(tx);
    // A model proof is a publication gate; actual B consumer adoption remains
    // the separate immutable prepared-Update observer in presentation_inplace.
    if(!rgba_carrier_model(g,s,m) || !rgba_carrier_host_zero(g,m,0)) {
        anim_rgba_carrier_recover(g,m);b->refused++;return 1;
    }
    if(!m->presenting){b->claims++;m->motion_started=c->ch->h.now;}
    m->presenting=1;m->padding_motion=0;m->displayed_texture=(u64)m->texture;
    m->displayed_bytes=(u64)m->pixel_w*m->pixel_h*4;m->last_used=c->ch->h.now;m->mutations++;
    rgba_carrier_remember(g,s,m);decoration_damage(c,s->view.window);decoration_damage(c,win);return 1;
}
struct rgba_carrier_before_scope {
    struct rgba_carrier *carrier;struct rgba_begin_binding *begin;u32 claiming;
};
static void rgba_carrier_before_cleanup(struct rgba_carrier_before_scope *scope) {
    scope->begin->claiming=scope->claiming;scope->carrier->before_slot=0;scope->carrier->preparing=0;
}
static void rgba_carrier_before_window(struct rgba_capture *g,void *window,unsigned flag,u64 frame,u64 *ticket) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct rgba_begin_binding *begin=rgba_begin_control(g);
    if(!b || b->dead || b->depth!=1 || b->preparing || b->before_slot || !b->slots || !begin || flag ||
       pc_address((void *)((u64 *)frame)[1])!=begin->returns[0])return;
    // rgba_begin_owner already validated this exact native frame and parent.
    // The parent's saved x23/x19 are UpdateDisplays' actual input array/count;
    // the session ordering array alone does not prove this pass's order.
    u64 parent=*(u64 *)frame;void **items=*(void ***)(parent-0x28);u32 count=*(u32 *)(parent-8);
    if(!items || ((u64)items&7) || !count || count>4096)return;
    struct rgba_inplace *slots=rgba_ordinary_slots(g);struct rgba_ordinary *o=rgba_ordinary_control(g);
    for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_inplace *m=&slots[i];struct rgba_carrier_slot *s=&b->slots[i];
        if(!m->on || m->presenting || m->window!=window || !rgba_view_owned(&s->view) ||
           rgba_inplace_source(g,m)!=m->window)continue;
        unsigned a=0,bb=0,ai=0,bi=0;
        for(unsigned j=0;j<count;j++) {
            if(items[j]==m->window){a++;ai=j;}
            if(items[j]==s->view.window){bb++;bi=j;}
        }
        if(a!=1 || bb!=1 || ai>=bi)return;
        struct ctx *c=g->pc.engine;struct ch_win *w=slot(c->ch,m->wid,0);
        if(!w || !w->used || !w->geo || w->geo==2 || m->opening || m->padding_motion || w->wait ||
           w->cur_alpha!=1 || !(w->held || w->pos.active || w->size.active) ||
           cover_index(c,m->wid,1)>=0 || birth_holds(c,m->wid))return;
        ticket[0]=i+1;
        struct rgba_carrier_before_scope scope __attribute__((cleanup(rgba_carrier_before_cleanup)))={b,begin,begin->claiming};
        b->preparing=2;b->before_slot=i+1;begin->claiming=i+1;
        if(o->candidate==i && g->pc.wid==m->wid && g->pc.stage==PC_ENCODED)anim_rgba_poll(g);
        if(o->candidate==i && g->pc.wid==m->wid && g->pc.stage==PC_GPU_COMPLETE)rgba_ordinary_accept(g,c->ch->h.now);
        if(!m->presenting && rgba_begin_takeover_ready(g,m,o->good_time[i]))rgba_carrier_pose(g,m,w);
        if(m->presenting)begin->takeovers++;
        return;
    }
}
void anim_rgba_carrier_failed(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);if(b)b->dead=1;
    struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(o && !o->command && o->sequence==o->ack) {
        __atomic_store_n(&o->command,2,__ATOMIC_RELEASE);__atomic_store_n(&o->sequence,o->ack+1,__ATOMIC_RELEASE);
    }
}
static void rgba_carrier_close_before(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct rgba_close *close=rgba_close_control(g);
    if(!b || !b->slots || !close || !close->slots)return;
    struct ctx *c=g->pc.engine;struct rgba_inplace *all=rgba_ordinary_slots(g);
    for(unsigned k=0;k<P8_N;k++) {
        struct p8c *e=&P8_TAB(c)[k];if(!e->live || e->pending!=0)continue;
        struct rgba_close_slot *out=&close->slots[k];if(out->transferred && rgba_close_matches(c,out,k))continue;
        for(unsigned i=0;i<CH_NW;i++) {
            struct rgba_inplace *m=&all[i];struct rgba_carrier_slot *s=&b->slots[i];
            if(!m->on || !m->presenting || m->wid!=e->src || (u64)m->window!=P8_SOURCE(c)[k] ||
               !s->displayed.texture || s->root!=(u64)m->root || !s->view.shown || !rgba_view_owned(&s->view))continue;
            char *source=c->by_id(e->src),*clone=c->by_id(e->wid);double stamp=e->t0;u32 clone_wid=e->wid;
            // A reused WID does not establish disappearance of this source.
            if(source && (source!=m->window || *(u64 *)(source+0x30)!=m->creator ||
               *(u64 *)((char *)m->creator+0x268)!=m->pid_version))continue;
            if(!clone || *(u32 *)(clone+4)!=3 || *(void **)(clone+0x30))continue;
            // The captured-H0 native clone must stay suppressed even if B ends
            // early. P8 does not order pending0 clones back IN after p8_go.
            {RGBA_CALLBACK_SCOPE(c);c->order(0,clone_wid,0,0);}
            if(!e->live || e->pending!=0 || e->wid!=clone_wid || e->t0!=stamp ||
               P8_SOURCE(c)[k]!=(u64)m->window || c->by_id(clone_wid)!=clone ||
               ((*(u64 *)(clone+0x928)>>44)&1))continue;
            source=c->by_id(e->src);
            if(source && (source!=m->window || !rgba_inplace_source(g,m) || ((*(u64 *)(source+0x928)>>44)&1)))break;
            if(out->clone_wid && !rgba_close_retire(g,out,k))break;
            source=c->by_id(e->src);
            if(source) {
                if(source!=m->window || !rgba_inplace_source(g,m) || ((*(u64 *)(source+0x928)>>44)&1))break;
                char *cwc=*(char **)(source+0x18);
                if(!cwc || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x98)!=m->host)break;
                // An ordered-out application window can later reappear with
                // the same identity. It must not retain our hidden Hosting.
                RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
                ((msgf_t)c->msg)(m->host,c->s_opacity,(float)m->host_opacity);RGBA_LAYER_COMMIT(tx);
                s->excluded_commit=0;
            }
            source=c->by_id(e->src);
            if(source && (source!=m->window || !rgba_inplace_source(g,m) || ((*(u64 *)(source+0x928)>>44)&1))) {
                anim_rgba_carrier_recover(g,m);break;
            }
            if(!e->live || e->pending!=0 || e->wid!=clone_wid || e->t0!=stamp ||
               P8_SOURCE(c)[k]!=(u64)m->window || c->by_id(clone_wid)!=clone)break;
            // Restore the immutable descriptor of contents actually left on B,
            // since a completed cache refresh need not have posed that image.
            struct rgba_retained_frame frame=s->displayed;
            for(unsigned n=0;n<sizeof(out->view);n++)((volatile unsigned char *)&out->view)[n]=((const volatile unsigned char *)&s->view)[n];
            for(unsigned n=0;n<sizeof(out->layers);n++)((volatile unsigned char *)&out->layers)[n]=((const volatile unsigned char *)m)[n];
            out->unpublished=(struct rgba_retained_frame){m->texture,m->source_w,m->source_h,
                (double)m->pixel_w/m->source_w,m->pixel_w,m->pixel_h,m->good_client_context,
                m->good_client_id,m->good_client_sequence,m->color};
            out->view.body=m->body;out->view.texture=frame.texture;
            out->layers.texture=frame.texture;out->layers.color=frame.color;
            out->layers.source_w=frame.width;out->layers.source_h=frame.height;
            out->layers.pixel_w=frame.pixel_width;out->layers.pixel_h=frame.pixel_height;
            out->layers.good_client_context=frame.client_context;out->layers.good_client_id=frame.client_id;
            out->layers.good_client_sequence=frame.client_sequence;
            out->layers.window=out->layers.context=out->layers.server_root=out->layers.host=0;
            out->clone=clone;out->clone_wid=clone_wid;out->source_wid=e->src;out->source=P8_SOURCE(c)[k];
            out->phase=0;out->stamp=stamp;out->shown_at=c->ch->h.now;out->inset=s->inset;
            out->logical_alpha=m->alpha;out->transferred=1;out->envelope=s->envelope;out->canvas_bytes=s->canvas_bytes;
            out->previous_displayed=s->retiring;s->retiring=(struct rgba_retained_frame){0};
            rect current=m->current;
            rgba_begin_forget(g,m);
            // No native/ObjC calls between the shallow move and relinquishing
            // both old owners. Extra cache/image refs now belong only to close.
            for(unsigned n=0;n<sizeof(*s);n++)((volatile unsigned char *)s)[n]=0;
            for(unsigned n=0;n<sizeof(*m);n++)((volatile unsigned char *)m)[n]=0;
            struct ch_win *w=slot(c->ch,clone_wid,0);
            if(w) {
                double pos[2]={current.x,current.y},size[2]={current.w,current.h};
                warp(&w->pos,2,pos);warp(&w->size,2,size);
                double scale=hd(c->ch,3);if(!finite(scale))scale=.92;if(scale<0)scale=0;if(scale>1)scale=1;
                double tw=size[0]*scale,th=size[1]*scale;if(tw<5)tw=size[0]<5?size[0]:5;if(th<5)th=size[1]<5?size[1]:5;
                double to_pos[2]={pos[0]+(size[0]-tw)/2,pos[1]+(size[1]-th)/2},to_size[2]={tw,th};
                u32 curve=(c->ch->h.reserved[0]>>8)&255;
                retarget(c,&w->pos,2,to_pos,curve,hd(c->ch,1),stamp);retarget(c,&w->size,2,to_size,curve,hd(c->ch,1),stamp);
            }
            close->prepared++;close->shown++;break;
        }
    }
}
void anim_rgba_scene_before(struct rgba_carrier *b,u64 frame) {
    (void)frame;
    if(b && b->magic==RGBA_CARRIER_MAGIC && b->version==2 && rgba_valid(b->capture)) {
        rgba_draw_scene_before(b->capture);return;
    }
    if(!b || b->magic!=RGBA_CARRIER_MAGIC || b->size!=sizeof(*b) || b->version!=1 ||
       !rgba_valid(b->capture) || b->depth || b->preparing)return;
    struct rgba_capture *g=b->capture;struct ctx *c=g->pc.engine;
    if(!c || c->in_cb || !rgba_carrier_stack(g,0))return;
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o)return;
    b->passes++;b->preparing=1;
    rgba_carrier_close_before(g);
    struct rgba_inplace *slots=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++)if(slots[i].on && slots[i].presenting) {
        struct rgba_inplace *m=&slots[i];struct rgba_carrier_slot *s=rgba_carrier_row(g,m);
        if(b->dead || !o->enabled || c->dead || c->ch->h.stop || c->ch->h.now>=o->expires ||
           !s || !rgba_carrier_valid(g,s,m,m->current) || !rgba_carrier_host_zero(g,m,0))anim_rgba_carrier_recover(g,m);
    }
    // Poll only the existing GPU candidate; never allocate/encode inside the
    // native frame boundary. Issued serial/native freshness are not relaxed.
    struct rgba_normal_binding *n=rgba_normal_binding(g);struct rgba_begin_binding *begin=rgba_begin_control(g);
    if(!b->dead && o->enabled && n && !n->inflight && begin && !begin->dead &&
       !g->quarantined && !g->locked_client && !g->pc.active_command && !o->command && o->sequence==o->ack) {
        if(o->candidate<CH_NW && g->pc.stage==PC_ENCODED)anim_rgba_poll(g);
        if(o->candidate<CH_NW && slots[o->candidate].on && g->pc.stage==PC_GPU_COMPLETE) {
            begin->claiming=o->candidate+1;rgba_ordinary_accept(g,c->ch->h.now);begin->claiming=0;
        }
        for(unsigned i=0;i<CH_NW;i++)if(slots[i].on && !slots[i].presenting) {
            struct rgba_begin_source *source=rgba_begin_row(g,&slots[i]);
            if(!source || source->valid!=1 || !source->serial || source->good_serial!=source->serial)continue;
            begin->claiming=i+1;rgba_carrier_pose(g,&slots[i],slot(c->ch,slots[i].wid,0));begin->claiming=0;
        }
    }
    b->preparing=0;
}
void anim_rgba_scene_enter(struct rgba_carrier *b) {if(b && b->magic==RGBA_CARRIER_MAGIC)__atomic_fetch_add(&b->depth,1,__ATOMIC_ACQ_REL);}
void anim_rgba_scene_leave(struct rgba_carrier *b) {if(b && b->magic==RGBA_CARRIER_MAGIC)__atomic_fetch_sub(&b->depth,1,__ATOMIC_ACQ_REL);}
void anim_rgba_scene_failed(struct rgba_carrier *b) {
    if(!b || b->magic!=RGBA_CARRIER_MAGIC)return;b->preparing=0;
    if(rgba_valid(b->capture))anim_rgba_carrier_failed(b->capture);
}
void anim_rgba_scene_recover_at(struct rgba_carrier *b,unsigned i) {
    if(!b || b->magic!=RGBA_CARRIER_MAGIC || i>=CH_NW || !rgba_valid(b->capture))return;
    struct rgba_capture *g=b->capture;struct rgba_inplace *m=&rgba_ordinary_slots(g)[i];
    if(rgba_draw_active(g)){rgba_draw_recover_at(g,i);return;}
    if(m->on && m->presenting)anim_rgba_carrier_recover(g,m);
}
// Definitions below keep the scene boundary, close transfer and joint model
// publication together; none retains native prepared lists or Update pointers.
_Static_assert(RGBA_INPLACE_OFFSET+sizeof(struct rgba_inplace)<=RGBA_CARRIER_OFFSET,"carrier follows in-place control");
_Static_assert(RGBA_CARRIER_OFFSET+sizeof(struct rgba_carrier)<=RGBA_NORMAL_OFFSET,"carrier control partition");
