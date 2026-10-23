"""Native ordinary-application occupancy, preserving the legacy ALL census.

No titles, owner display labels, AX calls, or geometry/window mutations.
Constructors are inert. A caller must supply a fresh stable native window census.
"""
import os
from pathlib import Path
import ctypes
import json

try:
    from . import system_ui, own_ui
except ImportError:
    import system_ui, own_ui

SCOPE='native-layer0-application-windows'


class NativeMetadata:
    """Cross-UID read-only birth/path; argv is read only for our exact menu app."""
    def __init__(self):self.reader=system_ui.Resolver();self.argv_reader=None;self.identity_library=None
    def _birth(self,pid):
        birth=self.reader._birth(pid)
        if birth:return birth
        # proc_pidinfo can deny a cross-UID WindowServer, while public sysctl
        # still supplies its exact birth. Use the same existing read-only C API
        # as the independent native session generation and the Swift manager.
        if self.identity_library is None:
            self.identity_library=ctypes.CDLL(str(Path(__file__).resolve().parent/'build/libmanaged_process_identity.dylib'))
            self.identity_library.managed_process_identity.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_uint64)]
            self.identity_library.managed_process_identity.restype=ctypes.c_int
        value=(ctypes.c_uint64*4)()
        if self.identity_library.managed_process_identity(pid,value)!=0 or value[0]!=pid or not value[2]:return None
        return tuple(value)
    def identity(self,pid,read_argv=True):
        if read_argv:
            if self.argv_reader is None:
                try:
                    from .lifecycle import DarwinProcesses
                except ImportError:
                    from lifecycle import DarwinProcesses
                self.argv_reader=DarwinProcesses()
            return self.argv_reader.identity(pid)
        birth=self._birth(pid);path=self.reader._executable(pid)
        if not birth or not path or self._birth(pid)!=birth or self.reader._executable(pid)!=path:return None
        return dict(pid=pid,birth=list(birth),executable=path,argv=None)


class Reader:
    def __init__(self, hook, processes=None, bundle=system_ui.bundle_identity):
        self.hook, self.processes, self.bundle=hook,processes,bundle

    def _processes(self):
        if self.processes is None:
            self.processes=NativeMetadata()
        return self.processes

    def actor(self,pid):
        processes=self._processes()
        first=processes.identity(pid,read_argv=False)
        if not isinstance(first,dict):return None,None
        birth=first.get('birth');path=first.get('executable')
        if (not isinstance(birth,(list,tuple)) or len(birth)!=4 or any(type(value)is not int for value in birth) or
                birth[0]!=pid or birth[1]<0 or birth[2]<=0 or not 0<=birth[3]<1000000 or
                not isinstance(path,str) or not path.startswith('/')):return None,None
        classification=None
        if path in system_ui.PLATFORM_SHELLS:
            bundle=self.bundle(path)
            if system_ui.platform_shell(path,bundle):classification=dict(reason='immutable-platform-shell',bundle_id=bundle)
        elif path==str(Path(self.hook).resolve().parent/'dist/HyprWM.app/Contents/MacOS/hyprwm-swift'):
            first=processes.identity(pid)
            if not first:return None,None
            if own_ui.menu_role(first,self.hook):classification=dict(reason='verified-own-menu-ui',bundle_id=own_ui.BUNDLE_ID,role='menu-only')
        final=processes.identity(pid,read_argv=False)
        if (not final or final.get('birth')!=first.get('birth') or final.get('executable')!=first.get('executable')):
            return None,None
        if classification and classification['reason']=='verified-own-menu-ui' and processes.identity(pid)!=first:
            return None,None
        return dict(pid=pid,birth=list(first['birth']),executable=first['executable']),classification

    def describe(self,windows,space):
        ordinary=[];excluded=[];actors={};complete=True;all_count=0;seen=set()
        for window in windows:
            if str(window.get('space'))!=str(space):continue
            all_count+=1
            wid,pid,layer=window.get('wid'),window.get('pid'),window.get('layer')
            if (type(wid)is not int or not 0<wid<2**32 or type(pid)is not int or pid<=0 or
                    type(layer)is not int or wid in seen):
                complete=False;continue
            seen.add(wid)
            if pid not in actors:
                try:actors[pid]=self.actor(pid)
                except (OSError,ValueError,TypeError,AttributeError):actors[pid]=(None,None)
            actor,classification=actors[pid]
            row=dict(wid=wid,pid=pid,space=space,layer=layer,on=bool(window.get('on')),alpha=window.get('alpha'),
                     birth=actor['birth'] if actor else None,executable=actor['executable'] if actor else None)
            if not actor:complete=False
            if layer!=0:
                row['reason']='nonzero-native-layer';excluded.append(row)
            elif classification:
                row.update(classification);excluded.append(row)
            else:ordinary.append(row)  # Hidden, ordered-out, uncertain and ordinary Apple apps remain occupied.
        descriptor=dict(schema=1,scope=SCOPE,space=space,complete=complete,all_window_count=all_count,
                        ordinary=ordinary,excluded=excluded,titles_read=False,owner_labels_used=False)
        return dict(ordinary_window_count=len(ordinary),ordinary_descriptor=descriptor)


def validate(value,*,space=None,require_empty=False):
    """Validate complete native evidence shape; positive classifications stay explicit."""
    if not isinstance(value,dict):return False
    count=value.get('ordinary_window_count');descriptor=value.get('ordinary_descriptor')
    if (type(count)is not int or count<0 or not isinstance(descriptor,dict) or descriptor.get('schema')!=1 or
            descriptor.get('scope')!=SCOPE or descriptor.get('complete')is not True or
            descriptor.get('titles_read')is not False or descriptor.get('owner_labels_used')is not False or
            space is not None and str(descriptor.get('space'))!=str(space)):return False
    ordinary,excluded=descriptor.get('ordinary'),descriptor.get('excluded')
    if not isinstance(ordinary,list) or not isinstance(excluded,list) or len(ordinary)!=count:return False
    if descriptor.get('all_window_count')!=len(ordinary)+len(excluded):return False
    seen=set()
    for row in ordinary+excluded:
        if not isinstance(row,dict) or row.get('wid') in seen or type(row.get('wid'))is not int:return False
        seen.add(row['wid']);birth=row.get('birth');path=row.get('executable')
        if (not isinstance(birth,(tuple,list)) or len(birth)!=4 or birth[0]!=row.get('pid') or
                any(type(v)is not int for v in birth) or birth[2]<=0 or not isinstance(path,str)):return False
        if str(row.get('space'))!=str(descriptor.get('space')):return False
        if row in ordinary and (row.get('layer')!=0 or row.get('reason')is not None):return False
        if row in excluded:
            reason=row.get('reason')
            if reason=='nonzero-native-layer':
                if type(row.get('layer'))is not int or row['layer']==0:return False
            elif reason=='immutable-platform-shell':
                if not system_ui.platform_shell(path,row.get('bundle_id')):return False
            elif reason=='verified-own-menu-ui':
                if row.get('bundle_id')!=own_ui.BUNDLE_ID or row.get('role')!='menu-only' or not path.endswith('/dist/HyprWM.app/Contents/MacOS/hyprwm-swift'):return False
            else:return False
    return not require_empty or count==0


def windows_snapshot(hook):
    """Read the same native census as the manager, with a private output buffer."""
    lib=ctypes.CDLL(str(Path(hook)/'build/libwinsnap.dylib'))
    lib.ws_snapshot.argtypes=[ctypes.c_void_p,ctypes.c_int];lib.ws_snapshot.restype=ctypes.c_int
    buffer=ctypes.create_string_buffer(1<<21)
    if lib.ws_snapshot(buffer,len(buffer))<0:raise ValueError('bounded native census unavailable')
    snapshot=json.loads(buffer.value)
    if snapshot.get('stable')not in(True,1) or snapshot.get('space_type')!=0:raise ValueError('stable ordinary native census required')
    return snapshot


def diagnostic(identity_library,hook):
    try:
        from .managed_space_switch import NativeDriver,_frozen
    except ImportError:
        from managed_space_switch import NativeDriver,_frozen
    native=NativeDriver(identity_library=str(identity_library));before=native.diagnostic_snapshot()
    snapshot=windows_snapshot(hook)
    # The owner name here only omits the WM's existing decoration census rows;
    # no application owner name determines a shell or own-UI classification.
    windows=[w for w in snapshot['windows'] if w.get('owner')!='hyprdeco']
    descriptor=Reader(hook).describe(windows,snapshot['space'])
    after=native.diagnostic_snapshot()
    result=dict(after,**descriptor,native_current_window_count=descriptor['ordinary_descriptor']['all_window_count'])
    if (_frozen(before['generation'])!=_frozen(after['generation']) or before['displays']!=after['displays'] or
            before['active_before']!=snapshot['space'] or after['active_after']!=snapshot['space'] or
            before['consistent']is not True or after['consistent']is not True):result['consistent']=False
    return result


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description='Read-only independent ordinary-application workspace witness')
    parser.add_argument('--diagnostic',action='store_true',required=True)
    parser.add_argument('--identity-library',required=True)
    args=parser.parse_args();print(json.dumps(diagnostic(args.identity_library,Path(__file__).resolve().parent)))
