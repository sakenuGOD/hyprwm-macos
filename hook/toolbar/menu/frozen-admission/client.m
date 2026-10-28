#import "client.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <unistd.h>

enum { HAMaxBytes = 8192 };
static NSString *serverExecutable;
void HASetServerExecutable(NSString *executable) {serverExecutable=executable.isAbsolutePath && executable.length<PROC_PIDPATHINFO_MAXSIZE ? [executable copy]:nil;}
BOOL HAHasServerExecutable(void) {return serverExecutable!=nil;}
double HAClock(void) {
    // CPython time.monotonic() on Darwin uses mach_absolute_time. Darwin's
    // CLOCK_MONOTONIC includes a different sleep offset; do not mix epochs.
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (double)mach_absolute_time() * base.numer / base.denom * 1e-9;
}
static BOOL wait_fd(int fd, short events, double deadline) {
    for (;;) {
        double left = deadline - HAClock();
        if (!(left > 0 && left <= .101)) return NO;
        struct pollfd p = {.fd = fd, .events = events};
        int result = poll(&p, 1, (int)ceil(left * 1000));
        if (result < 0 && errno == EINTR) continue;
        return result > 0 && (p.revents & events) && HAClock() < deadline;
    }
}
NSDictionary *HAExchange(NSString *path, NSDictionary *request, double deadline) {
    if (!path || !serverExecutable || deadline <= HAClock() || deadline - HAClock() > .101) return nil;
    struct stat directory={0},socketInfo={0};
    if (lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation,&directory) ||
        !S_ISDIR(directory.st_mode) || directory.st_uid != getuid() || (directory.st_mode & 077) ||
        lstat(path.fileSystemRepresentation,&socketInfo) || !S_ISSOCK(socketInfo.st_mode) ||
        socketInfo.st_uid != getuid() || (socketInfo.st_mode & 077)) return nil;
    const char *name = path.fileSystemRepresentation;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(name) >= sizeof(address.sun_path)) return nil;
    strlcpy(address.sun_path, name, sizeof(address.sun_path));
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + strlen(name) + 1);
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (!data || data.length + 1 > HAMaxBytes) return nil;
    NSMutableData *wire = [data mutableCopy];
    [wire appendBytes:"\n" length:1];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    NSDictionary *reply = nil;
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) goto done;
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) goto done;
    if (connect(fd, (struct sockaddr *)&address, address.sun_len) != 0) {
        if (errno != EINPROGRESS || !wait_fd(fd, POLLOUT, deadline)) goto done;
        int error = 0; socklen_t length = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 || error) goto done;
    }
    {
        uid_t uid;gid_t gid;pid_t pid=0;socklen_t length=sizeof(pid);
        struct stat current={0};struct proc_bsdinfo before={0},after={0};char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
        if (getpeereid(fd,&uid,&gid) || uid != getuid() ||
            getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&length) || pid<=0 ||
            lstat(path.fileSystemRepresentation,&current) || current.st_dev!=socketInfo.st_dev || current.st_ino!=socketInfo.st_ino ||
            proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,sizeof(before))!=sizeof(before) || before.pbi_uid!=uid ||
            proc_pidpath(pid,executable,sizeof(executable))<=0 ||
            ![serverExecutable isEqual:@(executable)] ||
            proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof(after))!=sizeof(after) ||
            before.pbi_start_tvsec!=after.pbi_start_tvsec || before.pbi_start_tvusec!=after.pbi_start_tvusec) goto done;
    }
    for (size_t offset = 0; offset < wire.length;) {
        if (HAClock() >= deadline) goto done;
        ssize_t count = send(fd, (const char *)wire.bytes + offset, wire.length - offset, MSG_NOSIGNAL);
        if (count > 0) offset += count;
        else if (count < 0 && errno == EINTR) continue;
        else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_fd(fd, POLLOUT, deadline)) continue;
        else goto done;
    }
    {
        char bytes[HAMaxBytes]; size_t used = 0;
        while (used < sizeof(bytes)) {
            if (HAClock() >= deadline) goto done;
            ssize_t count = recv(fd, bytes + used, sizeof(bytes) - used, 0);
            if (count > 0) {
                used += count;
                if (memchr(bytes, '\n', used)) {
                    char *end = memchr(bytes, '\n', used);
                    NSData *json = [NSData dataWithBytes:bytes length:(size_t)(end - bytes)];
                    id result = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
                    if ([result isKindOfClass:NSDictionary.class] && HAClock() < deadline) reply = result;
                    goto done;
                }
            } else if (count < 0 && errno == EINTR) continue;
            else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_fd(fd, POLLIN, deadline)) continue;
            else goto done;
        }
    }
done:
    close(fd);
    return reply;
}
static BOOL number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && isfinite([value doubleValue]);
}
BOOL HAOfferUsable(NSDictionary *offer, NSDictionary *request, double now) {
    if (![offer isKindOfClass:NSDictionary.class] || ![offer[@"status"] isEqual:@"offer"] ||
        ![offer[@"schema"] isEqual:@1] || ![offer[@"transport"] isEqual:@"fixture-uds-v1"] ||
        ![offer[@"key"] isEqual:request[@"key"]] || !number(offer[@"revision"]) ||
        [offer[@"revision"] doubleValue] < 0 || !number(offer[@"deadline"]) ||
        fabs([offer[@"deadline"] doubleValue] - [request[@"deadline"] doubleValue]) > 1e-6 ||
        now >= [offer[@"deadline"] doubleValue] || !number(offer[@"expires"]) ||
        [offer[@"expires"] doubleValue] <= now || [offer[@"expires"] doubleValue] > now + 1) return NO;
    for (NSString *key in @[@"service", @"lease"]) {
        id text = offer[key];
        if (![text isKindOfClass:NSString.class] || [text length] == 0 || [text length] > 128) return NO;
    }
    NSArray *rect = offer[@"rect"];
    if (![rect isKindOfClass:NSArray.class] || rect.count != 4) return NO;
    for (id value in rect) if (!number(value) || fabs([value doubleValue]) > 65536) return NO;
    return [rect[2] doubleValue] >= 1 && [rect[3] doubleValue] >= 1;
}
