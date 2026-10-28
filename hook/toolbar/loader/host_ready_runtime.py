"""Initialize LLDB/Python before stopping an exact authorized native-menu target.

No attach on import. The frozen runtime still owns authorization, rendering,
native symbols/selectors, retained handles, retry bounds, OFF and provenance.
Only its process-launch ordering is replaced here.
"""
import importlib.util
import json
import os
import stat
import subprocess
import time
from pathlib import Path

from event_menus import atomic, private_json, sha
from qualified_runtime import (HERE, LIFECYCLE, LIFECYCLE_SHA, QualifiedRuntime,
                               checked_file, native_identity, private_directory)

VERSION="host-ready-v1"
SOURCE=Path(__file__).resolve()


def checked_bytes(path,digest,private=False):
    """Read exact already authorized bytes; no key material enters LLDB."""
    path=Path(path)
    if path.is_symlink() or path.absolute()!=path.resolve(strict=True):raise ValueError("canonical trusted file required")
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&(0o077 if private else 0o022) or not 0<info.st_size<=1048576:
            raise ValueError("owned bounded trusted file required")
        data=os.read(fd,info.st_size+1)
        import hashlib
        if len(data)!=info.st_size or hashlib.sha256(data).hexdigest()!=digest:raise ValueError("authorized source/grant changed before attach")
        return data
    finally:os.close(fd)


def host_prepare(lldb,identity,script,script_digest,grant_path,grant_digest,output):
    """Host-only warmup. Returned attach callback repeats grant and birth checks."""
    started=time.time_ns()
    code=compile(checked_bytes(script,script_digest,private=True),str(script),"exec")
    if native_identity(identity["pid"])!=identity:raise ValueError("exact event birth changed during host initialization")
    checked_bytes(grant_path,grant_digest,private=True)
    timing={"version":VERSION,"host_started_wall_ns":started,"host_ready_wall_ns":time.time_ns(),"attach_attempted":False,"attached":False}

    def attach():
        try:
            # The parent verified the signed grant. Exact bytes must still be
            # unchanged after host warmup; never serialize its signing key.
            checked_bytes(grant_path,grant_digest,private=True)
            if native_identity(identity["pid"])!=identity:raise ValueError("exact event birth changed immediately before attach")
            timing["attach_requested_wall_ns"]=time.time_ns();timing["attach_attempted"]=True
            result=lldb.SBCommandReturnObject()
            lldb.debugger.GetCommandInterpreter().HandleCommand("process attach --pid "+str(identity["pid"]),result)
            timing["attach_returned_wall_ns"]=time.time_ns()
            if not result.Succeeded():raise RuntimeError("explicit exact-PID attach failed: "+str(result.GetError()))
            process=lldb.debugger.GetSelectedTarget().GetProcess()
            if not process.IsValid() or process.GetProcessID()!=identity["pid"]:raise RuntimeError("attached target PID mismatch")
            timing["attached"]=True
        except Exception as error:
            timing["refusal"]=str(error)

    def run():
        if not timing["attached"]:return
        try:exec(code,{})
        finally:timing["driver_finished_wall_ns"]=time.time_ns()

    def finish():
        # Invoked after the unchanged detach fallback. Disk I/O stays outside
        # the target's stopped interval.
        timing["finish_wall_ns"]=time.time_ns();atomic(output,timing)
    return attach,run,finish


def launch_argv(identity,script,grant_path,grant_digest,host_output,source_pins):
    files={str(HERE/name):digest for name,digest in source_pins.items()}
    files[str(SOURCE)]=sha(SOURCE);files[str(LIFECYCLE)]=LIFECYCLE_SHA
    # All host imports and driver compilation happen without a target. A
    # failed preparation leaves the guarded attach callback undefined.
    prepare="\n".join([
        "import hashlib,importlib.util,json,lldb,os,stat,sys,time",
        "_host_files="+repr(files),
        "for _path,_digest in _host_files.items():",
        " _p=__import__('pathlib').Path(_path);_s=_p.stat()",
        " if _p.is_symlink() or _p.absolute()!=_p.resolve(strict=True) or not stat.S_ISREG(_s.st_mode) or _s.st_uid!=os.getuid() or _s.st_mode&0o022 or not 0<_s.st_size<=1048576 or hashlib.sha256(_p.read_bytes()).hexdigest()!=_digest:raise RuntimeError('host source provenance refused')",
        "sys.path.insert(0,"+repr(str(HERE))+")",
        "_spec=importlib.util.spec_from_file_location('_hyprwm_host_ready',"+repr(str(SOURCE))+")",
        "_host_module=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_host_module)",
        "_host_attach,_host_run,_host_finish=_host_module.host_prepare(lldb,"+",".join(repr(v) for v in [identity,str(script),sha(script),str(grant_path),grant_digest,str(host_output)])+")",
    ])
    return ["/usr/bin/lldb","--batch","--no-lldbinit",
        "-o","settings set target.auto-import-clang-modules false",
        "-o","script exec("+repr(prepare)+")",
        "-o","script _host_attach()","-o","script _host_run()",
        "-o","script p=lldb.debugger.GetSelectedTarget().GetProcess(); p.Detach(False) if p.IsValid() and p.GetState() not in (lldb.eStateDetached,lldb.eStateExited,lldb.eStateInvalid) else None",
        "-o","script _host_finish()","-o","quit"]


class HostReadyRuntime(QualifiedRuntime):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        self.launcher_source_pins={SOURCE.name:sha(SOURCE)}
        self.require_launcher(self._grant)

    def require_launcher(self,grant):
        if grant.get("launcher")!=VERSION or grant.get("launcher_source_pins")!=self.launcher_source_pins:
            raise ValueError("explicit reviewed host-ready launcher source pins required")
        checked_file(SOURCE,self.launcher_source_pins[SOURCE.name])

    def authorize(self,*args,**kwargs):
        grant=super().authorize(*args,**kwargs);self.require_launcher(grant);return grant

    def invoke(self,i,d,profiles,flags,handle,action,folder):
        grant_digest=sha(self.grant_path)
        request={"epoch":self._grant["epoch"],"nonce":self._grant["nonce"],"allow_activation":False,"allow_input":False,"allow_restart":False}
        self.authorize(i,d,request,off=action==2)
        if sha(self.grant_path)!=grant_digest:raise ValueError("signed grant changed across authorization")
        folder=private_directory(folder);script=folder/"lldb-driver.py";output=folder/"native.json";host_output=folder/"host.json"
        if any(p.exists() for p in (script,output,host_output)):raise ValueError("new native operation directory required")
        script.write_text(self.render(i,d,profiles,flags,handle,action,output));script.chmod(0o600)
        argv=launch_argv(i,script,self.grant_path,grant_digest,host_output,self.source_pins)
        started=time.time_ns()
        try:
            result=subprocess.run(argv,capture_output=True,text=True,timeout=25,umask=0o077)
            (folder/"lldb.log").write_text(result.stdout+result.stderr)
        except subprocess.TimeoutExpired as error:
            (folder/"lldb.log").write_text(str(error.stdout or "")+str(error.stderr or "")+"\nTIMEOUT; detach unconfirmed; no retry\n")
            raise RuntimeError("bounded debugger timeout; generation quarantined") from error
        if not output.exists():raise RuntimeError("no native detach receipt; generation quarantined")
        value=private_json(output);timing=private_json(host_output)
        value["launcher"]={"version":VERSION,"source_pins":self.launcher_source_pins,"started_wall_ns":started,"ended_wall_ns":time.time_ns(),"host":timing}
        requested=timing.get("attach_requested_wall_ns");detached=value.get("end_wall_ns")
        if type(requested)==int and type(detached)==int:
            value["launcher"]["attach_requested_to_detach_upper_bound_ms"]=(detached-requested)/1e6
        value["identity_after_detach"]=self.identity(i["pid"])==i
        state=subprocess.run(["/bin/ps","-p",str(i["pid"]),"-o","state="],capture_output=True,text=True,timeout=3)
        value["not_stopped_after_detach"]=state.returncode==0 and bool(state.stdout.strip()) and state.stdout.strip()[0] not in "TZ"
        value["identity_after_state_query"]=self.identity(i["pid"])==i
        if any(value.get(k) is not True for k in ("detached","identity_after_detach","identity_after_state_query","not_stopped_after_detach","actual_main_thread","buffer_freed","handle_retained")):
            value["ok"]=False;value["reason"]="unqualified-native-postflight"
        if timing.get("attached") is not True or not all(type(timing.get(k))==int for k in ("host_ready_wall_ns","attach_requested_wall_ns","attach_returned_wall_ns")) or not (timing["host_ready_wall_ns"]<=timing["attach_requested_wall_ns"]<=timing["attach_returned_wall_ns"]<=value.get("start_wall_ns",0)<=value.get("end_wall_ns",0)):
            value["ok"]=False;value["reason"]="unqualified-host-ready-timing"
        value["postflight"]=str(folder/"postflight.json");atomic(folder/"postflight.json",value)
        return value
