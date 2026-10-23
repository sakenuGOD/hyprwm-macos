// Close follows the baseline P8 clock, but samples an independently retained
// client image. CaptureSurface remains the fallback until this carrier commits.
#define RGBA_CLOSE_OFFSET 6144
#define RGBA_CLOSE_MAGIC 0x3145534f4c434752ULL
struct rgba_close_slot {
    struct rgba_view view;
    struct rgba_inplace layers;
    void *clone;u64 source;
    u32 clone_wid,source_wid,phase,adopted;
    double stamp,shown_at,inset,logical_alpha;
};
struct rgba_close {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    void *storage;struct rgba_close_slot *slots;
    u64 prepared,shown,adoptions,refused;
    u32 rejected_wid[P8_N];u64 rejected_source[P8_N];double rejected_stamp[P8_N];
};
static struct rgba_close *rgba_close_control(struct rgba_capture *g) {
    struct rgba_close *b=(void *)((char *)g+RGBA_CLOSE_OFFSET);
    return b->magic==RGBA_CLOSE_MAGIC && b->size==sizeof(*b) && b->version==1 && b->capture==g?b:0;
}
static int rgba_close_matches(struct ctx *c,struct rgba_close_slot *s,unsigned index) {
    struct p8c *e=&P8_TAB(c)[index];
    return e->live && e->wid==s->clone_wid && e->src==s->source_wid &&
        P8_SOURCE(c)[index]==s->source && c->by_id(e->wid)==s->clone &&
        (e->pending==0 || e->pending==1) &&
        (e->t0==s->stamp || (s->phase==1 && e->pending==0));
}
static int rgba_close_retire(struct rgba_capture *g,struct rgba_close_slot *s,unsigned index) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    u32 was=c->in_cb;c->in_cb=1;
    if(v->window && !rgba_view_allocation(v)){c->in_cb=was;return 0;}
    if(v->window && v->api.order(0,v->wid,0,0)!=0){c->in_cb=was;return 0;}
    if(rgba_close_matches(c,s,index)) {
        struct ch_win *w=slot(c->ch,s->clone_wid,0);
        if(w && v->shown) {
            c->set_alpha(0,s->clone,(float)w->cur_alpha,0);rgba_inplace_legacy(c,m,w,0);
        }
    }
    if(v->context) {
        u64 tx[4]={0};c->tx_ctor(tx,1);c->tx_add(tx,v->context);
        for(unsigned i=0;i<4;i++)if(rgba_inplace_part(m,i))rgba_view_object(c,rgba_inplace_part(m,i),"setContents:",0);
        rgba_view_object(c,v->context,"setLayer:",0);layers_commit(c,tx);
    }
    // view owns the root/body/texture references; close owns only additions.
    for(unsigned i=0;i<3;i++)if(m->patch[i]){g->pc.release_obj(m->patch[i]);m->patch[i]=0;}
    if(m->surface){g->pc.release_obj(m->surface);m->surface=0;}
    if(m->ring_in){g->pc.release_obj(m->ring_in);m->ring_in=0;}
    if(m->ring_act){g->pc.release_obj(m->ring_act);m->ring_act=0;}
    if(m->shadow){g->pc.release_obj(m->shadow);m->shadow=0;}
    if(m->root){g->pc.release_obj(m->root);m->root=0;}
    if(m->accepted.texture){g->pc.release_obj(m->accepted.texture);m->accepted.texture=0;}
    if(m->accepted.color){g->api.geometry.release_cf(m->accepted.color);m->accepted.color=0;}
    if(m->color){g->api.geometry.release_cf(m->color);m->color=0;}
    if(!rgba_view_retire(v)){c->in_cb=was;return 0;}
    for(unsigned i=0;i<sizeof(*s);i++)((volatile unsigned char *)s)[i]=0;
    c->in_cb=was;return 1;
}
static int rgba_close_drop(struct rgba_capture *g) {
    struct rgba_close *b=rgba_close_control(g);if(!b)return 1;
    if(b->slots)for(unsigned i=0;i<P8_N;i++)if(b->slots[i].clone_wid && !rgba_close_retire(g,&b->slots[i],i))return 0;
    if(b->storage)g->pc.release_obj(b->storage);
    b->storage=0;b->slots=0;return 1;
}
static u64 rgba_close_bytes(struct rgba_capture *g) {
    struct rgba_close *b=rgba_close_control(g);u64 bytes=0;
    if(b && b->slots)for(unsigned i=0;i<P8_N;i++) {
        struct rgba_close_slot *s=&b->slots[i];
        if(s->view.texture)bytes+=(u64)s->layers.pixel_w*s->layers.pixel_h*4;
        if(s->layers.accepted.texture && s->layers.accepted.texture!=s->view.texture)
            bytes+=(u64)s->layers.accepted.pixel_width*s->layers.accepted.pixel_height*4;
    }
    return bytes;
}
static int rgba_close_create(struct rgba_capture *g,struct rgba_close_slot *s,struct rgba_inplace *source,unsigned index) {
    struct ctx *c=g->pc.engine;struct p8c *e=&P8_TAB(c)[index];
    // The latest completed cache is a candidate for this new destination. Its
    // older adopted image remains retained until the close consumer adopts it.
    struct rgba_retained_frame candidate={source->texture,source->source_w,source->source_h,
        (double)source->pixel_w/source->source_w,source->pixel_w,source->pixel_h,
        source->good_client_context,source->good_client_id,source->good_client_sequence,source->color};
    struct rgba_retained_frame *image=&candidate;
    struct ch_win *w=slot(c->ch,e->wid,0);char *clone=c->by_id(e->wid);
    if(!w || !clone || *(u32 *)(clone+4)!=3 || *(void **)(clone+0x30) || !image->texture ||
       !image->client_context || !image->client_id || !image->pixel_width || !image->pixel_height ||
       !rgba_view_rect((rect){0,0,image->width,image->height}) ||
       !finite(image->scale) || image->scale<=0 || image->scale>8)return 0;
    struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    struct rgba_view *template=(void *)((char *)g+RGBA_VIEW_OFFSET);
    s->clone=clone;s->clone_wid=e->wid;s->source_wid=e->src;s->source=P8_SOURCE(c)[index];s->phase=e->pending;s->stamp=e->t0;
    s->logical_alpha=source->logical_alpha;
    if(!finite(s->logical_alpha) || s->logical_alpha<0 || s->logical_alpha>1)return 0;
    v->capture=g;v->api=template->api;v->alpha=1;
    rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
    s->inset=SH_E+c->ch->deco.width;
    if(!finite(s->inset) || s->inset<0 || s->inset>512)return 0;
    v->target=(rect){target.x-s->inset,target.y-s->inset,target.w+2*s->inset,target.h+2*s->inset};
    if(rgba_view_create_image(v,image->texture,image->width,image->height,image->scale,image->color)!=0)return 0;
    m->capture=g;m->body=v->body;m->texture=v->texture;
    m->color=image->color?g->api.geometry.retain_cf(image->color):0;
    if(source->accepted.texture && source->accepted.texture!=v->texture) {
        m->accepted=source->accepted;m->accepted.texture=g->pc.retain_obj(source->accepted.texture);
        m->accepted.color=source->accepted.color?g->api.geometry.retain_cf(source->accepted.color):0;
        if(!m->accepted.texture)return 0;
    }
    m->current=target;m->source_w=image->width;m->source_h=image->height;
    m->pixel_w=image->pixel_width;m->pixel_h=image->pixel_height;m->radius=source->radius;
    m->surface=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    m->root=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    for(unsigned i=0;i<3;i++)m->patch[i]=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    if(!m->root || !m->surface || !m->patch[0] || !m->patch[1] || !m->patch[2])return 0;
    u64 tx[4]={0};c->tx_ctor(tx,1);c->tx_add(tx,v->context);
    rgba_view_get(c,m->body,"removeFromSuperlayer");
    rgba_view_point(c,m->root,"setAnchorPoint:",0,0);rgba_view_point(c,m->root,"setPosition:",s->inset,s->inset);
    rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,target.w,target.h});
    rgba_view_point(c,m->surface,"setAnchorPoint:",0,0);rgba_view_point(c,m->surface,"setPosition:",0,0);
    rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,m->current.w,m->current.h});
    rgba_view_bool(c,v->root,"setMasksToBounds:",0);rgba_view_bool(c,m->root,"setMasksToBounds:",0);rgba_view_bool(c,m->surface,"setMasksToBounds:",1);
    ((msgd_t)c->msg)(m->surface,c->s_radius,m->radius);((msgp_t)c->msg)(m->surface,c->s_curve,c->str_circ);
    for(unsigned i=0;i<4;i++) {
        void *part=rgba_inplace_part(m,i);rgba_view_point(c,part,"setAnchorPoint:",0,0);
        rgba_view_bool(c,part,"setOpaque:",0);rgba_view_bool(c,part,"setContentsOpaque:",0);
        ((msgd_t)c->msg)(part,c->sel("setContentsScale:"),image->scale);
        rgba_view_object(c,part,"setContentsGravity:",rgba_view_string(c,"resize"));
        rgba_view_object(c,part,"setContentsScaling:",rgba_view_string(c,"stretch"));
        rgba_view_object(c,part,"setMinificationFilter:",rgba_view_string(c,"nearest"));
        rgba_view_object(c,part,"setMagnificationFilter:",rgba_view_string(c,"nearest"));
        rgba_view_bounds(c,part,"setContentsCenter:",(rect){0,0,1,1});
        rgba_view_object(c,m->surface,"addSublayer:",part);
    }
    rgba_inplace_pixels(c,m,1);rgba_view_object(c,m->root,"addSublayer:",m->surface);
    rgba_view_object(c,v->root,"addSublayer:",m->root);
    struct ch_win proxy;proxy.bl_in=proxy.bl_act=0;void *curve=c->cur_curve;c->cur_curve=c->str_circ;
    border_make(c,&proxy,m->root);c->cur_curve=curve;
    m->ring_in=(void *)proxy.bl_in;m->ring_act=(void *)proxy.bl_act;
    int ready=m->ring_in && m->ring_act && rgba_view_get(c,m->ring_act,"mask");
    if(ready)rgba_inplace_border(c,m,w);
    layers_commit(c,tx);return ready;
}
// The model commit gates first order-in; actual prepared Update adoption below
// is recorded separately and is never replaced by this check.
static int rgba_close_committed(struct rgba_capture *g,struct rgba_close_slot *s) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    void *context=rgba_view_get(c,v->context,"renderContext");if(!context)return 0;
    u64 ids[5]={v->api.layer_id(m->surface),0,0,0,0};
    for(unsigned i=0;i<4;i++)ids[i+1]=v->api.layer_id(rgba_inplace_part(m,i));
    u32 commit=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
    if(g->api.lock_context(context)!=0)return 0;
    char *layers[5]={0};int ready=1;
    for(unsigned i=0;i<5;i++) {
        char *handle=ids[i]?v->api.lookup_handle(context,ids[i],0,0,0):0;
        layers[i]=handle && *(void **)(handle+0x18)==context?*(char **)(handle+0x10):0;
    }
    if(!layers[0] || !rgba_view_same(*(rect *)(layers[0]+0x48),(rect){0,0,m->current.w,m->current.h}))ready=0;
    for(unsigned i=0;i<4;i++) {
        rect boxes[4],uv[4];rgba_inplace_regions_at(m,m->current,boxes,uv);
        if(!rgba_inplace_region_matches(m,m->current,i,layers[i+1]) ||
           (boxes[i].w>0 && boxes[i].h>0 && !rgba_inplace_render_child(layers[0],layers[i+1])))ready=0;
    }
    if(*(u32 *)((char *)context+0x40)!=commit)ready=0;
    g->api.unlock_context(context);
    return ready && ((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"))==commit;
}
static void rgba_close_observe(struct rgba_capture *g,void *prepared) {
    struct rgba_close *b=rgba_close_control(g);if(!b || !b->slots)return;
    struct ctx *c=g->pc.engine;
    for(unsigned index=0;index<P8_N;index++) {
        struct rgba_close_slot *s=&b->slots[index];struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
        if(!s->clone_wid || !v->shown || s->adopted || !rgba_close_matches(c,s,index) || !rgba_view_owned(v))continue;
        char *source=0;unsigned count=0;
        for(char *at=prepared;at && count++<256;at=*(char **)(at+8))if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==v->wid) {
            if(source){source=0;break;}source=at;
        }
        if(!source || count>=256)continue;
        char *meta=*(char **)(source+0x48),*update=meta?*(char **)(meta+0x10):0;
        if(!meta || *(void **)meta!=v->window || *(void **)(meta+8) || !update ||
           *(void **)(source+0x28)!=update || *(void **)(source+0x30)!=update)continue;
        void *context=rgba_view_get(c,v->context,"renderContext");u32 sequence=0;
        if(!context || !rgba_included(update,context,&sequence))continue;
        u64 ids[5]={v->api.layer_id(m->surface),0,0,0,0};
        for(unsigned i=0;i<4;i++)ids[i+1]=v->api.layer_id(rgba_inplace_part(m,i));
        if(g->api.lock_context(context)!=0)continue;
        void *handles[5]={0};char *layers[5]={0};
        for(unsigned i=0;i<5;i++)handles[i]=ids[i]?v->api.lookup_handle(context,ids[i],0,0,0):0;
        char *heads[64],*next[64],*previous[64],*parents[64],*seen[512];
        unsigned depth=1,n=0;int valid=1;
        heads[0]=update+0xd8;next[0]=*(char **)heads[0];previous[0]=heads[0];parents[0]=0;
        while(depth && valid) {
            unsigned d=depth-1;char *node=next[d];
            if(node==heads[d]){if(*(char **)(heads[d]+8)!=previous[d])valid=0;depth--;continue;}
            if(!node || n==512 || *(char **)(node+8)!=previous[d] || *(char **)(node+0x58)!=parents[d]){valid=0;break;}
            for(unsigned i=0;i<n;i++)if(seen[i]==node)valid=0;
            if(!valid)break;
            seen[n++]=node;next[d]=*(char **)node;previous[d]=node;
            char *layer=*(char **)(node+0x20);void *handle=layer?*(void **)(layer+0x98):0;
            for(unsigned i=0;i<5;i++)if(handle && handle==handles[i]){if(layers[i])valid=0;layers[i]=layer;}
            if(depth==64){valid=0;break;}
            heads[depth]=node+0x60;next[depth]=*(char **)(node+0x60);previous[depth]=node+0x60;parents[depth]=node;depth++;
        }
        rect pose=layers[0]?*(rect *)(layers[0]+0x48):(rect){0};
        if(!rgba_view_rect(pose) || pose.x!=0 || pose.y!=0 || !layers[0] || (unsigned char)layers[0][0x24]!=255)valid=0;
        rect boxes[4],uv[4];rgba_inplace_regions_at(m,pose,boxes,uv);
        for(unsigned i=0;i<4;i++)if(!rgba_inplace_region_matches(m,pose,i,layers[i+1]) ||
            (boxes[i].w>0 && boxes[i].h>0 && !rgba_inplace_render_child(layers[0],layers[i+1])))valid=0;
        g->api.unlock_context(context);
        if(valid) {
            s->adopted=1;b->adoptions++;
            if(m->accepted.texture){g->pc.release_obj(m->accepted.texture);m->accepted.texture=0;}
            if(m->accepted.color){g->api.geometry.release_cf(m->accepted.color);m->accepted.color=0;}
        }
    }
}
static void rgba_close_refuse(struct rgba_capture *g,struct rgba_close_slot *s,unsigned index) {
    struct ctx *c=g->pc.engine;struct rgba_close *b=rgba_close_control(g);struct p8c *e=&P8_TAB(c)[index];
    b->refused++;b->rejected_wid[index]=e->wid;b->rejected_source[index]=P8_SOURCE(c)[index];b->rejected_stamp[index]=e->t0;
    rgba_close_retire(g,s,index);
}
static void rgba_close_tick(struct rgba_capture *g,double now) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o)return;
    if(!o->enabled){rgba_close_drop(g);return;}
    struct ctx *c=g->pc.engine;struct rgba_close *b=rgba_close_control(g);
    if(!b) {
        b=(void *)((char *)g+RGBA_CLOSE_OFFSET);
        for(unsigned i=0;i<sizeof(*b);i++)((volatile unsigned char *)b)[i]=0;
        b->magic=RGBA_CLOSE_MAGIC;b->size=sizeof(*b);b->version=1;b->capture=g;
    }
    for(unsigned index=0;index<P8_N;index++) {
        struct p8c *e=&P8_TAB(c)[index];struct rgba_close_slot *s=b->slots?&b->slots[index]:0;
        if(s && s->clone_wid && !rgba_close_matches(c,s,index)) {
            if(!rgba_close_retire(g,s,index))continue;
        }
        if(!e->live || (e->pending!=0 && e->pending!=1))continue;
        if(e->wid==b->rejected_wid[index] && P8_SOURCE(c)[index]==b->rejected_source[index] && e->t0==b->rejected_stamp[index]) {
            if(s && s->clone_wid)rgba_close_retire(g,s,index);
            continue;
        }
        if(!s || !s->clone_wid) {
            struct rgba_inplace *slots=rgba_ordinary_slots(g),*source=0;
            for(unsigned i=0;i<CH_NW;i++)if(slots[i].on && slots[i].wid==e->src &&
                (u64)slots[i].window==P8_SOURCE(c)[index] && slots[i].texture){source=&slots[i];break;}
            if(!source)continue;
            if(!b->slots) {
                void *data=((void *(*)(void *,void *,u64))c->msg)(c->cls("NSMutableData"),c->sel("dataWithLength:"),P8_N*sizeof(*s));
                if(!data)continue;
                b->storage=g->pc.retain_obj(data);b->slots=rgba_view_get(c,data,"mutableBytes");
                if(!b->slots){g->pc.release_obj(b->storage);b->storage=0;continue;}
            }
            s=&b->slots[index];
            if(!rgba_close_create(g,s,source,index)){rgba_close_refuse(g,s,index);continue;}
            b->prepared++;
        }
        if(e->pending==1)continue;
        s->phase=0;s->stamp=e->t0;
        struct ch_win *w=slot(c->ch,e->wid,0);struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
        if(!w || !rgba_view_owned(v)){rgba_close_refuse(g,s,index);continue;}
        if(v->shown && !s->adopted && now-s->shown_at>.08){rgba_close_refuse(g,s,index);continue;}
        rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        double alpha=w->cur_alpha*s->logical_alpha;
        if(!rgba_view_rect(target) || !finite(alpha) || alpha<0 || alpha>1){rgba_close_refuse(g,s,index);continue;}
        u32 was=c->in_cb;c->in_cb=1;
        u64 tx[4]={0};c->tx_ctor(tx,1);c->tx_add(tx,v->context);
        m->current=target;
        rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,target.w,target.h});
        rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,target.w,target.h});
        rgba_inplace_pixels(c,m,0);rgba_inplace_border(c,m,w);
        rect outer={target.x-s->inset,target.y-s->inset,target.w+2*s->inset,target.h+2*s->inset};
        rgba_view_bounds(c,v->root,"setBounds:",(rect){0,0,outer.w,outer.h});
        void *region=c->rgn(outer);int shaped=region?v->api.shape(v->window,region,0,0):-1;if(region)c->release(region);
        layers_commit(c,tx);
        if(shaped!=0){c->in_cb=was;rgba_close_refuse(g,s,index);continue;}
        if(shaped==0 && (v->shown || rgba_close_committed(g,s))) {
            if(!rgba_view_native_ready(v) || (v->shown && !rgba_view_native_alpha(v,v->current_alpha))) {
                c->in_cb=was;rgba_close_refuse(g,s,index);continue;
            }
            c->set_alpha(0,v->window,(float)alpha,0);
            if(!v->shown) {
                if(!rgba_view_native_ready(v) || *(float *)((char *)v->window+0x1e4)!=(float)alpha ||
                   v->api.order(0,v->wid,1,e->wid)!=0) {
                    c->in_cb=was;rgba_close_refuse(g,s,index);continue;
                }
                s->shown_at=now;b->shown++;v->shown=1;
            }
            if(rgba_view_native_alpha(v,alpha)) {
                v->current_alpha=alpha;
                c->set_alpha(0,s->clone,0,0);
                rgba_inplace_legacy(c,m,w,1);decoration_damage(c,v->window);
            }else {c->in_cb=was;rgba_close_refuse(g,s,index);continue;}
        }
        c->in_cb=was;
    }
}
_Static_assert(RGBA_CLOSE_OFFSET+sizeof(struct rgba_close)<=RGBA_INPLACE_OFFSET,"retained close control partition");
