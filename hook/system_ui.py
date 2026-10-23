"""Immutable macOS shell identities, never window titles or owner labels.

Only exact protected executable/CFBundleIdentifier pairs are excluded. Finder,
ordinary Apple apps and a user app named NotificationCenter remain ordinary.
Imports and construction perform no native calls or file reads.
"""
import ctypes
import os
from pathlib import Path
import plistlib


PLATFORM_SHELLS = {
    '/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter': 'com.apple.notificationcenterui',
    '/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter': 'com.apple.UserNotificationCenter',
    '/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter': 'com.apple.controlcenter',
    '/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer': 'com.apple.systemuiserver',
    '/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock': 'com.apple.dock',
    '/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight': 'com.apple.Spotlight',
}


def platform_shell(executable, bundle_id):
    return (isinstance(executable, str) and isinstance(bundle_id, str) and
            PLATFORM_SHELLS.get(executable) == bundle_id)


def bundle_identity(executable):
    if executable not in PLATFORM_SHELLS:
        return None  # Never read private/user application metadata for this guard.
    bundle = Path(executable).parents[2]
    info = bundle / 'Contents' / 'Info.plist'
    with info.open('rb') as stream:
        data = stream.read(65537)
    if not 0 < len(data) <= 65536:
        return None
    value = plistlib.loads(data)
    if not isinstance(value, dict) or value.get('CFBundleExecutable') != Path(executable).name:
        return None
    return value.get('CFBundleIdentifier')


class Resolver:
    def __init__(self, *, birth=None, executable=None, bundle=bundle_identity):
        self.birth, self.executable, self.bundle = birth, executable, bundle
        self.cache = {}
        self.lib = None

    def _load(self):
        if self.lib is not None:return
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]

    def _birth(self, pid):
        if self.birth is not None:return self.birth(pid)
        self._load()
        class BSDInfo(ctypes.Structure):
            _fields_=[('header',ctypes.c_uint32*12),('comm',ctypes.c_char*16),('name',ctypes.c_char*32),
                      ('tail',ctypes.c_uint32*6),('sec',ctypes.c_uint64),('usec',ctypes.c_uint64)]
        value=BSDInfo()
        if (self.lib.proc_pidinfo(pid,3,0,ctypes.byref(value),ctypes.sizeof(value)) != ctypes.sizeof(value) or
                value.header[3] != pid):return None
        return pid,value.header[5],value.sec,value.usec

    def _executable(self,pid):
        if self.executable is not None:return self.executable(pid)
        self._load();buffer=ctypes.create_string_buffer(4096)
        length=self.lib.proc_pidpath(pid,buffer,len(buffer))
        return os.fsdecode(buffer.value) if 0<length<len(buffer) else None

    def __call__(self,pid):
        if type(pid) is not int or pid<=0:return False
        try:
            birth=self._birth(pid)
            if (not isinstance(birth,(tuple,list)) or len(birth)!=4 or any(type(v) is not int for v in birth) or
                    birth[0]!=pid or birth[1]!=os.getuid() or birth[2]<=0 or not 0<=birth[3]<1000000):return False
            birth=tuple(birth)
            executable=self._executable(pid)  # exec can preserve PID birth; path is a fresh fence too.
            cached=self.cache.get(pid)
            if cached and cached[0]==birth and cached[1]==executable:
                return cached[2] if tuple(self._birth(pid) or ())==birth else False
            protected=executable in PLATFORM_SHELLS and platform_shell(executable,self.bundle(executable))
            if tuple(self._birth(pid) or ())!=birth:return False
            if len(self.cache)>=128 and pid not in self.cache:self.cache.pop(next(iter(self.cache)))
            self.cache[pid]=(birth,executable,bool(protected))
            return bool(protected)
        except (OSError,ValueError,TypeError,AttributeError,plistlib.InvalidFileException):
            return False
