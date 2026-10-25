#ifndef HYPRWM_AXPOLICY_H
#define HYPRWM_AXPOLICY_H

// Additive libax ABI. Negative returns mean AX evidence is unavailable, never permission to tile.
enum {
    AXWM_WINDOW = 1u << 0, AXWM_STANDARD = 1u << 1, AXWM_RESIZABLE = 1u << 2,
    AXWM_MODAL = 1u << 3, AXWM_SHEET = 1u << 4, AXWM_DIALOG = 1u << 5,
    AXWM_TRANSIENT = 1u << 6, AXWM_TILEABLE = 1u << 7,
    AXWM_MEDIA = 1u << 8,
};
enum {
    AXWM_FOCUS_MENU = 1u << 0, AXWM_FOCUS_TRANSIENT = 1u << 1,
    AXWM_FOCUS_UNKNOWN = 1u << 2, AXWM_FOCUS_MODAL = 1u << 3,
    AXWM_FOCUS_FULLSCREEN = 1u << 4,
    // AX explicitly returned no focused window, after focused-UI guards.
    // A timeout/unsupported attribute remains UNKNOWN, never NO_KEY.
    AXWM_FOCUS_NO_KEY = 1u << 5,
};
int ax_window_flags(int pid, unsigned wid);
int ax_focus_context(int pid, unsigned *focused_wid, unsigned *context);

#endif
