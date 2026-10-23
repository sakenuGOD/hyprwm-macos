.text
.p2align 3
.globl _own_pair_mirror
_own_pair_mirror:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    sub sp,sp,#0x40
.cfi_def_cfa_offset 64
    stp x20,x19,[sp,#0x20]
.cfi_offset w20,-32
.cfi_offset w19,-24
    stp x29,x30,[sp,#0x30]
.cfi_offset w29,-16
.cfi_offset w30,-8
    add x29,sp,#0x30
.cfi_def_cfa w29,16
    mov x16,x6
    mov x6,x29
    blraaz x16
    ldp x29,x30,[sp,#0x30]
.cfi_def_cfa wsp,64
.cfi_restore w29
.cfi_restore w30
    ldp x20,x19,[sp,#0x20]
.cfi_restore w20
.cfi_restore w19
    add sp,sp,#0x40
.cfi_def_cfa_offset 0
    retab
.cfi_endproc

.text
.p2align 3
.globl _own_pair_call
_own_pair_call:
.cfi_startproc
.cfi_b_key_frame
 pacibsp
 stp x29,x30,[sp,#-16]!
.cfi_def_cfa_offset 16
.cfi_offset w29,-16
.cfi_offset w30,-8
 mov x29,sp
.cfi_def_cfa w29,16
 bl _own_pair_mirror
.globl _own_pair_call_return
.alt_entry _own_pair_call_return
_own_pair_call_return:
 ldp x29,x30,[sp],#16
.cfi_def_cfa wsp,0
.cfi_restore w29
.cfi_restore w30
 retab
.cfi_endproc
