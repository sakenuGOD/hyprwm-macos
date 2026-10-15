// Прототипы hook/src/axlib.c и обёрток SkyLight/CoreGraphics (в Python-демоне это были ctypes-вызовы
// в hyprwm.py: win_pid_level, front_pid, win_bounds, win_alpha, move_to_space, mouse, mouse_down, spotlight).
#pragma once
#include <stdint.h>
#include "../../../../src/pointer_hit.h"

int ax_trusted(void);
int ax_tileable(int pid, unsigned wid);
int ax_focus_context(int pid, unsigned *focused_wid, unsigned *context);
int ax_frame(int pid, unsigned wid, double x, double y, double w, double h);
int ax_size(int pid, unsigned wid, double w, double h);
int ax_get_frame(int pid, unsigned wid, double *out);
typedef struct { int32_t result,stage;uint64_t lookup_ns,button_ns,press_ns; } hs_close_metrics;
void hs_close_request(int pid,unsigned wid,hs_close_metrics *out);
int hs_window_presence(int pid,unsigned wid);
void ax_forget(unsigned wid);
int ax_focus(int pid, unsigned wid, int raise);
int ax_menu_press(int pid, const char *title);

// sys.c
int hs_cid(void);
int hs_session_locked(void);
int hs_window_connection(unsigned wid, int expected_pid);
int hs_window_server_pid(void);
int hs_process_birth(int pid, uint64_t *seconds, uint64_t *micros);
int hs_win_pid_level(unsigned wid, int *pid, int *level);      // 0 — успех
int hs_front_pid(int *pid);                                    // 0 — успех
int hs_win_bounds(unsigned wid, double *out4);                 // 0 — успех
int hs_win_alpha(unsigned wid, float *a);                      // 0 — успех
void hs_move_to_space(const int32_t *wids, int n, uint64_t space);
uint64_t hs_active_space(void);
void hs_mouse(double *x, double *y);
int hs_mouse_down(void);
void hs_spotlight(void);

struct hs_resize_context {
    uint64_t sequence, epoch;
    uint32_t wid, phase;
    double x,y,w,h,mx,my,time,event_time;
    double accepted_x,accepted_y,accepted_w,accepted_h,accepted_time;
    uint64_t sample;
};
int hs_read_resize_context(int pid, double now, struct hs_resize_context *out);
uint64_t hs_overview10_mode(void);
int hs_notify_state(const char *name, uint64_t *value);
int hs_notify_publish_state(const char *name, uint64_t value);
#include "../../../../src/launcher_intent.h"
