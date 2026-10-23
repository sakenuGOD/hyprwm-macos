// Native pixel custody. First qualifier is explicitly restricted to one owned
// WID; it never changes source geometry/opacity or publishes a death animation.
// Borrowed CA update/source objects never survive the synchronous compositor call.
#define PC_MAGIC 0x31484341434d5748ULL
enum { PC_EMPTY, PC_ARMED, PC_ENCODED, PC_GPU_COMPLETE, PC_GPU_ERROR, PC_INVALID, PC_ADOPTED };
struct pc_node { void *next, *fn, *ctx; };
struct pc_capture {
    u64 magic; u32 size, version;
    struct pc_node node;
    struct ctx *engine;
    int (*is_main)(void);
    void *(*thread_self)(void);
    void *(*stack_top)(void *);
    u64 (*stack_size)(void *);
    void *session_control;
    int (*generate)(void *,void *);
    void (*populate)(void *,void *);
    void (*free_layers)(void *);
    void (*release_enumerator)(void *);
    void *(*compositor)(unsigned);
    void *(*texture)(void *,void *,u64);
    void *(*retain_obj)(void *);
    void (*release_obj)(void *);
    void *status_selector;
    u64 expected_texture, expected_context_count, expected_capture_backing;
    u64 cohort_pc[5];
    const u32 *native_flags;
    const unsigned char *native_capture_flag;
    u64 source, creator, pid_version;
    u32 wid, stage, dead, reason;
    rect capture_rect;
    void *clone, *capture, *texture_ref, *command_buffer;
    u32 clone_wid, gpu_status;
    u64 callbacks, nonmain, wrong_cohort, misses, encoded;
    u64 update, update_after, context, index, changed_seed;
    u64 command_before, command_after, depth_before, depth_after;
    u64 context_count, width, height, format;
    double scale, baked_alpha;
    u64 source_unchanged, present_unchanged, gpu_pending;
    void *width_selector, *height_selector, *format_selector, *type_selector;
    u64 scheduled_before, scheduled_after, stream_before, stream_after, capture_witness;
    u64 prepare_idle_permit;
    u64 command, command_sequence, command_claimed, command_ack, command_result, active_command;
    u64 dispatch_calls;
    double control_us;
    u64 first_order_qualifier;
    u64 birth_token;
    // Provenance of the client tree included in THIS native RenderUpdate.
    // This is distinct from the WS wrapper context, and is not by itself an
    // acknowledgment of the manager's configure revision.
    u64 client_context;
    u32 client_id,client_commit_sequence,client_transaction_seed,client_included;
};
_Static_assert(__builtin_offsetof(struct pc_capture,engine)==0x28,"pixel cache engine ABI");
_Static_assert(__builtin_offsetof(struct pc_capture,source)==0xf0,"pixel cache source ABI");

static int pc_main(struct pc_capture *p) {
    return p && p->magic==PC_MAGIC && p->size==sizeof(*p) && p->version==1 &&
        !__atomic_load_n(&p->dead,__ATOMIC_ACQUIRE) && p->is_main && p->is_main()==1;
}
// Strip local return addresses ONLY for comparison. No stripped pointer is called
// or written back. Native signed call targets stay untouched in the API table.
static u64 pc_address(void *pointer) {
    return (u64)__builtin_ptrauth_strip(pointer,0);
}
static int pc_normal_frame(struct pc_capture *p) {
    if(!p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 bottom=top-size,fp=(u64)__builtin_frame_address(0);unsigned phase=0;
    for(unsigned i=0;i<32;i++) {
        if((fp&15) || fp<bottom || fp>top-16)return 0;
        u64 *frame=(u64 *)fp,next=frame[0],pc=pc_address((void *)frame[1]);
        if(phase==0 && pc==p->cohort_pc[0])phase=1;
        else if(phase==1 && (pc==p->cohort_pc[1] || pc==p->cohort_pc[2]))phase=2;
        else if(phase==2 && pc==p->cohort_pc[3])phase=3;
        else if(phase==3 && pc==p->cohort_pc[4])return 1;
        if(next<=fp)return 0;
        fp=next;
    }
    return 0;
}
static char *pc_source(struct pc_capture *p) {
    struct ctx *c=p->engine;
    if(!c || c->dead || c->in_cb || !c->by_id || !p->session_control || !p->wid)return 0;
    if(!c->ch || c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=(u32)sizeof(struct ch) || c->ch->h.stop)return 0;
    char *control=*(char **)p->session_control;
    if(!control || *(void **)(control+0x20)!=c->session)return 0;
    char *win=c->by_id(p->wid);
    if(!win || (u64)win!=p->source || *(u32 *)win!=p->wid || *(u32 *)(win+4)!=5)return 0;
    char *creator=*(char **)(win+0x30);
    if(!creator || (u64)creator!=p->creator || *(u64 *)(creator+0x268)!=p->pid_version)return 0;
    if(!((*(u64 *)(win+0x928)>>44)&1))return 0;
    if(p->first_order_qualifier) {
        if(p->first_order_qualifier==1)return first_order_capture_source(c,win,p->capture_rect)?win:0;
        if(p->first_order_qualifier==2)return birth_capture_source(c,win,p->capture_rect,p->birth_token)?win:0;
        return 0;
    }
    if(*(int *)(win+0x20)!=0)return 0;
    struct ch_win *w=slot(c->ch,p->wid,0);rect r=p->capture_rect;
    if(!w || !w->geo || dabs(w->pos.v[0]-r.x)>.5 || dabs(w->pos.v[1]-r.y)>.5 ||
       dabs(w->size.v[0]-r.w)>.5 || dabs(w->size.v[1]-r.h)>.5)return 0;
    return win;
}
static u64 pc_slot(void *object,unsigned offset) {
    void **vtable=__builtin_ptrauth_strip(*(void ***)object,2);
    return pc_address(vtable[offset/8]);
}
static int pc_same(const unsigned char *a,const unsigned char *b,unsigned count) {
    for(unsigned i=0;i<count;i++)if(a[i]!=b[i])return 0;
    return 1;
}
static int pc_client_commit(struct pc_capture *p,void *update,char *cwc,char *state) {
    p->client_context=(u64)*(void **)(cwc+0x48);p->client_id=*(u32 *)(cwc+0x50);
    p->client_transaction_seed=*(u32 *)(state+0xdc);
    p->client_commit_sequence=0;p->client_included=0;
    if(!p->client_context || !p->client_id || !update)return 0;
    char *entry=*(char **)((char *)update+0x140);
    for(unsigned i=0;entry && i<256;i++,entry=*(char **)entry) {
        if(*(u64 *)(entry+8)==p->client_context) {
            p->client_commit_sequence=*(u32 *)(entry+0x18);p->client_included=1;return 1;
        }
    }
    return 0;
}
// Only the existing engine's native main-queue timer grants this one-use permit,
// after its original tick returns. A negative normal-frame match alone cannot
// prove absence of every nested composite.
// Initial CreateClone pixels are deliberately untrusted: this allocates the shell.
int anim_cache_prepare(struct pc_capture *p) {
    if(!pc_main(p) || p->stage!=PC_EMPTY || p->clone ||
       p->prepare_idle_permit!=0x31454c44494350ULL || pc_normal_frame(p))return 0;
    p->prepare_idle_permit=0;
    struct ctx *c=p->engine;char *source=pc_source(p);
    rect r=p->capture_rect;
    if(!source || !c->clone || !c->win_disp || !c->order || !c->set_alpha || !c->get_id || !c->sel ||
       !__builtin_isfinite(r.x) || !__builtin_isfinite(r.y) || !__builtin_isfinite(r.w) ||
       !__builtin_isfinite(r.h) || r.w<1 || r.h<1 || r.w>16384 || r.h>16384)return 0;
    float scale=*(float *)(source+0x210);
    if(!__builtin_isfinite(scale) || scale<=0 || scale>8 || r.w*r.h*scale*scale>8388608)return 0;
    p->status_selector=c->sel("status");p->width_selector=c->sel("width");
    p->height_selector=c->sel("height");p->format_selector=c->sel("pixelFormat");p->type_selector=c->sel("textureType");
    void *display=c->win_disp(source);if(!display)return 0;
    u32 was=c->in_cb;c->in_cb=1;
    char *clone=c->clone(source,r,display,1);
    if(clone) {
        unsigned wid=c->get_id(clone);
        c->set_alpha(0,clone,0,0);c->order(0,wid,0,0);
        p->clone=clone;p->clone_wid=wid;p->capture=*(void **)(clone+0x8b0);
    }
    c->in_cb=was;
    if(!p->clone || !p->capture || *(void **)((char *)p->clone+0x30))return 0;
    p->stage=PC_ARMED;return 1;
}

typedef void (*pc_encode_fn)(void *,void *,void *,void *);
static void pc_frame(void *mctx,void *display,void *third,struct pc_capture *p,
                     pc_encode_fn encode,void *encode_owner) {
    (void)display;
    if(!p || p->magic!=PC_MAGIC || p->size!=sizeof(*p) || p->version!=1)return;
    if(__atomic_load_n(&p->dead,__ATOMIC_ACQUIRE))return;
    __atomic_fetch_add(&p->callbacks,1,__ATOMIC_RELAXED);
    if(!pc_main(p)){__atomic_fetch_add(&p->nonmain,1,__ATOMIC_RELAXED);return;}
    if(p->stage!=PC_ARMED || third)return;
    if(!pc_normal_frame(p)){p->wrong_cohort++;return;}
    struct ctx *c=p->engine;char *win=pc_source(p),*cap=p->capture;
    if(!win || !cap || c->by_id(p->clone_wid)!=p->clone ||
       *(void **)((char *)p->clone+0x30) || *(void **)((char *)p->clone+0x8b0)!=cap ||
       !p->generate || !p->populate || !p->free_layers ||
       !p->release_enumerator || !p->compositor || !p->texture || !p->retain_obj ||
       !p->release_obj || !p->status_selector || !p->native_flags || !p->native_capture_flag) {
        p->reason=1;p->misses++;return;
    }
    char *cwc=*(char **)(win+0x18);if(!cwc){p->reason=2;p->misses++;return;}
    u64 index=*(u64 *)(cwc+0x588);
    if(index>1){p->reason=3;p->misses++;return;}
    char *state=cwc+0x260+0x190*index;void *update=*(void **)state;
    if(!update || *(void **)(state+8)){p->reason=4;p->misses++;return;}
    if(!cap[0x7a] || pc_slot(cap,0x48)!=p->expected_capture_backing) {
        p->reason=5;p->misses++;return;
    }
    void *backing=*(void **)(cap+0xb0);
    if(!backing || pc_slot(backing,0x70)!=p->expected_texture ||
       pc_slot(backing,0x40)!=p->expected_context_count) {p->reason=6;p->misses++;return;}
    unsigned accelerator=*(u32 *)(cap+0x7c);char *compositor=p->compositor(accelerator);
    if(!compositor || *(void **)(compositor+0x10)!=mctx) {p->reason=7;p->misses++;return;}
    rect bounds=*(rect *)(cap+8),r=p->capture_rect;
    if(bounds.x!=r.x || bounds.y!=r.y || bounds.w!=r.w || bounds.h!=r.h) {
        p->reason=8;p->misses++;return;
    }
    float scale=*(float *)(cap+0x68),alpha=*(float *)(cwc+0x174);
    if(!(scale>0) || !__builtin_isfinite(scale) || !(alpha>0) || alpha>1 ||
       (win[0x86]&2) || (win[0x92b]&2)) {p->reason=9;p->misses++;return;}
    unsigned char before[256];
    __builtin_memcpy(before,win+0x498,128);__builtin_memcpy(before+128,win+0x618,128);
    _Alignas(16) unsigned char redraw[0xc0];
    for(unsigned i=0;i<0xc0;i++)((volatile unsigned char *)redraw)[i]=0;
    void *head=0,*source=win;
    struct {void **data;int count;unsigned pad;} one={&source,1,0};
    *(void **)(redraw+0)=compositor;
    // Native source generation tests this as a protection-options mask.
    // ContextCount is a different getter/field, recorded separately below.
    *(u64 *)(redraw+8)=*(u64 *)((char *)backing+8);
    *(rect *)(redraw+0x10)=r;*(float *)(redraw+0x3c)=scale;
    *(u32 *)(redraw+0x48)=accelerator;
    *(void **)(redraw+0x50)=*(void **)(cap+0x60);
    void *clip=c->rgn(r);if(!clip){p->reason=10;p->misses++;return;}
    *(void **)(redraw+0x58)=clip;redraw[0x70]=accelerator!=0;
    *(void **)(redraw+0x78)=&head;redraw[0x92]=1;redraw[0x93]=0;
    redraw[0x9a]=*p->native_flags==0;redraw[0x9b]=1;redraw[0x9c]=1;
    redraw[0x9d]=*p->native_capture_flag;*(void **)(redraw+0xa8)=&one;
    p->index=index;p->update=(u64)update;p->context=(u64)*(void **)(cwc+0x30);
    p->changed_seed=p->context?*(u32 *)((char *)p->context+0x2c):0;
    p->command_before=(u64)*(void **)((char *)mctx+0x60);
    p->depth_before=*(u32 *)((char *)mctx+0x178);
    p->context_count=*(u64 *)((char *)backing+0x140);p->scale=scale;p->baked_alpha=alpha;
    p->reason=0;
    // Copy provenance while this exact borrowed CWC/U/R is still qualified,
    // before any generation/population/cleanup can replace the update.
    pc_client_commit(p,update,cwc,state);
    p->scheduled_before=*(u64 *)((char *)backing+0xb0);
    p->stream_before=*(u32 *)((char *)backing+0xb8);
    p->generate(redraw,win);
    if(head) {
      if(encode)encode(mctx,compositor,head,encode_owner);
      else {
        p->gpu_pending=1;
        p->populate(cap,head);
        // Keep only OWN ObjC resources. Native source/RenderUpdate stays local.
        void *texture=0;
        if(*(void **)(cap+0xb0)==backing) {
            p->scheduled_after=*(u64 *)((char *)backing+0xb0);
            p->stream_after=*(u32 *)((char *)backing+0xb8);
            p->capture_witness=p->scheduled_after==__atomic_load_n((u64 *)((char *)mctx+0xe0),__ATOMIC_ACQUIRE) &&
                p->stream_after==*(u32 *)((char *)mctx+0x1a8) &&
                (p->scheduled_after!=p->scheduled_before || p->stream_after!=p->stream_before);
            if(p->capture_witness)texture=p->texture(backing,mctx,0);
        }
        if(!p->capture_witness)p->reason=17;
        // Texture may PrepareForUse and switch/append GPU work. Retain the final
        // current command buffer only after that call, including failure cleanup.
        void *cb=*(void **)((char *)mctx+0x60);
        if(cb)p->command_buffer=p->retain_obj(cb);
        if(texture && p->command_buffer) {
            p->texture_ref=p->retain_obj(texture);
            p->command_after=(u64)cb;p->encoded++;
            if(p->width_selector && p->height_selector && p->format_selector && p->type_selector) {
                u64 (*get)(void *,void *)=(void *)c->msg;
                p->width=get(texture,p->width_selector);p->height=get(texture,p->height_selector);
                p->format=get(texture,p->format_selector);
                if(get(texture,p->type_selector)!=2 || (double)p->width!=*(double *)(cap+0x38) ||
                   (double)p->height!=*(double *)(cap+0x40))p->reason=13;
            } else p->reason=14;
        }
      }
      p->free_layers(head); // Never WSCleanUpArena: outer UpdateDisplays owns it.
    }
    void *opaque=*(void **)(redraw+0x60),*enumerator=*(void **)(redraw+0x68);
    if(opaque)c->release(opaque);
    if(enumerator)p->release_enumerator(enumerator);
    c->release(clip);
    p->depth_after=*(u32 *)((char *)mctx+0x178);
    p->update_after=(u64)*(void **)state;
    p->present_unchanged=*(void **)(state+8)==0;
    p->source_unchanged=*(char **)(win+0x18)==cwc && *(u64 *)(cwc+0x588)==index &&
        p->update_after==(u64)update && pc_same(before,(unsigned char *)win+0x498,128) &&
        pc_same(before+128,(unsigned char *)win+0x618,128);
    if(!head)p->reason=11;
    if(!p->source_unchanged || !p->present_unchanged || p->depth_after!=p->depth_before)p->reason=15;
    if(!p->texture_ref || !p->command_buffer) {if(!p->reason)p->reason=12;}
    p->stage=p->reason?PC_INVALID:PC_ENCODED;
}
void anim_cache_frame(void *mctx,void *display,void *third,struct pc_capture *p) {
    pc_frame(mctx,display,third,p,0,0);
}
// Never block/flush/commit a native command buffer. Poll only our retained object.
int anim_cache_poll(struct pc_capture *p) {
    if(!p || p->magic!=PC_MAGIC || p->size!=sizeof(*p) || p->version!=1 || !p->is_main ||
       p->is_main()!=1 || !p->command_buffer || !p->status_selector)return 0;
    u64 status=((u64 (*)(void *,void *))p->engine->msg)(p->command_buffer,p->status_selector);
    p->gpu_status=(u32)status;
    if(status==4 || status==5)p->gpu_pending=0;
    if(p->stage==PC_ENCODED && status==4)p->stage=PC_GPU_COMPLETE;
    else if(p->stage==PC_ENCODED && status==5)p->stage=PC_GPU_ERROR;
    return (int)status;
}
int anim_cache_destroy(struct pc_capture *p) {
    if(!p || p->magic!=PC_MAGIC || p->size!=sizeof(*p) || p->version!=1 || !p->is_main || p->is_main()!=1)return 0;
    // Caller must unlink the exact owned node before destruction. Keep mappings
    // even after OFF; a debugger stop can catch a callback's saved return PC.
    if(p->gpu_pending) {
        if(!p->command_buffer)return 0;
        if(anim_cache_poll(p)!=4 && p->gpu_status!=5)return 0;
    }
    if(p->command_buffer){p->release_obj(p->command_buffer);p->command_buffer=0;}
    if(p->texture_ref){p->release_obj(p->texture_ref);p->texture_ref=0;}
    struct ctx *c=p->engine;char *clone=p->clone;
    if(clone && c->by_id(p->clone_wid)==clone && !*(void **)(clone+0x30) &&
       *(void **)(clone+0x8b0)==p->capture) {
        u32 was=c->in_cb;c->in_cb=1;
        c->set_alpha(0,clone,0,0);c->order(0,p->clone_wid,0,0);
        p8_free_win(c,clone);c->in_cb=was;
        p->clone=0;p->capture=0;p->clone_wid=0;
    }
    p->dead=1;return p->clone==0;
}
unsigned anim_cache_state_size(void){return sizeof(struct pc_capture);}

// The sole existing engine timer owns native mutations. The root installer swaps
// only ctx.self after publishing these private gap pointers, and saves its exact
// previous signed value at +6e8. No second timer and no debugger call can interrupt
// clone/order/destruction halfway. Keep both pointers/mappings after OFF: one shim
// callback is already queued when the original tick schedules its successor.
#define PC_CONTROL_PTR 0x6e0
#define PC_ORIGINAL_TICK 0x6e8
_Static_assert(PC_CONTROL_PTR>=METAL_OBSERVE_STATE_OFFSET+sizeof(struct metal_observe_state),"capture control overlaps observer");
_Static_assert(PC_ORIGINAL_TICK+8<=0x800,"capture control overlaps P8");
void anim_cache_dispatch(struct ctx *c,double now) {
    void (*original)(struct ctx *,double)=*(void (**)(struct ctx *,double))((char *)c+PC_ORIGINAL_TICK);
    if(!original)return; // Installer refuses publication without this saved word.
    original(c,now); // Exactly once, preserving c, d0 and all original scheduling.
    struct pc_capture *p=*(void **)((char *)c+PC_CONTROL_PTR);
    if(!p || p->magic!=PC_MAGIC || p->size!=sizeof(*p) || p->version!=1 || p->engine!=c)return;
    p->dispatch_calls++;
    if(!p->is_main || p->is_main()!=1 || c->dead || c->in_cb)return;
    // The original tick owns scheduling and stops on these exact conditions.
    // Never create/show new resources after it has declined another tick.
    if(!c->ch || c->ch->h.magic!=CH_MAGIC || c->ch->h.size!=(u32)sizeof(struct ch) || c->ch->h.stop)return;
    char *control=p->session_control?*(char **)p->session_control:0;
    if(!control || *(void **)(control+0x20)!=c->session)return;
    u64 command=p->active_command;
    if(!command) {
        u64 sequence=__atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE);
        if(sequence==p->command_ack)return;
        command=__atomic_exchange_n(&p->command,0,__ATOMIC_ACQ_REL);
        if(!command)return;
        // A stopped-process writer may have published a newer request after our
        // first sequence read. Never claim its command under the previous epoch.
        if(__atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE)!=sequence) {
            u64 empty=0;
            __atomic_compare_exchange_n(&p->command,&empty,command,0,__ATOMIC_RELEASE,__ATOMIC_RELAXED);
            return;
        }
        p->command_claimed=sequence;p->active_command=command;
    }
    u64 start=c->mabs?c->mabs():0;int done=1,result=0;
    if(command==1) {
        // Provenance is this native main-queue timer, after the original tick;
        // not a guessed Mach wait or a negative normal-frame classification.
        p->prepare_idle_permit=0x31454c44494350ULL;
        result=anim_cache_prepare(p);
    } else if(command==2) {
        result=anim_cache_poll(p);
    } else if(command==3) {
        char *clone=p->clone;
        if(!p->dead && p->stage==PC_GPU_COMPLETE && !p->reason && p->source_unchanged &&
           p->present_unchanged && p->capture_witness && clone && c->by_id(p->clone_wid)==clone &&
           !*(void **)(clone+0x30) && *(void **)(clone+0x8b0)==p->capture && pc_source(p)) {
            u32 was=c->in_cb;c->in_cb=1;
            c->set_alpha(0,clone,1,0);c->order(0,p->clone_wid,1,p->wid);c->in_cb=was;
            result=1;
        }
    } else if(command==4) {
        result=anim_cache_destroy(p);
        if(!result)done=0; // Retry on original ticks until OWN GPU work is terminal.
    }
    if(c->mabs)p->control_us=(double)(c->mabs()-start)*c->mabs_us;
    if(done) {
        p->command_result=result;p->active_command=0;
        __atomic_store_n(&p->command_ack,p->command_claimed,__ATOMIC_RELEASE);
    }
}
