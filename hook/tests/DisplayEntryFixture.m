// Real arm64e OWN-process proof of the entry-B / six-argument wrapper /
// original-PAC trampoline ABI. No system text or WindowServer is modified.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <pthread.h>
#include <ptrauth.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/anim4.c"
__asm__(".text\n.p2align 2\n.globl _owned_display_target\n_owned_display_target:\n"
        "pacibsp\nsub sp,sp,#0x40\nstp x20,x19,[sp,#0x20]\nstp x29,x30,[sp,#0x30]\n"
        "add x29,sp,#0x30\nldr x8,[x0]\nadd x8,x8,#1\nstr x8,[x0]\n"
        "eor x8,x1,x1,lsr #32\nadd x8,x8,x2\neor x0,x8,x3\n"
        "ldp x29,x30,[sp,#0x30]\nldp x20,x19,[sp,#0x20]\nadd sp,sp,#0x40\nretab\n"
        ".globl _owned_display_target_end\n_owned_display_target_end:\n");
extern int owned_display_target(void *,u64,void *,void *);
extern char owned_display_target_end[];
static u32 branch(void *from,void *to){
    long delta=(char *)to-(char *)from;assert(!(delta&3) && delta>=-0x8000000 && delta<=0x7fffffc);
    return 0x14000000U|((u32)(delta/4)&0x3ffffffU);
}
static void protect(void *page,int protection){assert(mprotect(page,16384,protection)==0);}
int main(void){@autoreleasepool {
    [CATransaction class];
    unsigned char *page=mmap(NULL,16384,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(page!=MAP_FAILED);void *raw=ptrauth_strip(&owned_display_target,ptrauth_key_function_pointer);
    size_t size=(char *)owned_display_target_end-(char *)raw;assert(size==60);
    memcpy(page,raw,size);u32 original_word=*(u32 *)page;assert(original_word==0xd503237fU);
    display_original_fn target=(display_original_fn)ptrauth_sign_unauthenticated(page,ptrauth_key_function_pointer,0);
    u64 calls=0,force=0x123456789abcdef0ULL;void *begin=(void *)0x200,*end=(void *)0x230;
    int expected=(int)((force^(force>>32))+(u64)begin)^(int)(u64)end;
    protect(page,PROT_READ|PROT_EXEC);sys_icache_invalidate(page,16384);
    assert(target(&calls,force,begin,end)==expected && calls==1);
    static struct ch channel;static struct ctx engine;static struct display_probe probe;
    channel.h.magic=CH_MAGIC;engine.ch=&channel;engine.cls=(__typeof__(engine.cls))objc_getClass;
    engine.sel=(__typeof__(engine.sel))sel_registerName;engine.msg=(void *)objc_msgSend;
    probe.magic=DISPLAY_PROBE_MAGIC;probe.size=sizeof(probe);probe.version=1;
    probe.engine=&engine;probe.is_main=pthread_main_np;probe.enabled=1;
    unsigned char *entry=page+0x100,*trampoline=page+0x200;
    void *signed_original=ptrauth_sign_unauthenticated(trampoline,ptrauth_key_function_pointer,0);
    void *wrapper=ptrauth_strip(&anim_display_probe_entry,ptrauth_key_function_pointer);
    protect(page,PROT_READ|PROT_WRITE);
    // LDR x4,state; LDR x5,IA0-original; LDR x16,raw-wrapper; BR x16.
    u32 stub[4]={0x58000084U,0x580000a5U,0x580000d0U,0xd61f0200U};
    memcpy(entry,stub,sizeof(stub));*(void **)(entry+16)=&probe;
    *(void **)(entry+24)=signed_original;*(void **)(entry+32)=wrapper;
    *(u32 *)trampoline=original_word;*(u32 *)(trampoline+4)=branch(trampoline+4,page+4);
    *(u32 *)page=branch(page,entry);protect(page,PROT_READ|PROT_EXEC);sys_icache_invalidate(page,16384);
    assert(target(&calls,force,begin,end)==expected && calls==2);
    assert(probe.entered==1 && probe.returned==1 && !probe.inflight && probe.kinds[3]==1);
    assert(probe.states[0]==1 && !probe.nonmain && !probe.unavailable);
    probe.enabled=0;assert(target(&calls,force,begin,end)==expected && calls==3);
    assert(probe.entered==2 && probe.returned==2 && probe.states[0]==1);
    probe.magic=0;assert(target(&calls,force,begin,end)==expected && calls==4);
    assert(probe.entered==2 && probe.returned==2);
    protect(page,PROT_READ|PROT_WRITE);*(u32 *)page=original_word;
    protect(page,PROT_READ|PROT_EXEC);sys_icache_invalidate(page,16384);
    assert(target(&calls,force,begin,end)==expected && calls==5 && probe.entered==2);
    puts("OWN arm64e entry-B/six-arg/PAC-original/readonly-state/OFF/exact-forward PASS");
    // Keep this mapping until process exit, just as the native qualifier must.
    return 0;
}}
