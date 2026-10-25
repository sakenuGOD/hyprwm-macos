// Existing ordinary surfaces may take over only before the next native window
// Update snapshots their server Context. No native Update/Present is retained.
#define RGBA_BEGIN_OFFSET 57344
#define RGBA_BEGIN_MAGIC 0x314e494745425252ULL
struct rgba_begin_source {
    u64 window,creator,birth,root,token;
    double time,issued_max;
    u64 serial,good_serial;
    u32 seed,valid;
};
struct rgba_begin_binding {
    u64 magic;u32 size,version;struct rgba_capture *capture;
    u64 returns[2],parent_return;
    u32 dead,claiming;
    u64 calls,issued,takeovers,refused;
    u64 candidate_serial,candidate_token;
    double candidate_time;
    u32 candidate_seed,candidate_slot;
    struct rgba_begin_source source[CH_NW];
};
static struct rgba_begin_binding *rgba_begin_control(struct rgba_capture *g) {
    struct rgba_begin_binding *b=(void *)((char *)g+RGBA_BEGIN_OFFSET);
    return b->magic==RGBA_BEGIN_MAGIC && b->size==sizeof(*b) && b->version==1 && b->capture==g?b:0;
}
static int rgba_begin_active(struct rgba_capture *g) {
    struct rgba_begin_binding *b=rgba_begin_control(g);
    return b && !__atomic_load_n(&b->dead,__ATOMIC_ACQUIRE);
}
static unsigned rgba_begin_index(struct rgba_capture *g,struct rgba_inplace *m) {
    u64 start=(u64)rgba_ordinary_slots(g),address=(u64)m;
    return address>=start && address<start+CH_NW*sizeof(*m) &&
        (address-start)%sizeof(*m)==0?(address-start)/sizeof(*m):CH_NW;
}
static void rgba_begin_forget(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_begin_binding *b=rgba_begin_control(g);unsigned i=rgba_begin_index(g,m);
    if(!b || i>=CH_NW)return;
    struct rgba_begin_source *s=&b->source[i];
    for(unsigned z=0;z<sizeof(*s);z++)((volatile unsigned char *)s)[z]=0;
    if(b->candidate_slot==i)b->candidate_serial=0;
}
static struct rgba_begin_source *rgba_begin_row(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_begin_binding *b=rgba_begin_control(g);unsigned i=rgba_begin_index(g,m);
    if(!b || i>=CH_NW || !m->on || !rgba_inplace_source(g,m))return 0;
    struct rgba_begin_source *s=&b->source[i];
    if(s->window!=(u64)m->window || s->creator!=m->creator || s->birth!=m->pid_version || s->root!=(u64)m->root) {
        rgba_begin_forget(g,m);s->window=(u64)m->window;s->creator=m->creator;
        s->birth=m->pid_version;s->root=(u64)m->root;
    }
    return s;
}
static int rgba_begin_takeover_ready(struct rgba_capture *g,struct rgba_inplace *m,double time) {
    struct rgba_begin_binding *b=rgba_begin_control(g);if(!b)return 1;
    unsigned i=rgba_begin_index(g,m);struct rgba_begin_source *s=rgba_begin_row(g,m);
    return !b->dead && i<CH_NW && b->claiming==i+1 && s && s->valid==1 && s->serial &&
        s->good_serial==s->serial && finite(time) && time>=s->issued_max;
}
static void rgba_begin_captured(struct rgba_capture *g,void *update) {
    struct rgba_begin_binding *b=rgba_begin_control(g);struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(!b || b->dead || !o || o->candidate>=CH_NW)return;
    b->candidate_serial=0;b->candidate_slot=o->candidate;
    struct rgba_inplace *m=&rgba_ordinary_slots(g)[o->candidate];
    struct rgba_begin_source *s=rgba_begin_row(g,m);if(!s || s->valid!=1 || !update)return;
    double time=g->api.get_time(update);u32 seed=*(u32 *)((char *)update+0xe8);
    if(s->token!=(u64)update || s->seed!=seed || s->time!=time)return;
    b->candidate_serial=s->serial;b->candidate_token=(u64)update;
    b->candidate_seed=seed;b->candidate_time=time;
}
static void rgba_begin_promoted(struct rgba_capture *g,struct rgba_inplace *m) {
    struct rgba_begin_binding *b=rgba_begin_control(g);unsigned i=rgba_begin_index(g,m);
    struct rgba_begin_source *s=b?rgba_begin_row(g,m):0;
    if(!s)return;s->good_serial=0;
    if(i==b->candidate_slot && b->candidate_serial && s->serial==b->candidate_serial &&
       s->token==b->candidate_token && s->seed==b->candidate_seed && s->time==b->candidate_time)
        s->good_serial=b->candidate_serial;
}
static int rgba_begin_wait(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w,void *win) {
    if(!rgba_begin_active(g) || m->opening || m->padding_motion || w->wait || w->cur_alpha!=1)return 0;
    if(w->held)m->settle_started=0;
    else {
        double now=g->pc.engine->ch->h.now;
        if(!m->settle_started)m->settle_started=now;
        if(now-m->settle_started>.025)return 0;
    }
    // Native configure already freezes R and owns its bounded hold. Preserve
    // those clocks while an existing source gets a chance to supply B.
    struct ctx *c=g->pc.engine;RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
    live_edge_client(c,w,0);put_plain(c,w,win);rgba_inplace_legacy(c,m,w,1);
    RGBA_LAYER_COMMIT(tx);decoration_damage(c,win);return 1;
}
static int rgba_begin_owner(struct rgba_begin_binding *b,void *outer,u64 frame,u64 *ticket) {
    if(!b || b->magic!=RGBA_BEGIN_MAGIC || b->size!=sizeof(*b) || b->version!=1 || b->dead ||
       !rgba_valid(b->capture) || !pc_main(&b->capture->pc))return 0;
    struct pc_capture *p=&b->capture->pc;
    if(!p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 bottom=top-size,address=(u64)ticket;
    if(address<bottom || address>top-6*sizeof(u64))return 0;
    u64 fp=(u64)__builtin_frame_address(0);int found=0;
    for(unsigned i=0;i<32;i++) {
        if((fp&15) || fp<bottom || fp>top-16)return 0;
        if(fp==frame){found=1;break;}
        u64 next=*(u64 *)fp;if(next<=fp)return 0;fp=next;
    }
    if(!found)return 0;
    u64 ra=pc_address((void *)((u64 *)fp)[1]);
    if(ra!=b->returns[0] && ra!=b->returns[1])return 0;
    u64 parent=*(u64 *)fp;
    if((parent&15) || parent<=fp || parent<bottom || parent>top-16 ||
       pc_address((void *)((u64 *)parent)[1])!=b->parent_return)return 0;
    u64 update=*(u64 *)parent;
    return !(update&15) && update>parent && update>=bottom+0x9c0 && update<=top-16 &&
        (u64)outer==update-0x9c0;
}
// Native CWC clipping may use the Server root's bounds even when OWN leaves
// are non-clipping. Until a drawing-only footprint is owned, never publish an
// incomplete body outside that native envelope.
static int rgba_begin_frame_fits(struct rgba_capture *g,struct rgba_inplace *m) {
    if(rgba_draw_active(g))return rgba_draw_frame_fits(g,m);
    struct ctx *c=g->pc.engine;
    struct rect4 outer=((msgb_t)c->msg)(m->server_root,c->s_bounds);
    struct rect4 body=((msgb_t)c->msg)(m->root,c->sel("frame"));
    return finite(outer.x) && finite(outer.y) && finite(outer.w) && finite(outer.h) &&
        finite(body.x) && finite(body.y) && finite(body.w) && finite(body.h) &&
        outer.w>=1 && outer.h>=1 && body.w>=1 && body.h>=1 &&
        body.x>=outer.x-.01 && body.y>=outer.y-.01 &&
        body.x+body.w<=outer.x+outer.w+.01 && body.y+body.h<=outer.y+outer.h+.01;
}
// Pure Render reads under one ContextLock; all frontend identities are resolved
// before it. Static paths cannot be changed by Update animation evaluation.
static int rgba_begin_model_complete(struct rgba_capture *g,struct rgba_inplace *m,u32 *commit) {
    struct ctx *c=g->pc.engine;char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    if(!cwc || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x80)!=m->server_root ||
       *(void **)(cwc+0x98)!=m->host || m->alpha!=1 || !m->texture)return 0;
    if(!rgba_begin_frame_fits(g,m))return 0;
    void *context=*(void **)(cwc+0x30);struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    void *front[9]={m->server_root,*(void **)(cwc+0x88),m->host,m->root,m->surface,
        m->body,m->patch[0],m->patch[1],m->patch[2]};
    u64 ids[9];for(unsigned i=0;i<9;i++){ids[i]=front[i]?v->api.layer_id(front[i]):0;if(!ids[i])return 0;}
    u32 sequence=((u32 (*)(void *,void *))c->msg)(m->context,c->sel("commitId"));
    if(!context || g->api.lock_context(context)!=0)return 0;
    char *layers[9]={0};int ready=*(u32 *)((char *)context+0x40)==sequence;
    for(unsigned i=0;i<9;i++) {
        char *handle=v->api.lookup_handle(context,ids[i],0,0,0);
        layers[i]=handle && *(void **)(handle+0x18)==context?*(char **)(handle+0x10):0;
        if(!layers[i] || *(void **)(layers[i]+0x98)!=handle || *(void **)(layers[i]+0x90))ready=0;
    }
    if(ready) {
        ready=g->api.root(context)==layers[0] &&
            rgba_inplace_render_child(layers[0],layers[1]) && rgba_inplace_render_child(layers[1],layers[2]) &&
            rgba_inplace_render_child(layers[0],layers[3]) && rgba_inplace_render_child(layers[3],layers[4]) &&
            (unsigned char)layers[2][0x24]==0;
        for(unsigned i=0;i<5;i++)if(i!=2 && ((unsigned char)layers[i][0x24]!=255 || *(void **)(layers[i]+0x78)))ready=0;
        rect local={0,0,m->current.w,m->current.h};
        if(!rgba_view_same(*(rect *)(layers[3]+0x48),local) || !rgba_view_same(*(rect *)(layers[4]+0x48),local))ready=0;
        rect boxes[4],uv[4];rgba_inplace_regions_at(m,local,boxes,uv);
        for(unsigned i=0;i<4;i++) {
            if(!rgba_inplace_region_matches(m,local,i,layers[5+i]))ready=0;
            if(boxes[i].w>0 && boxes[i].h>0 && (!rgba_inplace_render_child(layers[4],layers[5+i]) ||
                *(void **)(layers[5+i]+0x78)))ready=0;
        }
    }
    if(ready)*commit=sequence;
    g->api.unlock_context(context);return ready;
}
static void rgba_begin_restore_before_original(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w,void *win) {
    int preparing=rgba_draw_revoke(g,m);
    struct ctx *c=g->pc.engine;RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
    ((msgf_t)c->msg)(m->host,c->s_opacity,(float)m->host_opacity);((msgf_t)c->msg)(m->root,c->s_opacity,0);
    m->displayed_texture=m->displayed_bytes=0;
    for(unsigned i=0;i<4;i++)rgba_view_object(c,rgba_inplace_part(m,i),"setContents:",0);
    if(preparing){rgba_inplace_legacy(c,m,w,0);m->motion_started=0;}
    else {
        live_edge_client(c,w,0);put_plain(c,w,win);rgba_inplace_legacy(c,m,w,1);
        m->padding_motion=1;w->settling=1;
    }
    RGBA_LAYER_COMMIT(tx);m->presenting=0;rgba_draw_forget(g,m);decoration_damage(c,win);
}
void anim_rgba_begin_before(void *window,void *outer,unsigned flag,struct rgba_begin_binding *b,u64 frame,u64 *ticket) {
    if(!rgba_begin_owner(b,outer,frame,ticket))return;
    struct rgba_capture *g=b->capture;struct pc_capture *p=&g->pc;struct ctx *c=p->engine;
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct rgba_normal_binding *n=rgba_normal_binding(g);
    if(!o || !o->enabled || c->dead || c->in_cb || c->ch->h.stop || c->ch->h.now>=o->expires ||
       !rgba_normal_valid(n) || n->inflight || p->active_command || g->locked_client ||
       p->command || __atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE)!=p->command_ack ||
       o->command || __atomic_load_n(&o->sequence,__ATOMIC_ACQUIRE)!=o->ack)return;
    b->calls++;
    if(rgba_carrier_active(g))rgba_carrier_before_window(g,window,flag,frame,ticket);
    struct rgba_inplace *slots=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_inplace *m=&slots[i];if(!m->on || m->window!=window || rgba_inplace_source(g,m)!=window)continue;
        char *cwc=*(char **)((char *)window+0x18);u64 index=cwc?*(u64 *)(cwc+0x588):2;
        if(index>1 || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x80)!=m->server_root ||
           *(void **)(cwc+0x98)!=m->host)return;
        struct rgba_begin_source *s=rgba_begin_row(g,m);if(!s)return;
        ticket[0]=i+1;ticket[1]=(u64)cwc;ticket[2]=index;ticket[3]=s->serial;ticket[4]=0;ticket[5]=0;
        struct ch_win *w=slot(c->ch,m->wid,0);
        // A still records every issued Update after a possible pre-both
        // publication of its warm carrier in the first-loop scope above.
        if(rgba_carrier_active(g))return;
        if(m->presenting) {
            if(!w || !w->used || w->wid!=m->wid)return;
            if(!rgba_begin_frame_fits(g,m)){b->refused++;rgba_begin_restore_before_original(g,m,w,window);}
            else if(rgba_draw_pending(g,m)) {
                u32 commit=0;
                if(rgba_begin_model_complete(g,m,&commit))rgba_draw_claim_commit(g,m,commit);
                else {b->refused++;rgba_begin_restore_before_original(g,m,w,window);}
            }
            return;
        }
        if(!w || !w->used || !w->geo || w->geo==2 || m->opening || m->padding_motion ||
           w->wait || w->cur_alpha!=1 || !(rgba_draw_pending(g,m) || w->held || w->pos.active || w->size.active) ||
           cover_index(c,m->wid,1)>=0 || birth_holds(c,m->wid))return;
        b->claiming=i+1;
        if(o->candidate==i && p->wid==m->wid && p->stage==PC_ENCODED)anim_rgba_poll(g);
        if(o->candidate==i && p->wid==m->wid && p->stage==PC_GPU_COMPLETE)rgba_ordinary_accept(g,c->ch->h.now);
        if(!m->presenting && rgba_inplace_source(g,m)==window &&
           rgba_begin_takeover_ready(g,m,o->good_time[i]))rgba_ordinary_pose(g,m,w);
        if(m->presenting) {
            u32 commit=0;
            if(rgba_begin_model_complete(g,m,&commit)){ticket[4]=1;ticket[5]=commit;b->takeovers++;rgba_draw_claim_commit(g,m,commit);}
            else {b->refused++;rgba_begin_restore_before_original(g,m,w,window);}
        }
        b->claiming=0;return;
    }
}
void anim_rgba_begin_after(void *window,void *outer,unsigned result,struct rgba_begin_binding *b,u64 frame,u64 *ticket) {
    if(!rgba_begin_owner(b,outer,frame,ticket) || !ticket[0] || ticket[0]>CH_NW)return;
    struct rgba_capture *g=b->capture;struct rgba_inplace *m=&rgba_ordinary_slots(g)[ticket[0]-1];
    struct rgba_begin_source *s=rgba_begin_row(g,m);
    char *cwc=rgba_inplace_source(g,m)==window?*(char **)((char *)window+0x18):0;
    if(!s)return;
    if(!cwc || (u64)cwc!=ticket[1] || *(u64 *)(cwc+0x588)!=ticket[2]){s->valid=2;return;}
    if(!result)return; // Native false/occluded exits do not create a new Update.
    if(m->presenting && rgba_carrier_active(g)) {
        void *opaque=*(void **)((char *)window+0xf0),*client_opaque=*(void **)(cwc+0x5b8);
        m->native_opaque=(!opaque?1:g->api.geometry.region_empty(opaque)?2:3) |
            ((!client_opaque?1:g->api.geometry.region_empty(client_opaque)?2:3)<<2);
    }
    void *update=*(void **)(cwc+0x260+0x190*ticket[2]);if(!update){s->valid=2;return;}
    double time=g->api.get_time(update);u32 seed=*(u32 *)((char *)update+0xe8);
    if(!finite(time) || time<=0){s->valid=2;return;}
    if(s->valid==2)return;
    if(s->serial && s->token==(u64)update && s->seed==seed && s->time==time)return;
    if(s->serial==~(u64)0 || (s->serial && time<s->time)){s->valid=2;return;}
    s->serial++;s->token=(u64)update;s->seed=seed;s->time=time;
    if(time>s->issued_max)s->issued_max=time;
    s->valid=1;b->issued++;
}
void anim_rgba_begin_restore(struct rgba_begin_binding *b,u64 *ticket) {
    if(!b || b->magic!=RGBA_BEGIN_MAGIC || b->size!=sizeof(*b) || b->version!=1 ||
       !ticket || !ticket[0] || ticket[0]>CH_NW || !rgba_valid(b->capture))return;
    struct rgba_capture *g=b->capture;struct rgba_inplace *m=&rgba_ordinary_slots(g)[ticket[0]-1];
    if(!m->on || !m->presenting)return;
    if(rgba_carrier_active(g)){anim_rgba_carrier_recover(g,m);return;}
    char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    struct ch_win *w=slot(g->pc.engine->ch,m->wid,0);
    if(cwc && w && *(void **)(cwc+0x38)==m->context && *(void **)(cwc+0x98)==m->host)
        rgba_begin_restore_before_original(g,m,w,win);
}
// No cleanup under native locks or during exception unwinding. MAIN's existing
// command handler restores the ordinary source surfaces on its next safe turn.
void anim_rgba_begin_failed(struct rgba_begin_binding *b) {
    if(!b || b->magic!=RGBA_BEGIN_MAGIC || b->size!=sizeof(*b) || b->version!=1)return;
    __atomic_store_n(&b->dead,1,__ATOMIC_RELEASE);b->claiming=0;
    struct rgba_capture *g=b->capture;if(!rgba_valid(g))return;
    struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(o && o->sequence==o->ack && !o->command) {
        __atomic_store_n(&o->command,2,__ATOMIC_RELEASE);
        __atomic_store_n(&o->sequence,o->ack+1,__ATOMIC_RELEASE);
    }
}
_Static_assert(RGBA_ORDINARY_SLOTS+CH_NW*sizeof(struct rgba_inplace)<=RGBA_BEGIN_OFFSET,"begin partition follows ordinary slots");
_Static_assert(RGBA_BEGIN_OFFSET+sizeof(struct rgba_begin_binding)<=RGBA_ORDINARY_BYTES,"begin ledger partition");
