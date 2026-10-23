.text
.p2align 3
.globl _ps_update_mirror
_ps_update_mirror:
.cfi_startproc
.cfi_b_key_frame
 pacibsp
 sub sp,sp,#0xd20
.cfi_def_cfa_offset 3360
 add x9,sp,#0xd00
 stp x29,x30,[x9,#0x10]
.cfi_offset w29,-16
.cfi_offset w30,-8
 add x29,x9,#0x10
.cfi_def_cfa w29,16
 stp x0,x1,[sp]
 stp x2,x3,[sp,#16]
 sub x0,x29,#0xb40
 sub x1,x29,#0xb88
 mov x2,x29
 adr x3,Lps_normal_return
 bl _fixture_fill
 sub x0,x29,#0xb40
 ldp x1,x2,[sp]
 ldp x3,x4,[sp,#16]
 bl _ps_source_mirror
Lps_normal_return:
 str w0,[sp,#32]
 sub x0,x29,#0xb40
 sub x1,x29,#0xb88
 bl _fixture_verify
 ldr w0,[sp,#32]
 add x9,sp,#0xd00
 ldp x29,x30,[x9,#0x10]
.cfi_def_cfa wsp,3360
.cfi_restore w29
.cfi_restore w30
 add sp,sp,#0xd20
.cfi_def_cfa_offset 0
 retab
.cfi_endproc
