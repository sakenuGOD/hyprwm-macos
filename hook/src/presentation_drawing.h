// The original window owns ordering/input. Only temporary native display
// sources and their per-Update viewport receive the retained drawing extent.
#define RGBA_DRAW_OFFSET 11264
#define RGBA_DRAW_MAGIC 0x31474e4957415244ULL
struct rgba_draw_slot {
    u64 window,creator,birth,root;
    void *region;
    rect envelope;
    u64 epoch,viewport_epoch,viewport_state;
    rect viewport;
    u32 claimable,pad;
    u64 request,claim_request,claim_epoch;
    rect future;
    double deadline,last_receipt;
    u32 phase,claim_commit;
    rect claim_frame;
};
struct rgba_drawing {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    void *storage;struct rgba_draw_slot *slots;
    void (*damage)(void *,void *,void *);
    void (*schedule)(void *,void *);
    rect (*bounds)(void *);
    void (*layer_to_window)(struct rgba_matrix *,const void *);
    struct rgba_matrix (*concat)(const struct rgba_matrix *,const struct rgba_matrix *);
    u64 clone_return,scene_start,scene_end;
    u32 dead,pad; // pad: explicit preflight enable; rendering remains available when zero.
    u64 content,frame,viewports,sources,refused;
    u32 command_cursor,command_seen;
};
void anim_rgba_draw_failed(struct rgba_drawing *);
static struct rgba_drawing *rgba_draw_control(struct rgba_capture *g) {
    struct rgba_drawing *d=(void *)((char *)g+RGBA_DRAW_OFFSET);
    return d->magic==RGBA_DRAW_MAGIC && d->size==sizeof(*d) && d->version==1 && d->capture==g?d:0;
}
static int rgba_draw_active(struct rgba_capture *g) {return rgba_draw_control(g)!=0;}
static struct rgba_draw_slot *rgba_draw_row(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_drawing *d=rgba_draw_control(g);unsigned i=rgba_begin_index(g,m);
    return d && d->slots && i<CH_NW?&d->slots[i]:0;
}
static int rgba_draw_identity(struct rgba_capture *g,struct rgba_inplace *m,struct rgba_draw_slot *s) {
    struct rgba_drawing *d=rgba_draw_control(g);
    return d && s && s->region && s->window==(u64)m->window && s->creator==m->creator &&
        s->birth==m->pid_version && s->root==(u64)m->root && rgba_inplace_source(g,m)==m->window;
}
static rect rgba_draw_union(rect a,rect b) {
    double x=a.x<b.x?a.x:b.x,y=a.y<b.y?a.y:b.y;
    double r=a.x+a.w>b.x+b.w?a.x+a.w:b.x+b.w;
    double t=a.y+a.h>b.y+b.h?a.y+a.h:b.y+b.h;
    return (rect){x,y,r-x,t-y};
}
static void rgba_draw_receipt(struct rgba_capture *g,struct rgba_inplace *m,u64 request,unsigned state) {
    if(request)post_evt(g->pc.engine->ch,EV_ORDINARY,m->wid,g->pc.engine->ch->h.now,
        (u32)request,(u32)(request>>32),state,1);
}
static int rgba_draw_pending(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    return rgba_draw_identity(g,m,s) && s->request && (s->phase==1 || s->phase==2) &&
        rgba_draw_control(g)->pad && g->pc.engine->ch->h.now<s->deadline;
}
static int rgba_draw_revoke(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    if(!s || !s->request)return 0;
    s->phase=3;s->claim_request=0;return 1;
}
static void rgba_draw_forget(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);if(!s)return;
    u64 request=s->request;
    if(s->region) {
        struct rgba_drawing *d=rgba_draw_control(g);
        d->damage(0,0,s->region);d->schedule(0,0);g->api.geometry.release_cf(s->region);
    }
    for(unsigned j=0;j<sizeof(*s);j++)((volatile unsigned char *)s)[j]=0;
    // Callers have committed H1 before retiring the drawing footprint.
    rgba_draw_receipt(g,m,request,2);
}
static void rgba_draw_finish_drop(struct rgba_capture *g) {
    struct rgba_drawing *d=rgba_draw_control(g);if(!d)return;
    if(!d->slots){if(d->storage)g->pc.release_obj(d->storage);d->storage=0;return;}
    for(unsigned i=0;i<CH_NW;i++)if(d->slots[i].region)return;
    g->pc.release_obj(d->storage);d->slots=0;d->storage=0;
}
static int rgba_draw_prepare(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w,rect target) {
    struct rgba_drawing *d=rgba_draw_control(g);struct ctx *c=g->pc.engine;
    if(!d || d->dead || !rgba_inplace_source(g,m) || !rgba_view_rect(target) ||
       !d->damage || !d->schedule || !d->bounds || !d->layer_to_window || !d->concat)return 0;
    char *win=(char *)m->window,*cwc=*(char **)(win+0x18);
    if(!cwc || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x80)!=m->server_root ||
       *(void **)(cwc+0x70) || *(void **)(cwc+0x78) || *(u32 *)(cwc+0x150) || *(u32 *)(cwc+0x154) ||
       (*(void **)(win+0x878) && !(win[0x92c]&16)))return 0;
    // Keep the native Server root and its input-affecting clip unmodified.
    if(((unsigned char (*)(void *,void *))c->msg)(m->server_root,c->sel("masksToBounds")))return 0;
    if(!d->slots) {
        void *data=((void *(*)(void *,void *,u64))c->msg)(c->cls("NSMutableData"),c->sel("dataWithLength:"),CH_NW*sizeof(*d->slots));
        if(!data)return 0;d->storage=g->pc.retain_obj(data);d->slots=rgba_view_get(c,data,"mutableBytes");
        if(!d->slots){g->pc.release_obj(d->storage);d->storage=0;return 0;}
    }
    struct rgba_draw_slot *s=rgba_draw_row(g,m);if(!s)return 0;
    double inset=SH_E+c->ch->deco.width;
    rect start={w->pos.b[0],w->pos.b[1],w->size.b[0],w->size.b[1]};
    rect goal={w->pos.g[0],w->pos.g[1],w->size.g[0],w->size.g[1]};
    // Spring state need not retain a valid start after a warp.
    if(!rgba_view_rect(start))start=m->current;
    if(!rgba_view_rect(start) || !rgba_view_rect(goal) || !finite(inset) || inset<0 || inset>512)return 0;
    rect both=rgba_draw_union(rgba_draw_union(start,goal),target);
    struct rgba_draw_slot *pending=rgba_draw_row(g,m);
    if(pending && pending->request && (pending->phase==1 || pending->phase==2) &&
       rgba_view_rect(pending->future))both=rgba_draw_union(both,pending->future);
    rect envelope={both.x-both.w*.125-inset,both.y-both.h*.125-inset,both.w*1.25+2*inset,both.h*1.25+2*inset};
    if(!rgba_view_rect(envelope))return 0;
    if(rgba_draw_identity(g,m,s) && rgba_view_contains(s->envelope,envelope))return 1;
    // Preserve the previous extent through the next redraw, including retargets.
    if(rgba_draw_identity(g,m,s))envelope=rgba_draw_union(envelope,s->envelope);
    if(!rgba_view_rect(envelope))return 0;
    void *region=c->rgn(envelope);if(!region)return 0;
    void *old=s->region;
    s->window=(u64)m->window;s->creator=m->creator;s->birth=m->pid_version;s->root=(u64)m->root;
    s->region=region;s->envelope=envelope;s->epoch++;s->viewport_state=0;
    if(old)g->api.geometry.release_cf(old);
    return 1;
}
static void rgba_draw_claim_commit(struct rgba_capture *g,struct rgba_inplace *m,u32 commit) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    if(rgba_draw_pending(g,m) && s->phase==1 && rgba_draw_ready(g,m,m->current,0)) {
        struct ctx *c=g->pc.engine;
        struct rect4 frame=((msgb_t)c->msg)(m->root,c->sel("frame"));
        s->claim_frame=(rect){frame.x,frame.y,frame.w,frame.h};
        if(!rgba_view_rect(s->claim_frame) || dabs(frame.w-m->current.w)>.01 || dabs(frame.h-m->current.h)>.01)return;
        s->claim_request=s->request;s->claim_epoch=s->epoch;s->claim_commit=commit;
    }
}
static int rgba_draw_static_layer(char *layer) {
    if(!layer || *(void **)(layer+0x90))return 0;
    char *ext=*(char **)(layer+0x88);
    if(!ext)return (*(u64 *)(layer+0x30)&(1ULL<<24))!=0;
    return !*(void **)(ext+0x10) && !*(void **)(ext+0x18) &&
        *(double *)(ext+0xc0)==0 && *(double *)(ext+0xc8)==0 &&
        *(double *)(ext+0xd0)==0 && *(double *)(ext+0xd8)==0;
}
// Called only under the observer's existing Render::ContextLock. The same
// static commit and exact actual surface object prove placement even when
// native preparation elides its empty OWN parent container LayerNode.
static int rgba_draw_model_adopted(struct rgba_capture *g,struct rgba_inplace *m,void *context,u32 commit,
                                   void *root_handle,void *surface_handle,void *server_handle,void *actual_surface) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    struct rgba_drawing *d=rgba_draw_control(g);
    // Caller validated native identity before locking. No by_id, ObjC, CF
    // or another ContextLock is permitted in this pure locked check.
    if(!d || !d->pad || !s || !s->request || s->phase!=1 ||
       s->window!=(u64)m->window || s->creator!=m->creator || s->birth!=m->pid_version ||
       s->root!=(u64)m->root || !s->region || g->pc.engine->ch->h.now>=s->deadline)return 0;
    unsigned failed=0;
    if(s->claim_request!=s->request || s->claim_epoch!=s->epoch || s->claim_commit!=commit ||
       *(u32 *)((char *)context+0x40)!=commit)failed|=2;
    char *handles[3]={server_handle,root_handle,surface_handle},*layers[3]={0};
    for(unsigned i=0;i<3;i++) {
        if(!handles[i] || *(void **)(handles[i]+0x18)!=context){failed|=1;continue;}
        layers[i]=*(char **)(handles[i]+0x10);
        if(!layers[i] || *(void **)(layers[i]+0x98)!=handles[i])failed|=1;
    }
    if(!failed) {
        if(layers[2]!=actual_surface)failed|=4;
        if(!rgba_inplace_render_child(layers[0],layers[1]) || !rgba_inplace_render_child(layers[1],layers[2]))failed|=8;
        if(*(void **)(layers[0]+0x90))failed|=16;
        if(!rgba_draw_static_layer(layers[1]) || !rgba_draw_static_layer(layers[2]))failed|=64;
        rect local={0,0,s->claim_frame.w,s->claim_frame.h};
        double px=*(double *)(layers[1]+0x38),py=*(double *)(layers[1]+0x40);
        if(!rgba_view_rect(s->claim_frame) || !rgba_view_same(*(rect *)(layers[1]+0x48),local) ||
           !rgba_view_same(*(rect *)(layers[2]+0x48),local) ||
           !finite(px) || !finite(py) || !(dabs(px-s->claim_frame.x)<=.01) || !(dabs(py-s->claim_frame.y)<=.01) ||
           *(double *)(layers[2]+0x38)!=0 || *(double *)(layers[2]+0x40)!=0)failed|=32;
    }
    m->native_opaque=failed;return !failed;
}
static void rgba_draw_adopted(struct rgba_capture *g,struct rgba_inplace *m,u32 commit,int placement_proven) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    if(!placement_proven || !m->presenting || !rgba_draw_pending(g,m) || s->phase!=1 ||
       s->claim_request!=s->request || s->claim_epoch!=s->epoch || s->claim_commit!=commit ||
       !rgba_draw_ready(g,m,m->current,0))return;
    s->phase=2;s->last_receipt=g->pc.engine->ch->h.now;rgba_draw_receipt(g,m,s->request,1);
}
static void rgba_draw_commands(struct ctx *c) {
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!rgba_valid(g) || g->pc.engine!=c || !pc_main(&g->pc) || c->in_cb || c->dead || !c->ch ||
       c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=sizeof(struct ch) || c->ch->h.stop)return;
    struct rgba_drawing *d=rgba_draw_control(g);struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(!d || d->dead || !o || !o->enabled || c->ch->h.now>=o->expires) {
        c->ch->h.version&=~CH_CAP_ORDINARY_PREPARE;return;
    }
    if(d->pad)c->ch->h.version|=CH_CAP_ORDINARY_PREPARE;
    else c->ch->h.version&=~CH_CAP_ORDINARY_PREPARE;
    struct rgba_inplace *all=rgba_ordinary_slots(g);
    if(d->slots)for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_draw_slot *s=&d->slots[i];
        if(s->request && (!d->pad || c->ch->h.now>=s->deadline)){s->phase=3;s->claim_request=0;}
        if(s->phase==2 && all[i].presenting && s->claim_request==s->request && s->claim_epoch==s->epoch &&
           rgba_draw_ready(g,&all[i],all[i].current,0) && c->ch->h.now-s->last_receipt>=.05) {
            s->last_receipt=c->ch->h.now;rgba_draw_receipt(g,&all[i],s->request,1);
        }
        if(s->phase==3 && !all[i].presenting)rgba_draw_forget(g,&all[i]);
    }
    u32 head=__atomic_load_n(&c->ch->h.cmd_head,__ATOMIC_ACQUIRE),tail=c->ch->h.cmd_tail;
    if(head-tail>CH_NCMD)return;
    u32 cursor=d->command_cursor;
    if(!d->command_seen || cursor-tail>head-tail)cursor=tail;
    d->command_seen=1;d->command_cursor=head;
    for(u32 at=cursor;at!=head;at++) {
        const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
        int found=0;
        for(unsigned i=0;i<CH_NW;i++)if(all[i].on && all[i].wid==k->wid) {
            found=1;
            struct rgba_inplace *m=&all[i];struct rgba_draw_slot *s=rgba_draw_row(g,m);
            if(k->op==OP_GEOM || k->op==OP_WARP || k->op==OP_FORGET || k->op==OP_SPACE) {
                if(s && s->request){s->request=s->claim_request=0;s->phase=0;}
                continue;
            }
            if(k->op!=OP_EDGE || k->flags!=CH_ORDINARY_PREPARE)continue;
            u64 request=(u64)k->pad0|((u64)k->pad1<<32);
            if(!request || k->cpos>1)continue;
            if(!k->cpos) {
                if(s && s->request==request){s->phase=3;s->claim_request=0;}
                else rgba_draw_receipt(g,m,request,2);
                continue;
            }
            if(!d->pad){rgba_draw_receipt(g,m,request,3);continue;}
            rect future={k->x,k->y,k->w,k->h};struct ch_win *w=slot(c->ch,k->wid,0);
            if(!w || !w->used || !w->geo || w->geo==2 || w->held || w->wait || w->pos.active ||
               w->size.active || w->alpha.active || w->cur_alpha!=1 || m->opening || m->padding_motion ||
               birth_holds(c,k->wid) || cover_index(c,k->wid,1)>=0 || !rgba_view_rect(future) ||
               !rgba_inplace_source(g,m)) {rgba_draw_receipt(g,m,request,3);continue;}
            if(s && s->request) {
                if(s->request==request)continue;
                rgba_draw_receipt(g,m,request,3);continue;
            }
            rect current={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
            if(!rgba_draw_prepare(g,m,w,current)){rgba_draw_receipt(g,m,request,3);continue;}
            s=rgba_draw_row(g,m);s->request=request;s->phase=1;s->future=future;s->deadline=c->ch->h.now+1;
            s->claim_request=0;s->claim_commit=0;
            rgba_draw_damage(g,m);o->next_capture=0;c->sched_win(0,m->window);
        }
        if(!found && k->op==OP_EDGE && k->flags==CH_ORDINARY_PREPARE && k->cpos<=1 && (k->pad0 || k->pad1))
            post_evt(c->ch,EV_ORDINARY,k->wid,c->ch->h.now,k->pad0,k->pad1,k->cpos?3:2,1);
    }
}
void anim_rgba_draw_commands(void *context) {rgba_draw_commands(context);}
void anim_rgba_draw_commands_abort(void *context) {
    struct ctx *c=context;struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!rgba_valid(g) || g->pc.engine!=c)return;
    c->ch->h.version&=~CH_CAP_ORDINARY_PREPARE;
    anim_rgba_draw_failed(rgba_draw_control(g));
}
static int rgba_draw_frame_fits(struct rgba_capture *g,struct rgba_inplace *m) {
    struct ctx *c=g->pc.engine;
    if(!rgba_draw_ready(g,m,m->current,0))return 0;
    return !((unsigned char (*)(void *,void *))c->msg)(m->server_root,c->sel("masksToBounds"));
}
static int rgba_draw_ready(struct rgba_capture *g,struct rgba_inplace *m,rect target,int publish) {
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    if(!rgba_draw_identity(g,m,s) || !rgba_view_contains(s->envelope,target) || !s->viewport_state ||
       s->viewport_epoch!=s->epoch || ((publish || !m->presenting) && !s->claimable))return 0;
    char *cwc=*(char **)((char *)m->window+0x18);u64 index=*(u64 *)(cwc+0x588);
    if(index>1 || s->viewport_state!=(u64)(cwc+0x260+0x190*index))return 0;
    return rgba_view_same(*(rect *)(s->viewport_state+0x78),s->viewport);
}
static void rgba_draw_damage(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_drawing *d=rgba_draw_control(g);struct rgba_draw_slot *s=rgba_draw_row(g,m);
    if(!d || !s || !s->region)return;
    d->damage(0,0,s->region);d->schedule(0,0);
}
// Every dereferenced frame belongs to this MAIN stack. The generator and
// ingestion prefixes each have one exact normal display caller; captures use
// other callsites even when their inner getter return PC is identical.
static int rgba_draw_scope(struct rgba_capture *g,u64 frame,unsigned kind,void *outer,void *transaction,int continuity) {
    struct rgba_drawing *d=rgba_draw_control(g);struct rgba_carrier *b=rgba_carrier_control(g);struct pc_capture *p=&g->pc;
    if(!d || (!continuity && d->dead) || !b || !b->depth || (!continuity && b->depth!=1) ||
       !pc_main(p) || !p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 low=top-size,fp=(u64)__builtin_frame_address(0);unsigned found=0;
    for(unsigned j=0;j<32;j++) {
        if((fp&15) || fp<low || fp>top-16)return 0;
        if(fp==frame){found=1;break;}u64 next=*(u64 *)fp;if(next<=fp)return 0;fp=next;
    }
    if(!found)return 0;
    u64 ra=pc_address((void *)((u64 *)fp)[1]),parent=*(u64 *)fp;
    if((parent&15) || parent<=fp || parent<low || parent>top-16)return 0;
    u64 update=*(u64 *)parent;
    if((update&15) || update<=parent || update<low+0xb88 || update>top-16)return 0;
    if(kind<2) {
        if(ra!=b->slide+(kind?0x186e19584ULL:0x186e194e0ULL) ||
           pc_address((void *)((u64 *)parent)[1])!=b->slide+0x186e13244ULL)return 0;
        char *redraw=(char *)(update-0xb40);
        if(redraw[0x93] || *(int *)(redraw+0xa0) || *(int *)(redraw+0xa4))return 0;
    }else if(ra!=b->slide+0x186e16998ULL ||
             pc_address((void *)((u64 *)parent)[1])!=b->slide+0x186e1058cULL ||
             (u64)outer!=update-0x9c0 || (u64)transaction!=parent-0x120)return 0;
    if(pc_address((void *)((u64 *)update)[1])!=d->clone_return)return 0;
    u64 clone=*(u64 *)update;
    if((clone&15) || clone<=update || clone<low || clone>top-16)return 0;
    ra=pc_address((void *)((u64 *)clone)[1]);
    if(ra<d->scene_start || ra>=d->scene_end)return 0;
    fp=*(u64 *)clone;unsigned scheduler=0;
    for(unsigned j=0;j<256;j++) {
        if((fp&15) || fp<=clone || fp<low || fp>top-16)return 0;
        u64 native=pc_address((void *)((u64 *)fp)[1])-b->slide;
        if(!continuity && ((native>=0x186e0f158ULL && native<0x186e2e830ULL) ||
           (native>=0x186d9b2fcULL && native<0x186d9b818ULL) ||
           (native>=0x18710d5bcULL && native<0x18710ebecULL)))return 0;
        if(native==0x186f93a44ULL || native==0x186f9506cULL)scheduler++;
        u64 next=*(u64 *)fp;if(!next)return continuity || scheduler==1;if(next<=fp)return 0;fp=next;
    }
    return 0;
}
static struct rgba_inplace *rgba_draw_window(struct rgba_capture *g,void *window) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct rgba_drawing *d=rgba_draw_control(g);
    if(!d || !o || g->destroyed)return 0;
    struct rgba_inplace *all=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++)if(all[i].on && all[i].window==window &&
        rgba_draw_identity(g,&all[i],rgba_draw_row(g,&all[i])) &&
        (all[i].presenting || (!d->dead && o->enabled && !g->quarantined && g->pc.engine->ch->h.now<o->expires)))return &all[i];
    return 0;
}
void *anim_rgba_draw_shape(void *window,unsigned flag,struct rgba_drawing *d,u64 frame,unsigned kind) {
    if(!d || d->magic!=RGBA_DRAW_MAGIC || kind>1 || flag || !rgba_valid(d->capture))return 0;
    struct rgba_capture *g=d->capture;
    struct rgba_inplace *m=rgba_draw_window(g,window);if(!m || !m->presenting)return 0;
    if(!rgba_draw_scope(g,frame,kind,0,0,1))return 0;
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    void *out=g->api.geometry.retain_cf(s->region);
    if(out){if(kind)d->frame++;else d->content++;}return out;
}
void anim_rgba_draw_release(struct rgba_drawing *d,void *region) {
    if(region)d->capture->api.geometry.release_cf(region);
}
void anim_rgba_draw_ingest_before(void *window,void *outer,void *transaction,struct rgba_drawing *d,u64 frame,u64 *ticket) {
    if(!d || d->magic!=RGBA_DRAW_MAGIC || !rgba_valid(d->capture))return;
    struct rgba_capture *g=d->capture;if(!pc_main(&g->pc))return;
    struct rgba_inplace *m=rgba_draw_window(g,window);if(!m)return;
    rgba_draw_row(g,m)->viewport_state=0;
    if(!rgba_draw_scope(g,frame,2,outer,transaction,m->presenting))return;
    char *cwc=*(char **)((char *)window+0x18);u64 index=*(u64 *)(cwc+0x588);
    if(index>1 || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x80)!=m->server_root)return;
    ticket[0]=(u64)cwc;ticket[1]=index;ticket[2]=(u64)m->context;ticket[3]=(u64)m->server_root;
    ticket[4]=rgba_draw_scope(g,frame,2,outer,transaction,0);
}
void anim_rgba_draw_ingested(void *window,void *outer,void *transaction,struct rgba_drawing *d,u64 frame,u64 *ticket) {
    if(!d || d->magic!=RGBA_DRAW_MAGIC || !rgba_valid(d->capture))return;
    struct rgba_capture *g=d->capture;
    struct rgba_inplace *m=rgba_draw_window(g,window);if(!m)return;
    if(!rgba_draw_scope(g,frame,2,outer,transaction,m->presenting))return;
    char *win=window,*cwc=*(char **)(win+0x18);u64 index=*(u64 *)(cwc+0x588);
    u64 old_index=ticket[1];
    if((u64)cwc!=ticket[0] || (u64)m->context!=ticket[2] || (u64)m->server_root!=ticket[3] ||
       old_index>1 || index!=(old_index^1) || *(u64 *)(cwc+0x580)!=old_index ||
       *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x80)!=m->server_root ||
       (*(void **)(win+0x878) && !(win[0x92c]&16)))return;
    char *state=cwc+0x260+0x190*index;
    if(*(void **)state || *(void **)(state+8))return;
    rect native=*(rect *)(state+0x78);if(!rgba_view_rect(native))return;
    rect e=rgba_draw_row(g,m)->envelope;
    // The native matrix maps screen coordinates into the window. During
    // translation its visual origin differs from the final frame shape.
    // Use that current mapping before the native window-to-layer conversion.
    double *matrix=(double *)(win+0x498);
    for(unsigned j=0;j<16;j++) {
        if(!finite(matrix[j]))return;
        if(j!=12 && j!=13 && dabs(matrix[j]-(j%5==0?1:0))>1e-6)return;
    }
    rect local={e.x+matrix[12],e.y+matrix[13],e.w,e.h};
    struct rgba_matrix transform;d->layer_to_window(&transform,win);
    transform=g->api.geometry.invert(&transform);
    int identity=1;
    for(unsigned j=0;j<16;j++)if(matrix[j]!=(j%5==0?1:0))identity=0;
    if(!identity)transform=d->concat(&transform,(struct rgba_matrix *)(cwc+0x1d0));
    rect extent=g->api.geometry.apply_rect(&transform,local);
    rect full=rgba_draw_union(native,extent);
    if(!rgba_view_rect(extent) || !rgba_view_rect(full))return;
    *(rect *)(state+0x78)=full;
    struct rgba_draw_slot *s=rgba_draw_row(g,m);
    s->viewport=full;s->viewport_state=(u64)state;s->viewport_epoch=s->epoch;s->claimable=ticket[4];d->viewports++;
}
void anim_rgba_draw_failed(struct rgba_drawing *d) {
    if(!d || d->magic!=RGBA_DRAW_MAGIC)return;d->dead=1;
    if(rgba_valid(d->capture))anim_rgba_carrier_failed(d->capture);
}
// A geometry prepass owns no client ContextLock. In particular, nested native
// display preparation must never release the outer capture's lock on failure.
void anim_rgba_normal_before_abort(struct rgba_normal_binding *n) {
    if(!n || n->magic!=RGBA_NORMAL_MAGIC || !rgba_valid(n->capture))return;
    anim_rgba_draw_failed(rgba_draw_control(n->capture));
}
static void rgba_draw_recover_at(struct rgba_capture *g,unsigned i) {
    if(i>=CH_NW)return;struct rgba_inplace *m=&rgba_ordinary_slots(g)[i];
    char *win=m->on && m->presenting?rgba_inplace_source(g,m):0;
    struct ch_win *w=win?slot(g->pc.engine->ch,m->wid,0):0;
    if(w)rgba_begin_restore_before_original(g,m,w,win);
}
struct rgba_draw_scene_scope {struct rgba_carrier *b;struct rgba_begin_binding *begin;};
static void rgba_draw_scene_cleanup(struct rgba_draw_scene_scope *scope) {
    scope->b->preparing=0;if(scope->begin)scope->begin->claiming=0;
}
static void rgba_draw_scene_before(struct rgba_capture *g) {
    struct rgba_carrier *b=rgba_carrier_control(g);struct rgba_drawing *d=rgba_draw_control(g);
    struct ctx *c=g->pc.engine;struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(!b || b->version!=2 || !d || b->depth || b->preparing || !c || c->in_cb || !o || !rgba_carrier_stack(g,0))return;
    struct rgba_begin_binding *begin=rgba_begin_control(g);struct rgba_normal_binding *n=rgba_normal_binding(g);
    struct rgba_draw_scene_scope cleanup __attribute__((cleanup(rgba_draw_scene_cleanup)))={b,begin};
    b->preparing=1;b->passes++;
    struct rgba_inplace *all=rgba_ordinary_slots(g);
    if(b->dead || d->dead || !o->enabled || c->dead || c->ch->h.stop || c->ch->h.now>=o->expires) {
        for(unsigned i=0;i<CH_NW;i++)rgba_draw_recover_at(g,i);return;
    }
    // Prepare a viewport before native ingestion, including an existing source
    // whose GPU frame may become claimable at the later first Begin.
    for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_inplace *m=&all[i];if(!m->on)continue;
        struct ch_win *w=slot(c->ch,m->wid,0);
        if(!w || !(m->presenting || rgba_draw_pending(g,m) || w->held || w->pos.active || w->size.active))continue;
        rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        if(!rgba_draw_prepare(g,m,w,target) && m->presenting)rgba_draw_recover_at(g,i);
    }
    if(n && !n->inflight && begin && !begin->dead && !g->quarantined && !g->locked_client &&
       !g->pc.active_command && !o->command && o->sequence==o->ack) {
        // Warm close's OWN local context before this native scene snapshots
        // windows. pending1 remains Source0 until native close confirmation.
        rgba_close_tick(g,c->ch->h.now);
        if(o->candidate<CH_NW && g->pc.stage==PC_ENCODED)anim_rgba_poll(g);
        if(o->candidate<CH_NW && all[o->candidate].on && g->pc.stage==PC_GPU_COMPLETE) {
            begin->claiming=o->candidate+1;rgba_ordinary_accept(g,c->ch->h.now);begin->claiming=0;
        }
        for(unsigned i=0;i<CH_NW;i++)if(all[i].on && !all[i].presenting) {
            struct rgba_begin_source *source=rgba_begin_row(g,&all[i]);
            if(!source || source->valid!=1 || !source->serial || source->good_serial!=source->serial)continue;
            struct ch_win *w=slot(c->ch,all[i].wid,0);if(!w)continue;
            begin->claiming=i+1;rgba_ordinary_pose(g,&all[i],w);begin->claiming=0;
            if(all[i].presenting) {
                u32 commit=0;
                if(rgba_begin_model_complete(g,&all[i],&commit)){begin->takeovers++;rgba_draw_claim_commit(g,&all[i],commit);}
                else rgba_draw_recover_at(g,i);
            }
        }
    }
    for(unsigned i=0;i<CH_NW;i++)if(all[i].on && all[i].presenting) {
        struct rgba_draw_slot *s=rgba_draw_row(g,&all[i]);
        if(!rgba_draw_identity(g,&all[i],s)){rgba_draw_recover_at(g,i);continue;}
        d->damage(0,0,s->region);
        void *native=*(void **)((char *)all[i].window+0x170);if(native)d->damage(0,0,native);
    }
}
struct rgba_draw_normal_scope {struct rgba_normal_binding *binding;u64 inflight;};
static void rgba_draw_normal_cleanup(struct rgba_draw_normal_scope *scope) {scope->binding->inflight=scope->inflight;}
void anim_rgba_normal_before(void *compositor,void *head,void *destination,void **shape,
                             struct rgba_normal_binding *n,u64 frame) {
    if(!n || n->magic!=RGBA_NORMAL_MAGIC || n->size!=sizeof(*n) || n->version!=1 ||
       !rgba_valid(n->capture) || n->capture->destroyed || !rgba_draw_active(n->capture))return;
    struct rgba_capture *g=n->capture;struct rgba_drawing *d=rgba_draw_control(g);
    if(!pc_main(&g->pc))return;
    struct rgba_draw_normal_scope cleanup __attribute__((cleanup(rgba_draw_normal_cleanup)))={n,n->inflight};
    n->inflight=1;
    struct rgba_normal_scope scope={n,compositor,head,destination,0,shape,frame,n->calls};
    if(!rgba_normal_frame_owner(&g->pc,&scope,1))return;
    char *stack[256],*seen[256];unsigned pending=1,count=0;stack[0]=head;
    while(pending) {
        char *s=stack[--pending];if(!s)continue;
        for(unsigned j=0;j<count;j++)if(seen[j]==s){rgba_close_block_tree(g,head);return;}
        if(count==256){rgba_close_block_tree(g,head);return;}seen[count++]=s;
        if(*(void **)s){if(pending==256){rgba_close_block_tree(g,head);return;}stack[pending++]=*(void **)s;}
        if(*(void **)(s+0x10)){if(pending==256){rgba_close_block_tree(g,head);return;}stack[pending++]=*(void **)(s+0x10);}
    }
    rgba_normal_close_gate(g,(void **)seen,count,!cleanup.inflight && !g->locked_client);
    char *dest=destination;
    int x=*(int *)(dest+0x2c),y=*(int *)(dest+0x30),right=*(int *)(dest+0x34),bottom=*(int *)(dest+0x38);
    rect canvas={x,y,(double)right-x,(double)bottom-y};if(!rgba_view_rect(canvas))return;
    // Validate the entire original-link graph before changing any source.
    for(unsigned j=0;j<count;j++) {
        char *s=seen[j];if(*(u32 *)(s+0x180)!=10)continue;
        char *meta=*(char **)(s+0x48);if(!meta || *(void **)(meta+8))continue;
        struct rgba_inplace *m=rgba_draw_window(g,*(void **)meta);if(!m || !m->presenting)continue;
        char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
        u64 index=cwc?*(u64 *)(cwc+0x588):2;
        if(index>1 || *(u32 *)(s+0x268)!=m->wid || *(u32 *)(meta+0x28)!=*(u32 *)(cwc+0x40) ||
           *(void **)(s+0x28)!=*(void **)(meta+0x10) || *(void **)(s+0x30)!=*(void **)(meta+0x10) ||
           *(void **)(meta+0x10)!=*(void **)(cwc+0x260+0x190*index))continue;
        unsigned matches=0;
        for(unsigned k=0;k<count;k++)if(*(u32 *)(seen[k]+0x180)==10 && *(u32 *)(seen[k]+0x268)==m->wid)matches++;
        if(matches!=1 || !*(void **)(s+0x1a0) || *(void **)(s+0x248) || *(void **)(s+0x250))continue;
        struct rgba_draw_slot *row=rgba_draw_row(g,m);
        void *region=g->api.geometry.retain_cf(row->region);
        void *clip=*(void **)(win+0x110);
        if(clip) {
            void *next=g->api.geometry.intersection(region,clip);g->api.geometry.release_cf(region);region=next;
        }
        void *canvas_region=g->pc.engine->rgn(canvas);
        if(!canvas_region){if(region)g->api.geometry.release_cf(region);continue;}
        void *clipped=g->api.geometry.intersection(region,canvas_region);
        if(region)g->api.geometry.release_cf(region);g->api.geometry.release_cf(canvas_region);region=clipped;
        if(!region)continue;
        rect bounds=d->bounds(region);
        if(!rgba_view_rect(bounds)){g->api.geometry.release_cf(region);continue;}
        int left=(int)rgba_floor(bounds.x),top=(int)rgba_floor(bounds.y);
        int last_x=(int)(-rgba_floor(-bounds.x-bounds.w))-1,last_y=(int)(-rgba_floor(-bounds.y-bounds.h))-1;
        void *old=*(void **)(s+0x1a0);
        *(void **)(s+0x1a0)=region; // +1 ownership moves to native source cleanup.
        *(int *)(s+0x50)=left;*(int *)(s+0x54)=last_x;*(int *)(s+0x58)=top;*(int *)(s+0x5c)=last_y;
        g->api.geometry.release_cf(old);d->sources++;
    }
}
_Static_assert(RGBA_CARRIER_OFFSET+sizeof(struct rgba_carrier)<=RGBA_DRAW_OFFSET,"drawing follows scene control");
_Static_assert(RGBA_DRAW_OFFSET+sizeof(struct rgba_drawing)<=RGBA_NORMAL_OFFSET,"drawing control partition");
