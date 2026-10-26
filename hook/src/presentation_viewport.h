// Live native content moves beneath a fixed tile. Existing capture/Hosting
// structures keep their frozen layouts; this optional ledger owns only offsets.
#define RGBA_PAN_OFFSET 62592
#define RGBA_PAN_MAGIC 0x31574f444e415052ULL
struct rgba_pan_row {
    u64 window,creator,birth,cwc,host,root,space,nonce;
    u32 wid,pending,cancel,applied;
    rect box;
    double origin[2],wanted[2],offset[2],expires;
};
struct rgba_pan {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    void *storage;struct rgba_pan_row *rows;
    u32 cursor,seen,dead,pad;
};
static void rgba_pan_border(struct rgba_capture *,struct ch_win *,char *,double,double);
int rgba_normal_viewport_drop(void *);
static struct rgba_pan *rgba_pan_control(struct rgba_capture *g) {
    struct rgba_pan *p=(void *)((char *)g+RGBA_PAN_OFFSET);
    return p->magic==RGBA_PAN_MAGIC && p->size==sizeof(*p) && p->version==1 && p->capture==g?p:0;
}
static int rgba_pan_active(struct rgba_capture *g,unsigned wid) {
    struct rgba_pan *p=rgba_pan_control(g);if(!p || !p->rows)return 0;
    for(unsigned i=0;i<CH_NW;i++)if(p->rows[i].wid==wid && p->rows[i].applied)return 1;
    return 0;
}
static void rgba_pan_clear(struct rgba_pan_row *r) {
    for(unsigned i=0;i<sizeof(*r);i++)((volatile unsigned char *)r)[i]=0;
}
static int rgba_pan_mutation_allowed(struct rgba_capture *g,int cleanup) {
    if(!rgba_valid(g) || !pc_main(&g->pc))return 0;
    struct pc_capture *p=&g->pc;struct ctx *c=p->engine;
    struct rgba_normal_binding *n=rgba_normal_binding(g);
    if(!c || !c->ch || c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=(u32)sizeof(struct ch) || c->in_cb ||
       !n || n->inflight || g->locked_client || p->update || p->context || p->client_context ||
       p->clone || p->capture || (p->active_command && (!cleanup || p->active_command!=4)))return 0;
    return rgba_carrier_timer_allowed(g);
}
static char *rgba_pan_source(struct rgba_capture *g,struct rgba_pan_row *r) {
    char *win=g->pc.engine->by_id(r->wid);
    return win && win==(void *)r->window && *(u32 *)win==r->wid && *(u32 *)(win+4)==5 &&
        *(u64 *)(win+0x30)==r->creator && r->creator &&
        *(u64 *)((char *)r->creator+0x268)==r->birth?win:0;
}
static void rgba_pan_invalidate(struct rgba_capture *g,unsigned wid) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct rgba_inplace *m=rgba_ordinary_slots(g);
    if(!o)return;
    for(unsigned i=0;i<CH_NW;i++)if(m[i].wid==wid) {
        o->good_time[i]=0;o->native_time[i]=g->pc.engine->ch->h.now;
    }
    o->next_capture=0;
}
static int rgba_pan_restore(struct rgba_capture *g,struct rgba_pan_row *r) {
    if(!rgba_pan_mutation_allowed(g,1))return 0;
    struct ctx *c=g->pc.engine;
    if(c->dead || c->ch->h.stop) {
        // Without a completed restoration receipt an applied projection is
        // still ours. Retain its row and storage for a live cleanup retry.
        if(r->applied)return 0;
        rgba_pan_clear(r);return 1;
    }
    struct ch_win *w=slot(c->ch,r->wid,0);char *win=rgba_pan_source(g,r);
    if(r->applied && !c->dead && !c->ch->h.stop && win && w && w->used && w->geo && w->geo!=2) {
        // A geometry command/retained takeover already reinstalls canonical
        // input. Never overwrite that newer motion with a saved viewport.
        struct rgba_inplace *all=rgba_ordinary_slots(g);int presenting=0;
        for(unsigned i=0;i<CH_NW;i++)if(all[i].wid==r->wid && all[i].presenting)presenting=1;
        if(!presenting && !w->pos.active && !w->size.active && !w->held && !w->wait) {
            double x=w->pos.v[0],y=w->pos.v[1],bw=w->size.v[0],bh=w->size.v[1];
            if(finite(x) && finite(y) && bw>=1 && bh>=1) {
                put_mask(c,w,win,0,0,0);
                put_xform(c,w,1,1,w->ax-x,w->ay-y);
                int crop=w->aw>bw+.5 || w->ah>bh+.5;
                put_clip(c,w,win,crop,x,y,bw<w->aw?bw:w->aw,bh<w->ah?bh:w->ah);
                w->settling=1;w->fkey[0]=-1;
                rgba_pan_border(g,w,win,0,0);
            }
        }
        rgba_pan_invalidate(g,r->wid);decoration_damage(c,win);
    }
    rgba_pan_clear(r);return 1;
}
int anim_rgba_viewport_drop_work(void *raw) {
    struct rgba_capture *g=raw;
    struct rgba_pan *p=rgba_pan_control(g);g->pc.engine->ch->h.version&=~CH_CAP_VIEWPORT;
    if(!p)return 1;
    if(!rgba_pan_mutation_allowed(g,1))return 0;
    if(p->rows)for(unsigned i=0;i<CH_NW;i++)if(p->rows[i].wid && !rgba_pan_restore(g,&p->rows[i]))return 0;
    if(p->storage)g->pc.release_obj(p->storage);
    p->rows=0;p->storage=0;return 1;
}
static int rgba_pan_drop(struct rgba_capture *g) {return rgba_normal_viewport_drop(g);}
// This pass only reads the command ring and records numbers. It also runs
// before a nested original tick can consume commands; no native mutation or
// Objective-C allocation is permitted here.
static void rgba_pan_record(struct ctx *c) {
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!rgba_valid(g) || g->pc.engine!=c || !pc_main(&g->pc) || c->in_cb || !c->ch)return;
    struct rgba_pan *p=rgba_pan_control(g);if(!p || p->dead || !p->rows)return;
    u32 head=__atomic_load_n(&c->ch->h.cmd_head,__ATOMIC_ACQUIRE),tail=c->ch->h.cmd_tail;
    if(head-tail>CH_NCMD)return;
    u32 cursor=p->cursor;if(!p->seen || cursor-tail>head-tail)cursor=tail;
    p->seen=1;p->cursor=head;
    for(u32 at=cursor;at!=head;at++) {
        const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
        struct ch_win *w=slot(c->ch,k->wid,0);
        if(!w || !w->used)continue;
        unsigned i=w-c->ch->win;if(i>=CH_NW)continue;
        struct rgba_pan_row *r=&p->rows[i];
        if(k->op==OP_GEOM || k->op==OP_WARP || k->op==OP_FORGET || k->op==OP_SPACE ||
           k->op==OP_ALPHA || k->op==OP_CFG) {if(r->wid==k->wid)r->cancel=1;continue;}
        if(k->op!=OP_EDGE || k->flags!=CH_VIEWPORT || k->cpos>1 || (!k->pad0 && !k->pad1))continue;
        if(k->cpos && (!finite(k->x) || !finite(k->y) || k->x<0 || k->y<0 || k->x>65536 || k->y>65536 ||
           !rgba_view_rect((rect){k->fx,k->fy,k->fw,k->fh})))continue;
        if(r->wid && r->wid!=k->wid)rgba_pan_clear(r);
        if(r->cancel && k->cpos)continue;
        r->wid=k->wid;r->nonce=(u64)k->pad0|((u64)k->pad1<<32);
        if(!k->cpos){r->cancel=1;continue;}
        r->wanted[0]=k->x;r->wanted[1]=k->y;
        r->box=(rect){k->fx,k->fy,k->fw,k->fh};r->pending=1;
        r->expires=c->ch->h.now+1.5;
    }
}
static int rgba_pan_ready(struct rgba_capture *g,struct ch_win *w,char **source) {
    struct ctx *c=g->pc.engine;char *win=c->by_id(w->wid),*cwc=win?*(char **)(win+0x18):0;
    if(!win || *(u32 *)(win+4)!=5 || *(int *)(win+0x20)!=0 || !((*(u64 *)(win+0x928)>>44)&1) ||
       !cwc || !*(void **)(win+0x30) || !*(void **)(cwc+0x38) || !*(void **)(cwc+0x80) ||
       !*(void **)(cwc+0x98) || *(void **)(cwc+0x70) || *(void **)(cwc+0x78) ||
       *(u32 *)(cwc+0x150) || *(u32 *)(cwc+0x154) || !w->geo || w->geo==2 ||
       w->held || w->wait || w->pos.active || w->size.active || w->alpha.active || w->cur_alpha!=1 ||
       birth_holds(c,w->wid) || cover_index(c,w->wid,1)>=0)return 0;
    struct rgba_inplace *all=rgba_ordinary_slots(g);struct rgba_ordinary *o=rgba_ordinary_control(g);
    for(unsigned i=0;i<CH_NW;i++)if(all[i].on && all[i].wid==w->wid &&
       (all[i].presenting || all[i].opening || all[i].padding_motion || rgba_draw_pending(g,&all[i])))return 0;
    if(o && o->candidate<CH_NW && g->pc.wid==w->wid)return 0;
    if(((float (*)(void *,void *))c->msg)(*(void **)(cwc+0x98),c->sel("opacity"))!=1)return 0;
    *source=win;return 1;
}
static void rgba_pan_border(struct rgba_capture *g,struct ch_win *w,char *win,double px,double py) {
    struct ctx *c=g->pc.engine;char *cwc=*(char **)(win+0x18);
    void *host=*(void **)(cwc+0x98),*root=*(void **)(cwc+0x80),*context=*(void **)(cwc+0x38);
    struct rect4 hb=((msgb_t)c->msg)(host,c->s_bounds);
    double bw=w->size.v[0],bh=w->size.v[1],ow=c->ch->deco.sys_off==1?0:c->ch->deco.width*ring_scale(w);
    double dy=c->ch->h.mask_flip?-py:py;
    struct rect4 ring={hb.x-ow+px,c->ch->h.mask_flip?hb.y+hb.h-bh-ow+dy:hb.y-ow+dy,bw+2*ow,bh+2*ow};
    struct rect4 fill={hb.x+px,c->ch->h.mask_flip?hb.y+hb.h-bh+dy:hb.y+dy,bw,bh};
    ring=((msgcv_t)c->msg)(host,c->s_convert,ring,root);
    fill=((msgcv_t)c->msg)(host,c->s_convert,fill,root);
    if(!rgba_view_rect((rect){ring.x,ring.y,ring.w,ring.h}) || !rgba_view_rect((rect){fill.x,fill.y,fill.w,fill.h}))return;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,context);
    u64 owned[4]={w->bl_in,w->bl_act,w->bl_sh,w->bl_fill};
    for(unsigned i=0;i<4;i++)if(owned[i] && rgba_view_get(c,(void *)owned[i],"superlayer")==root) {
        // Absolute geometry also handles a duplicate original tick and fill
        // layers whose canonical frame was not rewritten in that tick.
        ((msgr_t)c->msg)((void *)owned[i],c->s_frame,i==3?fill:ring);
    }
    RGBA_LAYER_COMMIT(tx);
}
void anim_rgba_viewport_tick(void *raw) {
    struct rgba_capture *g=raw;
    if(!rgba_pan_mutation_allowed(g,0))return;
    struct ctx *c=g->pc.engine;struct rgba_ordinary *o=rgba_ordinary_control(g);
    struct rgba_pan *p=rgba_pan_control(g);
    if(!p) {
        p=(void *)((char *)g+RGBA_PAN_OFFSET);
        for(unsigned i=0;i<sizeof(*p);i++)((volatile unsigned char *)p)[i]=0;
        p->magic=RGBA_PAN_MAGIC;p->size=sizeof(*p);p->version=1;p->capture=g;
    }
    if(p->dead || !o || !o->enabled || c->dead || c->ch->h.stop || g->quarantined || c->ch->h.now>=o->expires) {
        rgba_pan_drop(g);return;
    }
    if(!p->rows) {
        void *data=((void *(*)(void *,void *,u64))c->msg)(c->cls("NSMutableData"),c->sel("dataWithLength:"),CH_NW*sizeof(*p->rows));
        if(!data)return;p->storage=g->pc.retain_obj(data);p->rows=rgba_view_get(c,data,"mutableBytes");
        if(!p->rows){g->pc.release_obj(p->storage);p->storage=0;return;}
    }
    c->ch->h.version|=CH_CAP_VIEWPORT;
    for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_pan_row *r=&p->rows[i];struct ch_win *w=&c->ch->win[i];
        if(!r->wid)continue;
        u64 nonce=r->nonce;unsigned wid=r->wid;
        if(r->cancel || c->ch->h.now>=r->expires || !w->used || w->wid!=r->wid) {
            if(rgba_pan_restore(g,r) && nonce)post_evt(c->ch,EV_VIEWPORT,wid,c->ch->h.now,(u32)nonce,(u32)(nonce>>32),0,0);
            continue;
        }
        char *win=0;rect box={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        int ready=rgba_pan_ready(g,w,&win) && rgba_view_rect(box) && rgba_view_same(box,r->box);
        if(!ready) {
            if(r->applied) {
                if(rgba_pan_restore(g,r))post_evt(c->ch,EV_VIEWPORT,wid,c->ch->h.now,(u32)nonce,(u32)(nonce>>32),0,0);
            }
            continue;
        }
        char *cwc=*(char **)(win+0x18),*creator=*(char **)(win+0x30);u64 sid=rgba_carrier_space(g,win);
        if(!sid || (r->window && (rgba_pan_source(g,r)!=win || r->cwc!=(u64)cwc ||
           r->host!=*(u64 *)(cwc+0x98) || r->root!=*(u64 *)(cwc+0x80) || r->space!=sid ||
           dabs(r->origin[0]-w->ax)>.5 || dabs(r->origin[1]-w->ay)>.5))) {
            if(rgba_pan_restore(g,r))post_evt(c->ch,EV_VIEWPORT,wid,c->ch->h.now,(u32)nonce,(u32)(nonce>>32),0,0);continue;
        }
        r->window=(u64)win;r->creator=(u64)creator;r->birth=*(u64 *)(creator+0x268);
        r->cwc=(u64)cwc;r->host=*(u64 *)(cwc+0x98);r->root=*(u64 *)(cwc+0x80);r->space=sid;
        r->origin[0]=w->ax;r->origin[1]=w->ay;
        double mx=w->aw-box.w,my=w->ah-box.h;if(mx<0)mx=0;if(my<0)my=0;
        double px=r->wanted[0]<mx?r->wanted[0]:mx,py=r->wanted[1]<my?r->wanted[1]:my;
        if(!finite(px) || !finite(py)){rgba_pan_restore(g,r);continue;}
        int changed=!r->applied || r->offset[0]!=px || r->offset[1]!=py;
        if(changed)rgba_pan_invalidate(g,r->wid);
        if(px==0 && py==0) {
            if(rgba_pan_restore(g,r))post_evt(c->ch,EV_VIEWPORT,wid,c->ch->h.now,(u32)nonce,(u32)(nonce>>32),0,0);continue;
        }
        r->offset[0]=px;r->offset[1]=py;r->applied=1;
        put_mask(c,w,win,0,0,0);
        put_xform(c,w,1,1,w->ax-box.x+px,w->ay-box.y+py);
        put_clip(c,w,win,1,box.x,box.y,box.w,box.h);
        rgba_pan_border(g,w,win,px,py);decoration_damage(c,win);
        if(r->pending)post_evt(c->ch,EV_VIEWPORT,wid,c->ch->h.now,(u32)nonce,(u32)(nonce>>32),px,py);
        r->pending=0;
    }
}
void anim_rgba_viewport_failed(void *raw) {
    struct rgba_capture *g=raw;struct rgba_pan *p=rgba_pan_control(g);
    g->pc.engine->ch->h.version&=~CH_CAP_VIEWPORT;if(p)p->dead=1;
}
void anim_rgba_viewport_restore_at(void *raw,unsigned i) {
    struct rgba_capture *g=raw;struct rgba_pan *p=rgba_pan_control(g);
    if(p && p->rows && i<CH_NW && p->rows[i].wid)rgba_pan_restore(g,&p->rows[i]);
}
_Static_assert(RGBA_BEGIN_OFFSET+sizeof(struct rgba_begin_binding)<=RGBA_PAN_OFFSET,"viewport follows frozen Begin ledger");
_Static_assert(RGBA_PAN_OFFSET+sizeof(struct rgba_pan)<=RGBA_ORDINARY_BYTES,"viewport descriptor stays inside control");
