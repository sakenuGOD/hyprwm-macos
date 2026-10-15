#ifndef HYPRWM_POINTER_HIT_H
#define HYPRWM_POINTER_HIT_H
#include <stdint.h>
/* Passive annotated native input routing. No owner lookup, AX call or event
 * mutation occurs in the callback. Consumers independently fence WID owners. */
typedef struct {
    uint64_t sequence, monotonic_ns;
    double x, y;
    uint32_t wid, under_wid;
    int32_t target_pid, source_pid;
    uint32_t event_type, valid;
    uint64_t event_timestamp_ns;
} ax_pointer_hit; /* 64 bytes; valid1 coherent point/type,2 positive field92 */
int ax_pointer_hit_available(void); /*1 annotated tap ready,0 starting,negative unavailable*/
int ax_pointer_hit_read(ax_pointer_hit *out); /*1 coherent latest sample,0 absent/torn*/
#endif
