#ifndef HYPRWM_LAUNCHER_INTENT_H
#define HYPRWM_LAUNCHER_INTENT_H
#include <stdint.h>
typedef struct {
    uint64_t sequence, origin_space, monotonic_ns;
    int32_t front_pid, kind;
} ax_launcher_intent; /* kind: 1 Spotlight, 2 Command-Tab, 3 Dock click; 0 invalidation */
int ax_launcher_start(void); /* dedicated runloop thread; listen-only, never prompts */
int ax_launcher_available(void); /* 1 ready, 0 not started, negative unavailable */
uint64_t ax_launcher_now_ns(void);
void ax_launcher_stop(void);
void ax_launcher_cache(uint64_t space, int32_t front_pid, const uint32_t *dock_wids, uint32_t count);
void ax_launcher_cache_dock(uint64_t space, int32_t front_pid, const uint32_t *dock_wids,
                            const double *dock_rects_xywh, uint32_t count);
int ax_launcher_read(uint64_t after_sequence, ax_launcher_intent *out);
void ax_launcher_clear(uint64_t sequence);
#endif
