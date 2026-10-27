// Mode3 admission at the native owning prepare call. No native source graph,
// Update or Present is retained or prepared again. This binding is separate
// from the frozen pc_capture/RGBA v4 ABI and is inert until explicitly armed.
#define RGBA_NORMAL_OFFSET 12288
#define RGBA_NORMAL_MAGIC 0x314c414d524f4e52ULL
struct rgba_inplace;
struct rgba_carrier;
static struct rgba_carrier *rgba_carrier_control(struct rgba_capture *);
static void rgba_begin_forget(struct rgba_capture *,struct rgba_inplace *);
static int rgba_carrier_drop_slot(struct rgba_capture *,struct rgba_inplace *);
static struct rgba_view *rgba_carrier_view(struct rgba_capture *,struct rgba_inplace *);
static int rgba_carrier_source_excluded(struct rgba_capture *,struct rgba_inplace *,void *);
static int rgba_draw_active(struct rgba_capture *);
static int rgba_draw_frame_fits(struct rgba_capture *,struct rgba_inplace *);
static int rgba_draw_prepare(struct rgba_capture *,struct rgba_inplace *,struct ch_win *,rect);
static int rgba_draw_ready(struct rgba_capture *,struct rgba_inplace *,rect,int);
static void rgba_draw_damage(struct rgba_capture *,struct rgba_inplace *);
static void rgba_draw_forget(struct rgba_capture *,struct rgba_inplace *);
static void rgba_draw_finish_drop(struct rgba_capture *);
static void rgba_draw_scene_before(struct rgba_capture *);
static void rgba_draw_recover_at(struct rgba_capture *,unsigned);
static int rgba_draw_pending(struct rgba_capture *,struct rgba_inplace *);
static void rgba_draw_commands(struct ctx *);
static int rgba_draw_revoke(struct rgba_capture *,struct rgba_inplace *);
static int rgba_pan_active(struct rgba_capture *,unsigned);
static int rgba_pan_drop(struct rgba_capture *);
void rgba_normal_viewport_tick(void *);
void rgba_normal_draw_commands(void *);
void rgba_normal_close_gate(void *,void **,unsigned,int);
void rgba_normal_close_seed_commands(void *);
static void rgba_draw_claim_commit(struct rgba_capture *,struct rgba_inplace *,u32);
static void rgba_draw_adopted(struct rgba_capture *,struct rgba_inplace *,u32,int);
static int rgba_draw_model_adopted(struct rgba_capture *,struct rgba_inplace *,void *,u32,void *,void *,void *,void *);
static void rgba_close_accept_placement(struct rgba_capture *,struct rgba_inplace *,u32,rect);
static void rgba_draw_close_lease(struct rgba_capture *,u32,u64,int);
static int rgba_draw_close_cached(struct rgba_capture *,struct rgba_inplace *);
struct rgba_accepted_close_slot;
static void rgba_draw_close_detach(struct rgba_capture *,struct rgba_accepted_close_slot *);
#include "presentation_inplace.h"
struct rgba_normal_binding {
    u64 magic;u32 size,version;
    struct rgba_capture *capture;
    u64 prepare_return[2],composite_return[2];
    u64 inflight,calls,admitted,misses;
    u32 reason,dead;
};
struct rgba_normal_scope {
    struct rgba_normal_binding *binding;
    void *compositor,*head,*destination,*prepared;
    void **shape;
    u64 frame,generation;
};
static int rgba_normal_valid(struct rgba_normal_binding *n) {
    return n && n->magic==RGBA_NORMAL_MAGIC && n->size==sizeof(*n) && n->version==1 &&
        !__atomic_load_n(&n->dead,__ATOMIC_ACQUIRE) && rgba_valid(n->capture) &&
        n->capture->content_mode==RGBA_CLIENT_DOMAIN_MODE && !n->capture->destroyed && !n->capture->quarantined;
}
static int rgba_normal_frame_owner(struct pc_capture *p,const void *raw,int retained_display) {
    const struct rgba_normal_scope *s=raw;
    if(!pc_main(p) || !s || !p->thread_self || !p->stack_top || !p->stack_size)return 0;
    void *thread=p->thread_self();u64 top=(u64)p->stack_top(thread),size=p->stack_size(thread);
    if(size<4096 || size>0x40000000ULL || top<size)return 0;
    u64 bottom=top-size,address=(u64)s;
    if(address<bottom || address>top-sizeof(*s))return 0;
    struct rgba_normal_binding *n=s->binding;
    int valid=retained_display?
        n && n->magic==RGBA_NORMAL_MAGIC && n->size==sizeof(*n) && n->version==1 &&
            rgba_valid(n->capture) && n->capture->content_mode==RGBA_CLIENT_DOMAIN_MODE && !n->capture->destroyed:
        rgba_normal_valid(n);
    if(!valid || &n->capture->pc!=p || n->inflight!=1 ||
       s->generation!=n->calls || !s->compositor || !s->head || !s->destination || !s->shape)return 0;
    u64 fp=(u64)__builtin_frame_address(0);int current=0;
    for(unsigned i=0;i<32;i++) {
        if((fp&15) || fp<bottom || fp>top-16)return 0;
        if(fp==s->frame){current=1;break;}
        u64 next=*(u64 *)fp;if(next<=fp)return 0;fp=next;
    }
    if(!current)return 0;
    u64 *entry=(u64 *)fp,ra=pc_address((void *)entry[1]);
    if(ra!=n->prepare_return[0] && ra!=n->prepare_return[1])return 0;
    u64 composite=entry[0];
    if((composite&15) || composite<=fp || composite<bottom+0xe8 || composite>top-16 ||
       (u64)s->shape!=composite-0xe8)return 0;
    ra=pc_address((void *)((u64 *)composite)[1]);
    if(ra!=n->composite_return[0] && ra!=n->composite_return[1])return 0;
    u64 layers=*(u64 *)composite;
    if((layers&15) || layers<=composite || layers>top-16 ||
       pc_address((void *)((u64 *)layers)[1])!=p->cohort_pc[3])return 0;
    u64 render=*(u64 *)layers;
    if((render&15) || render<=layers || render>top-16 ||
       pc_address((void *)((u64 *)render)[1])!=p->cohort_pc[4])return 0;
    u64 update=*(u64 *)render;
    if((update&15) || update<=render || update<bottom+0xb88 || update>top-16 ||
       *(void **)(update-0xb88)!=s->head || *(void **)(update-0xb40)!=s->compositor)return 0;
    return *(void **)((char *)s->compositor+0x10)!=0;
}
static int rgba_normal_owner(struct pc_capture *p,const void *raw) {return rgba_normal_frame_owner(p,raw,0);}
int anim_rgba_normal_arm(struct rgba_normal_binding *n) {
    if(!rgba_normal_valid(n))return 0;
    struct rgba_capture *g=n->capture;struct pc_capture *p=&g->pc;
    n->reason=10;
    if(!pc_main(p) || !rgba_api_ready(&g->api) || !g->client_api.transform_set ||
       p->stage!=PC_EMPTY || p->clone || p->capture || g->update || g->root ||
       p->texture_ref || p->command_buffer || g->clear_buffer || g->sealed || p->gpu_pending ||
       (g->renderer && (!g->metal || !g->queue || !g->device || !rgba_flush_allowed(g))) ||
       n->inflight || p->prepare_idle_permit!=0x31454c44494350ULL || pc_normal_frame(p) ||
       !n->prepare_return[0] || !n->prepare_return[1] ||
       !n->composite_return[0] || !n->composite_return[1] || !p->cohort_pc[4])return 0;
    n->reason=11;char *source=pc_source(p);if(!source)return 0;
    p->prepare_idle_permit=0;
    struct ctx *c=p->engine;
    p->status_selector=c->sel("status");p->width_selector=c->sel("width");
    p->height_selector=c->sel("height");p->format_selector=c->sel("pixelFormat");p->type_selector=c->sel("textureType");
    n->reason=12;if(!rgba_prepare_selectors(g))return 0;
    p->stage=PC_ARMED;n->reason=0;
    if(c->sched_win)c->sched_win(0,source);
    return 1;
}
static struct rgba_normal_binding *rgba_normal_binding(struct rgba_capture *g);
static int rgba_normal_retry(struct rgba_capture *g);
static int rgba_close_drop(struct rgba_capture *g);
static u64 rgba_close_bytes(struct rgba_capture *g);
static int rgba_begin_active(struct rgba_capture *);
static int rgba_begin_wait(struct rgba_capture *,struct rgba_inplace *,struct ch_win *,void *);
static int rgba_begin_takeover_ready(struct rgba_capture *,struct rgba_inplace *,double);
static void rgba_begin_promoted(struct rgba_capture *,struct rgba_inplace *);
static int rgba_carrier_active(struct rgba_capture *);
static int rgba_carrier_pose(struct rgba_capture *,struct rgba_inplace *,struct ch_win *);
static int rgba_carrier_outside(struct rgba_capture *);
static int rgba_carrier_timer_allowed(struct rgba_capture *);
static u64 rgba_carrier_bytes(struct rgba_capture *);
static void rgba_carrier_finish_drop(struct rgba_capture *);
static int rgba_carrier_can_publish(struct rgba_capture *,struct rgba_inplace *);
static u64 rgba_carrier_space(struct rgba_capture *,void *);
static int rgba_carrier_space_sync(struct rgba_capture *,struct rgba_view *,u64);
static int rgba_carrier_ordered_windows(struct rgba_capture *,void *,void *);
static void rgba_carrier_observe_idle(struct rgba_capture *,struct rgba_inplace *,void *);
static void rgba_carrier_before_window(struct rgba_capture *,void *,unsigned,u64,u64 *);
extern void anim_rgba_carrier_recover(struct rgba_capture *,struct rgba_inplace *);
#include "presentation_ordinary.h"
#include "presentation_close.h"
#include "presentation_begin.h"
#include "presentation_carrier.h"
#include "presentation_drawing.h"
#include "presentation_viewport.h"
// Original links (+0/+10) and prepared links (+8) have different ownership.
// Reject duplicate target leaves, malformed lists and grouped targets rather
// than publishing a partial window as a complete accepted frame.
static char *rgba_normal_source(struct rgba_normal_scope *scope) {
    struct pc_capture *p=&scope->binding->capture->pc;
    char *stack[256],*seen[256],*selected=0;unsigned pending=1,count=0;stack[0]=scope->head;
    while(pending) {
        char *s=stack[--pending];if(!s)continue;
        for(unsigned i=0;i<count;i++)if(seen[i]==s)return 0;
        if(count==256)return 0;seen[count++]=s;
        if(*(void **)s){if(pending==256)return 0;stack[pending++]=*(void **)s;}
        if(*(void **)(s+0x10)){if(pending==256)return 0;stack[pending++]=*(void **)(s+0x10);}
        if(*(u32 *)(s+0x180)==10 && *(u32 *)(s+0x268)==p->wid) {
            if(selected || !rgba_geometry_source(p,s,*(char **)(s+0x48)))return 0;
            selected=s;
        }
    }
    scope->binding->capture->original_nodes=count;
    if(!selected)return 0;
    count=0;unsigned found=0;
    for(char *s=scope->prepared;s;s=*(char **)(s+8)) {
        if(count==256)return 0;
        for(unsigned i=0;i<count;i++)if(seen[i]==s)return 0;
        seen[count++]=s;if(s==selected)found++;
    }
    scope->binding->capture->prepared_nodes=count;
    return found==1?selected:0;
}
static void rgba_normal_encode(struct rgba_normal_scope *scope,char *selected,char *cwc,char *state) {
    struct rgba_capture *g=scope->binding->capture;struct pc_capture *p=&g->pc;
    struct rgba_render_api *a=&g->api;void *destination=0;
    void *mctx=*(void **)((char *)scope->compositor+0x10);
    void *shared_renderer=*(void **)((char *)mctx+0x90);
    if(!rgba_normal_owner(p,scope) || !rgba_update(g,cwc,state)) {
        // This attempt never touched a renderer. Sealing here would capture
        // the previous submission from the intentionally retained idle bundle.
        p->reason=234;return;
    }
    struct rgba_ordinary *control=rgba_ordinary_control(g);if(control){control->capture_generation=scope->generation;control->capture_time=a->get_time((void *)p->update);}
    rgba_begin_captured(g,(void *)p->update);
    if(!rgba_ordinary_capture_budget(g)){p->reason=250;goto done;}
    if(!rgba_resources_owned(g,shared_renderer,0,1)){p->reason=203;goto done;}
    char *normal=scope->destination;float scale=*(float *)(normal+0x68);if(scale==0)scale=1;
    if(!__builtin_isfinite(scale) || scale<=0 || scale>8){p->reason=204;goto done;}
    void *color=(normal[0x53]&4)?*(void **)(normal+0x60):0;
    struct rgba_ordinary *ordinary=rgba_ordinary_control(g);
    if(ordinary) {
        void *saved=color,*owned=0;
        if(!saved)saved=*a->geometry.native_display_rgb;
        if(!saved){owned=a->geometry.display_rgb();saved=owned;}
        if(ordinary->candidate_color)a->geometry.release_cf(ordinary->candidate_color);
        ordinary->candidate_color=saved?a->geometry.retain_cf(saved):0;
        if(owned)a->geometry.release_cf(owned);
    }
    u32 flags=color?0x14440000:0x10440000;g->destination_flags=flags;
    destination=a->destination(p->texture_ref,g->device,g->domain.mapped,scale,color,flags);
    if(!destination || *(void **)((char *)destination+0xa0)){p->reason=204;goto done;}
    rgba_render_selected(g,shared_renderer,selected,destination,g->domain.mapped,cwc,state,rgba_normal_owner,scope);
done:
    if(destination)a->release_destination(destination);
    rgba_seal(g);
}
// An active source that is already prepared need not wait for the timer to
// request another native frame. Reserve only empty, preinitialized OWN custody;
// allocation and encoding still use the existing owning-scope checks below.
static void rgba_normal_arm_active(struct rgba_normal_scope *scope) {
    struct rgba_capture *g=scope->binding->capture;struct pc_capture *p=&g->pc;
    struct rgba_ordinary *o=rgba_ordinary_control(g);struct ctx *c=p->engine;
    if(!o || !o->enabled || c->ch->h.now>=o->expires || c->ch->h.now<o->next_capture || o->candidate!=CH_NW ||
       __atomic_load_n(&o->sequence,__ATOMIC_ACQUIRE)!=o->ack || o->command ||
       __atomic_load_n(&p->command_sequence,__ATOMIC_ACQUIRE)!=p->command_ack || p->command ||
       !rgba_api_ready(&g->api) || !g->client_api.transform_set ||
       p->stage!=PC_EMPTY || p->active_command || p->gpu_pending || p->clone || p->capture ||
       p->texture_ref || p->command_buffer || g->clear_buffer || g->update || g->root ||
       g->sealed || g->locked_client || g->quarantined || !g->sel.read_bytes ||
       !g->texture_class || !g->pass_class || !p->status_selector ||
       !p->width_selector || !p->height_selector || !p->format_selector || !p->type_selector ||
       (g->renderer && (!g->metal || !g->queue || !g->device || !rgba_flush_allowed(g))))return;
    struct rgba_inplace *slots=rgba_ordinary_slots(g);
    for(unsigned pass=0;pass<2;pass++) {
        unsigned count=0,best=CH_NW,distance=CH_NW;
        for(char *s=scope->prepared;s && count++<256;s=*(char **)(s+8)) {
            if(*(u32 *)(s+0x180)!=10)continue;
            unsigned wid=*(u32 *)(s+0x268);struct ch_win *w=slot(c->ch,wid,0);
        if(!w || !w->used || !w->geo || w->geo==2 || (w->held && !rgba_begin_active(g)) || w->wait ||
               cover_index(c,wid,1)>=0 || birth_holds(c,wid))continue;
            for(unsigned i=0;i<CH_NW;i++) {
                struct rgba_inplace *m=&slots[i];unsigned d=(i+CH_NW-o->cursor)%CH_NW;
                if(d>=distance || !m->on || m->opening || m->padding_motion ||
                   m->wid!=wid || !!m->presenting!=pass || !rgba_inplace_source(g,m))continue;
                if(!(w->pos.active || w->size.active || w->alpha.active || rgba_draw_pending(g,m)))continue;
                if(!w->pos.active && !w->size.active && !w->alpha.active && rgba_draw_close_cached(g,m))continue;
                rect r={w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
                if(rgba_view_rect(r)){best=i;distance=d;}
            }
        }
        if(best==CH_NW)continue;
        struct rgba_inplace *m=&slots[best];struct ch_win *w=slot(c->ch,m->wid,0);
        p->source=(u64)m->window;p->creator=m->creator;p->pid_version=m->pid_version;p->wid=m->wid;
        p->capture_rect=(rect){w->pos.v[0],w->pos.v[1],w->size.v[0],w->size.v[1]};
        if(!pc_source(p))continue;
        struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
        v->source_wid=p->wid;v->source_creator=p->creator;v->source_pid_version=p->pid_version;
        o->candidate=best;o->cursor=(best+1)%CH_NW;o->started=c->ch->h.now;
        o->capture_generation=0;o->capture_time=0;p->stage=PC_ARMED;return;
    }
}
// Called by the exception boundary with the native original already returned.
void anim_rgba_normal_capture(void *compositor,void *head,void *destination,void **shape,
                             struct rgba_normal_binding *n,void *prepared,u64 entry_frame) {
    if(!rgba_normal_valid(n))return;
    struct rgba_capture *g=n->capture;struct pc_capture *p=&g->pc;
    if(!pc_main(p) || n->inflight)return;
    struct rgba_inplace *mount=rgba_inplace_control(g);
    struct rgba_ordinary *ordinary=rgba_ordinary_control(g);
    if(p->stage!=PC_ARMED && !(mount && mount->on) && !(ordinary && ordinary->enabled))return;
    n->calls++;p->callbacks++;n->inflight=1;
    struct rgba_normal_scope scope={n,compositor,head,destination,prepared,shape,
        entry_frame,n->calls};
    n->reason=1;
    if(!rgba_normal_owner(p,&scope))goto finish;
    if(mount && mount->on)rgba_inplace_observe(g,head,prepared);
    if(ordinary && ordinary->enabled)rgba_ordinary_observe(g,head,prepared);
    if(ordinary && ordinary->enabled)rgba_close_observe(g,prepared);
    rgba_normal_arm_active(&scope);
    if(p->stage!=PC_ARMED || p->gpu_pending){n->reason=0;goto finish;}
    char *win=pc_source(p),*cwc=win?*(char **)(win+0x18):0;
    n->reason=2;if(!cwc)goto finish;
    u64 index=*(u64 *)(cwc+0x588);if(index>1)goto finish;
    char *state=cwc+0x260+0x190*index;void *update=*(void **)state,*present=*(void **)(state+8);
    if(!update)goto finish;
    float scale=*(float *)((char *)destination+0x68);if(scale==0)scale=1;
    float alpha=*(float *)(cwc+0x174);
    n->reason=3;
    if(!__builtin_isfinite(scale) || scale<=0 || scale>8 || !__builtin_isfinite(alpha) || alpha<0 || alpha>1 ||
       (win[0x86]&2) || (win[0x92b]&2))goto finish;
    p->index=index;p->update=(u64)update;p->context=(u64)*(void **)(cwc+0x30);
    p->scale=scale;p->baked_alpha=alpha;
    n->reason=4;
    if(!pc_client_commit(p,update,cwc,state))goto clear;
    char *selected=rgba_normal_source(&scope);if(!selected)goto clear;
    char *mctx=*(char **)((char *)compositor+0x10);
    unsigned char before[256];
    __builtin_memcpy(before,win+0x498,128);__builtin_memcpy(before+128,win+0x618,128);
    p->command_before=(u64)*(void **)(mctx+0x60);p->depth_before=*(u32 *)(mctx+0x178);
    p->reason=0;n->admitted++;
    rgba_normal_encode(&scope,selected,cwc,state);
    p->depth_after=*(u32 *)(mctx+0x178);p->update_after=(u64)*(void **)state;
    p->present_unchanged=*(void **)(state+8)==present;
    p->source_unchanged=pc_source(p)==win && *(char **)(win+0x18)==cwc &&
        *(u64 *)(cwc+0x588)==index && p->update_after==(u64)update &&
        pc_same(before,(unsigned char *)win+0x498,128) && pc_same(before+128,(unsigned char *)win+0x618,128);
    if(!p->source_unchanged || !p->present_unchanged || p->depth_after!=p->depth_before ||
       *(void **)(mctx+0x60)!=(void *)p->command_before)p->reason=15;
    if(!p->texture_ref || !p->command_buffer){if(!p->reason)p->reason=12;}
    p->stage=p->reason?PC_INVALID:PC_ENCODED;n->reason=0;
clear:
    // No borrowed Update/Context can be used from the timer or a later frame.
    p->update=0;p->context=0;p->client_context=0;
finish:
    if(n->reason)n->misses++;
    n->inflight=0;rgba_ordinary_schedule_completion(g);return;
}

// Called only after OWN work unwinds, while the owning native parent is live.
// Release exactly the client ContextLock acquired by mode3, then quarantine all
// private roots/GPU resources. No renderer Finish/free is attempted here.
void anim_rgba_normal_abort(struct rgba_normal_binding *n) {
    if(!n || n->magic!=RGBA_NORMAL_MAGIC || n->size!=sizeof(*n) || n->version!=1 ||
       !rgba_valid(n->capture))return;
    struct rgba_capture *g=n->capture;struct pc_capture *p=&g->pc;
    if(g->locked_client && pc_main(p) && g->locked_client==(void *)p->client_context) {
        void *client=g->locked_client;g->locked_client=0;g->api.unlock_context(client);
    }
    g->quarantined=1;p->reason=248;p->stage=PC_INVALID;
    p->update=0;p->context=0;p->client_context=0;
    n->reason=248;n->inflight=0;__atomic_store_n(&n->dead,1,__ATOMIC_RELEASE);
}

// Existing sole MAIN timer, existing capture/view commands and GPU custody.
// The additional binding occupies its own bounded shared-control partition.
static struct rgba_normal_binding *rgba_normal_binding(struct rgba_capture *g) {
    struct rgba_normal_binding *n=(void *)((char *)g+RGBA_NORMAL_OFFSET);
    return n->magic==RGBA_NORMAL_MAGIC && n->size==sizeof(*n) && n->version==1 && n->capture==g?n:0;
}
static int rgba_normal_prepare_capture(struct rgba_capture *g) {
    struct rgba_normal_binding *n=rgba_normal_binding(g);return n?anim_rgba_normal_arm(n):0;
}
static int rgba_normal_retry(struct rgba_capture *g) {
    struct rgba_normal_binding *n=rgba_normal_binding(g);struct pc_capture *p=&g->pc;
    if(!rgba_normal_valid(n) || p->stage!=PC_INVALID || p->reason!=234 || g->client_reason!=235 ||
       n->inflight || !pc_main(p) || p->engine->in_cb ||
       g->quarantined || g->locked_client || p->clone || p->capture || p->active_command ||
       p->update || p->context || p->client_context)return 0;
    if(g->renderer) {
        char *metal=g->metal;
        if(!metal || *(void **)g->renderer!=metal || !g->queue || !g->device ||
           *(void **)(metal+0xee8)!=g->device || *(void **)(metal+0xef0)!=g->queue ||
           rgba_send0(g,g->queue,g->sel.device)!=g->device || !rgba_flush_allowed(g) ||
           *(void **)(metal+0x2d8) || *(void **)(metal+0xf00))return 0;
        void *previous=*(void **)(metal+0xef8);
        if(previous && ((u64 (*)(void *,void *))p->engine->msg)(previous,p->status_selector)!=4)return 0;
    }else if(g->metal || g->queue || g->device)return 0;
    if(!rgba_client_retry_empty(g,1))return 0;
    void *source=pc_source(p);if(source)p->engine->sched_win(0,source);
    return 1;
}
static int rgba_normal_before_destroy(struct rgba_capture *g) {
    struct rgba_normal_binding *n=rgba_normal_binding(g);
    if(!n || n->inflight)return 0;
    __atomic_store_n(&n->dead,1,__ATOMIC_RELEASE);
    struct rgba_begin_binding *b=rgba_begin_control(g);
    if(b)__atomic_store_n(&b->dead,1,__ATOMIC_RELEASE);
    if(!rgba_ordinary_drop(g))return 0;
    if(!rgba_inplace_drop(g))return 0;
    return rgba_view_before_capture_destroy(g);
}
void anim_rgba_normal_present_dispatch(struct ctx *c,double now) {
    rgba_pan_record(c);
    struct rgba_capture *before=*(void **)((char *)c+PC_CONTROL_PTR);
    if(rgba_valid(before) && rgba_carrier_control(before) && !rgba_carrier_timer_allowed(before)) {
        void (*original)(struct ctx *,double)=*(void (**)(struct ctx *,double))((char *)c+PC_ORIGINAL_TICK);
        if(original)original(c,now);return;
    }
    rgba_ordinary_before_tick(c);
    rgba_present_dispatch_control(c,now,rgba_normal_prepare_capture,rgba_normal_before_destroy);
    struct rgba_capture *g=*(void **)((char *)c+PC_CONTROL_PTR);
    if(rgba_valid(g) && !g->destroyed && !g->pc.dead && !g->pc.active_command)rgba_inplace_tick(g);
    if(rgba_valid(g) && !g->destroyed && !g->pc.dead && !g->pc.active_command) {
        struct rgba_accepted_close *accepted=rgba_accepted_close_control(g);
        if(accepted)rgba_close_tick_accepted(g,accepted,now);
        if(rgba_carrier_active(g))anim_rgba_carrier_close(g,now);else rgba_close_tick(g,now);
    }
    if(rgba_valid(g) && !g->destroyed && !g->pc.dead && !g->pc.active_command)rgba_ordinary_tick(g,now);
    if(rgba_valid(g) && !g->destroyed && !g->pc.dead && !g->pc.active_command)rgba_normal_viewport_tick(g);
}
void anim_rgba_normal_present_frame(void *mctx,void *display,void *third,struct rgba_capture *g) {
    if(third || !rgba_valid(g))return;
    struct rgba_view *v=(void *)((char *)g+RGBA_VIEW_OFFSET);
    if(rgba_view_valid(v,g))rgba_view_observe(v,mctx,display);
}
_Static_assert(RGBA_NORMAL_OFFSET+sizeof(struct rgba_normal_binding)<=16384,"normal binding partition");
