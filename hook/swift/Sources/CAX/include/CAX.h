// Прототипы hook/src/axlib.c и обёрток SkyLight/CoreGraphics (в Python-демоне это были ctypes-вызовы
// в hyprwm.py: win_pid_level, front_pid, win_bounds, win_alpha, move_to_space, mouse, mouse_down, spotlight).
#pragma once
#include <stdint.h>

int ax_trusted(void);
int ax_tileable(int pid, unsigned wid);
int ax_frame(int pid, unsigned wid, double x, double y, double w, double h);
int ax_get_frame(int pid, unsigned wid, double *out);
void ax_forget(unsigned wid);
int ax_focus(int pid, unsigned wid, int raise);
int ax_menu_press(int pid, const char *title);

// sys.c
int hs_cid(void);
int hs_win_pid_level(unsigned wid, int *pid, int *level);      // 0 — успех
int hs_front_pid(int *pid);                                    // 0 — успех
int hs_win_bounds(unsigned wid, double *out4);                 // 0 — успех
int hs_win_alpha(unsigned wid, float *a);                      // 0 — успех
void hs_move_to_space(const int32_t *wids, int n, uint64_t space);
uint64_t hs_active_space(void);
void hs_mouse(double *x, double *y);
int hs_mouse_down(void);
void hs_spotlight(void);
