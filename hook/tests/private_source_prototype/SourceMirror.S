// Statically compiled OWN fixture. No native code is loaded or patched.
// Synthetic body; native full frame offsets are mirrored for SDK CFI checking.
.text
.p2align 3
.globl _ps_source_mirror
_ps_source_mirror:
.cfi_startproc
.cfi_b_key_frame
    pacibsp
    stp d15,d14,[sp,#-0xa0]!
.cfi_def_cfa_offset 160
.cfi_offset d15,-160
.cfi_offset d14,-152
    stp d13,d12,[sp,#0x10]
.cfi_offset d13,-144
.cfi_offset d12,-136
    stp d11,d10,[sp,#0x20]
.cfi_offset d11,-128
.cfi_offset d10,-120
    stp d9,d8,[sp,#0x30]
.cfi_offset d9,-112
.cfi_offset d8,-104
    stp x28,x27,[sp,#0x40]
.cfi_offset w28,-96
.cfi_offset w27,-88
    stp x26,x25,[sp,#0x50]
.cfi_offset w26,-80
.cfi_offset w25,-72
    stp x24,x23,[sp,#0x60]
.cfi_offset w24,-64
.cfi_offset w23,-56
    stp x22,x21,[sp,#0x70]
.cfi_offset w22,-48
.cfi_offset w21,-40
    stp x20,x19,[sp,#0x80]
.cfi_offset w20,-32
.cfi_offset w19,-24
    stp x29,x30,[sp,#0x90]
.cfi_offset w29,-16
.cfi_offset w30,-8
    add x29,sp,#0x90
.cfi_def_cfa w29,16
    sub sp,sp,#0x2f0
    mov x16,x4
    mov x4,x29
    blraaz x16
    add sp,sp,#0x2f0
    ldp x29,x30,[sp,#0x90]
.cfi_def_cfa wsp,160
.cfi_restore w29
.cfi_restore w30
    ldp x20,x19,[sp,#0x80]
.cfi_restore w20
.cfi_restore w19
    ldp x22,x21,[sp,#0x70]
.cfi_restore w22
.cfi_restore w21
    ldp x24,x23,[sp,#0x60]
.cfi_restore w24
.cfi_restore w23
    ldp x26,x25,[sp,#0x50]
.cfi_restore w26
.cfi_restore w25
    ldp x28,x27,[sp,#0x40]
.cfi_restore w28
.cfi_restore w27
    ldp d9,d8,[sp,#0x30]
.cfi_restore d9
.cfi_restore d8
    ldp d11,d10,[sp,#0x20]
.cfi_restore d11
.cfi_restore d10
    ldp d13,d12,[sp,#0x10]
.cfi_restore d13
.cfi_restore d12
    ldp d15,d14,[sp],#0xa0
.cfi_restore d15
.cfi_restore d14
.cfi_def_cfa_offset 0
    retab

.cfi_endproc
