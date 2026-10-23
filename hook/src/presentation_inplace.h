// Qualified client texture mounted inside its original server window. The
// native window remains the ordering, Space and input owner.
#define RGBA_INPLACE_OFFSET 8192
#define RGBA_INPLACE_MAGIC 0x314543414c504e49ULL
struct rgba_retained_frame {
    void *texture;double width,height,scale;
    u32 pixel_width,pixel_height;u64 client_context;
    u32 client_id,client_sequence;
    void *color;
};
struct rgba_inplace {
    u64 magic;u32 size,version;
    struct rgba_capture *capture;
    void *window,*context,*server_root,*host,*root,*body,*texture;
    double host_opacity,source_w,source_h,expires;
    rect target,current;
    u64 command,sequence,claimed,ack,mutations,observations,adoptions;
    u32 on,reason,commit_sequence,adopted_sequence;
    int result;u32 client_included,client_sequence,client_current,host_seen,host_alpha;
    u64 creator,pid_version,adopted_texture,good_client_context;
    u32 wid,ordinary,good_client_sequence,good_client_id;
    double alpha;void *retiring_texture;
    double retiring_w,retiring_h;u64 retiring_client_context;u32 retiring_client_id,retiring_client_sequence;
    void *surface,*patch[3],*ring_in,*ring_act,*shadow;
    u64 legacy[4],style_hash;double focus,radius;
    u32 pixel_w,pixel_h,retiring_pixel_w,retiring_pixel_h;
    u32 presenting,padding_motion;u64 displayed_texture;double motion_started,settle_started,last_used;u64 displayed_bytes;
    struct rgba_retained_frame accepted;
    u32 opening,padding_opening;
    double logical_alpha;
    void *color,*retiring_color;
};
static struct rgba_inplace *rgba_inplace_control(struct rgba_capture *g) {
    struct rgba_inplace *m=(void *)((char *)g+RGBA_INPLACE_OFFSET);
    return m->magic==RGBA_INPLACE_MAGIC && m->size==sizeof(*m) && m->version==1 && m->capture==g?m:0;
}
// Four disjoint regions keep every UV inside the accepted texture. Empty
// extension regions are hidden; nearest filtering repeats exactly one texel.
static void *rgba_inplace_part(struct rgba_inplace *m,unsigned i) {return i?m->patch[i-1]:m->body;}
static void rgba_inplace_regions_at(struct rgba_inplace *m,rect pose,rect box[4],rect uv[4]) {
    double w=pose.w,h=pose.h,sw=m->source_w,sh=m->source_h;
    double cw=w<sw?w:sw,ch=h<sh?h:sh,dx=w-cw,dy=h-ch;
    double px=1.0/m->pixel_w,py=1.0/m->pixel_h;
    box[0]=(rect){0,dy,cw,ch};uv[0]=(rect){0,1-ch/sh,cw/sw,ch/sh};
    box[1]=(rect){cw,dy,dx,ch};uv[1]=(rect){1-px,1-ch/sh,px,ch/sh};
    box[2]=(rect){0,0,cw,dy};uv[2]=(rect){0,0,cw/sw,py};
    box[3]=(rect){cw,0,dx,dy};uv[3]=(rect){1-px,0,px,py};
}
static void rgba_inplace_pixels(struct ctx *c,struct rgba_inplace *m,int contents) {
    rect box[4],uv[4];rgba_inplace_regions_at(m,m->current,box,uv);
    for(unsigned i=0;i<4;i++) {
        void *L=rgba_inplace_part(m,i);
        rgba_view_bounds(c,L,"setBounds:",(rect){0,0,box[i].w,box[i].h});
        rgba_view_point(c,L,"setPosition:",box[i].x,box[i].y);
        rgba_view_bounds(c,L,"setContentsRect:",uv[i]);
        rgba_view_bool(c,L,"setHidden:",box[i].w<=0 || box[i].h<=0);
        if(contents)rgba_view_object(c,L,"setContents:",m->texture);
    }
}
static int rgba_inplace_border_on(struct ctx *c,struct ch_win *w) {
    struct ch_deco *d=&c->ch->deco;unsigned id=presentation_wid(c,w);
    return d->on && id!=d->nofull && (!d->only || id==d->only);
}
static void rgba_inplace_border(struct ctx *c,struct rgba_inplace *m,struct ch_win *w) {
    struct ch_deco *d=&c->ch->deco;double ow=d->sys_off==1?0:d->width,ins=d->inset10/10.0;
    if(d->sys_off==1 && ins>d->width)ins=d->width;
    double band=ow+ins;if(band<.5)band=d->width;
    struct rect4 f={-ow,-ow,m->current.w+2*ow,m->current.h+2*ow},mf={0,0,f.w,f.h};
    void *mask=rgba_view_get(c,m->ring_act,"mask");
    ((msgr_t)c->msg)(m->ring_in,c->s_frame,f);((msgr_t)c->msg)(m->ring_act,c->s_frame,f);
    ((msgr_t)c->msg)(mask,c->s_frame,mf);
    ((msgd_t)c->msg)(m->ring_in,c->s_bwidth,band);((msgd_t)c->msg)(mask,c->s_bwidth,band);
    ((msgd_t)c->msg)(m->ring_in,c->s_radius,m->radius+ow);((msgd_t)c->msg)(mask,c->s_radius,m->radius+ow);
    int on=rgba_inplace_border_on(c,w),shadow_created=0;
    if(!m->shadow && d->sh_on && c->path_rr && c->path_rel) {
        struct ch_win own;own.bl_sh=0;
        void *curve=c->cur_curve;c->cur_curve=c->str_circ;
        shadow_make(c,&own,m->root,0);c->cur_curve=curve;m->shadow=(void *)own.bl_sh;
        if(m->shadow && !rgba_view_get(c,m->shadow,"mask")) {
            rgba_view_get(c,m->shadow,"removeFromSuperlayer");((msg0_t)c->msg)(m->shadow,c->s_release);m->shadow=0;
        }
        if(m->shadow){shadow_created=1;rgba_view_object(c,m->shadow,"setName:",rgba_view_string(c,"hyprwm.rgba.client-shadow"));}
    }
    if(m->shadow) {
        ((msgr_t)c->msg)(m->shadow,c->s_frame,f);
        double radius=m->radius+ow;if(radius>f.w/2)radius=f.w/2;if(radius>f.h/2)radius=f.h/2;
        struct rect4_ bounds={0,0,f.w,f.h};void *path=c->path_rr(bounds,radius,radius,0);
        if(path){((msgp_t)c->msg)(m->shadow,c->s_shpath,path);c->path_rel(path);}
        void *smask=rgba_view_get(c,m->shadow,"mask");
        if(smask) {
            struct rect4 sf={-SH_E,-SH_E,f.w+2*SH_E,f.h+2*SH_E};
            ((msgr_t)c->msg)(smask,c->s_frame,sf);((msgd_t)c->msg)(smask,c->s_radius,m->radius+ow+SH_E);
        }
        ((msgd_t)c->msg)(m->shadow,c->s_shrad,d->srad);
        struct pt2 off={0,-d->soff};((msgpt_t)c->msg)(m->shadow,c->s_shoff,off);
        rgba_view_bool(c,m->shadow,"setHidden:",!on || !d->sh_on);
    }
    rgba_view_bool(c,m->ring_in,"setHidden:",!on);rgba_view_bool(c,m->ring_act,"setHidden:",!on);
    double focus=presentation_wid(c,w)==d->focus?1:0;u64 hash=decoration_hash(d);
    if(m->focus!=focus || m->style_hash!=hash || shadow_created) {
        fade_colors(c,m->ring_act,focus,m->style_hash?d->dur:0,d->bez);
        if(m->shadow) {
            double opacity=d->sh_on?d->sop_in+(d->sop_act-d->sop_in)*focus:0;
            fade_to(c,m->shadow,c->str_shop,c->s_shopget,c->s_shop,opacity,m->style_hash?d->sdur:0,d->sbez);
        }
        struct pt2 a={d->start[0],d->start[1]},b={d->end[0],d->end[1]};
        ((msgpt_t)c->msg)(m->ring_act,c->s_start,a);((msgpt_t)c->msg)(m->ring_act,c->s_end,b);
    }
    m->focus=focus;m->style_hash=hash;
}
static void rgba_inplace_legacy(struct ctx *c,struct rgba_inplace *m,struct ch_win *w,int hidden) {
    u64 layers[4]={w->bl_in,w->bl_act,w->bl_fill,w->bl_sh};
    for(unsigned i=0;i<4;i++)if(layers[i] && (hidden || layers[i]==m->legacy[i]))
        rgba_view_bool(c,(void *)layers[i],"setHidden:",hidden || (i==2 && w->fkey[0]<=0));
    if(hidden)for(unsigned i=0;i<4;i++)m->legacy[i]=layers[i];
}
static int rgba_inplace_drop_slot(struct rgba_capture *g,struct rgba_inplace *m) {
    if(!m)return 1;
    struct ctx *c=g->pc.engine;
    char *win=c->by_id(m->wid);
    if(win && (win!=m->window || *(u64 *)(win+0x30)!=m->creator || !m->creator ||
       *(u64 *)((char *)m->creator+0x268)!=m->pid_version))win=0;
    char *cwc=win?*(char **)(win+0x18):0;
    void *host=cwc?*(void **)(cwc+0x98):0,*context=cwc?*(void **)(cwc+0x38):0;
    u64 tx[4]={0};c->tx_ctor(tx,1);if(context && context==m->context)c->tx_add(tx,context);
    struct ch_win *w=win?slot(c->ch,m->wid,0):0;
    u32 was_presenting=m->presenting;
    if(w && m->ordinary && was_presenting)rgba_inplace_legacy(c,m,w,0);
    if(m->on && was_presenting && host && host==m->host && context==m->context &&
       ((float (*)(void *,void *))c->msg)(host,c->sel("opacity"))==0)
        ((void (*)(void *,void *,float))c->msg)(host,c->sel("setOpacity:"),(float)m->host_opacity);
    if(m->root)rgba_view_get(c,m->root,"removeFromSuperlayer");
    for(unsigned i=0;i<4;i++)if(rgba_inplace_part(m,i))rgba_view_object(c,rgba_inplace_part(m,i),"setContents:",0);
    if(win && m->ordinary && was_presenting && w) {
        c->set_alpha(0,win,(float)w->cur_alpha,0);put_plain(c,w,win);w->settling=1;w->fkey[0]=-1;
    }
    layers_commit(c,tx);
    for(unsigned i=0;i<4;i++)if(rgba_inplace_part(m,i))g->pc.release_obj(rgba_inplace_part(m,i));
    if(m->surface)g->pc.release_obj(m->surface);
    if(m->ring_in)g->pc.release_obj(m->ring_in);if(m->ring_act)g->pc.release_obj(m->ring_act);
    if(m->shadow)g->pc.release_obj(m->shadow);m->shadow=0;
    if(m->root)g->pc.release_obj(m->root);
    m->surface=m->ring_in=m->ring_act=0;for(unsigned i=0;i<3;i++)m->patch[i]=0;
    if(m->texture)g->pc.release_obj(m->texture);
    if(m->retiring_texture)g->pc.release_obj(m->retiring_texture);m->retiring_texture=0;
    if(m->accepted.texture)g->pc.release_obj(m->accepted.texture);
    if(m->accepted.color)g->api.geometry.release_cf(m->accepted.color);m->accepted=(struct rgba_retained_frame){0};
    if(m->color)g->api.geometry.release_cf(m->color);m->color=0;
    if(m->retiring_color)g->api.geometry.release_cf(m->retiring_color);m->retiring_color=0;
    m->body=m->root=m->texture=0;m->on=m->presenting=0;m->displayed_texture=m->displayed_bytes=0;
    if(cwc && context==m->context)decoration_damage(c,win);
    return 1;
}
static int rgba_inplace_drop(struct rgba_capture *g) {return rgba_inplace_drop_slot(g,rgba_inplace_control(g));}
static int rgba_inplace_mount_slot(struct rgba_capture *g,struct rgba_inplace *m) {
    if(!m)return 0;
    struct ctx *c=g->pc.engine;struct pc_capture *p=&g->pc;
    struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    if(m->on || m->root || m->body || !rgba_view_valid(v,g) || !rgba_view_pixels(v) ||
       g->content_mode!=RGBA_CLIENT_DOMAIN_MODE || !rgba_view_rect(m->target))return 0;
    char *win=pc_source(p),*cwc=win?*(char **)(win+0x18):0;if(!cwc)return 0;
    u32 client_sequence=0;void *client=*(void **)(cwc+0x48);
    if(*(u32 *)(cwc+0x50)!=g->domain.client_id ||
       !rgba_included(g->update,client,&client_sequence) || client_sequence!=p->client_commit_sequence)return 0;
    void *root=*(void **)(cwc+0x80),*host=*(void **)(cwc+0x98),*context=*(void **)(cwc+0x38);
    if(!root || !host || !context || ((float (*)(void *,void *))c->msg)(host,c->sel("opacity"))!=1)return 0;
    struct rect4 hb=((msgb_t)c->msg)(host,c->s_bounds);
    if(hb.w<1 || hb.h<1)return 0;
    m->wid=p->wid;m->creator=p->creator;m->pid_version=p->pid_version;m->alpha=1;
    m->window=win;m->context=context;m->server_root=root;m->host=host;m->host_opacity=1;
    m->source_w=(double)p->width/p->scale;m->source_h=(double)p->height/p->scale;
    m->good_client_sequence=p->client_commit_sequence;
    m->good_client_context=(u64)client;m->good_client_id=g->domain.client_id;
    if(m->source_w!=g->domain.mapped.w || m->source_h!=g->domain.mapped.h)return 0;
    m->pixel_w=p->width;m->pixel_h=p->height;
    m->texture=p->retain_obj(p->texture_ref);
    m->root=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    m->surface=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    m->body=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    for(unsigned i=0;i<3;i++)m->patch[i]=rgba_view_get(c,rgba_view_get(c,c->cls("CALayer"),"alloc"),"init");
    if(!m->texture || !m->root || !m->surface || !m->body || !m->patch[0] || !m->patch[1] || !m->patch[2] || !deco_ready(c)) {
        rgba_inplace_drop_slot(g,m);return 0;
    }
    rect local={0,0,m->target.w,m->target.h};m->current=m->target;m->radius=c->ch->deco.radius;
    struct rect4 r={hb.x,c->ch->h.mask_flip?hb.y+hb.h-local.h:hb.y,local.w,local.h};
    struct rect4 fr=((msgcv_t)c->msg)(host,c->s_convert,r,root);
    u64 tx[4]={0};c->tx_ctor(tx,1);c->tx_add(tx,context);
    rgba_view_object(c,m->root,"setName:",rgba_view_string(c,"hyprwm.rgba.client-root"));
    rgba_view_object(c,m->surface,"setName:",rgba_view_string(c,"hyprwm.rgba.client-surface"));
    rgba_view_point(c,m->root,"setAnchorPoint:",0,0);rgba_view_point(c,m->surface,"setAnchorPoint:",0,0);
    rgba_view_bounds(c,m->root,"setBounds:",local);rgba_view_bounds(c,m->surface,"setBounds:",local);
    rgba_view_point(c,m->root,"setPosition:",fr.x,fr.y);rgba_view_point(c,m->surface,"setPosition:",0,0);
    keep_top(c,m->root);keep_top(c,m->surface);
    rgba_view_bool(c,m->root,"setMasksToBounds:",0);rgba_view_bool(c,m->surface,"setMasksToBounds:",1);
    ((msgd_t)c->msg)(m->surface,c->s_radius,m->radius);
    ((msgp_t)c->msg)(m->surface,c->s_curve,c->str_circ);
    rgba_view_bool(c,m->root,"setOpaque:",0);rgba_view_bool(c,m->surface,"setOpaque:",0);
    for(unsigned i=0;i<4;i++) {
        void *L=rgba_inplace_part(m,i);
        rgba_view_object(c,L,"setName:",rgba_view_string(c,i?"hyprwm.rgba.client-edge":"hyprwm.rgba.client-body"));
        rgba_view_point(c,L,"setAnchorPoint:",0,0);
        ((msgd_t)c->msg)(L,c->sel("setContentsScale:"),p->scale);
        rgba_view_object(c,L,"setContentsGravity:",rgba_view_string(c,"resize"));
        rgba_view_object(c,L,"setContentsScaling:",rgba_view_string(c,"stretch"));
        rgba_view_bounds(c,L,"setContentsCenter:",(rect){0,0,1,1});
        rgba_view_bool(c,L,"setOpaque:",0);rgba_view_bool(c,L,"setContentsOpaque:",0);
        rgba_view_object(c,L,"setMinificationFilter:",rgba_view_string(c,"nearest"));
        rgba_view_object(c,L,"setMagnificationFilter:",rgba_view_string(c,"nearest"));
        rgba_view_object(c,m->surface,"addSublayer:",L);
    }
    rgba_inplace_pixels(c,m,1);rgba_view_object(c,m->root,"addSublayer:",m->surface);
    struct ch_win proxy;proxy.bl_in=proxy.bl_act=0;void *curve=c->cur_curve;c->cur_curve=c->str_circ;
    border_make(c,&proxy,m->root);c->cur_curve=curve;
    m->ring_in=(void *)proxy.bl_in;m->ring_act=(void *)proxy.bl_act;
    if(!m->ring_in || !m->ring_act || !rgba_view_get(c,m->ring_act,"mask")) {
        layers_commit(c,tx);rgba_inplace_drop_slot(g,m);return 0;
    }
    rgba_view_object(c,m->ring_in,"setName:",rgba_view_string(c,"hyprwm.rgba.client-ring-in"));
    rgba_view_object(c,m->ring_act,"setName:",rgba_view_string(c,"hyprwm.rgba.client-ring"));
    struct ch_win *w=slot(c->ch,m->wid,0);
    if(w)rgba_inplace_border(c,m,w);
    rgba_view_object(c,root,"addSublayer:",m->root);
    if(m->ordinary)((msgf_t)c->msg)(m->root,c->s_opacity,0);
    else {((msgf_t)c->msg)(host,c->s_opacity,0);m->presenting=1;}
    m->displayed_texture=(u64)m->texture;m->displayed_bytes=(u64)m->pixel_w*m->pixel_h*4;
    m->on=1;m->last_used=c->ch->h.now;m->expires=c->ch->h.now+8;layers_commit(c,tx);m->mutations++;
    m->commit_sequence=((u32 (*)(void *,void *))c->msg)(context,c->sel("commitId"));
    decoration_damage(c,win);return 1;
}
// This walk reads the actual prepared Update's nodes. Current MODEL handles are
// used only as stable identities; their current layer pointers are never used.
static char *rgba_inplace_source(struct rgba_capture *g,struct rgba_inplace *m) {
    char *win=g->pc.engine->by_id(m->wid);
    if(!win || win!=m->window || *(u32 *)win!=m->wid || *(u32 *)(win+4)!=5 ||
       *(u64 *)(win+0x30)!=m->creator || !m->creator ||
       *(u64 *)((char *)m->creator+0x268)!=m->pid_version)return 0;
    return win;
}
static int rgba_inplace_render_child(char *parent,char *child) {
    if(!parent || !child)return 0;
    char *children=*(char **)(parent+0x70);
    void *handle=*(void **)(child+0x98);if(!handle)return 0;
    if(*(u32 *)(parent+0xc)&(1U<<13))return children && *(void **)(children+0x98)==handle;
    if(!children || (unsigned char)children[0xc]!=1 || (children[0xd]&1))return 0;
    u32 n=*(u32 *)(children+0x10);if(n>64)return 0;
    for(u32 i=0;i<n;i++) {
        char *entry=*(char **)(children+0x18+8*i);
        if(entry && *(void **)(entry+0x98)==handle)return 1;
    }
    return 0;
}
static int rgba_inplace_region_matches(struct rgba_inplace *m,rect pose,unsigned i,char *layer) {
    rect box[4],uv[4];rgba_inplace_regions_at(m,pose,box,uv);
    if(box[i].w<=0 || box[i].h<=0)return 1;
    if(!layer || (unsigned char)layer[0x24]!=255 ||
       !rgba_view_same(*(rect *)(layer+0x48),(rect){0,0,box[i].w,box[i].h}))return 0;
    char *texture=*(char **)(layer+0x68),*ext=*(char **)(layer+0x88),*coords=ext?*(char **)(ext+0x28):0;
    if(!texture || (unsigned char)texture[0xc]!=0x24 || *(void **)(texture+0x70)!=m->texture)return 0;
    if(!coords)return uv[i].x==0 && uv[i].y==0 && uv[i].w==1 && uv[i].h==1;
    return (unsigned char)coords[0xc]==0x3e && *(u32 *)(coords+0x10)==4 &&
        dabs(*(double *)(coords+0x18)-uv[i].x)<1e-9 && dabs(*(double *)(coords+0x20)-uv[i].y)<1e-9 &&
        dabs(*(double *)(coords+0x28)-uv[i].x-uv[i].w)<1e-9 && dabs(*(double *)(coords+0x30)-uv[i].y-uv[i].h)<1e-9;
}
static void rgba_inplace_observe_slot(struct rgba_capture *g,struct rgba_inplace *m,void *head,void *prepared) {
    if(!m || !m->on)return;
    char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    if(!cwc || win!=m->window || *(void **)(cwc+0x38)!=m->context ||
       *(void **)(cwc+0x98)!=m->host || *(void **)(cwc+0x80)!=m->server_root)return;
    char *source=0;unsigned count=0;
    for(char *s=prepared;s && count++<256;s=*(char **)(s+8))
        if(*(u32 *)(s+0x180)==10 && *(u32 *)(s+0x268)==m->wid){if(source)return;source=s;}
    if(!source || count>=256)return;
    char *meta=*(char **)(source+0x48),*update=meta?*(char **)(meta+0x10):0;
    void *context=*(void **)(cwc+0x30);u32 sequence=0;
    if(!meta || *(void **)meta!=win || *(void **)(meta+8) || !update ||
       *(void **)(source+0x28)!=update || *(void **)(source+0x30)!=update ||
       !rgba_included(update,context,&sequence))return;
    m->client_included=rgba_included(update,*(void **)(cwc+0x48),&m->client_sequence);
    void *client=*(void **)(cwc+0x48);
    if(client && g->api.lock_context(client)==0) {
        m->client_current=*(u32 *)((char *)client+0x40);g->api.unlock_context(client);
    }
    struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    u64 root_id=v->api.layer_id(m->root),body_id=v->api.layer_id(m->body),host_id=v->api.layer_id(m->host);
    u64 surface_id=v->api.layer_id(m->surface),part_id[4]={body_id,0,0,0};
    for(unsigned i=1;i<4;i++)part_id[i]=v->api.layer_id(m->patch[i-1]);
    if(!root_id || !body_id || !host_id || !surface_id || g->api.lock_context(context)!=0)return;
    void *rh=v->api.lookup_handle(context,root_id,0,0,0),*bh=v->api.lookup_handle(context,body_id,0,0,0),
         *hh=v->api.lookup_handle(context,host_id,0,0,0);
    void *surface_handle=v->api.lookup_handle(context,surface_id,0,0,0),*part_handle[4];
    part_handle[0]=bh;
    for(unsigned i=1;i<4;i++)part_handle[i]=v->api.lookup_handle(context,part_id[i],0,0,0);
    char *parts[4]={0},*actual_surface=0;
    m->reason=100;int adopted=0;
    char *roots[64],*next[64],*prev[64],*parent[64],*seen[512];
    unsigned depth=1,n=0;char *actual_root=0,*actual_body=0,*actual_host=0;
    roots[0]=update+0xd8;next[0]=*(char **)roots[0];prev[0]=roots[0];parent[0]=0;
    while(depth) {
        unsigned d=depth-1;char *node=next[d];
        if(node==roots[d]){if(*(char **)(roots[d]+8)!=prev[d]){m->reason=101;goto done;}depth--;continue;}
        if(!node || n==512){m->reason=102;goto done;}
        if(*(char **)(node+8)!=prev[d] || *(char **)(node+0x58)!=parent[d]){m->reason=103;goto done;}
        for(unsigned i=0;i<n;i++)if(seen[i]==node){m->reason=104;goto done;}
        seen[n++]=node;next[d]=*(char **)node;prev[d]=node;
        char *layer=*(char **)(node+0x20);void *handle=layer?*(void **)(layer+0x98):0;
        if(handle && handle==rh){if(actual_root){m->reason=107;goto done;}actual_root=layer;}
        if(handle && handle==bh){if(actual_body){m->reason=108;goto done;}actual_body=layer;}
        if(handle && handle==surface_handle) {
            if(actual_surface){m->reason=109;goto done;}actual_surface=layer;
        }
        for(unsigned i=0;i<4;i++)if(handle && handle==part_handle[i]) {
            if(parts[i]){m->reason=110+i;goto done;}parts[i]=layer;
        }
        if(handle && handle==hh) {
            if(actual_host){m->reason=105;goto done;}actual_host=layer;
            // Hosting is excluded by this actual Update's zero opacity. Its
            // arbitrary application subtree cannot contain our Server sibling
            // root, and does not need to fit a window-manager traversal budget.
            if((unsigned char)layer[0x24]==0)continue;
        }
        if(depth==64){m->reason=106;goto done;}
        roots[depth]=node+0x60;next[depth]=*(char **)(node+0x60);prev[depth]=node+0x60;parent[depth]=node;depth++;
    }
    m->observations++;
    m->host_seen=actual_host!=0;m->host_alpha=actual_host?(unsigned char)actual_host[0x24]:256;
    // This actual Update can precede the current MAIN model pose by a frame.
    // Adoption proves its own immutable geometry and texture, never the newer
    // model sample that happened to be current when the callback was entered.
    rect local=actual_surface?*(rect *)(actual_surface+0x48):(rect){0};
    u32 failed=0;
    if(!actual_surface)failed|=2;
    if(!rgba_view_rect(local) || local.x!=0 || local.y!=0)failed|=4;
    if(actual_surface && (!rgba_view_same(*(rect *)(actual_surface+0x48),local) ||
       (unsigned char)actual_surface[0x24]==0))failed|=8;
    if(actual_root && ((unsigned char)actual_root[0x24]==0 ||
       !rgba_view_same(*(rect *)(actual_root+0x48),local)))failed|=16;
    if(actual_root && !rgba_inplace_render_child(actual_root,actual_surface))failed|=32;
    rect boxes[4],uv[4];rgba_inplace_regions_at(m,local,boxes,uv);
    for(unsigned i=0;i<4;i++) {
        if(!rgba_inplace_region_matches(m,local,i,parts[i]))failed|=64U<<i;
        if(boxes[i].w>0 && boxes[i].h>0 && !rgba_inplace_render_child(actual_surface,parts[i]))failed|=1024U<<i;
    }
    int excluded=actual_host && actual_host[0x24]==0;
    // A zero-opacity Hosting can be absent from optimized LayerNodes. Only a
    // Render layer from the exact server-context commit included in THIS
    // Update can supply that exclusion witness. A newer current commit cannot.
    if(!actual_host && *(u32 *)((char *)context+0x40)==sequence && hh &&
       *(void **)((char *)hh+0x18)==context) {
        char *hosting=*(char **)((char *)hh+0x10);
        if(hosting && *(void **)(hosting+0x98)==hh && hosting[0x24]==0) {
            excluded=1;m->host_seen=2;m->host_alpha=0;
        }
    }
    if(!excluded)failed|=16384;
    if(!failed) {
        m->adoptions++;m->adopted_sequence=sequence;m->adopted_texture=(u64)m->texture;m->reason=0;
        adopted=1;
    }else m->reason=0x10000|failed;
done:
    g->api.unlock_context(context);
    if(adopted && m->accepted.texture!=m->texture) {
        void *texture=g->pc.retain_obj(m->texture);
        if(texture) {
            if(m->accepted.texture)g->pc.release_obj(m->accepted.texture);
            if(m->accepted.color)g->api.geometry.release_cf(m->accepted.color);
            m->accepted=(struct rgba_retained_frame){texture,m->source_w,m->source_h,
                (double)m->pixel_w/m->source_w,m->pixel_w,m->pixel_h,m->good_client_context,
                m->good_client_id,m->good_client_sequence,m->color?g->api.geometry.retain_cf(m->color):0};
        }
    }
}
static void rgba_inplace_observe(struct rgba_capture *g,void *head,void *prepared) {rgba_inplace_observe_slot(g,rgba_inplace_control(g),head,prepared);}
static void rgba_inplace_tick(struct rgba_capture *g) {
    struct rgba_inplace *m=rgba_inplace_control(g);if(!m || !pc_main(&g->pc))return;
    if(m->on && (g->pc.engine->ch->h.now>=m->expires || !pc_source(&g->pc)))rgba_inplace_drop(g);
    u64 sequence=__atomic_load_n(&m->sequence,__ATOMIC_ACQUIRE);
    if(sequence==m->ack)return;
    u64 command=__atomic_exchange_n(&m->command,0,__ATOMIC_ACQ_REL);if(!command)return;
    m->claimed=sequence;
    m->result=command==1?rgba_inplace_mount_slot(g,m):command==2?rgba_inplace_drop(g):0;
    __atomic_store_n(&m->ack,sequence,__ATOMIC_RELEASE);
}
_Static_assert(RGBA_INPLACE_OFFSET+sizeof(struct rgba_inplace)<RGBA_NORMAL_OFFSET,"in-place control partition");
