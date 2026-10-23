#ifndef HYPRWM_FOCUS_MONITOR_H
#define HYPRWM_FOCUS_MONITOR_H
#include <math.h>
#include <stddef.h>

typedef struct { double x, y, w, h; } FocusMonitorRect;

/* CG global coordinates: greatest display intersection, then nearest display.
   Parked windows retain metadata but never become visible focus candidates. */
static inline size_t focus_monitor_for(FocusMonitorRect window,
                                      const FocusMonitorRect *monitors, size_t count) {
    size_t best = 0;
    double area_best = -1, distance_best = INFINITY;
    double cx = window.x + window.w / 2, cy = window.y + window.h / 2;
    for (size_t i = 0; i < count; ++i) {
        FocusMonitorRect m = monitors[i];
        double iw = fmax(0, fmin(window.x + window.w, m.x + m.w) - fmax(window.x, m.x));
        double ih = fmax(0, fmin(window.y + window.h, m.y + m.h) - fmax(window.y, m.y));
        double dx = fmax(fmax(m.x - cx, 0), cx - m.x - m.w);
        double dy = fmax(fmax(m.y - cy, 0), cy - m.y - m.h);
        double area = iw * ih, distance = dx * dx + dy * dy;
        if (area > area_best || (area == area_best && distance < distance_best)) {
            best = i;
            area_best = area;
            distance_best = distance;
        }
    }
    return best;
}
#endif
