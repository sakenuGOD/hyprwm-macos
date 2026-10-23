/* Dormant OWN unwind accounting. No native exception recovery qualification. */
#ifndef DISPLAY_UNWIND_H
#define DISPLAY_UNWIND_H
typedef unsigned long long du64;
typedef unsigned du32;
struct ctx;
struct display_pair;
struct display_source_sink;
struct display_visibility;
typedef int (*du_pair_original)(void *,du64,void *,void *);
typedef int (*du_source_original)(void *,void *);
typedef void (*du_timer_original)(struct ctx *,double);
enum { DU_PAIR,DU_SOURCE,DU_TIMER,DU_ENTRIES=3 };
enum { DU_PROBE,DU_SOURCE_ROLE,DU_VIS_ENTRY,DU_VIS_TIMER,DU_ROLES=4 };
enum { DU_CLOSED,DU_OPEN };
enum { DU_STAGE_ENTRY,DU_STAGE_ORIGINAL,DU_STAGE_MUTATION,DU_STAGE_COMPLETE };
/* failure_roles: role bits0..3, entry bits4..6, sticky provenance bits16..18. */
#define DU_FAIL_ROLE(role) (1ULL << (role))
#define DU_FAIL_ENTRY(kind) (1ULL << (4+(kind)))
#define DU_FAIL_UNKNOWN (1ULL << 16)
#define DU_FAIL_ORIGINAL (1ULL << 17)
#define DU_FAIL_MUTATION (1ULL << 18)
enum { DU_TERMINAL_NONE,DU_TERMINAL_PENDING,DU_TERMINAL_ATTEMPTING,
       DU_TERMINAL_NATIVE_RETURNED,DU_TERMINAL_FAILED };
#define DU_MAGIC 0x31574e55574d5748ULL
struct __attribute__((aligned(16))) display_unwind_bridge {
    du64 magic;du32 size,version;                  /* 0,8,12 */
    du64 generation;                              /* 16 */
    struct display_pair *pair;                    /* 24 */
    struct display_source_sink *sink;              /* 32 */
    struct display_visibility *visibility;         /* 40 */
    du32 enabled,pad;                             /* 48,52 */
    du64 entry_entered[DU_ENTRIES];                /* 56 */
    du64 entry_returned[DU_ENTRIES];               /* 80 */
    du64 entry_inflight[DU_ENTRIES];               /* 104 */
    du64 entry_unwound[DU_ENTRIES];                /* 128 */
    du64 role_unwound[DU_ROLES];                   /* 152 */
    du64 quarantine_generation;                   /* 184 */
    du64 pending_generation;                      /* 192 */
    du64 failure_roles;                           /* 200 */
    du64 failure_turn;                            /* 208 */
    du64 timer_ticket;                            /* 216 */
    du64 terminal_phase;                          /* 224 */
    du64 terminal_turn;                           /* 232 */
    du64 terminal_result;                         /* 240 */
    du64 original_threw;                          /* 248 */
    du64 mutation_threw;                          /* 256; size272/alignment16 */
};
/* Token stores only pointers to OWN counter storage; no R/S/Q/U/native ref. */
struct du_token {
    du64 *returned,*inflight,*unwound;              /* 0,8,16 */
    du64 prior_depth;                             /* 24 */
    du32 role,state;                              /* 32,36; size40 */
};
/* Stack-only; never published/stored beyond this invocation. */
struct du_local {
    struct display_unwind_bridge *bridge;          /* 0 */
    du64 generation,entry_fp,native_fp,timer_turn;  /* 8,16,24,32 */
    du64 owned_epoch,owned_revision,owned_receipt;  /* 40,48,56 */
    du32 entry_kind,count,stage,owns_receipt;       /* 64,68,72,76 */
    struct du_token token[2];                     /* 80; size160 */
};
#define DU_INLINE static __attribute__((always_inline)) inline
DU_INLINE int du_valid(const struct display_unwind_bridge *b) {
    return b && b->magic==DU_MAGIC && b->size==sizeof(*b) && b->version==1 &&
        b->generation && b->pair && b->sink && b->visibility && !b->pad;
}
DU_INLINE void du_quarantine(struct du_local *l,du64 roles) {
    struct display_unwind_bridge *b=l->bridge;du64 expected=0;
    if(__atomic_compare_exchange_n(&b->quarantine_generation,&expected,l->generation,
            0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE)) {
        b->failure_turn=l->timer_turn;
        __atomic_store_n(&b->pending_generation,l->generation,__ATOMIC_RELEASE);
    }
    __atomic_fetch_or(&b->failure_roles,roles,__ATOMIC_RELAXED);
}
DU_INLINE int du_forward_only(struct display_unwind_bridge *b) {
    return __atomic_load_n(&b->enabled,__ATOMIC_ACQUIRE)!=1 ||
        __atomic_load_n(&b->quarantine_generation,__ATOMIC_ACQUIRE) ||
        __atomic_load_n(&b->pending_generation,__ATOMIC_ACQUIRE);
}
DU_INLINE int du_legacy_enter(struct du_local *l,unsigned role,du64 *entered,
        du64 *returned,du64 *inflight,du64 *prior) {
    if(!l || !du_valid(l->bridge))return 0;
    if(role>=DU_ROLES || l->count>=2){du_quarantine(l,DU_FAIL_UNKNOWN|DU_FAIL_ENTRY(l->entry_kind));return 0;}
    struct du_token *t=&l->token[l->count++];
    t->returned=returned;t->inflight=inflight;t->unwound=&l->bridge->role_unwound[role];
    t->role=role;t->state=DU_CLOSED;
    __atomic_fetch_add(entered,1,__ATOMIC_RELAXED);
    t->prior_depth=__atomic_fetch_add(inflight,1,__ATOMIC_ACQ_REL);
    t->state=DU_OPEN;*prior=t->prior_depth;return 1;
}
DU_INLINE void du_legacy_close(struct du_local *l,unsigned role) {
    for(unsigned i=l->count;i;i--) {
        struct du_token *t=&l->token[i-1];
        if(t->role!=role || t->state!=DU_OPEN)continue;
        __atomic_fetch_add(t->returned,1,__ATOMIC_RELAXED);
        __atomic_fetch_sub(t->inflight,1,__ATOMIC_RELEASE);t->state=DU_CLOSED;return;
    }
}
DU_INLINE int du_balanced(du64 entered,du64 returned,du64 unwound,du64 depth) {
    return returned<=entered && unwound<=entered-returned && entered-returned-unwound==depth;
}
#undef DU_INLINE
#ifdef __cplusplus
extern "C" {
#endif
/* Island targets: Pair x0..x6; Source x0..x4; timer x0,x1,x2 + d0. */
int anim_display_unwind_pair(void *,du64,void *,void *,
    struct display_unwind_bridge *,du_pair_original,du64 native_fp);
int anim_display_unwind_source(void *,void *,struct display_unwind_bridge *,
    du_source_original,du64 native_fp);
void anim_display_unwind_timer(struct ctx *,double,
    struct display_unwind_bridge *,du_timer_original);
/* New C bodies: never call the old framed exports from these. */
int anim_display_unwind_pair_body(void *,du64,void *,void *,
    struct display_unwind_bridge *,du_pair_original,du64 entry_fp,
    du64 native_fp,struct du_local *); /* ninth arg on aligned caller stack */
int anim_display_unwind_source_body(void *,void *,struct display_unwind_bridge *,
    du_source_original,du64 entry_fp,du64 native_fp,struct du_local *);
__attribute__((nothrow)) void anim_display_unwind_abort(struct du_local *);
void anim_display_unwind_timer_begin(struct ctx *,struct display_unwind_bridge *,struct du_local *);
void anim_display_unwind_timer_mutation(struct ctx *,double,
    struct display_unwind_bridge *,struct du_local *);
__attribute__((nothrow)) void anim_display_unwind_timer_normal_end(struct display_unwind_bridge *,struct du_local *);
#ifdef __cplusplus
}
#endif
#endif
