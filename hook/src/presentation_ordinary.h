// One bounded producer feeds per-window retained good/retiring textures.
// The existing MAIN timer owns retirement and the animation clock. A bounded
// MAIN completion callback may publish finished pixels between its samples.
#define RGBA_ORDINARY_OFFSET 12800
#define RGBA_ORDINARY_SLOTS 16384
#define RGBA_ORDINARY_BYTES 65536
#define RGBA_ORDINARY_TEXTURE_BUDGET (256ULL*1024*1024)
#define RGBA_ORDINARY_RENDER_BYTES (128ULL*1024*1024)
#define RGBA_ORDINARY_RENDER_FRAMES 32
#define RGBA_ORDINARY_MAGIC 0x315952414e494452ULL
struct rgba_ordinary {
    u64 magic;u32 size,version;
    struct rgba_capture *capture;
    u64 command,sequence,ack;
    u32 enabled,cursor,candidate,reason;
    double expires,next_capture,started;
    u64 promoted,refused,retries;
    double seen[CH_NW];
    u64 renderer_bytes,renderer_frames,renderer_recycles,budget_refusals;
    void *candidate_color;
    u64 retry_successes;
    u64 capture_generation;double capture_time,good_time[CH_NW],native_time[CH_NW];
    u32 completion_queued,completion_polls;double completion_deadline;
    u64 fast_promoted,completion_generation;
};
static struct rgba_ordinary *rgba_ordinary_control(struct rgba_capture *g) {
    struct rgba_ordinary *o=(void *)((char *)g+RGBA_ORDINARY_OFFSET);
    return o->magic==RGBA_ORDINARY_MAGIC && o->size==sizeof(*o) && o->version==1 && o->capture==g?o:0;
}
static struct rgba_inplace *rgba_ordinary_slots(struct rgba_capture *g) {return (void *)((char *)g+RGBA_ORDINARY_SLOTS);}
static int rgba_ordinary_drop(struct rgba_capture *g) {
    if(!rgba_pan_drop(g))return 0;
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o)return 1;o->enabled=0;
    g->pc.engine->ch->h.version&=~CH_CAP_ORDINARY_PREPARE;
    int closed=rgba_close_drop(g);
    if(o->candidate_color){g->api.geometry.release_cf(o->candidate_color);o->candidate_color=0;}
    struct rgba_inplace *slots=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++)if(slots[i].on || slots[i].texture || slots[i].root)
        if(!rgba_inplace_drop_slot(g,&slots[i]))closed=0;
    if(closed)rgba_carrier_finish_drop(g);return closed;
}
static int rgba_ordinary_capture_budget(struct rgba_capture *g) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o || !o->enabled)return 1;
    u64 bytes=g->domain.pixel_width*g->domain.pixel_height*4+rgba_close_bytes(g)+rgba_carrier_bytes(g);
    struct rgba_inplace *slots=rgba_ordinary_slots(g);
    for(unsigned i=0;i<=CH_NW;i++) {
        struct rgba_inplace *m=i==CH_NW?rgba_inplace_control(g):&slots[i];if(!m)continue;
        if(m->texture)bytes+=(u64)m->pixel_w*m->pixel_h*4;
        if(m->retiring_texture && m->retiring_texture!=m->texture)
            bytes+=(u64)m->retiring_pixel_w*m->retiring_pixel_h*4;
        if(m->displayed_texture && m->displayed_texture!=(u64)m->texture &&
           m->displayed_texture!=(u64)m->retiring_texture)bytes+=m->displayed_bytes;
        if(m->accepted.texture && m->accepted.texture!=m->texture && m->accepted.texture!=m->retiring_texture &&
           (u64)m->accepted.texture!=m->displayed_texture)
            bytes+=(u64)m->accepted.pixel_width*m->accepted.pixel_height*4;
        if(bytes>RGBA_ORDINARY_TEXTURE_BUDGET){o->budget_refusals++;return 0;}
    }
    if(bytes>RGBA_ORDINARY_TEXTURE_BUDGET){o->budget_refusals++;return 0;}
    return 1;
}
static void rgba_ordinary_evict_idle(struct rgba_capture *g) {
    struct rgba_inplace *slots=rgba_ordinary_slots(g),*oldest=0;
    for(unsigned i=0;i<CH_NW;i++)if(slots[i].on && !slots[i].presenting && slots[i].wid!=g->pc.wid &&
       (!oldest || slots[i].last_used<oldest->last_used))oldest=&slots[i];
    if(oldest)rgba_inplace_drop_slot(g,oldest);
}
static int rgba_ordinary_reset(struct rgba_capture *g) {
    struct rgba_normal_binding *n=rgba_normal_binding(g);
    struct pc_capture *p=&g->pc;
    if(!n || n->inflight || g->quarantined || g->locked_client || p->clone || p->capture || p->active_command)return 0;
    int polled=anim_rgba_poll(g);if(p->gpu_pending || (g->metal && *(void **)((char *)g->metal+0x2d8)))return 0;
    if(pc_normal_frame(p))return 0;
    struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(o && g->render_called) {
        o->renderer_frames++;o->renderer_bytes+=p->width*p->height*4;
    }
    int rotate=o && (o->renderer_frames>=RGBA_ORDINARY_RENDER_FRAMES || o->renderer_bytes>=RGBA_ORDINARY_RENDER_BYTES);
    if(polled==5 || p->stage==PC_GPU_ERROR || p->gpu_status==5 || g->clear_status==5 || rotate) {
        if(!anim_rgba_destroy(g))return 0;
        if(o){o->renderer_recycles++;o->renderer_bytes=o->renderer_frames=0;}
    }else {
        if(g->update){g->api.finish_update(g->update);g->update=0;}
        if(g->root)g->api.assign_root(&g->root,0);
        if(g->clear_buffer){p->release_obj(g->clear_buffer);g->clear_buffer=0;}
        if(p->command_buffer){p->release_obj(p->command_buffer);p->command_buffer=0;}
        if(p->texture_ref){p->release_obj(p->texture_ref);p->texture_ref=0;}
    }
    // Completed candidate references are released. Consumer textures
    // remain retained independently by each slot and its CALayer contents.
    g->destroyed=0;g->shared_renderer=g->shared_metal=g->shared_queue=0;
    g->clear_status=g->clear_submitted=g->render_called=g->sealed=0;
    g->normal_wrapper_sequence=g->own_wrapper_sequence=g->own_client_sequence=g->inclusion=0;
    g->original_nodes=g->prepared_nodes=g->selected_type=g->destination_flags=0;
    g->last_own_status=g->command_buffer_bound=g->source_flags=0;
    g->client_nodes=g->client_reason=g->cohort_contexts=0;
    g->domain=(struct rgba_client_domain){0};g->client_mapping=(struct rgba_matrix){0};
    p->dead=0;p->stage=PC_EMPTY;p->reason=0;p->gpu_status=0;p->gpu_pending=0;
    p->width=p->height=p->format=0;p->scale=p->baked_alpha=0;
    p->encoded=p->capture_witness=p->source_unchanged=p->present_unchanged=0;
    p->update=p->update_after=p->context=p->client_context=0;
    p->client_id=p->client_commit_sequence=p->client_transaction_seed=p->client_included=0;
    p->misses=0;return 1;
}
// The installed baseline preserves opening stretch across an ordinary
// retarget. Read only the published command batch before that baseline tick;
// an explicit ordinary 1:1 command must not inherit an earlier opening mode.
static void rgba_ordinary_before_tick(struct ctx *c) {
    rgba_normal_close_seed_commands(c);
    rgba_normal_draw_commands(c);
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!rgba_valid(g) || g->pc.engine!=c || !pc_main(&g->pc) || c->in_cb || c->dead || !c->ch ||
       c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=sizeof(struct ch) || c->ch->h.stop)return;
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o || !o->enabled)return;
    u32 head=__atomic_load_n(&c->ch->h.cmd_head,__ATOMIC_ACQUIRE),tail=c->ch->h.cmd_tail;
    if(head-tail>CH_NCMD)return;
    for(unsigned i=0;i<CH_NW;i++) {
        struct ch_win *w=&c->ch->win[i];
        if(!w->used || !w->stretch || w->geo==2 || cover_index(c,w->wid,1)>=0 || birth_holds(c,w->wid))continue;
        unsigned count=0;u32 intent=F_STRETCH;
        for(u32 at=tail;at!=head;at++) {
            const struct ch_cmd *k=&c->ch->cmd[at%CH_NCMD];
            if(k->wid==w->wid && (k->op==OP_GEOM || k->op==OP_WARP)){count++;intent=k->flags;}
        }
        if(count==1 && !(intent&(F_STRETCH|F_NATIVE|F_SNAPSHOT)))w->stretch=0;
    }
}
// A growing native frame can supply B directly at 1:1. Keep the live crop and
// springs when it covers the whole current allocation; no cached pixels or
// takeover proof are needed for this path.
static inline __attribute__((always_inline)) int rgba_ordinary_live_covered(
        struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w,void *win) {
    struct ctx *c=g->pc.engine;void *fresh=0;
    if(!w || !w->used || w->wid!=m->wid || (w->geo!=1 && w->geo!=4) ||
       m->presenting || m->opening || w->stretch || w->wait ||
       !finite(w->cur_alpha) || w->cur_alpha<0 || w->cur_alpha>1 ||
       cover_index(c,w->wid,1)>=0 || birth_holds(c,w->wid) ||
       !actual(c,w,&fresh) || fresh!=win || rgba_inplace_source(g,m)!=win)return 0;
    char *cwc=*(char **)((char *)win+0x18);
    if(!cwc || *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x98)!=m->host ||
       *(void **)(cwc+0x80)!=m->server_root)return 0;
    double x=w->pos.v[0],y=w->pos.v[1],width=w->size.v[0],height=w->size.v[1];
    if(!finite(x) || !finite(y) || !finite(width) || !finite(height) || width<1 || height<1 ||
       w->aw<width || w->ah<height)return 0;
    struct rect4 host=((msgb_t)c->msg)(m->host,c->s_bounds);
    if(!finite(host.x) || !finite(host.y) || !finite(host.w) || !finite(host.h) ||
       host.w<width || host.h<height ||
       ((float (*)(void *,void *))c->msg)(m->host,c->sel("opacity"))<=0)return 0;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
    live_edge_client(c,w,0);
    put_xform(c,w,1,1,w->ax-x,w->ay-y);
    int crop=w->aw-width>.5 || w->ah-height>.5;
    double edge=crop && c->ch->deco.sys_off!=1?c->ch->deco.width:0;
    put_mask(c,w,win,use_mask(c,w) && crop,width,height);
    put_clip(c,w,win,crop,x-edge,y-edge,width+2*edge,height+2*edge);
    put_under(c,w,0,0,0,0,0,0,0,0);
    rgba_inplace_legacy(c,m,w,0);m->padding_motion=0;m->motion_started=0;
    RGBA_LAYER_COMMIT(tx);decoration_damage(c,win);return 1;
}
// A refused OWN transfer must leave the real application visible. The saved
// baseline tick can otherwise keep projecting/clipping its newly resized frame
// and drawing a fill while no qualified OWN surface is actually presenting.
static int rgba_ordinary_native_fallback(struct rgba_capture *g,struct rgba_inplace *m,
                                       struct ch_win *w,void *win) {
    struct ctx *c=g->pc.engine;
    double position[2]={w->pos.g[0],w->pos.g[1]},size[2]={w->size.g[0],w->size.g[1]};
    if(!finite(position[0]) || !finite(position[1]) || !finite(size[0]) || !finite(size[1]) ||
       size[0]<1 || size[1]<1 || m->presenting)return 1;
    if(rgba_ordinary_live_covered(g,m,w,win))return 1;
    int active=!w->held && !w->wait && (w->pos.active || w->size.active);
    // Minimum-size/grid mismatch can keep settling set indefinitely. Once A is
    // stable, retain the original tick's idle crop and allow the next motion.
    int ready=!w->held && !w->wait && !active && !w->alpha.active && w->stable>=2;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
    if(ready) {
        rgba_inplace_legacy(c,m,w,0);m->padding_motion=0;m->motion_started=0;
    } else {
        live_edge_client(c,w,0);put_plain(c,w,win);
        // Cancel only this unpresentable geometry motion. Alpha, native input,
        // the pending client configure and the freshness gate remain intact.
        if(active) {
            double dx=position[0]-w->ax,dy=position[1]-w->ay;
            if(w->geo==4)w->geo=1;
            if(c->move && (dabs(dx)>=.01 || dabs(dy)>=.01)) {
                unsigned wid=w->wid;c->move(0,&wid,1,0,(float)dx,(float)dy);
                if(!actual(c,w,&win) || rgba_inplace_source(g,m)!=win){RGBA_LAYER_COMMIT(tx);return 0;}
            }
            warp(&w->pos,2,position);warp(&w->size,2,size);
            w->settling=1;
        }
        rgba_inplace_legacy(c,m,w,1);m->padding_motion=1;
    }
    RGBA_LAYER_COMMIT(tx);decoration_damage(c,win);return 1;
}
static int rgba_ordinary_pose(struct rgba_capture *g,struct rgba_inplace *m,struct ch_win *w) {
    if(rgba_carrier_active(g))return rgba_carrier_pose(g,m,w);
    struct ctx *c=g->pc.engine;char *win=rgba_inplace_source(g,m),*cwc=win?*(char **)(win+0x18):0;
    if(!w || !w->used || w->wid!=m->wid || !w->geo || w->geo==2 || !cwc ||
       *(void **)(cwc+0x38)!=m->context || *(void **)(cwc+0x98)!=m->host ||
       *(void **)(cwc+0x80)!=m->server_root || *(void **)(cwc+0x70) || *(void **)(cwc+0x78) ||
       *(u32 *)(cwc+0x150) || *(u32 *)(cwc+0x154) || !((*(u64 *)(win+0x928)>>44)&1))return 0;
    m->logical_alpha=m->presenting && (w->held || w->wait)?m->alpha:w->cur_alpha;
    // Configure holds freeze R(t), not its already adopted pixels. Revealing
    // native H here can expose an unfinished resized frame for one display.
    int preparing=rgba_draw_pending(g,m);
    int moving=preparing || (m->presenting && (w->held || w->wait)) ||
        (rgba_begin_active(g) && !m->opening && w->held && !w->wait) ||
        (!w->held && !w->wait && (w->pos.active || w->size.active || w->alpha.active));
    if(m->padding_motion || (!rgba_begin_active(g) && !m->presenting && !m->opening && w->held))
        return rgba_ordinary_native_fallback(g,m,w,win);
    // A source texture never replaces the live application between animations.
    // In particular, native image-queue presentation feedback remains native.
    if(moving && m->presenting)m->settle_started=0;
    if(moving && !m->presenting) {
        if(!m->motion_started){m->motion_started=c->ch->h.now;m->settle_started=0;}
        struct rgba_ordinary *o=rgba_ordinary_control(g);unsigned index=m-rgba_ordinary_slots(g);
        // Never replace a newer native frame with an older idle cache. This
        // fences the entire owning normal cohort, including hosted producers.
        if(!o || index>=CH_NW || !finite(o->good_time[index]) || !finite(o->native_time[index]) ||
           o->good_time[index]<=0 || o->native_time[index]<=0 ||
           o->good_time[index]<o->native_time[index] ||
           !rgba_begin_takeover_ready(g,m,o->good_time[index]) ||
           m->good_client_context!=(u64)*(void **)(cwc+0x48) || m->good_client_id!=*(u32 *)(cwc+0x50)) {
            if(o)o->next_capture=0;
            // No real geometry has been released for this intent. Waiting
            // cannot park A, advance clocks, or enter the native fallback.
            if(preparing)return 1;
            if(rgba_begin_wait(g,m,w,win))return 1;
            return rgba_ordinary_native_fallback(g,m,w,win);
        }
    }
    if(!moving && m->presenting && !w->held && !w->wait) {
        struct rect4 hb=((msgb_t)c->msg)(m->host,c->s_bounds);
        int native_ready=!w->settling && dabs(hb.w-m->source_w)<.5 && dabs(hb.h-m->source_h)<.5 &&
            dabs(w->aw-w->size.v[0])<=c->ch->h.settle_px && dabs(w->ah-w->size.v[1])<=c->ch->h.settle_px;
        if(!m->settle_started)m->settle_started=c->ch->h.now;
        if(!native_ready && c->ch->h.now-m->settle_started<.15)moving=1;
    }
    if(!moving) {
        if(!m->presenting) {
            if(m->motion_started) {
                RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
                rgba_inplace_legacy(c,m,w,0);m->motion_started=0;
                RGBA_LAYER_COMMIT(tx);decoration_damage(c,win);
            }
            return 1;
        }
        RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
        ((msgf_t)c->msg)(m->root,c->s_opacity,0);
        ((msgf_t)c->msg)(m->host,c->s_opacity,(float)m->host_opacity);
        rgba_inplace_legacy(c,m,w,0);
        c->set_alpha(0,win,(float)w->cur_alpha,0);
        // Original tick already reconciled the native final crop/translation.
        // Preserve that exact fallback when native minimum size differs from B.
        // Hidden cached layers must not retain an extra displayed texture.
        for(unsigned i=0;i<4;i++)rgba_view_object(c,rgba_inplace_part(m,i),"setContents:",0);
        m->displayed_texture=m->displayed_bytes=0;
        m->motion_started=0;m->mutations++;w->settling=1;w->fkey[0]=-1;
        RGBA_LAYER_COMMIT(tx);m->presenting=0;rgba_draw_forget(g,m);decoration_damage(c,win);return 1;
    }
    rect target={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
    double alpha=m->presenting && (w->held || w->wait)?m->alpha:w->cur_alpha;
    if(!rgba_view_rect(target) || !finite(alpha) || alpha<0 || alpha>1)return 0;
    if(rgba_draw_active(g) && !rgba_draw_prepare(g,m,w,target))return 0;
    if(rgba_draw_active(g) && !rgba_draw_ready(g,m,target,1))return 1;
    struct rect4 hb=((msgb_t)c->msg)(m->host,c->s_bounds);
    struct rect4 local={hb.x,c->ch->h.mask_flip?hb.y+hb.h-target.h:hb.y,target.w,target.h};
    struct rect4 fr=((msgcv_t)c->msg)(m->host,c->s_convert,local,m->server_root);
    if(rgba_draw_active(g)) {
        // A may already be at its final native position (F_MOVE_END). Keep
        // its input transform intact and place only our graphic tree at R.
        double *matrix=(double *)(win+0x498);
        for(unsigned j=0;j<16;j++) {
            if(!finite(matrix[j]))return 0;
            if(j!=12 && j!=13 && dabs(matrix[j]-(j%5==0?1:0))>1e-6)return 0;
        }
        if(dabs(w->m[0]-1)>1e-6 || dabs(w->m[1]-1)>1e-6 ||
           *(float *)(win+0x1d8)!=1 || *(float *)(win+0x1e4)!=1)return 0;
        // Native screen_rect_from_rect uses the negative translation for
        // this unit matrix. Read it exactly, without CGRegion rounding.
        fr.x+=target.x+matrix[12];
        fr.y+=(c->ch->h.mask_flip?-1:1)*(target.y+matrix[13]);
    }
    // The client's native size remains final. Translation is always 1:1;
    // crop/clamp comes solely from the accepted texture extent below.
    int native=w->clipped || w->mask || dabs(w->m[0]-1)>1e-6 || dabs(w->m[1]-1)>1e-6 ||
        dabs(w->m[2]-w->ax+target.x)>1e-4 || dabs(w->m[3]-w->ay+target.y)>1e-4 ||
        *(float *)(win+0x1d8)!=1 || *(float *)(win+0x1e4)!=1;
    struct rect4 actual=((msgb_t)c->msg)(m->root,c->sel("frame"));
    int changed=!m->presenting || m->displayed_texture!=(u64)m->texture || !rgba_view_same(m->current,target) || m->alpha!=alpha ||
        dabs(actual.x-fr.x)>.01 || dabs(actual.y-fr.y)>.01 || dabs(actual.w-fr.w)>.01 || dabs(actual.h-fr.h)>.01;
    u64 dhash=decoration_hash(&c->ch->deco);
    double focus=presentation_wid(c,w)==c->ch->deco.focus?1:0;
    int style=m->style_hash!=dhash || m->focus!=focus || m->radius!=w->radius;
    int hidden=((float (*)(void *,void *))c->msg)(m->host,c->sel("opacity"))==0;
    u64 layers[4]={w->bl_in,w->bl_act,w->bl_fill,w->bl_sh};int legacy=0;
    for(unsigned i=0;i<4;i++)if(layers[i] && (layers[i]!=m->legacy[i] ||
        !((unsigned char (*)(void *,void *))c->msg)((void *)layers[i],c->sel("isHidden"))))legacy=1;
    if(!changed && !style && hidden && !legacy && !native &&
       !(w->under && w->ualpha!=0))return 1;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
    if(native && !rgba_draw_active(g)) {
        put_xform(c,w,1,1,w->ax-target.x,w->ay-target.y);
        put_clip(c,w,win,0,0,0,0,0);put_mask(c,w,win,0,0,0);
        if(*(float *)(win+0x1d8)!=1 || *(float *)(win+0x1e4)!=1)c->set_alpha(0,win,1,0);
    }
    if(changed || style) {
        m->current=m->target=target;m->alpha=alpha;m->radius=w->radius;
        rgba_view_bounds(c,m->root,"setBounds:",(rect){0,0,target.w,target.h});
        rgba_view_point(c,m->root,"setPosition:",fr.x,fr.y);
        rgba_view_bounds(c,m->surface,"setBounds:",(rect){0,0,target.w,target.h});
        rgba_view_point(c,m->surface,"setPosition:",0,0);
        ((msgd_t)c->msg)(m->surface,c->s_radius,m->radius);
        rgba_inplace_pixels(c,m,m->displayed_texture!=(u64)m->texture);
        m->displayed_texture=(u64)m->texture;m->displayed_bytes=(u64)m->pixel_w*m->pixel_h*4;rgba_inplace_border(c,m,w);
        ((msgf_t)c->msg)(m->root,c->s_opacity,(float)alpha);
    }
    // Complete B before hiding H. A throwing layer/style setter must never
    // leave a partially populated surface as the only visible presenter.
    if(!hidden)((msgf_t)c->msg)(m->host,c->s_opacity,0);
    if(!m->presenting)m->motion_started=c->ch->h.now;
    m->presenting=1;m->last_used=c->ch->h.now;rgba_inplace_legacy(c,m,w,1);
    // The qualified texture covers all of R, including transparent pixels.
    // Keeping a separate B-A fill beneath it changes those pixels until the
    // following adoption observation. Publish its removal with B and H0.
    put_under(c,w,0,0,0,0,0,0,0,0);
    RGBA_LAYER_COMMIT(tx);m->mutations++;rgba_draw_damage(g,m);decoration_damage(c,win);
    return 1;
}
static int rgba_ordinary_publish(struct rgba_capture *g,struct rgba_inplace *m) {
    if(!rgba_client_domain_ready(g))return 0;
    struct rgba_ordinary *o=rgba_ordinary_control(g);
    if(!m->on) {
        m->ordinary=1;int mounted=rgba_inplace_mount_slot(g,m);
        if(mounted && o && o->candidate_color)m->color=g->api.geometry.retain_cf(o->candidate_color);
        return mounted;
    }
    if(!rgba_inplace_source(g,m) || m->window!=(void *)g->pc.source)return 0;
    char *cwc=*(char **)((char *)m->window+0x18);u32 sequence=0;
    void *client=cwc?*(void **)(cwc+0x48):0;
    if(!cwc || *(u32 *)(cwc+0x50)!=g->domain.client_id ||
       !rgba_included(g->update,client,&sequence) || sequence!=g->pc.client_commit_sequence)return 0;
    void *texture=g->pc.retain_obj(g->pc.texture_ref);if(!texture)return 0;
    void *previous=m->texture;
    if(m->adopted_texture==(u64)previous) {
        if(m->retiring_texture)g->pc.release_obj(m->retiring_texture);
        if(m->retiring_color)g->api.geometry.release_cf(m->retiring_color);
        m->retiring_texture=previous;previous=0;
        m->retiring_color=m->color;m->color=0;
        m->retiring_w=m->source_w;m->retiring_h=m->source_h;
        m->retiring_pixel_w=m->pixel_w;m->retiring_pixel_h=m->pixel_h;
        m->retiring_client_context=m->good_client_context;m->retiring_client_id=m->good_client_id;
        m->retiring_client_sequence=m->good_client_sequence;
    }
    m->texture=texture;m->adopted_texture=0;m->last_used=g->pc.engine->ch->h.now;
    m->source_w=(double)g->pc.width/g->pc.scale;m->source_h=(double)g->pc.height/g->pc.scale;
    m->pixel_w=g->pc.width;m->pixel_h=g->pc.height;
    m->good_client_sequence=g->pc.client_commit_sequence;
    m->good_client_context=(u64)client;m->good_client_id=g->domain.client_id;
    if(m->color)g->api.geometry.release_cf(m->color);
    m->color=o && o->candidate_color?g->api.geometry.retain_cf(o->candidate_color):0;
    // Cache-only refresh has no visual transaction. CALayer contents and the
    // previous good remain independently retained until the next motion adopts.
    if(previous)g->pc.release_obj(previous);
    return 1;
}
static void rgba_ordinary_rollback(struct rgba_capture *g,struct rgba_inplace *m) {
    if(!m->retiring_texture){rgba_inplace_drop_slot(g,m);return;}
    struct ctx *c=g->pc.engine;void *candidate=m->texture;
    m->texture=m->retiring_texture;m->retiring_texture=candidate;
    void *color=m->color;m->color=m->retiring_color;m->retiring_color=color;
    m->source_w=m->retiring_w;m->source_h=m->retiring_h;
    m->pixel_w=m->retiring_pixel_w;m->pixel_h=m->retiring_pixel_h;
    m->good_client_context=m->retiring_client_context;m->good_client_id=m->retiring_client_id;
    m->good_client_sequence=m->retiring_client_sequence;m->adopted_texture=0;
    RGBA_LAYER_SCOPE(c,tx);c->tx_add(tx,m->context);
    rgba_inplace_pixels(c,m,1);
    RGBA_LAYER_COMMIT(tx);m->mutations++;c->sched_win(0,m->window);
}
static void rgba_ordinary_observe(struct rgba_capture *g,void *head,void *prepared) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o || !o->enabled)return;
    struct ctx *c=g->pc.engine;unsigned count=0;
    for(char *s=prepared;s && count++<256;s=*(char **)(s+8)) {
        if(*(u32 *)(s+0x180)!=10)continue;
        unsigned wid=*(u32 *)(s+0x268);char *meta=*(char **)(s+0x48);
        struct ch_win *w=slot(c->ch,wid,0);
        char *win=c->by_id(wid),*update=meta?*(char **)(meta+0x10):0;
        if(!w || !w->geo || !win || !meta || *(void **)meta!=win || *(void **)(meta+8) ||
           !update || update!=*(char **)(s+0x28) || update!=*(char **)(s+0x30))continue;
        o->seen[w-c->ch->win]=c->ch->h.now;
        char *cwc=*(char **)(win+0x18);u32 sequence=0;
        if(!cwc || !rgba_included(update,*(void **)(cwc+0x48),&sequence))continue;
        double time=g->api.get_time(update);if(!finite(time) || time<=0)continue;
        struct rgba_inplace *all=rgba_ordinary_slots(g);
        for(unsigned i=0;i<CH_NW;i++)if(!all[i].presenting && all[i].wid==wid &&
            rgba_inplace_source(g,&all[i])==win && time>o->native_time[i])o->native_time[i]=time;
    }
    struct rgba_inplace *slots=rgba_ordinary_slots(g);
    for(unsigned i=0;i<CH_NW;i++)if(slots[i].on && !slots[i].presenting)rgba_carrier_observe_idle(g,&slots[i],prepared);
    for(unsigned i=0;i<CH_NW;i++)if(slots[i].on && slots[i].presenting &&
        (slots[i].adopted_texture!=(u64)slots[i].texture || rgba_draw_pending(g,&slots[i])))
        rgba_inplace_observe_slot(g,&slots[i],head,prepared);
}
// Publication is shared by the regular tick and the completion callback. This
// function never destroys/resets a renderer, advances R(t), or arms new work.
static int rgba_ordinary_accept(struct rgba_capture *g,double now) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct pc_capture *p=&g->pc;
    if(!o || !o->enabled || now>=o->expires || __atomic_load_n(&o->command,__ATOMIC_ACQUIRE)==2 ||
       o->candidate>=CH_NW || !finite(o->capture_time) || o->capture_time<=0)return 0;
    struct ctx *c=p->engine;struct ch_win *w=slot(c->ch,p->wid,0);
    struct rgba_inplace *m=&rgba_ordinary_slots(g)[o->candidate];
    if(w && w->used && w->wid==p->wid)p->capture_rect=(rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
    if(p->stage!=PC_GPU_COMPLETE || p->reason || !pc_source(p) || !w ||
       (m->opening && (dabs(g->domain.mapped.w-w->size.g[0])>c->ch->h.settle_px ||
        dabs(g->domain.mapped.h-w->size.g[1])>c->ch->h.settle_px)))return 0;
    if(m->texture==p->texture_ref)return 1;
    if(!rgba_carrier_can_publish(g,m))return 0;
    m->target=p->capture_rect;
    int moving=(!w->held && !w->wait && (w->pos.active || w->size.active || w->alpha.active)) || m->presenting;
    char *cwc=*(char **)((char *)p->source+0x18);void *context=cwc?*(void **)(cwc+0x38):0;
    if(!context)return 0;
    struct rgba_layer_scope scope __attribute__((cleanup(rgba_layer_scope_cleanup)))={0};
    if(moving && !rgba_carrier_active(g)){rgba_layer_scope_begin(&scope,c);c->tx_add(scope.tx,context);}
    int published=rgba_ordinary_publish(g,m);
    if(published){o->good_time[o->candidate]=o->capture_time;rgba_begin_promoted(g,m);}
    int posed=published?rgba_ordinary_pose(g,m,w):0;
    if(scope.active)rgba_layer_scope_commit(&scope);
    if(!published)return 0;
    o->promoted++;m->ordinary=1;m->opening=0;
    if(!posed){rgba_inplace_drop_slot(g,m);return 0;}
    return 1;
}
static void rgba_ordinary_completion(struct rgba_capture *g,double now) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o)return;
    o->completion_queued=0;
    struct rgba_normal_binding *n=rgba_normal_binding(g);struct ctx *c=g->pc.engine;
    if(rgba_carrier_control(g) && !rgba_carrier_timer_allowed(g))return;
    if(!o->enabled || now>=o->expires || __atomic_load_n(&o->command,__ATOMIC_ACQUIRE)==2 ||
       !rgba_normal_valid(n) || !pc_main(&g->pc) || n->inflight ||
       c->in_cb || c->dead || !c->ch || c->ch->h.stop || g->quarantined || g->locked_client ||
       g->pc.active_command || o->candidate>=CH_NW || !pc_source(&g->pc))return;
    o->completion_polls++;
    if(o->completion_generation!=o->capture_generation) {
        o->completion_generation=o->capture_generation;o->completion_deadline=now+.025;
    }
    // A missed deadline never relaxes freshness. The original timer retains
    // terminal GPU custody and the live native fallback.
    if(now>o->completion_deadline)return;
    if(g->pc.stage==PC_ENCODED)anim_rgba_poll(g);
    if(g->pc.stage==PC_GPU_COMPLETE) {
        u64 promoted=o->promoted;
        rgba_ordinary_accept(g,now);o->fast_promoted+=o->promoted-promoted;return;
    }
    if(g->pc.stage==PC_ENCODED && g->pc.gpu_pending) {
        o->completion_queued=1;c->resched(c->queue,rgba_ordinary_completion,g,c->session,1,0,now+.002);
    }
}
static void rgba_ordinary_schedule_completion(struct rgba_capture *g) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct ctx *c=g->pc.engine;
    if(!o || !o->enabled || o->completion_queued || o->candidate>=CH_NW || !c->resched || !c->ch->h.nactive ||
       o->completion_generation==o->capture_generation ||
       g->pc.stage!=PC_ENCODED || !g->pc.gpu_pending)return;
    o->completion_queued=1;o->completion_polls=0;o->completion_deadline=c->ch->h.now+.025;
    o->completion_generation=o->capture_generation;
    c->resched(c->queue,rgba_ordinary_completion,g,c->session,1,0,0);
}
static void rgba_ordinary_tick(struct rgba_capture *g,double now) {
    struct rgba_ordinary *o=rgba_ordinary_control(g);if(!o || !pc_main(&g->pc))return;
    struct ctx *c=g->pc.engine;struct rgba_inplace *slots=rgba_ordinary_slots(g);
    u64 sequence=__atomic_load_n(&o->sequence,__ATOMIC_ACQUIRE);
    if(sequence!=o->ack) {
        u64 command=__atomic_exchange_n(&o->command,0,__ATOMIC_ACQ_REL);
        if(command==1) {
            o->enabled=1;o->expires=now+30;o->candidate=CH_NW;
            for(unsigned i=0;i<CH_NW;i++)if(c->ch->win[i].used) {
                void *win=c->by_id(c->ch->win[i].wid);if(win)c->sched_win(0,win);
            }
        }
        else if(command==2 && !rgba_ordinary_drop(g)) {
            u64 empty=0;__atomic_compare_exchange_n(&o->command,&empty,2,0,__ATOMIC_RELEASE,__ATOMIC_RELAXED);
            return;
        }
        if(command)__atomic_store_n(&o->ack,sequence,__ATOMIC_RELEASE);
    }
    if(!o->enabled)return;
    if(now>=o->expires || c->dead || !c->ch || c->ch->h.stop){rgba_ordinary_drop(g);return;}
    for(unsigned i=0;i<CH_NW;i++) {
        struct rgba_inplace *m=&slots[i];
        if(!m->on) {
            if(m->opening && !rgba_inplace_source(g,m))
                for(unsigned z=0;z<sizeof(*m);z++)((volatile unsigned char *)m)[z]=0;
            continue;
        }
        if(m->retiring_texture && m->adopted_texture==(u64)m->texture) {
            g->pc.release_obj(m->retiring_texture);m->retiring_texture=0;
            if(m->retiring_color)g->api.geometry.release_cf(m->retiring_color);m->retiring_color=0;
        }
        if(!rgba_ordinary_pose(g,m,slot(c->ch,m->wid,0)))rgba_inplace_drop_slot(g,m);
    }
    struct pc_capture *p=&g->pc;
    if(o->candidate<CH_NW) {
        struct ch_win *w=slot(c->ch,p->wid,0);
        if(w && w->used && w->wid==p->wid)p->capture_rect=(rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        rgba_normal_retry(g);
        anim_rgba_poll(g);
        if(p->stage==PC_ARMED && now-o->started>.3 && !g->update && !g->root && !p->texture_ref) {
            p->stage=PC_INVALID;p->reason=249;
        }
        if(p->stage==PC_ARMED || p->stage==PC_ENCODED)return;
        if(!rgba_ordinary_accept(g,now))o->refused++;
        if(p->reason==250)rgba_ordinary_evict_idle(g);
        u64 retries=p->misses;
        int recovered=retries && p->stage==PC_GPU_COMPLETE && !p->reason;
        if(!rgba_ordinary_reset(g))return;
        o->retries+=retries;o->retry_successes+=recovered;
        o->candidate=CH_NW;
        double interval=c->ch->h.nactive?1.0/60:1.0/30;
        o->next_capture=o->started+interval;if(o->next_capture<now)o->next_capture=now;
    }
    if(now<o->next_capture || p->active_command)return;
    if(p->stage!=PC_EMPTY && !rgba_ordinary_reset(g))return;
    // Leave an empty producer available to this active source's owning prepare.
    // Idle/bootstrap captures retain the existing timer admission below.
    if(g->sel.read_bytes && g->texture_class && g->pass_class && p->status_selector &&
       __atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE)==p->command_ack && !p->command)
        for(unsigned i=0;i<CH_NW;i++) {
            struct rgba_inplace *m=&slots[i];struct ch_win *w=m->on?slot(c->ch,m->wid,0):0;
            if(w && w->used && w->geo && w->geo!=2 && (!w->held || rgba_begin_active(g)) && !w->wait &&
               !m->opening && !m->padding_motion && (w->pos.active || w->size.active || w->alpha.active) &&
               cover_index(c,w->wid,1)<0 && !birth_holds(c,w->wid) && rgba_inplace_source(g,m))return;
        }
    for(unsigned n=0;n<CH_NW;n++) {
        unsigned i=(o->cursor+n)%CH_NW;struct ch_win *w=&c->ch->win[i];struct rgba_inplace *m=0;
        if(now-o->seen[i]>.1)continue;
        if(!w->used || !w->geo || w->geo==2 || rgba_pan_active(g,w->wid))continue;
        char *win=c->by_id(w->wid);
        if(!win || *(u32 *)(win+4)!=5 || *(int *)(win+0x20)!=0 || !((*(u64 *)(win+0x928)>>44)&1))continue;
        char *creator=*(char **)(win+0x30),*cwc=*(char **)(win+0x18);
        float alpha=cwc?*(float *)(cwc+0x174):-1;
        if(!creator || !cwc || !finite(alpha) || alpha<0 || alpha>1 || *(void **)(cwc+0x70) || *(void **)(cwc+0x78))continue;
        void *client=*(void **)(cwc+0x48);u32 commit=0;
        if(!client || g->api.lock_context(client)!=0)continue;
        commit=*(u32 *)((char *)client+0x40);g->api.unlock_context(client);
        for(unsigned j=0;j<CH_NW;j++)if(slots[j].on && slots[j].wid==w->wid) {
            if(rgba_inplace_source(g,&slots[j])==win)m=&slots[j];
            else rgba_inplace_drop_slot(g,&slots[j]);
        }
        if(!m)for(unsigned j=0;j<CH_NW;j++)if(!slots[j].on && !slots[j].root && !slots[j].texture &&
            slots[j].wid==w->wid && slots[j].window==win && slots[j].creator==(u64)creator &&
            slots[j].pid_version==*(u64 *)(creator+0x268)){m=&slots[j];break;}
        if(!m)for(unsigned j=0;j<CH_NW;j++)if(!slots[j].on && !slots[j].root && !slots[j].texture && !slots[j].opening){m=&slots[j];break;}
        if(!m)continue;
        if(m->on && m->good_client_sequence==commit && m->good_client_context==(u64)client &&
           m->good_client_id==*(u32 *)(cwc+0x50) &&
           ((!rgba_draw_pending(g,m) && !m->presenting) || rgba_draw_close_cached(g,m)) &&
           !w->pos.active && !w->size.active && !w->alpha.active)continue;
        if(!m->on && (m->wid!=w->wid || m->window!=win || m->creator!=(u64)creator ||
           m->pid_version!=*(u64 *)(creator+0x268))) {
            for(unsigned z=0;z<sizeof(*m);z++)((volatile unsigned char *)m)[z]=0;
            m->magic=RGBA_INPLACE_MAGIC;m->size=sizeof(*m);m->version=1;m->capture=g;
            o->good_time[m-slots]=o->native_time[m-slots]=0;
            m->opening=w->held || w->wait || w->stretch;
            m->wid=w->wid;m->window=win;m->creator=(u64)creator;m->pid_version=*(u64 *)(creator+0x268);
            m->target=(rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        }
        p->source=(u64)win;p->creator=(u64)creator;p->pid_version=*(u64 *)(creator+0x268);p->wid=w->wid;
        p->capture_rect=(rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
        v->source_wid=p->wid;v->source_creator=p->creator;v->source_pid_version=p->pid_version;
        p->prepare_idle_permit=0x31454c44494350ULL;
        o->capture_generation=0;o->capture_time=0;
        if(anim_rgba_normal_arm(rgba_normal_binding(g))) {
            o->candidate=m-slots;o->cursor=(i+1)%CH_NW;o->started=now;return;
        }
        o->refused++;o->next_capture=now+.05;return;
    }
}
_Static_assert(RGBA_ORDINARY_OFFSET+sizeof(struct rgba_ordinary)<RGBA_ORDINARY_SLOTS,"ordinary control partition");
_Static_assert(RGBA_ORDINARY_SLOTS+CH_NW*sizeof(struct rgba_inplace)<=RGBA_ORDINARY_BYTES,"ordinary slots partition");
