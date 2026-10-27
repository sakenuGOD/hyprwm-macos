// Initialize one already-created, private descriptor for a new native engine.
// Never opens a path, creates a file or changes permissions.
#include "../src/chan.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc,char **argv) {
    if(argc!=2)return 2;
    char *end=0;errno=0;long value=strtol(argv[1],&end,10);
    if(errno || !end || *end || value<3 || value>INT_MAX)return 2;
    int fd=(int)value;struct stat info;
    size_t extent=(sizeof(struct ch)+0x3fff)&~(size_t)0x3fff;
    if(fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 ||
       (info.st_mode&077) || info.st_size!=(off_t)extent ||
       (info.st_uid!=getuid() && !(getuid()==0 && info.st_uid==88)))return 3;
    void *memory=mmap(0,extent,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(memory==MAP_FAILED)return 4;
    unsigned char *bytes=memory;
    for(size_t i=0;i<extent;i++)if(bytes[i]){munmap(memory,extent);return 5;}
    struct ch *channel=memory;
    channel->h.version=6;channel->h.size=sizeof(*channel);
    channel->h.idle_poll=0.008;channel->h.settle=1;channel->h.settle_px=3;
    channel->h.phase=0.1;channel->h.margin=0.002;
    __atomic_store_n(&channel->h.magic,CH_MAGIC,__ATOMIC_RELEASE);
    int result=msync(memory,extent,MS_SYNC);
    munmap(memory,extent);
    if(result)return 6;
    printf("{\"abi\":6,\"size\":%zu,\"extent\":%zu}\n",sizeof(struct ch),extent);
    return 0;
}
