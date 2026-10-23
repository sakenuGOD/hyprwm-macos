"""Hypr ordinal/history/ring policy over fresh existing ordinary native Spaces.

Imports perform no native calls. Native creation and display switching require
separately verified backends; unsupported focus/follow fails before window move.
"""
from dataclasses import dataclass
import ctypes
import plistlib
import re
import time


class WorkspaceError(ValueError):
    pass


@dataclass(frozen=True)
class Target:
    ordinal: int
    sid: int
    display: str


@dataclass(frozen=True)
class Catalog:
    targets: tuple
    current: int

    @classmethod
    def from_managed(cls, displays, current):
        if not isinstance(displays, list) or len(displays)>16:
            raise WorkspaceError('bounded managed display snapshot required')
        targets=[];seen=set()
        for display in displays:
            if not isinstance(display, dict):
                raise WorkspaceError('invalid managed display')
            identifier=display.get('Display Identifier')
            spaces=display.get('Spaces')
            if not isinstance(identifier,str) or not identifier or len(identifier)>128 or not isinstance(spaces,list) or len(spaces)>64:
                raise WorkspaceError('bounded native display/Space metadata required')
            for space in spaces:
                if not isinstance(space,dict):
                    raise WorkspaceError('invalid native Space')
                kind=space.get('type')
                if isinstance(kind,bool) or not isinstance(kind,int):
                    raise WorkspaceError('native Space type must be an integer')
                if kind!=0:  # Fullscreen/system Spaces never become Hypr numeric desktops.
                    continue
                sid=space.get('id64',space.get('ManagedSpaceID'))
                if isinstance(sid,bool) or not isinstance(sid,int) or not 0<sid<2**53 or sid in seen:
                    raise WorkspaceError('unique exactly representable native Space ID required')
                seen.add(sid);targets.append(Target(len(targets)+1,sid,identifier))
        if isinstance(current,bool) or not isinstance(current,int) or current<=0:
            raise WorkspaceError('fresh native current Space required')
        return cls(tuple(targets),current)

    def by_sid(self,sid):
        return next((target for target in self.targets if target.sid==sid),None)

    def ordinal(self,value):
        if not isinstance(value,str) or not re.fullmatch(r'(?:[1-9]|10)',value):
            raise WorkspaceError('workspace selector must be ordinal1..10 or previous')
        ordinal=int(value)
        target=next((target for target in self.targets if target.ordinal==ordinal),None)
        if target is None:
            raise WorkspaceError(f'workspace{ordinal} does not exist; native Space creation is unsupported (existing ordinary Spaces: {len(self.targets)})')
        return target


class History:
    def __init__(self):
        self.current=None
        self.previous=None

    def observe(self,catalog):
        if catalog.by_sid(catalog.current) is None:
            return  # A native fullscreen transition cannot replace ordinary desktop history.
        if self.current is not None and self.current!=catalog.current:
            self.previous=self.current
        self.current=catalog.current
        if self.previous is not None and catalog.by_sid(self.previous) is None:
            self.previous=None

    def resolve(self,selector,catalog,back_and_forth=True):
        self.observe(catalog)
        if selector=='previous':
            target=catalog.by_sid(self.previous)
            if target is None:
                raise WorkspaceError('no previous existing ordinary workspace')
            return target
        target=catalog.ordinal(selector)
        if back_and_forth and target.sid==catalog.current and self.previous is not None:
            return catalog.by_sid(self.previous)
        return target

    def step(self,direction,catalog,lo=1,hi=5):
        if isinstance(direction,bool) or direction not in (-1,1) or not 1<=lo<=hi<=10:
            raise WorkspaceError('workspace ring requires direction±1 and ordinal bounds1..10')
        self.observe(catalog)
        current=catalog.by_sid(catalog.current)
        ordinal=current.ordinal if current and lo<=current.ordinal<=hi else lo
        next_ordinal=lo+(ordinal-lo+direction)%(hi-lo+1)
        return catalog.ordinal(str(next_ordinal))


def native_catalog():
    """Read-only CF property-list copy; no show/hide/create/set-current calls."""
    sl=ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
    cf=ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    sl.SLSMainConnectionID.restype=ctypes.c_int
    sl.SLSGetActiveSpace.argtypes=[ctypes.c_int];sl.SLSGetActiveSpace.restype=ctypes.c_uint64
    sl.SLSCopyManagedDisplaySpaces.argtypes=[ctypes.c_int];sl.SLSCopyManagedDisplaySpaces.restype=ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_long,ctypes.c_long,ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype=ctypes.c_void_p
    cf.CFDataGetLength.argtypes=[ctypes.c_void_p];cf.CFDataGetLength.restype=ctypes.c_long
    cf.CFDataGetBytePtr.argtypes=[ctypes.c_void_p];cf.CFDataGetBytePtr.restype=ctypes.c_void_p
    cf.CFRelease.argtypes=[ctypes.c_void_p]
    cid=sl.SLSMainConnectionID();spaces=sl.SLSCopyManagedDisplaySpaces(cid);data=None
    if not spaces:
        raise WorkspaceError('native managed Space snapshot unavailable')
    try:
        data=cf.CFPropertyListCreateData(None,spaces,100,0,None)
        if not data:
            raise WorkspaceError('native Space snapshot is not a property list')
        length=cf.CFDataGetLength(data)
        if not 0<length<=262144:
            raise WorkspaceError('native Space snapshot exceeds bounded metadata limit')
        payload=ctypes.string_at(cf.CFDataGetBytePtr(data),length)
        return Catalog.from_managed(plistlib.loads(payload),int(sl.SLSGetActiveSpace(cid)))
    finally:
        if data:cf.CFRelease(data)
        cf.CFRelease(spaces)


def command(wm,argv,area,space,wins,bind_settings=None):
    """Main-thread consumer. Native focus is gated by an explicit verified provider."""
    try:
        locked=getattr(wm,'mutation_locked',None)
        if callable(locked) and locked():
            raise WorkspaceError('session locked; no workspace mutation performed')
        if argv[0] not in ('workspace','wsstep','moveworkspace'):
            raise WorkspaceError('unsupported workspace command')
        provider=getattr(wm,'_workspace_catalog_provider',native_catalog)
        catalog=provider()
        if catalog.current!=int(space):
            raise WorkspaceError('native Space changed before workspace command; retry after a fresh stable snapshot')
        history=wm.__dict__.setdefault('_workspace_history',History())
        if argv[0]=='wsstep':
            if len(argv)!=2 or argv[1] not in ('-1','1'):
                raise WorkspaceError('wsstep requires direction -1 or1')
            target=history.step(int(argv[1]),catalog)
        else:
            if len(argv) not in (2,3) or (argv[0]=='workspace' and len(argv)!=2):
                raise WorkspaceError('invalid workspace arguments')
            config=bind_settings or {}
            back=config.get('workspace_back_and_forth',True)
            target=history.resolve(argv[1],catalog,back_and_forth=back if argv[0]=='workspace' else False)
        follow=argv[0]!='moveworkspace' or len(argv)==2 or argv[2]=='follow'
        if argv[0]=='moveworkspace' and len(argv)==3 and argv[2] not in ('follow','silent'):
            raise WorkspaceError('moveworkspace action must be follow or silent')
        if target.sid==catalog.current:
            return f'workspace{target.ordinal} already active'
        switch=getattr(wm,'_workspace_focus_provider',None)
        if follow and not callable(switch):
            raise WorkspaceError('native workspace focus backend is unverified/unavailable; follow/move not performed')
        if argv[0]=='moveworkspace':
            window=wm.command_window(wins,space,wm.layout(area,wm.sp(space)))
            if window is None:
                raise WorkspaceError('no eligible native key window to move')
            identity={'wid':window['wid'],'pid':window['pid']}
            if wm.window_record_live(identity,wins) is not True:
                raise WorkspaceError('move window native birth/owner is not confirmed')
            if follow and not switch(target,preflight=True):
                raise WorkspaceError('verified native workspace focus preflight refused; move not performed')
            pending=wm.__dict__.setdefault('_workspace_moves',{})
            if window['wid'] not in pending and len(pending)>=64:
                raise WorkspaceError('bounded pending native workspace move limit reached')
            fresh=provider()
            if fresh.current!=catalog.current or fresh.by_sid(target.sid)!=target:
                raise WorkspaceError('native workspace target/current changed at commit; move not performed')
            if callable(locked) and locked():
                raise WorkspaceError('session locked at commit; move not performed')
            wm.cancel_configure(window['wid'])
            wm.eng.c.space(window['wid'],target.sid);wm.eng.c.commit()
            pending[window['wid']]=dict(identity=identity,target=target.sid,deadline=time.monotonic()+2,follow=follow)
            if follow and not switch(target,preflight=False):
                return f'workspace move queued for WID{window["wid"]}; follow failed, destination acknowledgement pending'
            return f'workspace move queued: WID{window["wid"]} -> ordinal{target.ordinal}/native{target.sid}; acknowledgement pending'
        if not switch(target,preflight=True):
            raise WorkspaceError('native workspace focus backend rejected target; history waits for real Space observation')
        fresh=provider()
        if fresh.current!=catalog.current or fresh.by_sid(target.sid)!=target:
            raise WorkspaceError('native workspace target/current changed at focus commit; no focus mutation performed')
        if callable(locked) and locked():
            raise WorkspaceError('session locked at focus commit; no focus mutation performed')
        if not switch(target,preflight=False):
            raise WorkspaceError('native workspace focus backend rejected target; history waits for real Space observation')
        return f'workspace focus requested: ordinal{target.ordinal}/native{target.sid}; acknowledgement pending'
    except (WorkspaceError,OSError,ValueError,TypeError,AttributeError) as error:
        return 'workspace unavailable: '+str(error)


def observe(wm,space,wins=None):
    history=getattr(wm,'_workspace_history',None)
    if history is None and not getattr(wm,'_workspace_moves',{}):return
    try:
        catalog=getattr(wm,'_workspace_catalog_provider',native_catalog)()
        if catalog.current!=int(space):return
        if history is not None:history.observe(catalog)
        if wins is None:return
        results=wm.__dict__.setdefault('_workspace_move_results',[])
        pending=getattr(wm,'_workspace_moves',{})
        live={w['wid']:w for w in wins}
        for wid,request in list(pending.items()):
            identity=request['identity'];verified=wm.window_record_live(identity,wins)
            window=live.get(wid)
            matched=(verified is True and window is not None and int(window.get('space',0))==request['target'] and
                     (not request['follow'] or catalog.current==request['target']))
            expired=time.monotonic()>=request['deadline']
            if not matched and verified is not False and not expired:continue
            pending.pop(wid,None)
            results.append(dict(wid=wid,target=request['target'],acknowledged=matched,
                reason='native destination confirmed' if matched else 'stale owner' if verified is False else 'native destination/follow acknowledgement timed out'))
            del results[:-32]
    except (WorkspaceError,OSError,ValueError,TypeError,AttributeError):
        pass  # Incomplete/fullscreen native snapshots never invent a desktop transition.
