// Private native first-order custody. Included after the engine and pixel cache;
// shared channel layout is unchanged. A root-owned installer supplies the pinned
// API template and leaves policy disabled until the matching daemon is ready.
#define BIRTH_STATE_OFFSET 0x700
#define BIRTH_MAGIC 0x32545249424d5748ULL
#define BIRTH_WINDOWS 256
#define BIRTH_CAPTURES 8
#define BIRTH_NONE 0xffffffffu
struct birth_window {
    u64 source,creator,pid_version,token,policy_epoch;
    u32 wid,phase,ordered,holding,acknowledged,pool,fresh,p8;
    double expires,replay;
    rect target,desired_clip;
    u64 revision;
    u32 desired_on,cancel,superseded,pad;
};
struct birth_capture {struct pc_capture pixels;u64 token,revision,shell,surface;u32 shell_wid,retiring,adopted,pad;};
struct birth_state {
    u64 magic;u32 size,version;
    struct ctx *engine;
    void *callback;
    int (*is_main)(void);
    void *(*thread_self)(void);
    void *(*stack_top)(void *);
    u64 (*stack_size)(void *);
    int (*region_empty)(void *);
    void (*schedule_all)(void *,int);
    u64 callback_pc,notification_pc,order_pc;
    u32 uid,scope_pid,enabled,advertise,dead,registered,generation,sequence;
    u64 policy_epoch;double authority_until;
    void *empty_clip;
    u64 dispatches,callbacks,nonmain,refused,conflicts,held,revealed,event_full;
    struct birth_window windows[BIRTH_WINDOWS];
    struct pc_capture capture_api;
    struct birth_capture captures[BIRTH_CAPTURES];
    struct pc_node node;
    struct pc_node **metal_callbacks;
    void *frame_callback;
    u32 node_linked,node_conflict;
    // Disposable-fixture control uses the same native consumer on its existing
    // timer. Never accepted without a nonzero root-pinned fixture PID.
    struct ch_cmd fixture_command;
    u64 fixture_sequence,fixture_ack;
    u32 fixture_result,pad;
};
_Static_assert(sizeof(struct birth_state)<=0x10000,"native birth mapping");
_Static_assert(BIRTH_STATE_OFFSET>=BO_ORIGINAL+8 && BIRTH_STATE_OFFSET+8<=0x800,"native birth ctx gap");
// Volatile byte loops keep this flat image independent of libc/GOT helpers.
static void birth_clear(void *data,unsigned size) {
    for(unsigned i=0;i<size;i++)((volatile unsigned char *)data)[i]=0;
}
static void birth_copy(void *to,const void *from,unsigned size) {
    for(unsigned i=0;i<size;i++)((volatile unsigned char *)to)[i]=((const volatile unsigned char *)from)[i];
}
static struct birth_state *birth_state(struct ctx *c) {
    struct birth_state *p=*(void **)((char *)c+BIRTH_STATE_OFFSET);
    return p && p->magic==BIRTH_MAGIC && p->size==sizeof(*p) && p->version==1 && p->engine==c?p:0;
}
static int birth_main(struct birth_state *p) {return p && p->is_main && p->is_main()==1;}
static int birth_frame_node(struct birth_state *p,int on) {
    if(!p->metal_callbacks || !p->frame_callback)return !on && !p->node_linked;
    struct pc_node **link=p->metal_callbacks;
    for(unsigned i=0;i<128;i++) {
        struct pc_node *node=*link;
        if(node==&p->node) {
            if(node->fn!=p->frame_callback || node->ctx!=p){p->node_conflict=1;return 0;}
            if(!on){*link=node->next;p->node_linked=0;}else p->node_linked=1;
            return 1;
        }
        if(!node) {
            if(on) {
                p->node.fn=p->frame_callback;p->node.ctx=p;p->node.next=*p->metal_callbacks;
                *p->metal_callbacks=&p->node;p->node_linked=1;
            } else p->node_linked=0;
            return 1;
        }
        link=(struct pc_node **)&node->next;
    }
    p->node_conflict=1;return 0;
}
static int birth_live(struct birth_state *p) {
    struct ctx *c=p->engine;
    return birth_main(p) && p->enabled && !p->dead && !c->dead && !c->in_cb && c->ch &&
        c->ch->h.magic==CH_MAGIC && c->ch->h.size==sizeof(struct ch) && !c->ch->h.stop;
}
static struct birth_window *birth_find(struct birth_state *p,u32 wid) {
    for(unsigned i=0;i<BIRTH_WINDOWS;i++)if(p->windows[i].wid==wid && !p->windows[i].superseded)return &p->windows[i];
    return 0;
}
static struct birth_window *birth_token(struct birth_state *p,u32 wid,u64 token) {
    for(unsigned i=0;i<BIRTH_WINDOWS;i++)if(p->windows[i].wid==wid && p->windows[i].token==token)return &p->windows[i];
    return 0;
}
static char *birth_source(struct birth_state *p,struct birth_window *w) {
    if(w->superseded)return 0; // A native create defeats even complete pointer ABA.
    char *win=p->engine->by_id(w->wid);
    if(!win || (u64)win!=w->source || *(u32 *)win!=w->wid || *(u32 *)(win+4)!=5)return 0;
    char *creator=*(char **)(win+0x30);
    if((u64)creator!=w->creator || !creator || *(u64 *)(creator+0x268)!=w->pid_version)return 0;
    u32 pid=(u32)w->pid_version,version=(u32)(w->pid_version>>32);
    if(*(u32 *)(creator+0x274)!=p->uid || *(u32 *)(creator+0x27c)!=p->uid ||
       *(u32 *)(creator+0x284)!=pid || *(u32 *)(creator+0x28c)!=version)return 0;
    return win;
}
static void birth_phase(struct birth_window *w,u32 phase) {w->phase=phase;w->acknowledged=0;w->replay=0;}
static void birth_reap(struct birth_window *w) {
    if(w->phase>=BIRTH_REVEALED && w->acknowledged && !w->holding &&
       w->pool==BIRTH_NONE && w->fresh==BIRTH_NONE && w->p8==BIRTH_NONE)birth_clear(w,sizeof(*w));
}
static int birth_abort(struct birth_state *,struct birth_window *,double,int);
static void birth_supersede(struct birth_state *,struct birth_window *);
static void birth_forget_slot(struct birth_state *,u32);
static int birth_event(struct birth_state *p,struct birth_window *w,double now) {
    struct ch *ch=p->engine->ch;
    u32 head=__atomic_load_n(&ch->h.evt_head,__ATOMIC_RELAXED);
    u32 tail=__atomic_load_n(&ch->h.evt_tail,__ATOMIC_ACQUIRE);
    if(head-tail>=CH_NEVT){p->event_full++;return 0;}
    struct ch_evt *e=&ch->evt[head%CH_NEVT];
    *e=(struct ch_evt){EV_BIRTH,w->wid,now,(u32)w->token,(u32)(w->token>>32),(u32)w->pid_version,w->phase};
    __atomic_store_n(&ch->h.evt_head,head+1,__ATOMIC_RELEASE);return 1;
}
static int birth_rect_same(rect a,rect b) {
    return dabs(a.x-b.x)<=.5 && dabs(a.y-b.y)<=.5 && dabs(a.w-b.w)<=.5 && dabs(a.h-b.h)<=.5;
}
static int birth_rect_valid(rect r) {return finite(r.x) && finite(r.y) && finite(r.w) && finite(r.h) && r.w>=1 && r.h>=1;}
static rect birth_bounds(struct birth_state *p,char *win) {
    void *shape=*(void **)(win+p->engine->shape_off);
    return shape?p->engine->bbox(shape):(rect){0};
}
static void birth_conflict(struct birth_state *p,struct birth_window *w) {
    if(w->phase!=BIRTH_CONFLICT){p->conflicts++;birth_phase(w,BIRTH_CONFLICT);}
}
// Remove only this exact still-owned clip, directly to the current desired crop.
// Caller prepares source presentation first and retires the shell only on success.
static int birth_unclip(struct birth_state *p,struct birth_window *w) {
    if(!w->holding)return 1;
    char *win=birth_source(p,w);
    if(!win){w->holding=0;return 1;}
    if(*(void **)(win+0x160)!=p->empty_clip){birth_conflict(p,w);w->holding=0;return 1;}
    struct ctx *c=p->engine;void *desired=w->desired_on?c->rgn(w->desired_clip):0;
    if(w->desired_on && !desired)return 0;
    u32 was=c->in_cb;c->in_cb=1;c->clip((void *)w->creator,desired,&w->wid,1);c->in_cb=was;
    int ok=*(void **)(win+0x160)==desired;
    if(desired)c->release(desired);
    if(ok)w->holding=0;
    return ok;
}
static int birth_clip(struct ctx *c,struct ch_win *engine,void *win,int on,rect desired) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return 0;
    struct birth_window *w=birth_find(p,engine->wid);
    if(!w || !w->holding || birth_source(p,w)!=win)return 0;
    w->desired_on=on;w->desired_clip=desired;
    engine->clipped=on;
    engine->clip[0]=desired.x;engine->clip[1]=desired.y;engine->clip[2]=desired.w;engine->clip[3]=desired.h;
    if(*(void **)((char *)win+0x160)!=p->empty_clip || *(void **)((char *)win+0x8d8))birth_conflict(p,w);
    return 1;
}
static int birth_tracks(struct ctx *c,u32 wid) {
    struct birth_state *p=birth_state(c);
    if(!birth_main(p))return 0;
    struct birth_window *w=birth_find(p,wid);
    return w && w->holding && birth_source(p,w);
}
static int birth_holds(struct ctx *c,u32 wid) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return 0;
    struct birth_window *w=birth_find(p,wid);return w && w->holding && birth_source(p,w);
}
static void birth_cancel(struct birth_state *p,struct birth_window *w) {
    w->cancel=1;
    if(w->p8!=BIRTH_NONE){birth_abort(p,w,p->engine->ch->h.now,0);return;}
    if(w->pool!=BIRTH_NONE)p->captures[w->pool].retiring=1;
    if(w->fresh!=BIRTH_NONE)p->captures[w->fresh].retiring=1;
    if(birth_unclip(p,w) && w->phase!=BIRTH_CONFLICT)birth_phase(w,BIRTH_CANCELLED);
}
static void birth_cancel_id(struct ctx *c,u32 wid) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return;
    struct birth_window *w=birth_find(p,wid);if(w && w->holding)birth_cancel(p,w);
}
static struct birth_window *birth_reserve(struct birth_state *p,char *win) {
    if(*(u32 *)(win+4)!=5 || !p->generation || p->sequence==0xffffffffu)return 0;
    u32 wid=*(u32 *)win;
    if(!wid || p->engine->by_id(wid)!=win)return 0;
    char *creator=*(char **)(win+0x30);if(!creator)return 0;
    u64 identity=*(u64 *)(creator+0x268);
    if(!(u32)identity || (p->scope_pid && (u32)identity!=p->scope_pid) ||
       *(u32 *)(creator+0x274)!=p->uid || *(u32 *)(creator+0x27c)!=p->uid ||
       *(u32 *)(creator+0x284)!=(u32)identity || *(u32 *)(creator+0x28c)!=(u32)(identity>>32))return 0;
    struct birth_window *old=birth_find(p,wid);
    if(old)birth_supersede(p,old);
    else birth_forget_slot(p,wid); // The prior birth may already have been ACKed/reaped.
    for(unsigned i=0;i<BIRTH_WINDOWS;i++)if(!p->windows[i].wid) {
        struct birth_window *w=&p->windows[i];birth_clear(w,sizeof(*w));
        w->wid=wid;w->source=(u64)win;w->creator=(u64)creator;w->pid_version=identity;
        w->token=((u64)p->generation<<32)|++p->sequence;
        w->pool=w->fresh=w->p8=BIRTH_NONE;return w;
    }
    p->refused++;return 0;
}
static char *birth_order_frame(struct birth_state *p,u32 *op) {
    if(!p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 bottom=top-size,fp=(u64)__builtin_frame_address(0);
    for(unsigned i=0;i<32;i++) {
        if((fp&15) || fp<bottom || fp>top-16)return 0;
        u64 *f=(u64 *)fp,next=f[0];
        if(pc_address((void *)f[1])==p->callback_pc) {
            u64 n=next;
            if((n&15) || n<=fp || n<bottom+0x30 || n>top-16 || pc_address(*(void **)(n+8))!=p->notification_pc)return 0;
            u64 post=*(u64 *)n;
            if((post&15) || post<=n || post<bottom+0x18 || post>top-16 || post-n!=0x30 ||
               pc_address(*(void **)(post+8))!=p->order_pc)return 0;
            *op=(u32)*(u64 *)(n-0x30);return *(char **)(post-8);
        }
        if(next<=fp)return 0;fp=next;
    }
    return 0;
}
static void birth_first_order(struct birth_state *p,struct birth_window *w,u32 op) {
    if(w->ordered || !op)return;
    w->ordered=1;
    char *win=birth_source(p,w);struct ctx *c=p->engine;
    if(!win || (op!=1 && (int)op!=-1) || !p->policy_epoch || c->ch->h.now>=p->authority_until ||
       !p->empty_clip || *(int *)(win+0x20)!=0 || *(u32 *)(win+0x8a0) ||
       ((*(u64 *)(win+0x928)>>44)&1) || (*(u64 *)(win+0x928)&(1ULL<<62)) ||
       *(void **)(win+0x160) || *(void **)(win+0x8d8))return;
    u32 was=c->in_cb;c->in_cb=1;c->clip((void *)w->creator,p->empty_clip,&w->wid,1);c->in_cb=was;
    if(*(void **)(win+0x160)!=p->empty_clip){p->refused++;return;}
    w->holding=1;w->policy_epoch=p->policy_epoch;w->expires=c->ch->h.now+2;
    w->revision=1;p->held++;birth_phase(w,BIRTH_HELD);
}
static int birth_capture_source(struct ctx *c,void *win,rect r,u64 token) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return 0;
    struct birth_window *w=birth_find(p,*(u32 *)win);
    return w && w->token==token && w->holding && birth_source(p,w)==win &&
        *(int *)((char *)win+0x20)==0 && ((*(u64 *)((char *)win+0x928)>>44)&1) &&
        !(*(u64 *)((char *)win+0x928)&(1ULL<<62)) && !*(void **)((char *)win+0x8d8) &&
        *(void **)((char *)win+0x160)==p->empty_clip && birth_rect_valid(r) && birth_rect_same(birth_bounds(p,win),r);
}
static unsigned birth_pool(struct birth_state *p,struct birth_window *w) {
    for(unsigned i=0;i<BIRTH_CAPTURES;i++)if(!p->captures[i].token) {
        struct birth_capture *a=&p->captures[i];birth_clear(a,sizeof(*a));
        birth_copy(&a->pixels,&p->capture_api,sizeof(a->pixels));
        a->pixels.magic=PC_MAGIC;a->pixels.size=sizeof(struct pc_capture);a->pixels.version=1;a->pixels.engine=p->engine;
        a->pixels.source=w->source;a->pixels.creator=w->creator;a->pixels.pid_version=w->pid_version;
        a->pixels.wid=w->wid;a->pixels.capture_rect=w->target;
        a->pixels.first_order_qualifier=2;a->pixels.birth_token=w->token;
        a->token=w->token;a->revision=w->revision;return i;
    }
    return BIRTH_NONE;
}
static int birth_adopt(struct birth_state *,struct birth_window *,const struct ch_cmd *,double);
static int birth_command(struct ctx *c,struct ch_cmd *k,double now) {
    struct birth_state *p=birth_state(c);
    if(k->op!=OP_BIRTH) {
        if(!birth_main(p))return 0;
        struct birth_window *w=birth_find(p,k->wid);
        if(w && w->holding && birth_source(p,w)) {
            if(k->op==OP_SNAP)return 1; // No second, unverified legacy acquisition.
            if(k->op==OP_FORGET || k->op==OP_SPACE) {
                if(!birth_abort(p,w,now,1))return 1;
                return 0; // The original command executes exactly once after release.
            }
        }
        if(w && w->holding && w->phase==BIRTH_PRESENTING) {
            if(k->op==OP_GEOM || k->op==OP_WARP) {
                rect target={k->x,k->y,k->w,k->h};
                if(birth_rect_valid(target) && !birth_rect_same(w->target,target)) {
                    w->target=target;w->revision++;
                    if(w->fresh<BIRTH_CAPTURES)p->captures[w->fresh].retiring=1;
                }
            }
        }
        return w && w->holding && w->phase!=BIRTH_PRESENTING;
    }
    if(!birth_main(p) || !p->enabled || p->dead)return 1;
    u32 action=k->flags&CH_BIRTH_ACTION_MASK;u64 token=((u64)k->pad1<<32)|k->pad0;
    if(!k->wid) {
        if(action==BIRTH_ARM && token && finite(k->x) && k->x>0 && k->x<=.5) {
            if(p->policy_epoch!=token)for(unsigned i=0;i<BIRTH_WINDOWS;i++)if(p->windows[i].holding)birth_cancel(p,&p->windows[i]);
            p->policy_epoch=token;p->authority_until=c->ch->h.now+k->x;
        } else if(action==BIRTH_DISARM) {
            p->authority_until=0;
            for(unsigned i=0;i<BIRTH_WINDOWS;i++)if(p->windows[i].holding)birth_cancel(p,&p->windows[i]);
        } else if(action==BIRTH_QUERY)for(unsigned i=0;i<BIRTH_WINDOWS;i++)p->windows[i].acknowledged=0;
        return 1;
    }
    struct birth_window *w=token?birth_token(p,k->wid,token):0;
    if(!w)return 1;
    if(action==BIRTH_ACK) {
        if(k->x==w->phase) {
            w->acknowledged=1;
            birth_reap(w);
        }
        return 1;
    }
    if(w->superseded)return 1;
    if(action==BIRTH_CANCEL){birth_cancel(p,w);return 1;}
    if(!w->holding || w->policy_epoch!=p->policy_epoch || c->ch->h.now>=p->authority_until || !birth_source(p,w))return 1;
    rect target={k->x,k->y,k->w,k->h};
    if(action==BIRTH_PREPARE && w->phase>=BIRTH_HELD && w->phase<=BIRTH_READY && birth_rect_valid(target) &&
       birth_capture_source(c,(void *)w->source,target,token)) {
        if(!birth_rect_same(w->target,target)) {
            w->target=target;w->revision++;
            if(w->pool<BIRTH_CAPTURES)p->captures[w->pool].retiring=1;
        }
        if(w->pool==BIRTH_NONE)w->pool=birth_pool(p,w);
        birth_phase(w,BIRTH_PREPARING);
    } else if(action==BIRTH_CLAIM && w->phase==BIRTH_READY)birth_adopt(p,w,k,now);
    return 1;
}
unsigned anim_birth_production_size(void){return sizeof(struct birth_state);}

static int birth_capture_ready(struct birth_state *p,struct birth_window *w,unsigned index) {
    if(index>=BIRTH_CAPTURES)return 0;
    struct birth_capture *a=&p->captures[index];struct pc_capture *v=&a->pixels;
    if(a->retiring || a->token!=w->token || a->revision!=w->revision || v->stage!=PC_GPU_COMPLETE || v->reason ||
       v->gpu_status!=4 || v->gpu_pending || !v->capture_witness || !v->source_unchanged ||
       !v->present_unchanged || v->baked_alpha!=1 || !v->texture_ref || !v->command_buffer || !v->client_included)return 0;
    char *source=birth_source(p,w);
    if(!source || !birth_capture_source(p->engine,source,v->capture_rect,w->token))return 0;
    char *cwc=*(char **)(source+0x18);
    void *context=cwc?*(void **)(cwc+0x30):0;
    // A later client redraw does not invalidate an immutable GPU-complete copy.
    // Context replacement and configure revision do. This does not yet prove a
    // client post-configure buffer commit; that requires a separate native witness.
    return context && (u64)context==v->context && v->client_context && v->client_id &&
        *(u64 *)(cwc+0x48)==v->client_context && *(u32 *)(cwc+0x50)==v->client_id;
}
// CLAIM's entire validation precedes slot allocation and any native mutation.
static int birth_adopt(struct birth_state *p,struct birth_window *w,const struct ch_cmd *k,double now) {
    struct ctx *c=p->engine;rect target={k->x,k->y,k->w,k->h},from={k->fx,k->fy,k->fw,k->fh};
    if(!birth_rect_valid(target) || !birth_rect_valid(from) || !birth_rect_same(target,w->target) ||
       !finite(k->a) || k->a<0 || k->a>1 || !finite(k->fa) || k->fa<0 || k->fa>1 ||
       k->cpos>CH_INSTANT || k->csize>CH_INSTANT || k->calpha>CH_INSTANT ||
       !finite(k->dpos) || !finite(k->dsize) || !finite(k->dalpha) ||
       k->dpos<0 || k->dsize<0 || k->dalpha<0 || k->dpos>40 || k->dsize>40 || k->dalpha>40 ||
       !c->set_level || !c->order || !birth_capture_ready(p,w,w->pool))return 0;
    struct birth_capture *a=&p->captures[w->pool];struct pc_capture *v=&a->pixels;
    char *source=birth_source(p,w),*shell=v->clone;
    if(!shell || c->by_id(v->clone_wid)!=shell || *(void **)(shell+0x30) ||
       *(void **)(shell+0x8b0)!=v->capture || !v->capture || slot(c->ch,v->clone_wid,0))return 0;
    unsigned free_slots=0;int index=-1;
    for(unsigned i=0;i<CH_NW;i++)free_slots+=!c->ch->win[i].used;
    for(unsigned i=0;i<P8_N;i++)if(!P8_TAB(c)[i].live){index=(int)i;break;}
    if(index<0 || free_slots<(slot(c->ch,w->wid,0)?1u:2u))return 0;
    struct ch_win *sw=slot(c->ch,w->wid,1),*cw=slot(c->ch,v->clone_wid,1);
    double fp[2]={from.x,from.y},fs[2]={from.w,from.h},tp[2]={target.x,target.y},ts[2]={target.w,target.h};
    double fa[1]={k->fa},ta[1]={k->a};
    warp(&sw->pos,2,fp);warp(&sw->size,2,fs);warp(&sw->alpha,1,fa);
    retarget(c,&sw->pos,2,tp,k->cpos,k->dpos,now);retarget(c,&sw->size,2,ts,k->csize,k->dsize,now);
    retarget(c,&sw->alpha,1,ta,k->calpha,k->dalpha,now);
    sw->cur_alpha=k->fa;sw->geo=1;sw->stretch=1;sw->held=sw->needs=sw->wait=0;sw->settling=1;
    actual(c,sw,(void **)&source);
    cw->geo=1;cw->held=1;cw->stretch=1;cw->needs=cw->wait=0;cw->cur_alpha=0;
    warp(&cw->pos,2,fp);warp(&cw->size,2,fs);warp(&cw->alpha,1,fa);
    u32 was=c->in_cb;c->in_cb=1;
    c->set_level(shell,0,*(int *)(source+0x20),*(short *)(source+0x28));
    c->set_alpha(0,shell,0,0);c->in_cb=was;
    a->shell=(u64)shell;a->surface=(u64)v->capture;a->shell_wid=v->clone_wid;
    struct p8c *e=&P8_TAB(c)[index];
    *e=(struct p8c){v->clone_wid,w->wid,now,0,4};
    P8_SOURCE(c)[index]=w->source;P8_EPOCH(c)[index]=0;
    w->p8=(u32)index;birth_phase(w,BIRTH_PRESENTING);
    e->live=1; // Full token and both raw identities already live in private state.
    a->adopted=1;v->stage=PC_ADOPTED;v->clone=0;v->capture=0;v->clone_wid=0;
    return 1;
}
static int birth_p8_matches(struct birth_state *p,struct birth_window *w) {
    if(w->p8>=P8_N || w->pool>=BIRTH_CAPTURES)return 0;
    struct p8c *e=&P8_TAB(p->engine)[w->p8];struct birth_capture *a=&p->captures[w->pool];
    char *shell=p->engine->by_id(a->shell_wid);
    return e->live && e->pending==4 && e->src==w->wid && e->wid==a->shell_wid &&
        P8_SOURCE(p->engine)[w->p8]==w->source && a->token==w->token && a->adopted &&
        shell==(void *)a->shell && shell && !*(void **)(shell+0x30) && *(u64 *)(shell+0x8b0)==a->surface;
}
static struct birth_window *birth_p8(struct birth_state *p,unsigned index) {
    for(unsigned i=0;i<BIRTH_WINDOWS;i++)if(p->windows[i].wid && p->windows[i].p8==index && birth_p8_matches(p,&p->windows[i]))return &p->windows[i];
    return 0;
}
static void birth_pool_retire(struct birth_state *p,struct birth_window *w) {
    if(w->pool<BIRTH_CAPTURES)p->captures[w->pool].retiring=1;
    if(w->fresh<BIRTH_CAPTURES)p->captures[w->fresh].retiring=1;
}
static int birth_channel(struct birth_state *p) {
    struct ch *ch=p->engine->ch;
    return ch && ch->h.magic==CH_MAGIC && ch->h.size==sizeof(*ch);
}
static int birth_shell_live(struct birth_state *p,struct birth_capture *a) {
    char *shell=p->engine->by_id(a->shell_wid);
    return a->adopted && shell && shell==(void *)a->shell && !*(void **)(shell+0x30) &&
        *(u64 *)(shell+0x8b0)==a->surface;
}
// This touches only the retained, identity-qualified shell. In particular it
// never emits the legacy untagged EV_GONE for a possibly reused source WID.
static void birth_drop_cover(struct birth_state *p,struct birth_window *w) {
    struct ctx *c=p->engine;
    if(w->pool<BIRTH_CAPTURES) {
        struct birth_capture *a=&p->captures[w->pool];
        if(a->token==w->token && a->adopted) {
            if(w->p8<P8_N) {
                struct p8c *e=&P8_TAB(c)[w->p8];
                if(e->pending==4 && e->src==w->wid && e->wid==a->shell_wid &&
                   P8_SOURCE(c)[w->p8]==w->source) {
                    e->live=0;P8_SOURCE(c)[w->p8]=0;P8_EPOCH(c)[w->p8]=0;
                }
            }
            if(birth_shell_live(p,a)) {
                char *shell=(char *)a->shell;
                struct ch_win *cw=birth_channel(p)?slot(c->ch,a->shell_wid,0):0;
                u32 was=c->in_cb;c->in_cb=1;c->set_alpha(0,shell,0,0);
                if(cw){cw->held=0;put_plain(c,cw,shell);slot_free(c,cw,shell);}
                p8_free_win(c,shell);c->in_cb=was;
            }
        }
    }
    w->p8=BIRTH_NONE;birth_pool_retire(p,w);
}
static void birth_forget_slot(struct birth_state *p,u32 wid) {
    struct ctx *c=p->engine;
    struct ch_win *sw=birth_channel(p)?slot(c->ch,wid,0):0;
    if(sw) {
        // Revoke local helpers without sending anything to the replacement,
        // including when its raw pointer happens to equal the old allocation.
        if(c->edges) {
            unsigned i=(unsigned)(sw-c->ch->win);
            c->edges[i].source_window=0;c->edges[i].source_id=0;
            struct edge_lease *lease=live_edge_lease(c,sw);
            lease->on=0;c->pending_edge_generation[i]=0;
        }
        sw->geo=0;slot_free(c,sw,0);
    }
}
static void birth_supersede(struct birth_state *p,struct birth_window *w) {
    w->superseded=1;w->holding=0; // Invalidate old native authority before cleanup.
    birth_drop_cover(p,w);birth_forget_slot(p,w->wid);
    if(!w->phase && w->pool==BIRTH_NONE && w->fresh==BIRTH_NONE)birth_clear(w,sizeof(*w));
    else birth_phase(w,BIRTH_GONE);
}
// Cancellation is a synchronous ownership handoff, never a request for another
// capture. It also works after the consumer/channel has stopped. In-flight GPU
// resources may quarantine; neither a visible shell nor our EMPTY may remain.
static int birth_abort(struct birth_state *p,struct birth_window *w,double now,int plain) {
    struct ctx *c=p->engine;char *source=birth_source(p,w);
    int channel=birth_channel(p),conflict=w->phase==BIRTH_CONFLICT;
    struct ch_win *sw=channel && w->p8!=BIRTH_NONE?slot(c->ch,w->wid,0):0;
    struct p8c *e=birth_p8_matches(p,w)?&P8_TAB(c)[w->p8]:0;
    if(source && w->holding && (*(void **)(source+0x160)!=p->empty_clip || *(void **)(source+0x8d8))) {
        conflict=1;birth_conflict(p,w);w->desired_on=0;
    }
    if(e)e->live=0; // Source state may be prepared while EMPTY is still held.
    if(source && sw && !conflict) {
        if(plain)put_plain(c,sw,source);
        else {sw->held=0;sw->wait=0;frame_win(c,sw,now);}
        double a=plain==2?1:finite(sw->cur_alpha)?sw->cur_alpha:1;
        u32 was=c->in_cb;c->in_cb=1;c->set_alpha(0,source,(float)(a<0?0:a>1?1:a),0);c->in_cb=was;
        if(plain==2)sw->cur_alpha=1;
    }
    if(!channel)w->desired_on=0;
    if(!birth_unclip(p,w)){if(e)e->live=1;return 0;}
    if(source && sw && plain && !conflict) {
        sw->held=sw->wait=sw->needs=sw->settling=0;slot_free(c,sw,source);
    }
    if(conflict)birth_forget_slot(p,w->wid);
    birth_drop_cover(p,w);w->cancel=1;
    birth_phase(w,conflict?BIRTH_CONFLICT:BIRTH_CANCELLED);return 1;
}
static void birth_departed(struct birth_state *p,struct birth_window *w,double now) {
    struct ctx *c=p->engine;
    w->holding=0;birth_pool_retire(p,w);
    if(birth_p8_matches(p,w)) {
        struct ch_win *cw=slot(c->ch,P8_TAB(c)[w->p8].wid,0);
        if(cw){cw->held=0;cw->wait=0;cw->stretch=1;}
        u32 was=c->in_cb;c->in_cb=1;p8_go(c,(int)w->p8,now);c->in_cb=was;
        w->p8=BIRTH_NONE;
    }
    birth_phase(w,BIRTH_GONE);
}
static int birth_source_release(struct ctx *c,char *source,double now) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return 0;
    struct birth_window *w=birth_find(p,*(u32 *)source);
    if(!w || w->source!=(u64)source || *(u64 *)(source+0x30)!=w->creator ||
       !w->creator || *(u64 *)((char *)w->creator+0x268)!=w->pid_version)return 0;
    if(!w->phase){birth_clear(w,sizeof(*w));return 0;}
    birth_departed(p,w,now);return 1;
}
static int birth_retire_cover(struct ctx *c,unsigned index,int stopping,double now) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return 0;
    struct birth_window *w=birth_p8(p,index);if(!w)return 0;
    if(stopping || w->cancel)return birth_abort(p,w,now,stopping?2:0);
    char *source=birth_source(p,w);
    if(!source){birth_departed(p,w,now);return 1;}
    struct ch_win *sw=slot(c->ch,w->wid,0);
    if(!sw)return birth_abort(p,w,now,1);
    // A second owned candidate witnesses the final configure, rather than
    // treating the initial frozen image or stable bounds as fresh native pixels.
    if(sw->pos.active || sw->size.active || sw->alpha.active || sw->held)return 1;
    if(w->fresh==BIRTH_NONE)w->fresh=birth_pool(p,w);
    if(!birth_capture_ready(p,w,w->fresh))return 1;
    struct p8c *e=&P8_TAB(c)[index];unsigned clone_id=e->wid;
    char *clone=c->by_id(clone_id);struct ch_win *cw=slot(c->ch,clone_id,0);
    e->live=0; // frame_win now prepares source B while the manager clip is held.
    sw->settling=1;sw->wait=0;frame_win(c,sw,now);
    // The clone suppressed native alpha writes while logical cur_alpha advanced.
    // Synchronize explicitly before unclip; cached equality is not an applied ACK.
    double a=finite(sw->cur_alpha)?sw->cur_alpha:1;
    u32 alpha_was=c->in_cb;c->in_cb=1;c->set_alpha(0,source,(float)(a<0?0:a>1?1:a),0);c->in_cb=alpha_was;
    if(!birth_unclip(p,w)){e->live=1;return 1;}
    u32 was=c->in_cb;c->in_cb=1;
    if(clone)c->set_alpha(0,clone,0,0);
    if(cw){cw->held=0;if(clone)put_plain(c,cw,clone);slot_free(c,cw,clone);}
    if(clone && !*(void **)(clone+0x30))p8_free_win(c,clone);
    c->in_cb=was;P8_SOURCE(c)[index]=0;P8_EPOCH(c)[index]=0;
    w->p8=BIRTH_NONE;birth_pool_retire(p,w);p->revealed++;birth_phase(w,BIRTH_REVEALED);return 1;
}
static void birth_clone_frame(struct ctx *c,struct ch_win *cw,struct ch_win *sw,double now) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return;
    int index=cover_index(c,sw->wid,1);
    struct birth_window *w=index>=0?birth_p8(p,(unsigned)index):0;if(!w)return;
    char *clone=c->by_id(cw->wid),*cwc=clone?*(char **)(clone+0x18):0;
    void *context=cwc?*(void **)(cwc+0x38):0;
    unsigned long long transaction[4]={0};
    if(context && deco_ready(c)){c->tx_ctor(transaction,1);c->tx_add(transaction,context);}else context=0;
    double position[2]={sw->pos.v[0],sw->pos.v[1]},size[2]={sw->size.v[0],sw->size.v[1]},alpha[1]={sw->cur_alpha};
    warp(&cw->pos,2,position);warp(&cw->size,2,size);warp(&cw->alpha,1,alpha);
    cw->held=1;cw->wait=cw->needs=0;cw->geo=1;cw->stretch=1;
    frame_win(c,cw,now); // Held sample: no second animation clock or completion crop.
    if(context){border_win(c,cw,now);layers_commit(c,transaction);}
    if(clone && !((*(u64 *)(clone+0x928)>>44)&1)) {
        u32 was=c->in_cb;c->in_cb=1;c->order(0,cw->wid,1,sw->wid);c->in_cb=was;
    }
}
void anim_birth_production_observe(u32 type,void *data,u32 length,struct birth_state *p) {
    if(!p || p->magic!=BIRTH_MAGIC || p->size!=sizeof(*p) || p->version!=1)return;
    p->callbacks++;if(!birth_main(p)){p->nonmain++;return;}
    if(!birth_live(p) || !p->registered)return;
    if(type==0x3e8 && data && length==8){birth_reserve(p,data);return;}
    if(type==0x3e9 && data && length==8){birth_source_release(p->engine,data,p->engine->ch->h.now);return;}
    if(type==0x3ee && !data && !length) {
        u32 op=0;char *win=birth_order_frame(p,&op);
        if(!win)return;
        struct birth_window *w=birth_find(p,*(u32 *)win);
        if(w && birth_source(p,w)==win)birth_first_order(p,w,op);
    }
}
void anim_birth_production_frame(void *mctx,void *display,void *third,struct birth_state *p) {
    if(!p || p->magic!=BIRTH_MAGIC || p->size!=sizeof(*p) || p->version!=1)return;
    if(!birth_main(p)){p->nonmain++;return;}
    for(unsigned i=0;i<BIRTH_CAPTURES;i++)if(p->captures[i].token && !p->captures[i].retiring && !p->captures[i].adopted)
        anim_cache_frame(mctx,display,third,&p->captures[i].pixels);
}
static void birth_tick(struct ctx *c,double now,int after) {
    struct birth_state *p=birth_state(c);if(!birth_main(p))return;
    int channel=birth_channel(p);
    if(c->in_cb)return;
    int stopping=!channel || p->dead || !p->enabled || c->dead || c->ch->h.stop;
    if(!after) {
        p->dispatches++;
        if(!stopping && !p->registered && c->add_cb && c->rm_cb && p->callback && p->region_empty && c->rgn && c->clip && c->release) {
            if(!p->empty_clip)p->empty_clip=c->rgn((rect){0});
            if(p->empty_clip && p->region_empty(p->empty_clip) && birth_frame_node(p,1)) {
                c->add_cb(p->callback,0x3e8,p);c->add_cb(p->callback,0x3ee,p);c->add_cb(p->callback,0x3e9,p);p->registered=1;
            }
        }
        if(stopping && p->registered && c->rm_cb) {
            c->rm_cb(p->callback,0x3e8,p);c->rm_cb(p->callback,0x3ee,p);c->rm_cb(p->callback,0x3e9,p);p->registered=0;
        }
        if(stopping)birth_frame_node(p,0);
        if(channel) {
            if(p->advertise && !stopping && p->registered)c->ch->h.version|=CH_CAP_BIRTH;
            else c->ch->h.version&=~CH_CAP_BIRTH;
        }
        if(p->scope_pid && !stopping) {
            u64 sequence=__atomic_load_n(&p->fixture_sequence,__ATOMIC_ACQUIRE);
            if(sequence!=p->fixture_ack) {
                struct ch_cmd k;birth_copy(&k,&p->fixture_command,sizeof(k));
                if(__atomic_load_n(&p->fixture_sequence,__ATOMIC_ACQUIRE)==sequence) {
                    p->fixture_result=birth_command(c,&k,now);__atomic_store_n(&p->fixture_ack,sequence,__ATOMIC_RELEASE);
                }
            }
        }
    }
    for(unsigned i=0;i<BIRTH_WINDOWS;i++) {
        struct birth_window *w=&p->windows[i];if(!w->wid)continue;
        char *source=birth_source(p,w);
        int role_lost=source && (*(int *)(source+0x20)!=0 || *(u32 *)(source+0x8a0) ||
            !((*(u64 *)(source+0x928)>>44)&1) || (*(u64 *)(source+0x928)&(1ULL<<62)));
        role_lost|=source && w->holding &&
            (*(void **)(source+0x160)!=p->empty_clip || *(void **)(source+0x8d8));
        if(w->holding && (stopping || role_lost))birth_abort(p,w,now,stopping?2:1);
        else if(w->holding && (!source || now>=p->authority_until || now>=w->expires))birth_cancel(p,w);
        if(!stopping && w->phase==BIRTH_PREPARING && w->pool==BIRTH_NONE)w->pool=birth_pool(p,w);
        if(w->phase==BIRTH_PREPARING && birth_capture_ready(p,w,w->pool))birth_phase(w,BIRTH_READY);
        if(channel && w->phase && !w->acknowledged && now>=w->replay && birth_event(p,w,now))w->replay=now+.05;
        birth_reap(w);
    }
    if(!after)return;
    for(unsigned i=0;i<BIRTH_CAPTURES;i++) {
        struct birth_capture *a=&p->captures[i];if(!a->token)continue;
        struct pc_capture *v=&a->pixels;
        if(a->retiring) {
            if(birth_shell_live(p,a))continue;
            if(anim_cache_destroy(v)) {
                for(unsigned j=0;j<BIRTH_WINDOWS;j++)if(p->windows[j].token==a->token) {
                    if(p->windows[j].pool==i)p->windows[j].pool=BIRTH_NONE;
                    if(p->windows[j].fresh==i)p->windows[j].fresh=BIRTH_NONE;
                    birth_reap(&p->windows[j]);
                }
                birth_clear(a,sizeof(*a));
            }
            continue;
        }
        if(a->adopted)continue;
        struct birth_window *w=birth_token(p,v->wid,a->token);
        if(stopping || !w || w->superseded || a->revision!=w->revision ||
           v->stage==PC_GPU_ERROR || v->stage==PC_INVALID) {a->retiring=1;continue;}
        if(v->stage==PC_GPU_COMPLETE && !birth_capture_ready(p,w,i)) {
            char *source=birth_source(p,w),*cwc=source?*(char **)(source+0x18):0;
            void *context=cwc?*(void **)(cwc+0x30):0;
            if(!context || (u64)context!=v->context || !v->client_included ||
               (cwc && (*(u64 *)(cwc+0x48)!=v->client_context || *(u32 *)(cwc+0x50)!=v->client_id)) ||
               (v->baked_alpha!=1 && cwc && *(float *)(cwc+0x174)!=v->baked_alpha)) {
                a->retiring=1;
                if(w->phase==BIRTH_READY)birth_phase(w,BIRTH_PREPARING);
            }
        }
        if(v->stage==PC_EMPTY && !stopping) {
            v->prepare_idle_permit=0x31454c44494350ULL;
            if(anim_cache_prepare(v) && p->schedule_all)p->schedule_all(0,0);
        } else if(v->stage==PC_ENCODED)anim_cache_poll(v);
    }
    if(stopping && !p->registered && p->empty_clip) {
        int holding=0;for(unsigned i=0;i<BIRTH_WINDOWS;i++)holding|=p->windows[i].holding;
        if(!holding){c->release(p->empty_clip);p->empty_clip=0;}
    }
}
