#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../src/display_damage.h"

static struct display_damage d;
static struct display_damage_command command;
static unsigned calls,action;
static void *region;
static jmp_buf interrupted;
static void invalidate(void *connection,void *window,void *input) {
    assert(!connection && !window && input==region);
    assert(d.phase==DISPLAY_DAMAGE_INVALIDATING && d.epoch && d.entry_word);
    calls++;
    if(action==1) {
        // A producer may publish the next request during this native call.
        __atomic_store_n(&command.request,7,__ATOMIC_RELEASE);
        unsigned before=calls;
        assert(display_damage_begin(&d,99,1)==0 && calls==before);
    }
    if(action==2)longjmp(interrupted,1);
}
static void reset(void) {
    memset(&d,0,sizeof(d));memset(&command,0,sizeof(command));
    command.magic=DISPLAY_DAMAGE_COMMAND_MAGIC;command.size=sizeof(command);command.version=1;
    d.magic=DISPLAY_DAMAGE_MAGIC;d.size=sizeof(d);d.version=1;
    d.region=region;d.invalidate=invalidate;d.command=&command;d.enabled=1;
    command.request=2;calls=action=0;
}
int main(void) {
    size_t page=(size_t)sysconf(_SC_PAGESIZE);
    region=mmap(0,page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(region!=MAP_FAILED);
    reset();
    assert(display_damage_begin(&d,1,1)==2 && calls==1 && !command.completed);
    assert(!display_damage_end(&d,2,2,0,1)); // another entry cannot ACK this one
    assert(!display_damage_end(&d,1,3,0,1)); // nor can a conflicting mode
    assert(d.phase==DISPLAY_DAMAGE_ACTIVE);
    assert(display_damage_end(&d,1,2,0,1) && command.completed==2);
    assert(display_damage_begin(&d,2,1)==2 && calls==1); // steady frame needs no new damage
    assert(display_damage_end(&d,2,2,0,1));

    command.request=5;action=1;
    assert(display_damage_begin(&d,3,1)==5 && command.request==7);
    assert(display_damage_end(&d,3,5,0,1) && command.completed==5);
    action=0;
    assert(display_damage_begin(&d,4,1)==7 && calls==3);
    assert(!display_damage_end(&d,4,7,0,0) && command.completed==5);
    assert(display_damage_begin(&d,5,1)==7 && calls==4); // no matching frame: retry damage
    assert(!display_damage_end(&d,5,7,-1,1) && command.completed==5);
    assert(display_damage_begin(&d,6,1)==7 && calls==5);
    assert(display_damage_end(&d,6,7,0,1) && command.completed==7);
    command.request=6;assert(!display_damage_begin(&d,7,1)); // same revision, opposite mode
    command.request=5;assert(!display_damage_begin(&d,7,1)); // old revision
    assert(calls==5 && command.completed==7);

    reset();d.enabled=0;assert(!display_damage_begin(&d,1,1) && !calls);
    d.enabled=1;assert(!display_damage_begin(&d,1,0) && !calls);
    assert(!display_damage_begin(&d,0,1) && !calls);
    assert(!display_damage_begin(&d,1,2) && !calls);
    command.request=1;assert(!display_damage_begin(&d,1,1) && !calls);
    command.request=2;command.version=2;assert(!display_damage_begin(&d,1,1) && !calls);
    command.version=1;d.pad=1;assert(!display_damage_begin(&d,1,1) && !calls);
    d.pad=0;d.invalidate=0;assert(!display_damage_begin(&d,1,1) && !calls);

    reset();action=2;
    if(!setjmp(interrupted)) {
        (void)display_damage_begin(&d,10,1);
        assert(!"interrupted helper returned");
    }
    assert(calls==1 && d.phase==DISPLAY_DAMAGE_INVALIDATING && !command.completed);
    assert(!mprotect(region,page,PROT_NONE));
    for(unsigned i=0;i<12;i++) {
        assert(!display_damage_begin(&d,11+i,1));
        assert(!display_damage_end(&d,10,2,0,1));
    }
    assert(calls==1 && d.phase==DISPLAY_DAMAGE_INVALIDATING && !command.completed);
    // Test-owned allocation only. Production exposes no quarantine reset/cleanup.
    assert(!munmap(region,page));
    puts("display_damage: PASS");
    return 0;
}
