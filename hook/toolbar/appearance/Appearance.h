#ifndef HYPR_WINDOW_APPEARANCE_H
#define HYPR_WINDOW_APPEARANCE_H
#include <stdint.h>
enum { HWA_STATUS=0,HWA_ON=1,HWA_OFF=2,HWA_ON_MAIN_ONLY=3 };
enum { HWA_OK=0,HWA_ARGUMENT=-1,HWA_THREAD=-2,HWA_IDENTITY=-3,HWA_NO_APP=-4,
 HWA_WINDOW=-5,HWA_PROVENANCE=-6,HWA_INELIGIBLE=-7,HWA_ORIGINAL_AMBIGUOUS=-8,
 HWA_OTHER_TRACKED=-9,HWA_VERIFY=-10,HWA_EXCEPTION=-11 };
// Target-local, main-thread, explicit exact current process identity + one WID.
// Never creates NSApplication, hooks/listeners, timers, native focus or windows.
// Status is read-only. ON stores originals once. OFF restores those exact bits.
// >=8192-byte output is mandatory BEFORE any mutation. UUID: exact32hex digits.
int hyprappearance_v1_json(int action,int32_t pid,uint32_t uid,uint64_t birth_sec,
 uint64_t birth_usec,const char *executable,const char *main_uuid,uint32_t wid,
 char *output,uint32_t capacity);
#endif
