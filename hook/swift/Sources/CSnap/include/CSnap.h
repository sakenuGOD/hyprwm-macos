// Прототипы hook/src/winsnap.m.
#pragma once
int ws_snapshot(char *buf, int cap);
int ws_close(int pid, unsigned wid);
int ws_focus(int pid, unsigned wid);
int ws_quit(int pid);
