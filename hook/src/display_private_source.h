/* Dormant controlled privateB source. A stays native; no total fallback claim. */
#ifndef DISPLAY_PRIVATE_SOURCE_H
#define DISPLAY_PRIVATE_SOURCE_H
#include "display_unwind.h"
enum ps_status { PS_REFUSED_BEFORE_CUSTODY=-1,PS_COMPLETE=0,PS_ABORTED=1 };
enum ps_call { PS_CALL_NONE,PS_CALL_RETAIN,PS_CALL_GENERATE,PS_CALL_OBSERVE,
 PS_CALL_FREE_LAYERS,PS_CALL_RELEASE_OPAQUE,PS_CALL_RELEASE_ENUMERATOR,
 PS_CALL_OBSERVE_MAIN,PS_CALL_OBSERVE_A,PS_CALL_OBSERVE_B,PS_CALL_OBSERVE_CLOCK,
 PS_CALL_ADMIT_MAIN,PS_CALL_ADMIT_THREAD,PS_CALL_ADMIT_TOP,PS_CALL_ADMIT_SIZE,PS_CALL_ADMIT_B };
enum { PS_ORIGINAL_NOT_STARTED,PS_ORIGINAL_STARTED,PS_ORIGINAL_RETURNED };
enum { PS_OK,PS_DISABLED,PS_SCOPE,PS_BUSY,PS_QUARANTINE,PS_BINDING,PS_EPOCH };
#define PS_MAGIC 0x31535043574d5748ULL
struct __attribute__((aligned(16))) display_private_source {
 struct display_unwind_bridge bridge;
 du64 magic;du32 size,version;
 du32 enabled,pad;
 du64 revision,attempted,completed,refused,aborted,epoch,entry_revision;
 du32 active_call,returned_call,original_state,reason;
 int native_result;du32 native_result_valid;
 du64 checkpoints;
};
static __attribute__((always_inline)) inline int ps_valid(struct display_private_source*t){
 return t && t->magic==PS_MAGIC && t->size==sizeof(*t) && t->version==1 &&
  !t->pad && __atomic_load_n(&t->enabled,__ATOMIC_ACQUIRE)<=1 && du_valid(&t->bridge);
}
#ifdef __cplusplus
extern "C" {
#endif
int anim_display_private_source(void*,void*,struct display_private_source*,du_source_original,du64);
int anim_display_private_source_body(void*,void*,struct display_private_source*,du_source_original,
                                    du64,du64,struct du_local*);
#ifdef __cplusplus
}
static_assert(sizeof(display_private_source)==384);
#else
_Static_assert(sizeof(struct display_private_source)==384,"private source capsule384");
#endif
#endif
