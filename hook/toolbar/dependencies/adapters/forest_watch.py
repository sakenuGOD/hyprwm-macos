"""Existing saved-forest rename notifications; no polling or WM commands."""
import os
from pathlib import Path
import select
import stat


class ForestWatch:
    def __init__(self, path):
        self.path = Path(path)
        if not self.path.is_absolute() or self.path != self.path.resolve():
            raise ValueError("canonical forest path required")
        self.fd = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        self.queue = None
        try:
            info = os.fstat(self.fd)
            if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022:
                raise ValueError("owned non-writable forest parent required")
            self.queue = select.kqueue()
            flags = select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE | select.KQ_NOTE_ATTRIB
            event = select.kevent(self.fd, filter=select.KQ_FILTER_VNODE,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                                 fflags=flags)
            self.queue.control([event], 0, 0)
        except BaseException:
            self.close()
            raise

    def fileno(self):
        return self.queue.fileno()

    def drain(self):
        """Called only after outer selector readiness; one coalesced refresh."""
        events = self.queue.control([], 16, 0)
        if any(event.flags & select.KQ_EV_ERROR for event in events):
            raise ValueError("forest notification source failed")
        if any(event.fflags & (select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE) for event in events):
            raise ValueError("forest parent generation changed")
        return bool(events)

    def close(self):
        if self.queue is not None:
            self.queue.close()
            self.queue = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
