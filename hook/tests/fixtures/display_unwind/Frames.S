.text
// Own Update-like stack storage. Its genuine FP owns R/head/display reference
// only until this synchronous call returns or unwinds.
.p2align 3
.globl _own_frame_update_shell
_own_frame_update_shell:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    sub sp,sp,#0x40
.cfi_def_cfa_offset 0x40
    stp x19,x20,[sp]
    stp x21,x22,[sp,#0x10]
    stp x29,x30,[sp,#0x30]
.cfi_offset w19,-64
.cfi_offset w20,-56
.cfi_offset w21,-48
.cfi_offset w22,-40
.cfi_offset w29,-16
.cfi_offset w30,-8
    add x29,sp,#0x30
.cfi_def_cfa w29,16
    sub sp,sp,#0xc00
    mov x19,x0
    mov x20,x1
    mov x1,x29
    bl _own_case_prepare_frame
    mov x22,x0
    ldr x4,[x22,#56]
    cbz x4,Lown_no_source
    sub x0,x29,#0xb40
    ldr x1,[x22,#32]
    ldr x2,[x22,#40]
    ldr x3,[x22,#48]
    bl _own_source_mirror
.globl _own_source_normal_return
.alt_entry _own_source_normal_return
_own_source_normal_return:
Lown_no_source:
    bl _own_frame_outer
.globl _own_cohort_4
.alt_entry _own_cohort_4
_own_cohort_4:
    add sp,sp,#0xc00
    ldp x19,x20,[sp]
    ldp x21,x22,[sp,#0x10]
    ldp x29,x30,[sp,#0x30]
.cfi_def_cfa wsp,0x40
.cfi_restore w19
.cfi_restore w20
.cfi_restore w21
.cfi_restore w22
.cfi_restore w29
.cfi_restore w30
    add sp,sp,#0x40
.cfi_def_cfa_offset 0
    retab
.cfi_endproc

.macro own_small_frame name,callee,label
.p2align 3
.globl \name
\name:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp x29,x30,[sp,#-16]!
.cfi_def_cfa_offset 16
.cfi_offset w29,-16
.cfi_offset w30,-8
    mov x29,sp
.cfi_def_cfa w29,16
    bl \callee
.globl \label
.alt_entry \label
\label:
    ldp x29,x30,[sp],#16
.cfi_def_cfa wsp,0
.cfi_restore w29
.cfi_restore w30
    retab
.cfi_endproc
.endm
own_small_frame _own_frame_outer,_own_frame_middle,_own_cohort_3
own_small_frame _own_frame_middle,_own_frame_inner,_own_cohort_1
own_small_frame _own_frame_call,_own_frame_update_shell,_own_update_return

.p2align 3
.globl _own_frame_inner
_own_frame_inner:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp x29,x30,[sp,#-16]!
.cfi_def_cfa_offset 16
.cfi_offset w29,-16
.cfi_offset w30,-8
    mov x29,sp
.cfi_def_cfa w29,16
    ldp x0,x1,[x22]
    ldp x2,x3,[x22,#16]
    blraaz x20
.globl _own_cohort_0
.alt_entry _own_cohort_0
_own_cohort_0:
    ldp x29,x30,[sp],#16
.cfi_def_cfa wsp,0
.cfi_restore w29
.cfi_restore w30
    retab
.cfi_endproc
