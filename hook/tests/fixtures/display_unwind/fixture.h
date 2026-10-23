#pragma once
#include <stdint.h>
typedef struct OwnCase OwnCase;
typedef void (*OwnFrame)(void *,void *,void *,void *);
struct OwnCallbacks {
 int (*is_main)(void);void *(*thread_self)(void);void *(*stack_top)(void *);uint64_t (*stack_size)(void *);
 void (*invalidate)(void *,void *,void *);int (*contains)(void *,void *);
 void (*prepare)(void);void (*region_bbox)(void);int (*alpha)(float,unsigned);int (*order)(unsigned);
 void (*getter)(unsigned);void (*policy)(unsigned,unsigned);void (*source_observer)(void);
};
struct OwnVisibilitySnapshot {uint64_t completed,constructed,committed,inflight,pair_inflight,source_inflight,timer_inflight;unsigned workspace_phase;};
#ifdef __cplusplus
extern "C" {
#endif
OwnCase *own_case_new(const struct OwnCallbacks *,uint64_t,const uint64_t[5],const uint64_t[2]);
void *own_case_vector(OwnCase *);void *own_case_vector_end(OwnCase *);
void *own_case_region(OwnCase *);void *own_case_dirty(OwnCase *);
void own_case_request(OwnCase *,uint64_t);
void **own_case_prepare_frame(OwnCase *,uint64_t);
void *own_case_unwind(OwnCase *);void *own_case_engine(OwnCase *);
void own_case_visibility_snapshot(OwnCase *,struct OwnVisibilitySnapshot *);
void own_case_assert_A(OwnCase *);void own_case_policy(OwnCase *,unsigned);
float own_case_local_alpha(OwnCase *);
void own_case_du_enabled(OwnCase *,unsigned);
void own_case_source_binding(OwnCase *,void *,void *);void *own_case_B_window(OwnCase *);
void own_case_source_returned(OwnCase *,unsigned);void own_case_source_return_address(OwnCase *,uint64_t);
void own_case_workspace_sentinel(OwnCase *);void *own_case_workspace_head(OwnCase *);
void own_case_du_poison(OwnCase *);void own_case_host_order(OwnCase *);
void own_case_role_storage(OwnCase *,uint64_t *[4][3]);
#ifdef __cplusplus
}
#endif
