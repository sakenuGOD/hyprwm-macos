// P8 keeps its original control and image ABI. Accepted closes own a separate
// pool and lifetime, sharing only the qualified image builder/proof/cleanup.
#define RGBA_CLOSE_OFFSET 6144
#define RGBA_CLOSE_MAGIC 0x3145534f4c434752ULL
#define RGBA_ACCEPTED_CLOSE_OFFSET 7168
#define RGBA_ACCEPTED_CLOSE_MAGIC 0x314c434143475252ULL
#define RGBA_ACCEPTED_CLOSE_N P8_N
enum { CLOSE_WARM=1,CLOSE_READY=2,CLOSE_HELD=3,CLOSE_ARMED=4,CLOSE_RUNNING=5,CLOSE_RETIRING=6 };
struct rgba_close_profile {
    u64 callback_pc,notification_pc,order_pc;
    void *key;u64 string_type;
    void (*get_property)(void *,const void *,const void **,u64);
    unsigned char (*string_bytes)(const void *,char *,long,u32);
};
struct rgba_close_peer {u32 wid,pad;u64 window,creator,birth;};
#define RGBA_CLOSE_IMAGE_FIELDS \
    struct rgba_view view; \
    struct rgba_inplace layers; \
    void *clone;u64 source; \
    u32 clone_wid,source_wid,phase,adopted; \
    double stamp,shown_at,inset,logical_alpha; \
    u32 transferred,pad; \
    rect envelope; \
    u64 canvas_bytes; \
    struct rgba_retained_frame previous_displayed; \
    struct rgba_retained_frame unpublished;

struct rgba_close_slot {RGBA_CLOSE_IMAGE_FIELDS};
struct rgba_accepted_close_slot {
    union {struct rgba_close_slot image;struct {RGBA_CLOSE_IMAGE_FIELDS};};
    u32 lifecycle,release_requested;
    u64 nonce,generation,creator,birth,space,source_root,accepted_epoch;
    struct rgba_retained_frame frame; // Aliases image/color owned by view/layers.
    rect accepted_pose,pending_pose;
    u32 pending_sequence,departure_confirmed;
    struct ch_var pos,size,alpha;
    double expires;
    u64 batch;
    double last_notice;
    u32 publication,cohort_count;
    struct rgba_close_peer cohort[CH_NW];
};
#undef RGBA_CLOSE_IMAGE_FIELDS
struct rgba_close {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    void *storage;struct rgba_close_slot *slots;
    u64 prepared,shown,adoptions,refused;
    u32 rejected_wid[P8_N];u64 rejected_source[P8_N];double rejected_stamp[P8_N];
};
struct rgba_accepted_close {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    void *storage;struct rgba_accepted_close_slot *slots;
    u64 prepared,shown,adoptions,refused,binding_sequence;
    struct rgba_close_profile profile;
    u64 epoch[2],callback_depth;
    double policy_expires;
    u32 armed,dead,publication_tail,publication_head;
};
_Static_assert(sizeof(struct rgba_close)==712 && sizeof(struct rgba_close_slot)==1376,"legacy close ABI");
_Static_assert(__builtin_offsetof(struct rgba_accepted_close_slot,lifecycle)==sizeof(struct rgba_close_slot),"accepted image prefix");
_Static_assert(RGBA_CLOSE_OFFSET+sizeof(struct rgba_close)<=RGBA_ACCEPTED_CLOSE_OFFSET,"legacy close partition");
_Static_assert(RGBA_ACCEPTED_CLOSE_OFFSET+sizeof(struct rgba_accepted_close)<=8192,"accepted close partition");
static struct rgba_close *rgba_close_control(struct rgba_capture *g) {
    struct rgba_close *b=(void *)((char *)g+RGBA_CLOSE_OFFSET);
    return b->magic==RGBA_CLOSE_MAGIC && b->size==sizeof(*b) && b->version==1 && b->capture==g?b:0;
}
static int rgba_close_empty(struct rgba_capture *g) {
    const volatile unsigned char *bytes=(const void *)((char *)g+RGBA_CLOSE_OFFSET);
    for(unsigned i=0;i<sizeof(struct rgba_close);i++)if(bytes[i])return 0;return 1;
}
static struct rgba_accepted_close *rgba_accepted_close_control(struct rgba_capture *g) {
    struct rgba_accepted_close *b=(void *)((char *)g+RGBA_ACCEPTED_CLOSE_OFFSET);
    return b->magic==RGBA_ACCEPTED_CLOSE_MAGIC && b->size==sizeof(*b) && b->version==1 && b->capture==g?b:0;
}
static int rgba_accepted_close_empty(struct rgba_capture *g) {
    const volatile unsigned char *bytes=(const void *)((char *)g+RGBA_ACCEPTED_CLOSE_OFFSET);
    for(unsigned i=0;i<sizeof(struct rgba_accepted_close);i++)if(bytes[i])return 0;return 1;
}
static void rgba_close_notice(struct rgba_capture *g,struct rgba_accepted_close_slot *s,u32 phase) {
    if(!s->nonce || !s->generation || s->generation>0xffffffffu)return;
    struct ch *ch=g->pc.engine->ch;
    post_evt(ch,EV_CLOSE,s->source_wid,ch->h.now,(u32)s->nonce,(u32)(s->nonce>>32),phase,(u32)s->generation);
    s->last_notice=ch->h.now;
}
static struct rgba_close *rgba_close_reserve(struct rgba_capture *g) {
    struct rgba_close *b=rgba_close_control(g);struct ctx *c=g->pc.engine;
    if(!b) {
        b=(void *)((char *)g+RGBA_CLOSE_OFFSET);
        // An older mapped graph still owns its storage. Only fresh empty
        // capture storage can acquire the new independent-row layout.
        if(!rgba_close_empty(g))return 0;
        for(unsigned i=0;i<sizeof(*b);i++)((volatile unsigned char *)b)[i]=0;
        b->magic=RGBA_CLOSE_MAGIC;b->size=sizeof(*b);b->version=1;b->capture=g;
    }
    if(!b->slots) {
        void *data=((void *(*)(void *,void *,u64))c->msg)(c->cls("NSMutableData"),c->sel("dataWithLength:"),P8_N*sizeof(*b->slots));
        if(!data)return 0;b->storage=g->pc.retain_obj(data);b->slots=rgba_view_get(c,data,"mutableBytes");
        if(!b->slots){g->pc.release_obj(b->storage);b->storage=0;return 0;}
    }
    return b;
}
static struct rgba_accepted_close *rgba_accepted_close_reserve(struct rgba_capture *g) {
    struct rgba_accepted_close *b=rgba_accepted_close_control(g);struct ctx *c=g->pc.engine;
    if(!b) {
        b=(void *)((char *)g+RGBA_ACCEPTED_CLOSE_OFFSET);
        // An older mapped graph still owns its storage. Only fresh empty
        // capture storage can acquire the new independent-row layout.
        if(!rgba_accepted_close_empty(g))return 0;
        for(unsigned i=0;i<sizeof(*b);i++)((volatile unsigned char *)b)[i]=0;
        b->magic=RGBA_ACCEPTED_CLOSE_MAGIC;b->size=sizeof(*b);b->version=1;b->capture=g;
    }
    if(!b->slots) {
        void *data=((void *(*)(void *,void *,u64))c->msg)(c->cls("NSMutableData"),c->sel("dataWithLength:"),P8_N*sizeof(*b->slots));
        if(!data)return 0;b->storage=g->pc.retain_obj(data);b->slots=rgba_view_get(c,data,"mutableBytes");
        if(!b->slots){g->pc.release_obj(b->storage);b->storage=0;return 0;}
    }
    return b;
}
static int rgba_close_matches(struct ctx *c,struct rgba_close_slot *s,unsigned index) {
    if(index>=P8_N)return 0;
    struct p8c *e=&P8_TAB(c)[index];
    return e->live && e->wid==s->clone_wid && e->src==s->source_wid &&
        P8_SOURCE(c)[index]==s->source && c->by_id(e->wid)==s->clone &&
        (e->pending==0 || e->pending==1) &&
        (e->t0==s->stamp || (s->phase==1 && e->pending==0));
}
static int rgba_close_confirmed(struct rgba_capture *g,struct rgba_close_slot *s,unsigned index) {
    struct ctx *c=g->pc.engine;
    if(!rgba_close_matches(c,s,index))return 0;
    struct p8c *e=&P8_TAB(c)[index];
    if(e->pending==0)return 1;
    // The baseline publishes live pending1 only after its initial orderOUT.
    // Only confirmed p8_go orders that exact private clone IN, immediately
    // before writing pending0; native display may reenter in that call.
    char *clone=s->clone;
    return e->pending==1 && clone && *(u32 *)(clone+4)==3 && !*(void **)(clone+0x30) &&
        ((*(u64 *)(clone+0x928)>>44)&1);
}
static int rgba_close_retire_image(struct rgba_capture *g,struct rgba_close_slot *s,unsigned index) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    if(v->capture && v->capture!=g)return 0;
    if(!v->capture) {
        if(v->window || v->context || v->body || v->root || v->texture)return 0;
        v->capture=g;
    }
    RGBA_CALLBACK_SCOPE(c);
    if(v->window && !rgba_view_allocation(v)){return 0;}
    if(v->window && v->api.order(0,v->wid,0,0)!=0){return 0;}
    if(rgba_close_matches(c,s,index)) {
        struct ch_win *w=slot(c->ch,s->clone_wid,0);
        if(w && !s->transferred) {
            c->set_alpha(0,s->clone,(float)w->cur_alpha,0);
            if(v->shown)rgba_inplace_legacy(c,m,w,0);
        }
    }
    if(v->context) {
        RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);
        for(unsigned i=0;i<4;i++)if(rgba_inplace_part(m,i))rgba_view_object(c,rgba_inplace_part(m,i),"setContents:",0);
        rgba_view_object(c,v->context,"setLayer:",0);RGBA_LAYER_COMMIT(tx);
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
    if(m->retiring_texture){g->pc.release_obj(m->retiring_texture);m->retiring_texture=0;}
    if(m->retiring_color){g->api.geometry.release_cf(m->retiring_color);m->retiring_color=0;}
    if(s->previous_displayed.texture){g->pc.release_obj(s->previous_displayed.texture);s->previous_displayed.texture=0;}
    if(s->previous_displayed.color){g->api.geometry.release_cf(s->previous_displayed.color);s->previous_displayed.color=0;}
    if(s->unpublished.texture){g->pc.release_obj(s->unpublished.texture);s->unpublished.texture=0;}
    if(s->unpublished.color){g->api.geometry.release_cf(s->unpublished.color);s->unpublished.color=0;}
    if(!rgba_view_retire(v)){return 0;}
    return 1;
}
static int rgba_close_retire(struct rgba_capture *g,struct rgba_close_slot *s,unsigned index) {
    if(!rgba_close_retire_image(g,s,index))return 0;
    for(unsigned i=0;i<sizeof(*s);i++)((volatile unsigned char *)s)[i]=0;return 1;
}
static int rgba_accepted_close_retire(struct rgba_capture *g,struct rgba_accepted_close_slot *s,unsigned index) {
    (void)index;s->lifecycle=CLOSE_RETIRING;rgba_draw_close_detach(g,s);
    if(!rgba_close_retire_image(g,&s->image,P8_N))return 0;
    rgba_close_notice(g,s,CLOSE_E_RETIRED);
    for(unsigned i=0;i<sizeof(*s);i++)((volatile unsigned char *)s)[i]=0;return 1;
}
static struct rgba_close_slot *rgba_close_image_at(struct rgba_close *legacy,struct rgba_accepted_close *accepted,unsigned index) {
    if(index<P8_N)return legacy && legacy->slots?&legacy->slots[index]:0;
    index-=P8_N;return accepted && accepted->slots && index<RGBA_ACCEPTED_CLOSE_N?&accepted->slots[index].image:0;
}
static int rgba_close_drop(struct rgba_capture *g) {
    struct rgba_close *b=rgba_close_control(g);struct rgba_accepted_close *a=rgba_accepted_close_control(g);
    int legacy=b!=0 || rgba_close_empty(g),accepted=a!=0 || rgba_accepted_close_empty(g);
    if(b && b->slots) {
        for(unsigned i=0;i<P8_N;i++)if((b->slots[i].clone_wid || b->slots[i].view.window) && !rgba_close_retire(g,&b->slots[i],i))legacy=0;
        if(legacy){if(b->storage)g->pc.release_obj(b->storage);b->storage=0;b->slots=0;}
    }
    if(a && a->slots) {
        for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++)if((a->slots[i].lifecycle || a->slots[i].view.window) && !rgba_accepted_close_retire(g,&a->slots[i],i))accepted=0;
        if(accepted){if(a->storage)g->pc.release_obj(a->storage);a->storage=0;a->slots=0;}
    }
    return legacy && accepted;
}
static u64 rgba_close_bytes(struct rgba_capture *g) {
    struct rgba_close *b=rgba_close_control(g);struct rgba_accepted_close *a=rgba_accepted_close_control(g);u64 bytes=0;
    if((!b && !rgba_close_empty(g)) || (!a && !rgba_accepted_close_empty(g)))return RGBA_ORDINARY_TEXTURE_BUDGET+1;
    for(unsigned i=0;i<P8_N+RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_close_slot *s=rgba_close_image_at(b,a,i);if(!s)continue;
        bytes+=s->canvas_bytes;
        if(s->previous_displayed.texture)bytes+=(u64)s->previous_displayed.pixel_width*s->previous_displayed.pixel_height*4;
        if(s->unpublished.texture)bytes+=(u64)s->unpublished.pixel_width*s->unpublished.pixel_height*4;
        if(s->view.texture)bytes+=(u64)s->layers.pixel_w*s->layers.pixel_h*4;
        if(s->layers.accepted.texture && s->layers.accepted.texture!=s->view.texture)bytes+=(u64)s->layers.accepted.pixel_width*s->layers.accepted.pixel_height*4;
        if(s->layers.retiring_texture && s->layers.retiring_texture!=s->view.texture && s->layers.retiring_texture!=s->layers.accepted.texture)
            bytes+=(u64)s->layers.retiring_pixel_w*s->layers.retiring_pixel_h*4;
    }
    return bytes;
}
// Every input is an owned image/accepted value supplied by the caller. The
// native-close caller must not silently select a producer's latest candidate.
static int rgba_close_build_image(struct rgba_capture *g,struct rgba_close_slot *s,
        const struct rgba_retained_frame *image,const struct rgba_retained_frame *fallback,
        rect target,double radius,double logical_alpha,struct ch_win *w) {
    struct ctx *c=g->pc.engine;
    if(!w || !image || !image->texture || !rgba_view_rect(target) ||
       !image->client_context || !image->client_id || !image->pixel_width || !image->pixel_height ||
       !rgba_view_rect((rect){0,0,image->width,image->height}) ||
       !finite(image->scale) || image->scale<=0 || image->scale>8 ||
       !finite(radius) || radius<0)return 0;
    struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    struct rgba_view *template=(void *)((char *)g+RGBA_VIEW_OFFSET);
    s->logical_alpha=logical_alpha;
    if(!finite(s->logical_alpha) || s->logical_alpha<0 || s->logical_alpha>1)return 0;
    v->capture=g;v->api=template->api;v->alpha=1;
    s->inset=SH_E+c->ch->deco.width;
    if(!finite(s->inset) || s->inset<0 || s->inset>512)return 0;
    v->target=(rect){target.x-s->inset,target.y-s->inset,target.w+2*s->inset,target.h+2*s->inset};
    if(rgba_view_create_image(v,image->texture,image->width,image->height,image->scale,image->color)!=0)return 0;
    m->capture=g;m->body=v->body;m->texture=v->texture;
    m->color=image->color?g->api.geometry.retain_cf(image->color):0;
    if(fallback && fallback->texture && fallback->texture!=v->texture) {
        m->accepted=*fallback;m->accepted.texture=g->pc.retain_obj(fallback->texture);
        m->accepted.color=fallback->color?g->api.geometry.retain_cf(fallback->color):0;
        if(!m->accepted.texture)return 0;
    }
    m->current=target;m->source_w=image->width;m->source_h=image->height;
    m->pixel_w=image->pixel_width;m->pixel_h=image->pixel_height;m->radius=radius;
    m->surface=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    m->root=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    for(unsigned i=0;i<3;i++)m->patch[i]=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    if(!m->root || !m->surface || !m->patch[0] || !m->patch[1] || !m->patch[2])return 0;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);
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
    RGBA_LAYER_COMMIT(tx);return ready;
}
static int rgba_close_create(struct rgba_capture *g,struct rgba_close_slot *s,struct rgba_inplace *source,unsigned index) {
    struct ctx *c=g->pc.engine;struct p8c *e=&P8_TAB(c)[index];
    struct ch_win *w=slot(c->ch,e->wid,0);char *clone=c->by_id(e->wid);
    if(!source || !w || !clone || *(u32 *)(clone+4)!=3 || *(void **)(clone+0x30))return 0;
    // Preserve the legacy P8 candidate/fallback choice. The independent native
    // path supplies its proven accepted frame explicitly to the same builder.
    struct rgba_retained_frame candidate={source->texture,source->source_w,source->source_h,
        (double)source->pixel_w/source->source_w,source->pixel_w,source->pixel_h,
        source->good_client_context,source->good_client_id,source->good_client_sequence,source->color};
    s->clone=clone;s->clone_wid=e->wid;s->source_wid=e->src;s->source=P8_SOURCE(c)[index];s->phase=e->pending;s->stamp=e->t0;
    rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
    return rgba_close_build_image(g,s,&candidate,&source->accepted,target,source->radius,source->logical_alpha,w);
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
static int rgba_draw_static_layer(char *);
struct rgba_close_lock {struct rgba_capture *capture;void *context;};
static void rgba_close_unlock(struct rgba_close_lock *s) {
    if(s->context)s->capture->api.unlock_context(s->context);
}
static int rgba_close_image_ready_pose(struct rgba_capture *g,struct rgba_close_slot *s,char *source,int fixed_pose) {
    struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;struct ctx *c=g->pc.engine;
    if(!source || *(u32 *)(source+0x180)!=10 || *(u32 *)(source+0x268)!=v->wid || !rgba_view_owned(v))return 0;
    char *cwc=*(char **)((char *)v->window+0x18);u64 index=cwc?*(u64 *)(cwc+0x588):2;
    if(index>1)return 0;
    char *native_update=*(char **)(cwc+0x260+0x190*index);
    if(!*(void **)(source+0x48) || !native_update || *(void **)(source+0x28)!=native_update ||
       *(u32 *)(*(char **)(source+0x48)+0x28)!=*(u32 *)(cwc+0x40))return 0;
    char *meta=*(char **)(source+0x48),*update=meta?*(char **)(meta+0x10):0;
    if(!meta || *(void **)meta!=v->window || *(void **)(meta+8) || !update ||
       *(void **)(source+0x28)!=update || *(void **)(source+0x30)!=update)return 0;
    void *context=rgba_view_get(c,v->context,"renderContext");u32 sequence=0;
    if(!context || !rgba_included(update,context,&sequence))return 0;
    u64 ids[5]={v->api.layer_id(m->surface),0,0,0,0};
    for(unsigned i=0;i<4;i++)ids[i+1]=v->api.layer_id(rgba_inplace_part(m,i));
    u64 root_id=v->api.layer_id(m->root),outer_id=v->api.layer_id(v->root);
    u32 model=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
    if(!model || (!s->transferred && (sequence!=model || model!=v->commit_sequence)) || g->api.lock_context(context)!=0)return 0;
    struct rgba_close_lock lock __attribute__((cleanup(rgba_close_unlock)))={g,context};
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
    // Empty native containers may be elided from Update nodes. The same
    // immutable commit and exact actual surface join prove their placement.
    if(!s->transferred) {
    char *rh=root_id?v->api.lookup_handle(context,root_id,0,0,0):0;
    char *oh=outer_id?v->api.lookup_handle(context,outer_id,0,0,0):0;
    char *root=rh && *(void **)(rh+0x18)==context?*(char **)(rh+0x10):0;
    char *outer=oh && *(void **)(oh+0x18)==context?*(char **)(oh+0x10):0;
    double root_x=fixed_pose?m->current.x-s->envelope.x:s->inset;
    double root_y=fixed_pose?s->envelope.h-(m->current.y-s->envelope.y)-m->current.h:s->inset;
    if(!root || !outer || *(u64 *)((char *)context+0x110)!=outer_id || *(void **)(root+0x98)!=rh || *(void **)(outer+0x98)!=oh ||
       !rgba_draw_static_layer(root) || !rgba_draw_static_layer(outer) ||
       !rgba_draw_static_layer(layers[0]) ||
       !handles[0] || *(void **)((char *)handles[0]+0x18)!=context ||
       *(void **)((char *)handles[0]+0x10)!=layers[0] ||
       !rgba_inplace_render_child(outer,root) || !rgba_inplace_render_child(root,layers[0]) ||
       !rgba_view_same(pose,(rect){0,0,m->current.w,m->current.h}) ||
       !rgba_view_same(*(rect *)(root+0x48),pose) ||
       *(double *)(root+0x38)!=root_x || *(double *)(root+0x40)!=root_y ||
       *(double *)(outer+0x38)!=0 || *(double *)(outer+0x40)!=0 ||
       *(double *)(layers[0]+0x38)!=0 || *(double *)(layers[0]+0x40)!=0)valid=0;
    if(fixed_pose && (!outer || !rgba_view_same(*(rect *)(outer+0x48),(rect){0,0,s->envelope.w,s->envelope.h})))valid=0;
    for(unsigned i=0;i<4;i++)if(boxes[i].w>0 && boxes[i].h>0 &&
       (!rgba_draw_static_layer(layers[i+1]) ||
        *(double *)(layers[i+1]+0x38)!=boxes[i].x || *(double *)(layers[i+1]+0x40)!=boxes[i].y))valid=0;
    }
    if(*(u32 *)((char *)context+0x40)!=model)valid=0;
    return valid;
}
static int rgba_close_image_ready(struct rgba_capture *g,struct rgba_close_slot *s,char *source) {
    return rgba_close_image_ready_pose(g,s,source,0);
}
static struct rgba_inplace *rgba_close_source(struct rgba_capture *g,struct rgba_accepted_close_slot *s) {
    struct ctx *c=g->pc.engine;char *win=c->by_id(s->source_wid);
    if(!win || (u64)win!=s->source || *(u32 *)(win+4)!=5 || *(u64 *)(win+0x30)!=s->creator ||
       !s->creator || *(u64 *)((char *)s->creator+0x268)!=s->birth ||
       rgba_carrier_space(g,win)!=s->space)return 0;
    struct rgba_inplace *all=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_inplace *m=&all[i];
        if(m->on && m->wid==s->source_wid && m->window==win && m->creator==s->creator &&
           m->pid_version==s->birth && (u64)m->root==s->source_root)return m;
    }
    return 0;
}
// The existing actual Update proof calls this after releasing Render locks.
// Retain only immutable pixels and the pose proven in that same Update; graph
// creation remains on the outside-frame MAIN route. Ordinary's fixed ABI is
// untouched, including its exact 640-byte slot partition.
static void rgba_close_accept_placement(struct rgba_capture *g,struct rgba_inplace *m,u32 sequence,rect pose) {
    struct rgba_accepted_close *b=rgba_accepted_close_control(g);
    if(!b || !b->slots || !m || !sequence || !rgba_view_rect(pose) || !m->accepted.texture ||
       m->accepted.texture!=m->texture)return;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(!s->lifecycle || s->lifecycle>=CLOSE_HELD || s->release_requested==2 || s->source_wid!=m->wid ||
           s->source!=(u64)m->window || s->creator!=m->creator || s->birth!=m->pid_version ||
           s->source_root!=(u64)m->root)continue;
        if(s->frame.texture==m->accepted.texture && s->accepted_epoch==sequence && rgba_view_same(s->accepted_pose,pose))return;
        if(s->unpublished.texture==m->accepted.texture && s->pending_sequence==sequence && rgba_view_same(s->pending_pose,pose))return;
        s->pending_sequence=0;
        if(s->unpublished.texture)g->pc.release_obj(s->unpublished.texture);
        if(s->unpublished.color)g->api.geometry.release_cf(s->unpublished.color);
        s->unpublished=m->accepted;s->unpublished.texture=0;s->unpublished.color=0;
        s->unpublished.texture=g->pc.retain_obj(m->accepted.texture);if(!s->unpublished.texture)return;
        if(m->accepted.color)s->unpublished.color=g->api.geometry.retain_cf(m->accepted.color);
        s->pending_pose=pose;s->pending_sequence=sequence;return;
    }
}
static int rgba_close_frame_current(struct rgba_capture *g,struct rgba_accepted_close_slot *s) {
    struct rgba_inplace *m=rgba_close_source(g,s);struct ctx *c=g->pc.engine;
    struct ch_win *w=m?slot(c->ch,m->wid,0):0;
    if(!m || !w || !w->geo || w->held || w->wait || w->pos.active || w->size.active || w->alpha.active ||
       w->cur_alpha!=1 || !m->presenting || m->adopted_sequence!=s->accepted_epoch || m->accepted.texture!=s->frame.texture ||
       m->accepted.client_context!=s->frame.client_context || m->accepted.client_id!=s->frame.client_id ||
       m->accepted.client_sequence!=s->frame.client_sequence ||
       !rgba_view_same(m->current,s->accepted_pose) ||
       !rgba_view_same((rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]},s->accepted_pose))return 0;
    char *win=m->window,*cwc=*(char **)(win+0x18);void *client=cwc?*(void **)(cwc+0x48):0;
    if(!cwc || (u64)client!=s->frame.client_context || *(u32 *)(cwc+0x50)!=s->frame.client_id ||
       !((*(u64 *)(win+0x928)>>44)&1) || *(int *)(win+0x20)!=0 ||
       *(float *)(win+0x1d8)!=1 || *(float *)(win+0x1dc)!=1 ||
       *(float *)(win+0x1e0)!=1 || *(float *)(win+0x1e4)!=1)return 0;
    // No Objective-C or native lookup while holding the client render lock.
    if(g->api.lock_context(client)!=0)return 0;
    u32 sequence=*(u32 *)((char *)client+0x40);g->api.unlock_context(client);
    return sequence==s->frame.client_sequence;
}
// Fixed profile and pre-created CF key are installed by the same exact-image
// native loader. The callback never creates strings, allocates a graph, locks a
// client, or contacts another process.
unsigned anim_rgba_accepted_close_size(void){return sizeof(struct rgba_accepted_close);}
unsigned anim_rgba_accepted_close_profile_offset(void){return __builtin_offsetof(struct rgba_accepted_close,profile);}
static struct rgba_capture *rgba_close_context(struct ctx *c) {
    if(!c || !c->ch || c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=sizeof(struct ch))return 0;
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    return rgba_valid(g) && g->pc.engine==c?g:0;
}
static int rgba_close_policy(struct rgba_capture *g,struct rgba_accepted_close *b) {
    struct ctx *c=g->pc.engine;struct rgba_ordinary *o=rgba_ordinary_control(g);
    return b && !b->dead && b->armed && !c->dead && !c->ch->h.stop && o && o->enabled &&
        !g->destroyed && !g->quarantined && !g->pc.dead && !g->pc.active_command &&
        !(c->ch->h.reserved[0]&(1ULL<<24)) &&
        c->ch->h.now<o->expires && finite(b->policy_expires) && c->ch->h.now<b->policy_expires;
}
static inline int rgba_close_callbacks_needed(struct ctx *c) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    return b && !b->dead && b->profile.key && b->profile.get_property && b->profile.string_bytes;
}
static void rgba_close_capability(struct ctx *c,int installed) {
    if(installed && rgba_close_callbacks_needed(c))
        c->ch->h.version|=CH_CAP_CLOSE;
    else if(c && c->ch)c->ch->h.version&=~CH_CAP_CLOSE;
}
static int rgba_close_hex(const char *text,unsigned length,u64 *value) {
    u64 n=0;for(unsigned i=0;i<length;i++) {
        unsigned char c=text[i];unsigned digit=c>='0' && c<='9'?c-'0':c>='a' && c<='f'?c-'a'+10:16;
        if(digit>15)return 0;n=(n<<4)|digit;
    }
    *value=n;return 1;
}
static char *rgba_close_order_window(struct rgba_capture *g,struct rgba_accepted_close *b,u32 *op) {
    struct pc_capture *p=&g->pc;
    if(!p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 bottom=top-size,fp=(u64)__builtin_frame_address(0);
    for(unsigned i=0;i<32;i++) {
        if((fp&15) || fp<bottom || fp>top-16)return 0;
        u64 *f=(u64 *)fp,next=f[0];
        if(pc_address((void *)f[1])==b->profile.callback_pc) {
            u64 n=next;
            if((n&15) || n<=fp || n<bottom+0x30 || n>top-16 || pc_address(*(void **)(n+8))!=b->profile.notification_pc)return 0;
            u64 post=*(u64 *)n;
            if((post&15) || post<=n || post<bottom+0x18 || post>top-16 ||
               pc_address(*(void **)(post+8))!=b->profile.order_pc || post-n!=0x30)return 0;
            *op=(u32)*(u64 *)(n-0x30);return *(char **)(post-8);
        }
        if(next<=fp)return 0;fp=next;
    }
    return 0;
}
void *anim_rgba_close_order_begin(struct ctx *c) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    if(!g || !rgba_close_policy(g,b) || c->in_cb || !pc_main(&g->pc) || b->callback_depth ||
       g->locked_client || pc_normal_frame(&g->pc) ||
       !b->profile.key || !(c->ch->h.version&CH_CAP_CLOSE))return 0;
    b->callback_depth=1;return b;
}
void anim_rgba_close_order_end(struct rgba_accepted_close *b){if(b && b->callback_depth==1)b->callback_depth=0;}
void anim_rgba_close_order_abort(struct ctx *c,struct rgba_accepted_close *b) {
    if(!b)return;b->dead=1;b->armed=0;if(c && c->ch)c->ch->h.version&=~CH_CAP_CLOSE;
}
void anim_rgba_close_failed(struct ctx *c) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    anim_rgba_close_order_abort(c,b);
}
int anim_rgba_close_order_body(struct ctx *c,struct rgba_accepted_close *b) {
    struct rgba_capture *g=rgba_close_context(c);
    if(!g || rgba_accepted_close_control(g)!=b || !rgba_close_policy(g,b) || b->callback_depth!=1 || !b->slots)return 0;
    u32 op=~0u;char *win=rgba_close_order_window(g,b,&op);
    if(op || !win || *(u32 *)(win+4)!=5 || c->by_id(*(u32 *)win)!=win)return 0;
    const void *value=0;b->profile.get_property(win,b->profile.key,&value,b->profile.string_type);
    char text[256]={0};u64 epoch[2],nonce,wid,generation;
    if(!value || !b->profile.string_bytes(value,text,sizeof(text),0x0600) || text[87] ||
       !pc_same((void *)text,(const unsigned char *)"HLC1:",5) || text[37]!=':' || text[70]!=':' ||
       !rgba_close_hex(text+5,16,&epoch[0]) || !rgba_close_hex(text+21,16,&epoch[1]) ||
       !rgba_close_hex(text+38,16,&nonce) || !rgba_close_hex(text+54,16,&wid) ||
       !rgba_close_hex(text+71,16,&generation) || epoch[0]!=b->epoch[0] || epoch[1]!=b->epoch[1] ||
       !nonce || !wid || wid>0xffffffffu || wid!=*(u32 *)win || !generation || generation>0xffffffffu)return 0;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(s->nonce!=nonce || s->generation!=generation || s->source_wid!=wid)continue;
        if(s->lifecycle!=CLOSE_READY || s->source!=(u64)win || !s->adopted || !s->view.shown ||
           s->release_requested || c->ch->h.now>=s->expires || !rgba_close_source(g,s))return 0;
        struct rgba_inplace *m=rgba_close_source(g,s);struct ch_win *w=slot(c->ch,(u32)wid,0);
        char *cwc=*(char **)(win+0x18);void *client=cwc?*(void **)(cwc+0x48):0;
        // Read-only identity/accepted-cohort checks. No ContextLock in ORDER.
        if(!m || !w || !w->geo || w->held || w->wait || w->pos.active || w->size.active || w->alpha.active ||
           w->cur_alpha!=1 || !m->presenting || m->adopted_sequence!=s->accepted_epoch ||
           m->accepted.texture!=s->frame.texture || m->accepted.client_context!=s->frame.client_context ||
           m->accepted.client_id!=s->frame.client_id || m->accepted.client_sequence!=s->frame.client_sequence ||
           !rgba_view_same(m->current,s->accepted_pose) ||
           !rgba_view_same((rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]},s->accepted_pose) ||
           (u64)client!=s->frame.client_context || !client || *(u32 *)(cwc+0x50)!=s->frame.client_id ||
           __atomic_load_n((u32 *)((char *)client+0x40),__ATOMIC_ACQUIRE)!=s->frame.client_sequence ||
           !((*(u64 *)(win+0x928)>>44)&1) || *(int *)(win+0x20)!=0 ||
           *(float *)(win+0x1d8)!=1 || *(float *)(win+0x1dc)!=1 || *(float *)(win+0x1e0)!=1 || *(float *)(win+0x1e4)!=1)return 0;
        s->lifecycle=CLOSE_HELD;s->expires=c->ch->h.now+2;
        // Suppress only this positively tagged close's legacy duplicate.
        P8_ON(c)[w-c->ch->win]=0;rgba_close_notice(g,s,CLOSE_E_HELD);return 1;
    }
    return 0;
}
static int rgba_close_source_held(struct ctx *c,void *source) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    char *win=source;if(!b || !b->slots || !win || *(u32 *)(win+4)!=5)return 0;
    u32 wid=*(u32 *)win;char *creator=*(char **)(win+0x30);void *current=c->by_id(wid);
    if(!creator || (current && current!=source))return 0;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(s->source==(u64)source && s->source_wid==wid && s->creator==(u64)creator &&
           s->birth==*(u64 *)(creator+0x268) && s->lifecycle>=CLOSE_HELD && s->lifecycle<CLOSE_RETIRING &&
           s->release_requested!=2 && c->ch->h.now<s->expires)return 1;
    }
    return 0;
}
static int rgba_close_take_prepare(struct rgba_capture *g,struct rgba_inplace *m,u64 nonce) {
    struct rgba_accepted_close *b=rgba_accepted_close_control(g);struct rgba_accepted_close_slot *match=0;
    if(!b || !b->slots || !nonce)return 0;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(!s->lifecycle || s->nonce!=nonce || s->source_wid!=m->wid)continue;
        if(match || s->lifecycle>=CLOSE_HELD || s->source!=(u64)m->window || s->creator!=m->creator ||
           s->birth!=m->pid_version || s->source_root!=(u64)m->root)return 0;
        match=s;
    }
    if(!match)return 0;match->release_requested=2;return 1;
}
static int rgba_close_fixed_pose(struct rgba_capture *g,struct rgba_accepted_close_slot *s,rect pose,double alpha) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    rect outer={pose.x-s->inset,pose.y-s->inset,pose.w+2*s->inset,pose.h+2*s->inset};
    if(!s->lifecycle || !rgba_view_rect(pose) || !rgba_view_rect(s->accepted_pose) ||
       !finite(alpha) || alpha<0 || alpha>1 || !rgba_view_contains(s->envelope,outer) ||
       !rgba_view_owned(v) || !c->srr || rgba_carrier_space(g,v->window)!=s->space ||
       !rgba_view_same(c->srr(v->window,(rect){0,0,s->envelope.w,s->envelope.h}),s->envelope) ||
       (v->shown && !rgba_view_native_alpha(v,v->current_alpha)))return 0;
    double sx=pose.w/s->accepted_pose.w,sy=pose.h/s->accepted_pose.h;
    if(!finite(sx) || !finite(sy) || sx<=0 || sy<=0 || sx>8 || sy>8)return 0;
    RGBA_CALLBACK_SCOPE(c);RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);
    m->current=pose;m->source_w=s->frame.width*sx;m->source_h=s->frame.height*sy;
    rgba_view_point(c,m->root,"setPosition:",pose.x-s->envelope.x,s->envelope.h-(pose.y-s->envelope.y)-pose.h);
    rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,pose.w,pose.h});
    rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,pose.w,pose.h});
    rgba_inplace_pixels(c,m,0);
    struct ch_win style;style.wid=s->source_wid;rgba_inplace_border(c,m,&style);
    RGBA_LAYER_COMMIT(tx);
    v->commit_sequence=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
    // Keep the native opaque set empty during prewarming and the first fade
    // sample. Source selection applies opacity exactly once through native B.
    alpha=(double)(float)alpha;if(alpha>=1)alpha=0x1.fffffep-1;
    c->set_alpha(0,v->window,(float)alpha,0);v->current_alpha=alpha;
    if(v->shown && !rgba_view_native_alpha(v,alpha))return 0;
    return 1;
}
// Request on the ordinary outside-frame MAIN route, before ordinary preflight.
// A later call builds only the actual frame+pose delivered by its Update proof.
// This cannot enable lifecycle callbacks or painting.
int anim_rgba_close_prepare_accepted(struct rgba_capture *g,u32 wid,u64 nonce) {
    if(!rgba_valid(g) || !nonce || !rgba_carrier_timer_allowed(g) || g->quarantined ||
       g->locked_client || g->pc.active_command)return 0;
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct ctx *c=g->pc.engine;
    if(!o || !o->enabled || c->dead || c->ch->h.stop || c->ch->h.now>=o->expires)return 0;
    struct rgba_inplace *m=0,*all=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++)if(all[i].on && all[i].wid==wid){if(m)return 0;m=&all[i];}
    if(!m || !rgba_inplace_source(g,m))return 0;
    struct rgba_accepted_close *b=rgba_accepted_close_reserve(g);if(!b)return 0;
    struct rgba_accepted_close_slot *s=0;unsigned index=0;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        if(b->slots[i].lifecycle && b->slots[i].source_wid==wid) {
            if(b->slots[i].nonce!=nonce || b->slots[i].lifecycle>=CLOSE_HELD)return 0;
            s=&b->slots[i];index=i;break;
        }
        if(!s && !b->slots[i].lifecycle && !b->slots[i].view.window){s=&b->slots[i];index=i;}
    }
    if(!s || b->binding_sequence>=0xffffffffu)return 0;
    if(!s->lifecycle) {
        s->lifecycle=CLOSE_WARM;s->view.capture=g;s->nonce=nonce;s->source_wid=wid;s->source=(u64)m->window;
        s->creator=m->creator;s->birth=m->pid_version;s->source_root=(u64)m->root;
        s->space=rgba_carrier_space(g,m->window);s->generation=++b->binding_sequence;s->expires=c->ch->h.now+0.6;
        if(!s->space)goto refused;
        return 1;
    }
    // Subscribe WARM before ordinary preflight can prove its placement, even
    // when another source is encoding. Image/graph work still waits for GPU.
    if(g->pc.gpu_pending)return 1;
    if(s->view.window) {
        if(rgba_close_frame_current(g,s)) {
            if(s->lifecycle==CLOSE_READY)s->expires=c->ch->h.now+1.5;
            return 1;
        }
        rgba_accepted_close_retire(g,s,index);return 0;
    }
    if(!s->pending_sequence || !s->unpublished.texture || !rgba_view_rect(s->pending_pose))return 1;
    s->accepted_epoch=s->pending_sequence;s->accepted_pose=s->pending_pose;s->frame=s->unpublished;
    struct ch_win *w=slot(c->ch,wid,0);
    if(!s->space || !rgba_close_frame_current(g,s) ||
       !rgba_close_build_image(g,&s->image,&s->unpublished,0,s->accepted_pose,m->radius,m->logical_alpha,w))goto refused;
    s->frame.texture=s->view.texture;s->frame.color=s->layers.color;
    void *candidate=s->unpublished.texture,*candidate_color=s->unpublished.color;
    s->unpublished=(struct rgba_retained_frame){0};s->pending_sequence=0;
    if(candidate)g->pc.release_obj(candidate);if(candidate_color)g->api.geometry.release_cf(candidate_color);
    rect envelope=s->view.target;long left=(long)envelope.x,top=(long)envelope.y;
    double right=envelope.x+envelope.w,bottom=envelope.y+envelope.h;
    long ir=(long)right,ib=(long)bottom;
    if(left>envelope.x)left--;if(top>envelope.y)top--;if(ir<right)ir++;if(ib<bottom)ib++;
    s->envelope=(rect){left,top,ir-left,ib-top};
    s->canvas_bytes=(u64)(s->envelope.w*s->frame.scale+1)*(u64)(s->envelope.h*s->frame.scale+1)*4;
    if(!rgba_view_rect(s->envelope) || !rgba_ordinary_capture_budget(g))goto refused;
    {
    RGBA_CALLBACK_SCOPE(c);
    void *region=c->rgn(s->envelope);if(!region)goto refused;
    int result=s->view.api.shape(s->view.window,region,0,0);c->release(region);if(result)goto refused;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,s->view.context);
    rgba_view_bounds(c,s->view.root,"setBounds:",(rect){0,0,s->envelope.w,s->envelope.h});
    RGBA_LAYER_COMMIT(tx);s->view.target=s->view.current=s->envelope;
    if(!rgba_carrier_space_sync(g,&s->view,s->space) ||
       !rgba_close_fixed_pose(g,s,s->accepted_pose,s->logical_alpha) || !rgba_close_committed(g,&s->image))goto refused;
    if(s->view.api.order(0,s->view.wid,-1,wid)!=0)goto refused;
    s->view.shown=1;
    if(!rgba_view_native_alpha(&s->view,s->view.current_alpha) ||
       !rgba_carrier_ordered_windows(g,m->window,s->view.window))goto refused;
    b->prepared++;return 1;
    }
refused:
    b->refused++;rgba_accepted_close_retire(g,s,index);return 0;
}
static int rgba_close_departure(struct rgba_capture *g,struct rgba_accepted_close_slot *s) {
    if(s->lifecycle<CLOSE_HELD || s->lifecycle==CLOSE_RETIRING)return 0;
    if(s->departure_confirmed)return 1;
    char *win=g->pc.engine->by_id(s->source_wid);
    // Accepted close already fixed A's identity. A replacement with the same
    // public number is not A, and is never mutated by this independent row.
    if(!win || (u64)win!=s->source || !((*(u64 *)(win+0x928)>>44)&1))s->departure_confirmed=1;
    return s->departure_confirmed!=0;
}
static void rgba_close_accepted_gate(struct rgba_capture *g,struct rgba_accepted_close *b,void **nodes,unsigned count,const float *original) {
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];struct rgba_view *v=&s->view;
        if(s->lifecycle<CLOSE_HELD || s->lifecycle==CLOSE_RETIRING || s->release_requested==2 || !s->adopted || !v->shown || !rgba_close_departure(g,s) ||
           !rgba_view_owned(v) || rgba_carrier_space(g,v->window)!=s->space ||
           !rgba_view_native_alpha(v,v->current_alpha) || !g->pc.engine->srr ||
           !rgba_view_same(g->pc.engine->srr(v->window,(rect){0,0,s->envelope.w,s->envelope.h}),s->envelope))continue;
        void *event=*(void **)((char *)v->window+0x100);
        if(!event || *(void **)((char *)v->window+0x108) || !g->api.geometry.region_empty(event))continue;
        char *image=0;unsigned images=0,position=0;
        for(unsigned j=0;j<count;j++) {
            char *at=nodes[j],*meta=*(char **)(at+0x48);
            if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==v->wid &&
               meta && *(void **)meta==v->window && !*(void **)(meta+8)){image=at;position=j;images++;}
        }
        if(images!=1 || !finite(original[position]) || original[position]<=0 || original[position]>1)continue;
        void *opaque=*(void **)(image+0x1a8);
        int empty=opaque?(g->api.geometry.region_empty(opaque)&1):
            (*(int *)(image+0x174)<*(int *)(image+0x170) || *(int *)(image+0x17c)<*(int *)(image+0x178));
        if(!empty || !rgba_close_image_ready_pose(g,&s->image,image,1))continue;
        // The complete OWN graph passed the same texture/topology proof as
        // legacy close, without transferred/P8 exemptions. Native B owns fade.
        *(float *)(image+0x188)=original[position];
    }
}
// Allocation-free default exclusion covers both pools independently.
static void rgba_close_block_tree(struct rgba_capture *g,char *head) {
    struct rgba_close *b=rgba_close_control(g);struct rgba_accepted_close *a=rgba_accepted_close_control(g);
    for(char *at=head;at;at=*(char **)at) {
        if(*(u32 *)(at+0x180)==10) {
            char *meta=*(char **)(at+0x48);
            if(meta)for(unsigned i=0;i<P8_N+RGBA_ACCEPTED_CLOSE_N;i++) {
                struct rgba_close_slot *s=rgba_close_image_at(b,a,i);
                if(s && s->view.window && !s->transferred && *(u32 *)(at+0x268)==s->view.wid && *(void **)meta==s->view.window)
                    *(float *)(at+0x188)=0;
            }
        }
        if(*(char **)(at+0x10))rgba_close_block_tree(g,*(char **)(at+0x10));
    }
}
void anim_rgba_close_gate(struct rgba_capture *g,void **nodes,unsigned count,int promote) {
    struct rgba_close *b=rgba_close_control(g);struct rgba_accepted_close *a=rgba_accepted_close_control(g);if(count>256)return;
    float original[256];
    for(unsigned j=0;j<count;j++)original[j]=*(float *)((char *)nodes[j]+0x188);
    // Default every OWN B to no paint before any potentially throwing proof.
    // A proof exception leaves all P8 Sources untouched in this scene.
    for(unsigned i=0;i<P8_N+RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_close_slot *s=rgba_close_image_at(b,a,i);if(!s)continue;struct rgba_view *v=&s->view;
        if(!v->window || s->transferred)continue;
        for(unsigned j=0;j<count;j++) {
            char *at=nodes[j],*meta=*(char **)(at+0x48);
            if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==v->wid &&
               meta && *(void **)meta==v->window)*(float *)(at+0x188)=0;
        }
    }
    if(!promote || g->locked_client)return;
    if(a && a->slots)rgba_close_accepted_gate(g,a,nodes,count,original);
    if(!b || !b->slots)return;
    for(unsigned i=0;i<P8_N;i++) {
        struct rgba_close_slot *s=&b->slots[i];struct rgba_view *v=&s->view;
        int native_close=s->phase==1 || s->phase==2;
        if(!s->clone_wid || (!native_close && !v->shown) || s->transferred)continue;
        char *image=0;unsigned images=0,fallbacks=0,ambiguous=0,image_index=0;
        for(unsigned j=0;j<count;j++) {
            char *at=nodes[j];u32 wid=*(u32 *)(at+0x268),type=*(u32 *)(at+0x180);
            if(wid==v->wid && type==10) {
                char *meta=*(char **)(at+0x48);
                if(meta && *(void **)meta==v->window && !*(void **)(meta+8)) {
                    image=at;image_index=j;images++;
                }
            }
            if(wid==s->clone_wid) {
                char *meta=*(char **)(at+0x48);
                if(type==30 || (meta && (type!=10 || *(void **)meta!=s->clone || *(void **)(meta+8))))ambiguous++;
                else {
                    // Check the opaque snapshot that built this Source tree,
                    // rather than a window alpha that may have changed later.
                    void *opaque=*(void **)(at+0x1a8);
                    int empty=opaque?(g->api.geometry.region_empty(opaque)&1):
                        (*(int *)(at+0x174)<*(int *)(at+0x170) ||
                         *(int *)(at+0x17c)<*(int *)(at+0x178));
                    if(empty)fallbacks++;else ambiguous++;
                }
            }
        }
        // B starts with alpha<1, hence cannot remove P8 in the generator's
        // earlier opaque pass. Missing/ambiguous fallback is never a handoff.
        if(!fallbacks || ambiguous || !rgba_close_confirmed(g,s,i) ||
           !s->clone || *(u32 *)((char *)s->clone+4)!=3 || *(void **)((char *)s->clone+0x30))continue;
        float fallback_alpha=*(float *)((char *)s->clone+0x1d8);
        if(!finite(fallback_alpha) || fallback_alpha<0 || fallback_alpha>=1)continue;
        if(native_close) {
            // The application already removed A before confirming release.
            // Preserve that native close instead of resurrecting a late image.
            // Every excluded Source has an empty opaque snapshot, so it has
            // not removed the surviving windows from this scene.
            for(unsigned j=0;j<count;j++)if(*(u32 *)((char *)nodes[j]+0x268)==s->clone_wid)
                *(float *)((char *)nodes[j]+0x188)=0;
            continue;
        }
        if(images!=1 || !rgba_view_native_alpha(v,v->current_alpha) || !rgba_close_image_ready(g,s,image))continue;
        float alpha=(float)v->current_alpha;
        if(!finite(alpha) || alpha<0 || alpha>=1)continue;
        if(!finite(original[image_index]) || original[image_index]<=0 || original[image_index]>1)continue;
        for(unsigned j=0;j<count;j++)if(*(u32 *)((char *)nodes[j]+0x268)==s->clone_wid)
            *(float *)((char *)nodes[j]+0x188)=0;
        // Native ServerRoot already carries window alpha. Preserve Source's
        // original multiplier instead of applying the fade a second time.
        *(float *)(image+0x188)=original[image_index];
    }
}
static void rgba_close_observe(struct rgba_capture *g,void *prepared) {
    struct rgba_accepted_close *a=rgba_accepted_close_control(g);
    if(a && a->slots)for(unsigned index=0;index<RGBA_ACCEPTED_CLOSE_N;index++) {
        struct rgba_accepted_close_slot *s=&a->slots[index];struct rgba_view *v=&s->view;
            if(s->lifecycle!=CLOSE_WARM || s->release_requested==2 || !v->shown || !rgba_view_owned(v) || !rgba_close_frame_current(g,s))continue;
            char *source=0;unsigned count=0;
            for(char *at=prepared;at && count++<256;at=*(char **)(at+8))
                if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==v->wid) {if(source){source=0;break;}source=at;}
            if(source && count<256 && rgba_close_image_ready_pose(g,&s->image,source,1)) {
                s->adopted=1;s->lifecycle=CLOSE_READY;s->expires=g->pc.engine->ch->h.now+1.5;a->adoptions++;
                rgba_close_notice(g,s,CLOSE_E_READY);
            }
    }
    struct rgba_close *b=rgba_close_control(g);if(!b || !b->slots)return;
    for(unsigned index=0;index<P8_N;index++) {
        struct rgba_close_slot *s=&b->slots[index];struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
        if(!s->clone_wid || !v->shown || s->adopted || !rgba_close_confirmed(g,s,index) || !rgba_view_owned(v))continue;
        char *source=0;unsigned count=0;
        for(char *at=prepared;at && count++<256;at=*(char **)(at+8))if(*(u32 *)(at+0x180)==10 && *(u32 *)(at+0x268)==v->wid) {
            if(source){source=0;break;}source=at;
        }
        if(!source || count>=256 || !rgba_close_image_ready(g,s,source))continue;
        s->adopted=1;b->adoptions++;
        if(m->accepted.texture){g->pc.release_obj(m->accepted.texture);m->accepted.texture=0;}
        if(m->accepted.color){g->api.geometry.release_cf(m->accepted.color);m->accepted.color=0;}
        if(s->previous_displayed.texture){g->pc.release_obj(s->previous_displayed.texture);s->previous_displayed.texture=0;}
        if(s->previous_displayed.color){g->api.geometry.release_cf(s->previous_displayed.color);s->previous_displayed.color=0;}
    }
}
static void rgba_close_refuse(struct rgba_capture *g,struct rgba_close_slot *s,unsigned index) {
    struct ctx *c=g->pc.engine;struct rgba_close *b=rgba_close_control(g);struct p8c *e=&P8_TAB(c)[index];
    b->refused++;b->rejected_wid[index]=e->wid;b->rejected_source[index]=P8_SOURCE(c)[index];b->rejected_stamp[index]=e->t0;
    rgba_close_retire(g,s,index);
}
static int rgba_close_transferred_pose(struct rgba_capture *g,struct rgba_close_slot *s,struct ch_win *w) {
    struct ctx *c=g->pc.engine;struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
    rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};double alpha=w->cur_alpha*s->logical_alpha;
    rect outer={target.x-s->inset,target.y-s->inset,target.w+2*s->inset,target.h+2*s->inset};
    if(!rgba_view_rect(target) || !finite(alpha) || alpha<0 || alpha>1 ||
       !rgba_view_contains(s->envelope,outer) || !rgba_view_owned(v) || !rgba_view_native_alpha(v,1))return 0;
    RGBA_CALLBACK_SCOPE(c);RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);
    m->current=target;
    rgba_view_point(c,m->root,"setPosition:",target.x-s->envelope.x,s->envelope.h-(target.y-s->envelope.y)-target.h);
    rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,target.w,target.h});
    rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,target.w,target.h});
    rgba_view_point(c,m->surface,"setPosition:",0,0);
    rgba_inplace_pixels(c,m,0);rgba_inplace_border(c,m,w);
    ((msgf_t)c->msg)(m->root,c->s_opacity,(float)alpha);RGBA_LAYER_COMMIT(tx);
    decoration_damage(c,v->window);return 1;
}
// The nonce-bound batch consumer may call this only after the surviving GEOM
// participants have acquired their actual common t0 and no configure holds.
static int rgba_close_start_accepted(struct rgba_capture *g,struct rgba_accepted_close_slot *s,double t0) {
    if(s->lifecycle!=CLOSE_ARMED || !s->batch || s->release_requested!=1 || !rgba_close_departure(g,s) ||
       !finite(s->expires) || s->expires<=0 || g->pc.engine->ch->h.now>=s->expires ||
       !finite(t0) || t0<0 || !rgba_view_rect(s->accepted_pose))return 0;
    struct ctx *c=g->pc.engine;struct ch *ch=c->ch;
    double scale=hd(ch,3),geometry=hd(ch,1),fade=hd(ch,2);
    if(!finite(scale) || !finite(geometry) || !finite(fade) || geometry<0 || fade<0 || geometry>60 || fade>60)return 0;
    if(scale<0)scale=0;else if(scale>1)scale=1;
    rect from=s->accepted_pose;double tw=from.w*scale,th=from.h*scale;
    if(tw<5)tw=from.w<5?from.w:5;if(th<5)th=from.h<5?from.h:5;
    double pos[2]={from.x,from.y},size[2]={from.w,from.h},alpha[1]={1};
    warp(&s->pos,2,pos);warp(&s->size,2,size);warp(&s->alpha,1,alpha);
    pos[0]+=(from.w-tw)/2;pos[1]+=(from.h-th)/2;size[0]=tw;size[1]=th;alpha[0]=0;
    u32 cs=(ch->h.reserved[0]>>8)&0xff,ca=(ch->h.reserved[0]>>16)&0xff;
    retarget(c,&s->pos,2,pos,cs,geometry,t0);retarget(c,&s->size,2,size,cs,geometry,t0);
    retarget(c,&s->alpha,1,alpha,ca,fade,t0);
    double duration=geometry>fade?geometry:fade;if(duration<2)duration=2;
    s->expires=t0+duration+1;s->lifecycle=CLOSE_RUNNING;return 1;
}
static int rgba_close_u32(double value,u32 *result) {
    if(!__builtin_isfinite(value) || value<0 || value>0xffffffffu || (double)(u32)value!=value)return 0;
    *result=(u32)value;return 1;
}
static void rgba_close_batch_begin(struct ctx *c,u32 tail,u32 head) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    if(!b)return;b->publication_tail=tail;b->publication_head=head;
    if(!b->slots || head-tail>CH_NCMD)return;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(s->lifecycle!=CLOSE_ARMED || s->publication==head)continue;
        for(u32 at=tail;at!=head;at++) {
            const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
            if(k->op!=OP_GEOM && k->op!=OP_WARP && k->op!=OP_FORGET && k->op!=OP_SPACE && k->op!=OP_CFG && k->op!=OP_ALPHA)continue;
            for(unsigned peer=0;peer<s->cohort_count;peer++)if(s->cohort[peer].wid==k->wid)s->release_requested=2;
        }
    }
}
static int rgba_close_join(struct rgba_capture *g,struct rgba_accepted_close *b,struct rgba_accepted_close_slot *s,u64 batch,u32 expected) {
    struct ctx *c=g->pc.engine;
    if(expected>CH_NW || b->publication_head-b->publication_tail>CH_NCMD)return 0;
    s->cohort_count=0;
    for(u32 at=b->publication_tail;at!=b->publication_head;at++) {
        const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
        if(k->op!=OP_GEOM || ((u64)k->pad0|((u64)k->pad1<<32))!=batch)continue;
        if(!(k->flags&F_HOLD) || k->wid==s->source_wid || s->cohort_count>=expected ||
           !rgba_view_rect((rect){k->x,k->y,k->w,k->h}))return 0;
        for(unsigned j=0;j<s->cohort_count;j++)if(s->cohort[j].wid==k->wid)return 0;
        struct ch_win *w=slot(c->ch,k->wid,0);char *win=c->by_id(k->wid),*creator=win?*(char **)(win+0x30):0;
        if(!w || !w->used || !w->geo || !win || !creator || *(u32 *)(win+4)!=5 ||
           *(int *)(win+0x20)!=0 || !((*(u64 *)(win+0x928)>>44)&1) || rgba_carrier_space(g,win)!=s->space)return 0;
        s->cohort[s->cohort_count++]=(struct rgba_close_peer){k->wid,0,(u64)win,(u64)creator,*(u64 *)(creator+0x268)};
    }
    if(s->cohort_count!=expected)return 0;
    // Multiple daemon commits may be consumed in one native tick. A later
    // untagged retarget in that same captured range must not inherit this join.
    for(u32 at=b->publication_tail;at!=b->publication_head;at++) {
        const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
        if(k->op!=OP_GEOM && k->op!=OP_WARP && k->op!=OP_FORGET && k->op!=OP_SPACE && k->op!=OP_CFG)continue;
        for(unsigned j=0;j<s->cohort_count;j++)if(s->cohort[j].wid==k->wid &&
            (k->op!=OP_GEOM || ((u64)k->pad0|((u64)k->pad1<<32))!=batch))return 0;
    }
    s->publication=b->publication_head;return 1;
}
int anim_rgba_close_command(struct ctx *c,const struct ch_cmd *k) {
    if(!k || k->op!=OP_EDGE || k->flags!=CH_CLOSE)return 0;
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    if(!g || !b || b->dead || !pc_main(&g->pc) || !rgba_carrier_timer_allowed(g) ||
       !(c->ch->h.version&CH_CAP_CLOSE))return 1;
    if(k->cpos==CLOSE_ARM) {
        u32 part[4];
        if(k->wid || !rgba_close_u32(k->x,&part[0]) || !rgba_close_u32(k->y,&part[1]) ||
           !rgba_close_u32(k->w,&part[2]) || !rgba_close_u32(k->h,&part[3]) ||
           !finite(k->dpos) || k->dpos<0.1 || k->dpos>5)return 1;
        u64 epoch[2]={(u64)part[0]|((u64)part[1]<<32),(u64)part[2]|((u64)part[3]<<32)};
        if(!epoch[0] || !epoch[1])return 1;
        if(b->epoch[0]!=epoch[0] || b->epoch[1]!=epoch[1]) {
            if(b->callback_depth)return 1;
            if(b->slots)for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++)
                if(b->slots[i].lifecycle || b->slots[i].view.window || b->slots[i].clone_wid)return 1;
            b->epoch[0]=epoch[0];b->epoch[1]=epoch[1];
        }
        b->armed=1;b->policy_expires=c->ch->h.now+k->dpos;return 1;
    }
    if(k->cpos==CLOSE_DISARM) {
        b->armed=0;
        if(b->slots)for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++)if(b->slots[i].lifecycle) {
            struct rgba_accepted_close_slot *s=&b->slots[i];s->release_requested=2;
            rgba_draw_close_lease(g,s->source_wid,s->nonce,1);
        }
        return 1;
    }
    u64 nonce=(u64)k->pad0|((u64)k->pad1<<32);
    if(!k->wid || !nonce)return 1;
    if(k->cpos==CLOSE_PREARM) {
        if(!rgba_close_policy(g,b))return 1;
        // A heartbeat may have been queued immediately before AppKit accepted
        // the close. Never report a later REFUSED for an already-held frame.
        if(b->slots)for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
            struct rgba_accepted_close_slot *s=&b->slots[i];
            if(s->source_wid==k->wid && s->nonce==nonce && s->lifecycle>=CLOSE_HELD) {
                if(s->lifecycle==CLOSE_HELD)rgba_close_notice(g,s,CLOSE_E_HELD);
                return 1;
            }
        }
        rgba_draw_close_lease(g,k->wid,nonce,0);
        if(!anim_rgba_close_prepare_accepted(g,k->wid,nonce)) {
            post_evt(c->ch,EV_CLOSE,k->wid,c->ch->h.now,k->pad0,k->pad1,CLOSE_E_REFUSED,k->csize);return 1;
        }
        if(g->pc.gpu_pending)return 1;
        if(b->slots)for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
            struct rgba_accepted_close_slot *s=&b->slots[i];
            if(s->source_wid==k->wid && s->nonce==nonce && s->lifecycle==CLOSE_READY && s->release_requested!=2)rgba_close_notice(g,s,CLOSE_E_READY);
        }
        return 1;
    }
    if(!b->slots) {
        if(k->cpos==CLOSE_CANCEL)post_evt(c->ch,EV_CLOSE,k->wid,c->ch->h.now,k->pad0,k->pad1,CLOSE_E_RETIRED,k->csize);
        return 1;
    }
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(!s->lifecycle || s->source_wid!=k->wid || s->nonce!=nonce)continue;
        if(s->generation!=k->csize && !(k->cpos==CLOSE_CANCEL && !k->csize && s->lifecycle<CLOSE_HELD)) {
            if(k->cpos==CLOSE_CANCEL && !k->csize && s->lifecycle==CLOSE_HELD)rgba_close_notice(g,s,CLOSE_E_HELD);
            else if(k->cpos==CLOSE_CANCEL)post_evt(c->ch,EV_CLOSE,k->wid,c->ch->h.now,k->pad0,k->pad1,CLOSE_E_RETIRED,k->csize);
            return 1;
        }
        if(k->cpos==CLOSE_CANCEL) {
            s->release_requested=2;rgba_draw_close_lease(g,s->source_wid,s->nonce,1);return 1;
        }
        if(k->cpos==CLOSE_RELEASE) {
            u32 low,high,count;
            if(!rgba_close_policy(g,b) || !rgba_close_u32(k->x,&low) || !rgba_close_u32(k->y,&high) ||
               !rgba_close_u32(k->w,&count))return 1;
            u64 batch=(u64)low|((u64)high<<32);if(!batch)return 1;
            if(s->release_requested || s->lifecycle!=CLOSE_HELD)return 1;
            if(!finite(s->expires) || s->expires<=0 || c->ch->h.now>=s->expires){s->release_requested=2;return 1;}
            if(!rgba_close_join(g,b,s,batch,count)){s->release_requested=2;return 1;}
            s->batch=batch;s->release_requested=1;s->lifecycle=CLOSE_ARMED;s->expires=c->ch->h.now+2;return 1;
        }
        return 1;
    }
    if(k->cpos==CLOSE_CANCEL)post_evt(c->ch,EV_CLOSE,k->wid,c->ch->h.now,k->pad0,k->pad1,CLOSE_E_RETIRED,k->csize);
    return 1;
}
void anim_rgba_close_seed_commands(struct ctx *c) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    if(!b || b->dead || !pc_main(&g->pc) || !rgba_carrier_timer_allowed(g))return;
    u32 head=__atomic_load_n(&c->ch->h.cmd_head,__ATOMIC_ACQUIRE),tail=c->ch->h.cmd_tail;
    if(head-tail>CH_NCMD)return;
    for(u32 at=tail;at!=head;at++) {
        const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
        if(k->op!=OP_EDGE || k->flags!=CH_CLOSE)continue;
        if(k->cpos==CLOSE_ARM){anim_rgba_close_command(c,k);continue;}
        if(k->cpos!=CLOSE_PREARM || !rgba_close_policy(g,b))continue;
        int found=0;
        if(b->slots)for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++)
            if(b->slots[i].lifecycle && b->slots[i].source_wid==k->wid){found=1;break;}
        // Seed only a new WARM row before ordinary preflight can synchronously
        // reenter Update. Existing rows and all full commands are consumed once
        // by apply_cmd using its own captured publication head.
        if(!found)anim_rgba_close_prepare_accepted(g,k->wid,(u64)k->pad0|((u64)k->pad1<<32));
    }
}
static void rgba_close_batch_start(struct ctx *c,double t0) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;
    if(!b || !b->slots || !rgba_close_policy(g,b) || !pc_main(&g->pc) ||
       c->in_cb || c->ch->h.holding || !rgba_carrier_timer_allowed(g))return;
    for(unsigned i=0;i<CH_NW;i++)if(c->ch->win[i].used && c->ch->win[i].held)return;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++)if(b->slots[i].lifecycle==CLOSE_ARMED) {
        struct rgba_accepted_close_slot *s=&b->slots[i];int valid=s->release_requested==1 && finite(s->expires) && s->expires>0 && c->ch->h.now<s->expires;
        for(unsigned j=0;valid && j<s->cohort_count;j++) {
            struct rgba_close_peer *peer=&s->cohort[j];struct ch_win *w=slot(c->ch,peer->wid,0);char *win=c->by_id(peer->wid);
            valid=w && w->used && w->geo && !w->held && !w->wait && win && (u64)win==peer->window &&
                *(u64 *)(win+0x30)==peer->creator && peer->creator && *(u64 *)((char *)peer->creator+0x268)==peer->birth &&
                rgba_carrier_space(g,win)==s->space &&
                w->pos.t0==t0 && w->size.t0==t0 && w->alpha.t0==t0;
        }
        if(valid)rgba_close_start_accepted(g,s,t0);else s->release_requested=2;
    }
}
static unsigned rgba_close_active(struct ctx *c) {
    struct rgba_capture *g=rgba_close_context(c);struct rgba_accepted_close *b=g?rgba_accepted_close_control(g):0;unsigned count=0;
    if(!b || !b->slots)return 0;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];
        if(s->lifecycle>=CLOSE_HELD && s->lifecycle<=CLOSE_RUNNING && s->release_requested!=2 &&
           s->view.shown && s->adopted && c->ch->h.now<s->expires)count++;
    }
    return count;
}
static void rgba_close_tick_accepted(struct rgba_capture *g,struct rgba_accepted_close *b,double now) {
    if(!b || !b->slots || !rgba_carrier_timer_allowed(g))return;
    struct ctx *c=g->pc.engine;double sample=c->ch->h.te>0?c->ch->h.te:now;
    for(unsigned i=0;i<RGBA_ACCEPTED_CLOSE_N;i++) {
        struct rgba_accepted_close_slot *s=&b->slots[i];if(!s->lifecycle)continue;
        if(s->lifecycle==CLOSE_RETIRING){rgba_accepted_close_retire(g,s,i);continue;}
        if(!rgba_close_policy(g,b))s->release_requested=2;
        if(s->lifecycle<CLOSE_HELD) {
            if(!rgba_close_source(g,s) || !finite(s->expires) || s->expires<=0 || now>=s->expires ||
               s->release_requested==2 || (s->view.window && !rgba_close_frame_current(g,s)))rgba_accepted_close_retire(g,s,i);
            continue;
        }
        if(!finite(s->expires) || s->expires<=0 || now>=s->expires || s->release_requested==2) {
            rgba_accepted_close_retire(g,s,i);continue;
        }
        if(s->lifecycle==CLOSE_HELD && now-s->last_notice>=0.1)rgba_close_notice(g,s,CLOSE_E_HELD);
        if(s->lifecycle!=CLOSE_RUNNING)continue;
        step(c,&s->pos,2,sample);step(c,&s->size,2,sample);step(c,&s->alpha,1,sample);
        if(!s->pos.active && !s->size.active && !s->alpha.active) {rgba_accepted_close_retire(g,s,i);continue;}
        rect pose={s->pos.v[0],s->pos.v[1],s->size.v[0],s->size.v[1]};
        double alpha=s->alpha.v[0]*s->logical_alpha;if(alpha<0)alpha=0;else if(alpha>1)alpha=1;
        if(!rgba_close_fixed_pose(g,s,pose,alpha)){rgba_accepted_close_retire(g,s,i);continue;}
        decoration_damage(c,s->view.window);
    }
}
static void rgba_close_tick(struct rgba_capture *g,double now) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o)return;
    if(!o->enabled){rgba_close_drop(g);return;}
    struct ctx *c=g->pc.engine;struct rgba_close *b=rgba_close_reserve(g);if(!b)return;
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
            if(!source && e->pending!=1)continue;
            s=&b->slots[index];
            if(e->pending==1) {
                char *clone=c->by_id(e->wid);
                if(!clone || *(u32 *)(clone+4)!=3 || *(void **)(clone+0x30) || !P8_SOURCE(c)[index])continue;
                s->view.capture=g;s->clone=clone;s->clone_wid=e->wid;s->source_wid=e->src;
                s->source=P8_SOURCE(c)[index];s->phase=1;s->stamp=e->t0;
            }else if(!rgba_close_create(g,s,source,index)){rgba_close_refuse(g,s,index);continue;}
            b->prepared++;
        }
        int warming=e->pending==1;
        if(!warming) {
            if(s->phase==1 && s->view.shown)s->shown_at=now;
            if(s->phase==1)s->phase=2;
            s->stamp=e->t0;
        }
        if(!s->transferred && (s->phase==1 || s->phase==2)) {
            // No extra window, CA context or texture is needed for native
            // close. Keep its private fallback non-opaque until selection.
            if(warming && *(float *)((char *)s->clone+0x1e4)==1) {
                RGBA_CALLBACK_SCOPE(c);
                c->set_alpha(0,s->clone,0x1.fffffep-1f,0);
            }
            continue;
        }
        struct ch_win *w=slot(c->ch,e->wid,0);struct rgba_view *v=&s->view;struct rgba_inplace *m=&s->layers;
        if(!w || !rgba_view_owned(v)){rgba_close_refuse(g,s,index);continue;}
        if(s->transferred) {
            if(!rgba_close_transferred_pose(g,s,w))rgba_close_refuse(g,s,index);
            continue;
        }
        if(!warming && v->shown && !s->adopted && now-s->shown_at>.08){rgba_close_refuse(g,s,index);continue;}
        rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        double alpha=w->cur_alpha*s->logical_alpha;
        if(!rgba_view_rect(target) || !finite(alpha) || alpha<0 || alpha>1){rgba_close_refuse(g,s,index);continue;}
        // One ULP below native float1 keeps the generator's opaque set empty
        // while a pending close warms its real Update without painting. A/P8
        // retain their exact native alpha; the selected B applies fade once.
        alpha=(double)(float)alpha;if(alpha>=1)alpha=0x1.fffffep-1;
        RGBA_CALLBACK_SCOPE(c);
        // Keep both Sources in the first confirmed scene. Native orderIN
        // applies this requested alpha before updating the ordered-in flag,
        // invalidating the clone's opaque cache before any display reentry.
        // Logical P8 alpha and captured pixels retain their baseline values.
        if(warming && *(float *)((char *)s->clone+0x1e4)==1)
            c->set_alpha(0,s->clone,0x1.fffffep-1f,0);
        RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,v->context);
        m->current=target;
        rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,target.w,target.h});
        rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,target.w,target.h});
        rgba_inplace_pixels(c,m,0);rgba_inplace_border(c,m,w);
        rect outer={target.x-s->inset,target.y-s->inset,target.w+2*s->inset,target.h+2*s->inset};
        rgba_view_bounds(c,v->root,"setBounds:",(rect){0,0,outer.w,outer.h});
        void *region=c->rgn(outer);int shaped=region?v->api.shape(v->window,region,0,0):-1;if(region)c->release(region);
        RGBA_LAYER_COMMIT(tx);
        v->commit_sequence=((u32 (*)(void *,void *))c->msg)(v->context,c->sel("commitId"));
        if(shaped!=0){rgba_close_refuse(g,s,index);continue;}
        if(shaped==0 && (v->shown || rgba_close_committed(g,s))) {
            if(!rgba_view_native_ready(v) || (v->shown && !rgba_view_native_alpha(v,v->current_alpha))) {
                rgba_close_refuse(g,s,index);continue;
            }
            c->set_alpha(0,v->window,(float)alpha,0);
            // Ordered-out windows update requested alpha only; native orderIN
            // applies it to current alpha. Keep the native lifecycle contract.
            if(v->shown?!rgba_view_native_alpha(v,alpha):
               (!rgba_view_native_ready(v) || *(float *)((char *)v->window+0x1e4)!=(float)alpha)) {
                rgba_close_refuse(g,s,index);continue;
            }
            // A native order may reenter display. Publish the verified alpha
            // before that call; all allocated unshown B sources default to0.
            v->current_alpha=alpha;
            if(!v->shown) {
                if(v->api.order(0,v->wid,1,0)!=0) {
                    rgba_close_refuse(g,s,index);continue;
                }
                s->shown_at=now;b->shown++;v->shown=1;
            }
            if(!rgba_view_native_alpha(v,alpha)){rgba_close_refuse(g,s,index);continue;}
            decoration_damage(c,v->window);
        }

    }
}
_Static_assert(RGBA_CLOSE_OFFSET+sizeof(struct rgba_close)<=RGBA_INPLACE_OFFSET,"retained close control partition");
