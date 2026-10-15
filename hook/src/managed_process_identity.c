/* Read-only public sysctl birth identity, including the WindowServer UID.
   No AppKit, constructors, process attachment, signals, or Space operations. */
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <stdint.h>
#include <errno.h>

int managed_process_identity(int pid, uint64_t output[4]) {
    if (pid <= 0 || !output) return EINVAL;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return errno ?: EIO;
    if (size != sizeof(info) || info.kp_proc.p_pid != pid || info.kp_proc.p_starttime.tv_sec <= 0)
        return ESRCH;
    output[0] = (uint64_t)info.kp_proc.p_pid;
    output[1] = (uint64_t)info.kp_eproc.e_ucred.cr_uid;
    output[2] = (uint64_t)info.kp_proc.p_starttime.tv_sec;
    output[3] = (uint64_t)info.kp_proc.p_starttime.tv_usec;
    return 0;
}
