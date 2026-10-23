// Declarations for hook/src/winsnap.m.
#pragma once
int ws_snapshot(char *buf, int cap);
int ws_close(int pid, unsigned wid);
int ws_focus(int pid, unsigned wid);
int ws_quit(int pid);

char *hypridentity_copy_connection_json(int caller, int target, int expectedPID, int *error);

int ws_menu_tracking(void);
int ws_input_overlay(void);
// Caller owns/free() the bounded, read-only JSON result. NULL means unknown.
char *hs_workspace_identity_json(int pid);
char *hs_workspace_diagnostic_json(void);
char *hs_platform_fingerprint_json(void);
