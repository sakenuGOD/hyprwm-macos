// Reuse the existing timer dispatch ABI (x0=engine, d0=time). Immutable slots
// are filled once before RX/publication. No extra timer or native frame exists.
.text
.p2align 3
.globl _display_visibility_timer_island
_display_visibility_timer_island:
.cfi_startproc
    bti c
    ldr x1,Lvisibility_timer_state
    ldr x2,Lvisibility_timer_original
    ldr x16,Lvisibility_timer_entry
    braaz x16
.cfi_endproc
.globl _display_visibility_timer_island_end
_display_visibility_timer_island_end:
.p2align 3
.globl _display_visibility_timer_state_slot
_display_visibility_timer_state_slot:
Lvisibility_timer_state: .quad 0
.globl _display_visibility_timer_original_slot
_display_visibility_timer_original_slot:
Lvisibility_timer_original: .quad 0
.globl _display_visibility_timer_entry_slot
_display_visibility_timer_entry_slot:
Lvisibility_timer_entry: .quad 0
