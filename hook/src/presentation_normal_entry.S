// Entry island replaces only the qualified prefix of Compositor::prepare_layers.
// Slots are filled once before RX publication and never changed afterward.
.text
.p2align 3
.globl _rgba_normal_entry
_rgba_normal_entry:
.cfi_startproc
.cfi_def_cfa wsp,0
    bti c
    ldr x4,Lnormal_binding
    ldr x5,Lnormal_original
    ldr x16,Lnormal_callback
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_normal_original
_rgba_normal_original:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    sub sp,sp,#0x90
.cfi_def_cfa_offset 144
    stp d9,d8,[sp,#0x20]
.cfi_offset b9,-112
.cfi_offset b8,-104
    stp x28,x27,[sp,#0x30]
.cfi_offset w28,-96
.cfi_offset w27,-88
    stp x26,x25,[sp,#0x40]
.cfi_offset w26,-80
.cfi_offset w25,-72
    stp x24,x23,[sp,#0x50]
.cfi_offset w24,-64
.cfi_offset w23,-56
    stp x22,x21,[sp,#0x60]
.cfi_offset w22,-48
.cfi_offset w21,-40
    stp x20,x19,[sp,#0x70]
.cfi_offset w20,-32
.cfi_offset w19,-24
    stp x29,x30,[sp,#0x80]
.cfi_offset w29,-16
.cfi_offset w30,-8
    add x29,sp,#0x80
.cfi_def_cfa w29,16
    mov x20,x3
    mov x22,x2
    ldr x16,Lnormal_back
    braaz x16
.cfi_endproc
.globl _rgba_normal_original_prefix_end
_rgba_normal_original_prefix_end = _rgba_normal_original + 0x30
.p2align 3
.globl _rgba_normal_slots
_rgba_normal_slots:
Lnormal_binding: .quad 0
Lnormal_original: .quad 0
Lnormal_callback: .quad 0
Lnormal_back: .quad 0

// C++ runtime veneers keep all copied text self-contained. SDK-resolved typed
// targets and the indirect personality cell are pinned before RX publication.
.text
.p2align 3
.globl _rgba_normal_personality
_rgba_normal_personality:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_personality_cell
    braaz x16
.cfi_endproc
___cxa_begin_catch:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_begin_catch
    braaz x16
.cfi_endproc
___cxa_end_catch:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_end_catch
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_normal_runtime_slots
_rgba_normal_runtime_slots:
Lncxx_personality_cell: .quad 0
Lncxx_begin_catch: .quad 0
Lncxx_end_catch: .quad 0
