#ifndef HY_EFFECTS_RUNTIME_API_H
#define HY_EFFECTS_RUNTIME_API_H
#include "../src/chan.h"
#include "shadow_contract.h"

// Separate runtime state; neither edge_state nor the shared channel is enlarged.
// API is installed only after independent library/Metal/backend verification.
#define HY_EFFECTS_MAGIC 0x3146584552505948ull
enum { HY_EFFECTS_ROUNDING=1, HY_EFFECTS_GLOW=2, HY_EFFECTS_MASTER_OFF=4 };
enum { HY_EFFECTS_APPLIED=1, HY_EFFECTS_ANIMATING=2, HY_EFFECTS_DIRTY=4 };
struct hy_effects_config {
    double rounding, power, glow_range, glow_power;
    double active[4], inactive[4], glow_duration;
    unsigned enabled;
    struct ch_curve curve; // immutable copied snapshot, not a live shared pointer
};
struct hy_effects_frame {
    unsigned slot, role, wid, prepared, focus; // role0=source,1=owned full-body helper
    unsigned long long generation, source_window, source_context;
    void *host, *root, *parent_mask; // parent_mask=current legal P4/foreign mask
    void *border, *border_parent_mask;
    void *legacy_shadow;
    double border_width;
    double width, height, scale, now;
};
struct hy_effects_api {
    unsigned long long magic;
    unsigned size, version;
    void *(*create)(const char *metal_source);
    int (*configure)(void *,const struct hy_effects_config *);
    int (*frame)(void *,const struct hy_effects_frame *);
    void (*drop)(void *,unsigned slot,unsigned role);
    void (*destroy)(void *);
    unsigned (*flags)(void *);
    void (*suspend)(void *,unsigned slot,unsigned role);
    int (*eligible)(void *,const struct hy_effects_frame *);
    int (*configure_shadow)(void *,const HYShadowConfig *,const struct ch_curve *,double,unsigned);
    int (*shadow_supported)(void *);
};
const struct hy_effects_api *hy_effects_api(void);
#endif
