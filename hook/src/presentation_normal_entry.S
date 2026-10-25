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

// Per-window normal BeginUpdate. The observer runs before the native snapshot;
// the original prologue and its unwind contract remain intact.
.text
.p2align 3
.globl _rgba_begin_entry
_rgba_begin_entry:
.cfi_startproc
.cfi_def_cfa wsp,0
    bti c
    ldr x3,Lbegin_binding
    ldr x4,Lbegin_original
    ldr x16,Lbegin_callback
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_begin_original
_rgba_begin_original:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp d11,d10,[sp,#-0x80]!
.cfi_def_cfa_offset 128
.cfi_offset b11,-128
.cfi_offset b10,-120
    stp d9,d8,[sp,#0x10]
.cfi_offset b9,-112
.cfi_offset b8,-104
    stp x28,x27,[sp,#0x20]
.cfi_offset w28,-96
.cfi_offset w27,-88
    stp x26,x25,[sp,#0x30]
.cfi_offset w26,-80
.cfi_offset w25,-72
    stp x24,x23,[sp,#0x40]
.cfi_offset w24,-64
.cfi_offset w23,-56
    stp x22,x21,[sp,#0x50]
.cfi_offset w22,-48
.cfi_offset w21,-40
    stp x20,x19,[sp,#0x60]
.cfi_offset w20,-32
.cfi_offset w19,-24
    stp x29,x30,[sp,#0x70]
.cfi_offset w29,-16
.cfi_offset w30,-8
    add x29,sp,#0x70
.cfi_def_cfa w29,16
    sub sp,sp,#0x2a0
    mov x21,x2
    ldr x16,Lbegin_back
    braaz x16
.cfi_endproc
.globl _rgba_begin_original_prefix_end
_rgba_begin_original_prefix_end = _rgba_begin_original + 0x30
.p2align 3
.globl _rgba_begin_slots
_rgba_begin_slots:
Lbegin_binding: .quad 0
Lbegin_original: .quad 0
Lbegin_callback: .quad 0
Lbegin_back: .quad 0

.text
.p2align 3
.globl _rgba_scene_entry
_rgba_scene_entry:
.cfi_startproc
.cfi_def_cfa wsp,0
    bti c
    ldr x4,Lscene_binding
    ldr x5,Lscene_original
    ldr x16,Lscene_callback
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_scene_slots
_rgba_scene_slots:
Lscene_binding: .quad 0
Lscene_original: .quad 0
Lscene_callback: .quad 0

// These Copy getters have the same typed ABI. Their first sixteen bytes are
// stack saves only; the native suffix retains the rest of its own frame.
.text
.p2align 3
.globl _rgba_content_entry
_rgba_content_entry:
.cfi_startproc
.cfi_def_cfa wsp,0
    bti c
    ldr x2,Lcontent_binding
    ldr x3,Lcontent_original
    mov w4,#0
    ldr x16,Lcontent_callback
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_content_original
_rgba_content_original:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp x24,x23,[sp,#-0x40]!
.cfi_def_cfa_offset 64
.cfi_offset w24,-64
.cfi_offset w23,-56
    stp x22,x21,[sp,#0x10]
.cfi_offset w22,-48
.cfi_offset w21,-40
    stp x20,x19,[sp,#0x20]
.cfi_offset w20,-32
.cfi_offset w19,-24
    ldr x16,Lcontent_back
    braaz x16
.cfi_endproc
.globl _rgba_content_original_prefix_end
_rgba_content_original_prefix_end = _rgba_content_original + 0x10
.p2align 3
.globl _rgba_content_slots
_rgba_content_slots:
Lcontent_binding: .quad 0
Lcontent_original: .quad 0
Lcontent_callback: .quad 0
Lcontent_back: .quad 0
.p2align 3
.globl _rgba_frame_entry
_rgba_frame_entry:
.cfi_startproc
.cfi_def_cfa wsp,0
    bti c
    ldr x2,Lframe_binding
    ldr x3,Lframe_original
    mov w4,#1
    ldr x16,Lframe_callback
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_frame_original
_rgba_frame_original:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp d9,d8,[sp,#-0x70]!
.cfi_def_cfa_offset 112
.cfi_offset b9,-112
.cfi_offset b8,-104
    stp x28,x27,[sp,#0x10]
.cfi_offset w28,-96
.cfi_offset w27,-88
    stp x26,x25,[sp,#0x20]
.cfi_offset w26,-80
.cfi_offset w25,-72
    ldr x16,Lframe_back
    braaz x16
.cfi_endproc
.globl _rgba_frame_original_prefix_end
_rgba_frame_original_prefix_end = _rgba_frame_original + 0x10
.p2align 3
.globl _rgba_frame_slots
_rgba_frame_slots:
Lframe_binding: .quad 0
Lframe_original: .quad 0
Lframe_callback: .quad 0
Lframe_back: .quad 0
.p2align 3
.globl _rgba_ingestion_entry
_rgba_ingestion_entry:
.cfi_startproc
.cfi_def_cfa wsp,0
    bti c
    ldr x3,Lingestion_binding
    ldr x4,Lingestion_original
    ldr x16,Lingestion_callback
    braaz x16
.cfi_endproc
.p2align 3
.globl _rgba_ingestion_original
_rgba_ingestion_original:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp d13,d12,[sp,#-0x90]!
.cfi_def_cfa_offset 144
.cfi_offset b13,-144
.cfi_offset b12,-136
    stp d11,d10,[sp,#0x10]
.cfi_offset b11,-128
.cfi_offset b10,-120
    stp d9,d8,[sp,#0x20]
.cfi_offset b9,-112
.cfi_offset b8,-104
    ldr x16,Lingestion_back
    braaz x16
.cfi_endproc
.globl _rgba_ingestion_original_prefix_end
_rgba_ingestion_original_prefix_end = _rgba_ingestion_original + 0x10
.p2align 3
.globl _rgba_ingestion_slots
_rgba_ingestion_slots:
Lingestion_binding: .quad 0
Lingestion_original: .quad 0
Lingestion_callback: .quad 0
Lingestion_back: .quad 0

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
___cxa_rethrow:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_rethrow
    braaz x16
.cfi_endproc
__ZSt9terminatev:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_terminate
    braaz x16
.cfi_endproc
__Unwind_Resume:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_resume
    braaz x16
.cfi_endproc
_abort:
.cfi_startproc
.cfi_def_cfa wsp,0
    ldr x16,Lncxx_abort
    braaz x16
.cfi_endproc

.p2align 3
.globl _rgba_normal_runtime_slots
_rgba_normal_runtime_slots:
Lncxx_personality_cell: .quad 0
Lncxx_begin_catch: .quad 0
Lncxx_end_catch: .quad 0
Lncxx_rethrow: .quad 0
Lncxx_terminate: .quad 0
Lncxx_resume: .quad 0
Lncxx_abort: .quad 0
