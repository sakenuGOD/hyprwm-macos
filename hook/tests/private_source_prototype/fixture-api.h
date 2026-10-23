#include "../../src/display_private_source.h"
#ifdef __cplusplus
extern "C" {
#endif
void fixture_reset(unsigned fault_call,unsigned fault_mode);
struct display_private_source*fixture_trial(void);
void*fixture_window(void);
int fixture_original(void*,void*);
int fixture_nested_throw(void*,void*);
void fixture_check(unsigned outcome,unsigned fault_call,unsigned mode);
void fixture_fill(void*,void**,unsigned long long,unsigned long long);
void fixture_verify(void*,void**);
void fixture_fault(unsigned call);
int fixture_core_body(void*,void*,struct display_private_source*,du_source_original,du64,du64,struct du_local*);
void fixture_set_case(unsigned);
int fixture_state_call(void);
#ifdef __cplusplus
}
#endif
