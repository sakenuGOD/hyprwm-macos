// First-order qualifier. Default observes only; the explicit one-window gate is
// restricted by the root driver to its known ordinary disposable fixture.
#define BO_MAGIC 0x31545249424d5748ULL
#define BO_STATE 0x6f0
#define BO_ORIGINAL 0x6f8
#define BO_WINDOWS 16
#define BO_RECORDS 128
struct bo_record {
    u64 clock,window,creator,pid_version;
    u32 event,wid,op,on,level,flags;
    float alpha[4]; // native base, system, third factor, target
    rect bounds;
};
struct bo_window {u64 window,creator,pid_version;u32 wid,ordered;struct bo_record last;};
struct bo_lease {double expires;float original_target;u32 held;};
struct bo_clip_sample {u64 manager,native,effective;u32 empty,flags;float alpha[4];};
struct bo_state {
    u64 magic;u32 size,version;
    struct ctx *engine;
    void *callback;
    int (*is_main)(void);
    void *(*thread_self)(void);
    void *(*stack_top)(void *);
    u64 (*stack_size)(void *);
    u64 callback_pc,notification_pc,order_pc;
    u32 pid,dead,registered,command;
    u64 sequence,ack,dispatches,callbacks,nonmain,wrong_frame,count,dropped;
    struct bo_window windows[BO_WINDOWS];
    struct bo_record records[BO_RECORDS];
    u32 gate,gates_left;
    u64 held_count,claimed_count,expired_count,conflict_count;
    struct bo_lease leases[BO_WINDOWS];
    // Gate2 is a one-birth clip qualifier, not production admission. All fields
    // are appended so root can validate and retire an older observer receipt.
    int (*region_empty)(void *);
    void *empty_clip;
    u64 clip_held,clip_released,clip_conflicts;
    struct bo_clip_sample clips[BO_WINDOWS];
};
_Static_assert(sizeof(struct bo_state)<=0x8000,"birth qualifier mapping");
static int bo_live(struct bo_state *p) {
    if(!p || p->magic!=BO_MAGIC || p->size!=sizeof(*p) || p->version!=1 || !p->is_main || p->is_main()!=1)return 0;
    struct ctx *c=p->engine;
    return p->thread_self && p->stack_top && p->stack_size && c && !c->dead && !c->in_cb && c->ch && c->ch->h.magic==CH_MAGIC &&
        c->ch->h.size==sizeof(struct ch) && !c->ch->h.stop;
}
static struct bo_window *bo_window(struct bo_state *p,char *win,int create) {
    struct ctx *c=p->engine;
    if(!win || *(u32 *)(win+4)!=5)return 0;
    u32 wid=*(u32 *)win;
    if(!wid || c->by_id(wid)!=win)return 0;
    char *creator=*(char **)(win+0x30);if(!creator)return 0;
    u64 version=*(u64 *)(creator+0x268);
    if((u32)version!=p->pid)return 0;
    struct bo_window *empty=0;
    for(unsigned i=0;i<BO_WINDOWS;i++) {
        struct bo_window *w=&p->windows[i];
        if(!w->window){if(!empty)empty=w;continue;}
        if(w->window==(u64)win && w->wid==wid && w->creator==(u64)creator && w->pid_version==version)return w;
    }
    if(!create || !empty || *(int *)(win+0x20)!=0)return 0;
    empty->window=(u64)win;empty->creator=(u64)creator;empty->pid_version=version;empty->wid=wid;return empty;
}
static void bo_record(struct bo_state *p,struct bo_window *w,u32 type,u32 op) {
    char *win=(char *)w->window;struct ctx *c=p->engine;struct bo_record r={0};
    r.clock=c->mabs?c->mabs():0;r.window=w->window;r.creator=w->creator;r.pid_version=w->pid_version;
    r.event=type;r.wid=w->wid;r.op=op;r.on=(u32)((*(u64 *)(win+0x928)>>44)&1);
    r.level=*(u32 *)(win+0x20);r.flags=(unsigned char)win[0x92d];
    __builtin_memcpy(r.alpha,win+0x1d8,16);
    void *shape=*(void **)(win+c->shape_off);if(shape)r.bounds=c->bbox(shape);
    if(type==0x3ea && w->last.on==r.on && w->last.flags==r.flags &&
       pc_same((void *)w->last.alpha,(void *)r.alpha,16) && pc_same((void *)&w->last.bounds,(void *)&r.bounds,sizeof(rect)))return;
    w->last=r;
    if(p->count<BO_RECORDS)p->records[p->count++]=r;else p->dropped++;
}
static char *bo_order_frame(struct bo_state *p,u32 *op) {
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
            if((post&15) || post<=n || post<bottom+0x18 || post>top-16 ||
               pc_address(*(void **)(post+8))!=p->order_pc || post-n!=0x30)return 0;
            *op=(u32)*(u64 *)(n-0x30);return *(char **)(post-8);
        }
        if(next<=fp)return 0;fp=next;
    }
    return 0;
}
static void bo_first_hold(struct bo_state *p,struct bo_window *w,u32 op) {
    char *win=(char *)w->window;struct ctx *c=p->engine;
    if((p->gate!=1 && p->gate!=2) || !p->gates_left || w->ordered || *(int *)(win+0x20)!=0 || (op!=1 && (int)op!=-1) ||
       ((*(u64 *)(win+0x928)>>44)&1) || *(u32 *)(win+0x8a0) || *(void **)(win+0x8e0) ||
       *(float *)(win+0x1d8)!=1 || *(float *)(win+0x1dc)!=1 ||
       *(float *)(win+0x1e0)!=1 || *(float *)(win+0x1e4)!=1 || !c->set_alpha)return;
    struct bo_lease *lease=&p->leases[w-p->windows];
    if(p->gate==2) {
        if(!p->empty_clip || !p->region_empty || !c->clip || *(void **)(win+0x160) ||
           *(void **)(win+0x8d8) || (*(u64 *)(win+0x928)&(1ULL<<62)))return;
        u32 was=c->in_cb;c->in_cb=1;
        c->clip((void *)w->creator,p->empty_clip,&w->wid,1);c->in_cb=was;
        // Own region stays retained until every lease is retired, excluding
        // pointer reuse. A foreign replacement never gives us restore rights.
        if(*(void **)(win+0x160)!=p->empty_clip)return;
        lease->held=1;lease->expires=c->ch->h.now+30;
        p->gates_left--;p->held_count++;p->clip_held++;bo_record(p,w,0xb011,op);
        return;
    }
    lease->original_target=*(float *)(win+0x1e4);
    u32 was=c->in_cb;c->in_cb=1;c->set_alpha(0,win,0,0);c->in_cb=was;
    if(*(float *)(win+0x1e4)!=0)return;
    lease->held=1;lease->expires=c->ch->h.now+0.5;
    p->gates_left--;p->held_count++;bo_record(p,w,0xb001,op);
}
static void bo_retire_leases(struct bo_state *p,double now,int revoke) {
    struct ctx *c=p->engine;
    for(unsigned i=0;i<BO_WINDOWS;i++) {
        struct bo_lease *lease=&p->leases[i];struct bo_window *w=&p->windows[i];
        if(!lease->held)continue;
        char *win=c->by_id(w->wid);
        if(win!=(void *)w->window || bo_window(p,win,0)!=w){lease->held=0;continue;}
        if(p->gate==2) {
            struct bo_clip_sample *sample=&p->clips[i];
            sample->manager=*(u64 *)(win+0x160);sample->native=*(u64 *)(win+0x148);
            sample->effective=*(u64 *)(win+0x110);sample->flags=(u32)(*(u64 *)(win+0x928)>>32);
            sample->empty=sample->effective && p->region_empty((void *)sample->effective);
            __builtin_memcpy(sample->alpha,win+0x1d8,16);
            if(sample->manager!=(u64)p->empty_clip || *(void **)(win+0x8d8)) {
                lease->held=0;p->clip_conflicts++;bo_record(p,w,0xb014,0);continue;
            }
            // Explicit command3, OFF, or the recovery deadline only. Geometry
            // and native alpha are deliberately NOT a clip handoff witness.
            if(revoke || p->dead || now>=lease->expires) {
                u32 was=c->in_cb;c->in_cb=1;c->clip((void *)w->creator,0,&w->wid,1);c->in_cb=was;
                if(*(void **)(win+0x160)==p->empty_clip) {
                    if(lease->held==1){lease->held=2;p->clip_conflicts++;}continue;
                }
                lease->held=0;p->expired_count++;p->clip_released++;bo_record(p,w,0xb013,0);
            }
            continue;
        }
        struct ch_win *engine=!revoke?slot(c->ch,w->wid,0):0;
        float base=*(float *)(win+0x1d8),target=*(float *)(win+0x1e4);
        double logical=engine?engine->cur_alpha:0;
        if(logical<0)logical=0;else if(logical>1)logical=1;
        if(engine && engine->geo && engine->alpha.g[0]>0 &&
           ((*(u64 *)(win+0x928)>>44)&1) && dabs(base-logical)<0.00001 &&
           dabs(target-logical)<0.00001 && dabs(engine->alpha.v[0]-engine->cur_alpha)<0.00001) {
            // A fresh geometry slot alone defaults to logical alpha1. Require
            // native base+target to match its actual alpha sample before handing
            // off; otherwise an instant ALPHA1 could skip the native write.
            lease->held=0;p->claimed_count++;bo_record(p,w,0xb002,0);continue;
        }
        if(target!=0) {
            // A later owner has replaced the target. It now owns visibility.
            lease->held=0;p->conflict_count++;bo_record(p,w,0xb004,0);continue;
        }
        if(revoke || p->dead || now>=lease->expires) {
            // Recovery only, never a readiness condition. Respect a replacement
            // owner alpha. Before order our zero target can still have base1;
            // after order it has base0. Both are this lease's expected states.
            if(base==0 || base==lease->original_target) {
                u32 was=c->in_cb;c->in_cb=1;c->set_alpha(0,win,lease->original_target,0);c->in_cb=was;
                lease->held=0;p->expired_count++;bo_record(p,w,0xb003,0);
            } else if(lease->held==1) {
                // An unrecognized alpha writer is not permission to restore1.
                // Retain this exact resource and make failed OFF observable.
                lease->held=2;p->conflict_count++;bo_record(p,w,0xb005,0);
            }
        }
    }
}
void anim_birth_observe(u32 type,void *data,u32 length,struct bo_state *p) {
    if(!p || p->magic!=BO_MAGIC || p->size!=sizeof(*p) || p->version!=1 || p->dead)return;
    __atomic_fetch_add(&p->callbacks,1,__ATOMIC_RELAXED);
    if(!p->is_main || p->is_main()!=1){__atomic_fetch_add(&p->nonmain,1,__ATOMIC_RELAXED);return;}
    if(!bo_live(p) || !p->registered)return;
    if(type==0x3e8 && data && length==8) {
        struct bo_window *w=bo_window(p,data,1);if(w)bo_record(p,w,type,0);return;
    }
    if(type==0x3ee && !data && !length) {
        u32 op=0;char *win=bo_order_frame(p,&op);
        if(!win){p->wrong_frame++;return;}
        struct bo_window *w=bo_window(p,win,0);
        if(w){bo_record(p,w,type,op);bo_first_hold(p,w,op);if((int)op!=0)w->ordered=1;}
        return;
    }
    if(type==0x3ea)for(unsigned i=0;i<BO_WINDOWS;i++) {
        struct bo_window *w=&p->windows[i];
        if(w->window && w->ordered && p->engine->by_id(w->wid)==(void *)w->window && bo_window(p,(char *)w->window,0)==w)bo_record(p,w,type,0);
    }
}
unsigned anim_birth_state_size(void){return sizeof(struct bo_state);}
// Positive eligibility for the clipped-buffer qualifier. No engine geometry is
// required: this exact cold source has not been adopted or revealed yet.
static int first_order_capture_source(struct ctx *c,void *source,rect r) {
    struct bo_state *p=*(void **)((char *)c+BO_STATE);
    if(!p || p->engine!=c || !bo_live(p) || p->dead || !p->registered || p->gate!=2 || !p->empty_clip)return 0;
    struct bo_window *w=bo_window(p,source,0);
    if(!w || p->leases[w-p->windows].held!=1 || *(void **)((char *)source+0x160)!=p->empty_clip ||
       *(void **)((char *)source+0x8d8) || (*(u64 *)((char *)source+0x928)&(1ULL<<62)))return 0;
    void *shape=*(void **)((char *)source+c->shape_off);if(!shape)return 0;
    rect actual=c->bbox(shape);
    return __builtin_isfinite(r.x) && __builtin_isfinite(r.y) && r.w>=1 && r.h>=1 &&
        dabs(actual.x-r.x)<.5 && dabs(actual.y-r.y)<.5 && dabs(actual.w-r.w)<.5 && dabs(actual.h-r.h)<.5;
}
void anim_birth_dispatch(struct ctx *c,double now) {
    void (*original)(struct ctx *,double)=*(void (**)(struct ctx *,double))((char *)c+BO_ORIGINAL);
    if(!original)return;
    struct bo_state *p=*(void **)((char *)c+BO_STATE);
    int valid=p && p->magic==BO_MAGIC && p->size==sizeof(*p) && p->version==1 && p->engine==c;
    // Original stop does not schedule a successor. Revoke our own unadopted
    // holds before that final tick, including a mismatched channel version.
    if(valid && p->is_main && p->is_main()==1 && !c->in_cb && c->by_id && c->set_alpha &&
       (c->dead || !c->ch || c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=sizeof(struct ch) || c->ch->h.stop)) {
        p->dead=1;bo_retire_leases(p,now,1);
        if(p->registered && c->rm_cb) {
            c->rm_cb(p->callback,0x3e8,p);c->rm_cb(p->callback,0x3ee,p);c->rm_cb(p->callback,0x3ea,p);p->registered=0;
        }
        int held=0;for(unsigned i=0;i<BO_WINDOWS;i++)held|=p->leases[i].held;
        if(!held && p->empty_clip && c->release){c->release(p->empty_clip);p->empty_clip=0;}
        if(!p->registered) {p->command=0;p->ack=p->sequence;}
    }
    original(c,now);
    if(!valid)return;
    p->dispatches++;
    if(!bo_live(p) || !c->add_cb || !c->rm_cb)return;
    bo_retire_leases(p,now,0);
    u64 sequence=__atomic_load_n(&p->sequence,__ATOMIC_ACQUIRE);
    if(sequence==p->ack)return;
    u32 command=__atomic_exchange_n(&p->command,0,__ATOMIC_ACQ_REL);
    if(!command)return;
    if(__atomic_load_n(&p->sequence,__ATOMIC_ACQUIRE)!=sequence) {
        u32 empty=0;__atomic_compare_exchange_n(&p->command,&empty,command,0,__ATOMIC_RELEASE,__ATOMIC_RELAXED);return;
    }
    if(command==1 && !p->dead && !p->registered) {
        if(p->gate==2) {
            if(!p->region_empty || !c->rgn || !c->clip || !c->release)return;
            p->empty_clip=c->rgn((rect){0,0,0,0});
            if(!p->empty_clip || !p->region_empty(p->empty_clip)) {
                if(p->empty_clip)c->release(p->empty_clip);p->empty_clip=0;return;
            }
        }
        c->add_cb(p->callback,0x3e8,p);c->add_cb(p->callback,0x3ee,p);c->add_cb(p->callback,0x3ea,p);p->registered=1;
    } else if(command==2 && p->dead) {
        c->rm_cb(p->callback,0x3e8,p);c->rm_cb(p->callback,0x3ee,p);c->rm_cb(p->callback,0x3ea,p);p->registered=0;
    } else if(command==3 && p->gate==2) {
        bo_retire_leases(p,now,1);
    } else return;
    if(p->empty_clip && (p->dead || !p->registered)) {
        int held=0;for(unsigned i=0;i<BO_WINDOWS;i++)held|=p->leases[i].held;
        if(!held){c->release(p->empty_clip);p->empty_clip=0;}
    }
    __atomic_store_n(&p->ack,sequence,__ATOMIC_RELEASE);
}
