// Same SDK ABI in OWN qualifier and bounded native prepare; no external symbols.
#include <libunwind.h>
#include <ptrauth.h>
struct display_unwind_check {
 int (*getcontext)(unw_context_t*);
 int (*init_local)(unw_cursor_t*,unw_context_t*);
 int (*get_reg)(unw_cursor_t*,unw_regnum_t,unw_word_t*);
 int (*set_reg)(unw_cursor_t*,unw_regnum_t,unw_word_t);
 int (*get_info)(unw_cursor_t*,unw_proc_info_t*);
 unsigned long long starts[2],fdes[2];
};
unsigned display_unwind_check(const struct display_unwind_check*p){
 unw_context_t context;unw_cursor_t cursor;unw_word_t sp=0;
 if(p->getcontext(&context)||p->init_local(&cursor,&context))return 1;
 if(p->get_reg(&cursor,UNW_REG_SP,&sp))return 2;
 for(unsigned i=0;i<2;i++){
  unw_proc_info_t before;
  if(p->get_info(&cursor,&before)||before.gp)return 3;
  void*ip=__builtin_ptrauth_sign_unauthenticated((void*)(p->starts[i]+0x60),1,sp);
  if(p->set_reg(&cursor,UNW_REG_IP,(unw_word_t)ip))return 4;
  unw_proc_info_t info;
  if(p->get_info(&cursor,&info))return 5;
  if(info.start_ip!=p->starts[i]||info.unwind_info!=p->fdes[i])return 6;
 }
 return 0;
}
