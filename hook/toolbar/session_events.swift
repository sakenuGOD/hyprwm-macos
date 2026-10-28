// Session metadata events and owned runtime-file events. No AX, input or GUI.
import AppKit
import CoreServices
import Foundation
import Darwin
import notify

let arguments=CommandLine.arguments
guard let index=arguments.firstIndex(of:"--runtime"),index+1<arguments.count else { exit(2) }
let runtime=URL(fileURLWithPath:arguments[index+1]).standardizedFileURL
let fixture=arguments.contains("--fixture-runtime-only")
var ownerProcess: DispatchSourceProcess?
func parentMatches(_ pid:pid_t,_ birth:[Int])->Bool {
    var value=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size)
    return pid==getppid() && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&value,size)==size &&
        birth==[Int(pid),Int(value.pbi_uid),Int(value.pbi_start_tvsec),Int(value.pbi_start_tvusec)] && value.pbi_uid==getuid()
}
if let ownerIndex=arguments.firstIndex(of:"--owner-pid") {
    guard ownerIndex+1<arguments.count,let pid=pid_t(arguments[ownerIndex+1]),pid>1,
          let birthIndex=arguments.firstIndex(of:"--owner-birth"),birthIndex+1<arguments.count else {exit(2)}
    let pieces=arguments[birthIndex+1].split(separator:":");let birth=pieces.compactMap{Int($0)}
    guard pieces.count==4,birth.count==4,parentMatches(pid,birth) else {exit(2)}
    let source=DispatchSource.makeProcessSource(identifier:pid,eventMask:.exit,queue:.main)
    source.setEventHandler{exit(0)};source.resume();ownerProcess=source
    guard parentMatches(pid,birth) else {exit(2)}
} else if arguments.contains("--owner-birth") {exit(2)}
func emit(_ value:[String:Any]) {
    guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else{return}
    FileHandle.standardOutput.write(data+Data([10]))
}
func app(_ value:NSRunningApplication)->[String:Any]? {
    let pid=value.processIdentifier
    var before=proc_bsdinfo(),after=proc_bsdinfo()
    let size=Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,size)==size,
          before.pbi_pid==pid,before.pbi_uid==getuid() else{return nil}
    var buffer=[CChar](repeating:0,count:4096)
    guard proc_pidpath(pid,&buffer,UInt32(buffer.count))>0 else{return nil}
    let executable=URL(fileURLWithPath:String(cString:buffer)).resolvingSymlinksInPath().path
    guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,size)==size,
          before.pbi_start_tvsec==after.pbi_start_tvsec,before.pbi_start_tvusec==after.pbi_start_tvusec,
          value.executableURL?.resolvingSymlinksInPath().path==executable else{return nil}
    return ["pid":Int(pid),"bundle_id":value.bundleIdentifier ?? "","executable":executable,"activation_policy":value.activationPolicy.rawValue,
     "birth":[Int(pid),Int(before.pbi_uid),Int(before.pbi_start_tvsec),Int(before.pbi_start_tvusec)],
     "bundle_path":value.bundleURL?.path ?? "","launch_time":value.launchDate?.timeIntervalSince1970 ?? 0]
}
func terminationEvent(_ snapshot:[String:Any]?,_ launchTime:Double?)->[String:Any] {
    // Directly executed AppKit tools may lack launchDate. Recheck owned kernel identities instead of guessing.
    guard let snapshot=snapshot,let recorded=snapshot["launch_time"] as? Double,
          let launchTime=launchTime,recorded==launchTime else{return ["event":"runtime_rescan"]}
    return ["event":"application_terminated","application":snapshot]
}
if arguments.contains("--fixture-unverified-termination") {
    let snapshots:[[String:Any]?] = [["pid":1,"launch_time":0.0],nil,["pid":1,"launch_time":42.0],["pid":1,"launch_time":42.0]]
    let dates:[Double?] = [nil,42,43,42]
    for (snapshot,date) in zip(snapshots,dates) {emit(terminationEvent(snapshot,date))}
    exit(0)
}
let applications=fixture ? [] : NSWorkspace.shared.runningApplications
var knownApplications:[pid_t:[String:Any]]=[:]
var admissionWatches:[pid_t:(birth:[Int],token:Int32)]=[:]
func observeAdmission(_ application:NSRunningApplication,_ snapshot:[String:Any]) {
    guard application.activationPolicy == .regular,application.bundleIdentifier != "com.apple.logic10",
          let birth=snapshot["birth"] as? [Int] else{return}
    let pid=application.processIdentifier
    if let previous=admissionWatches[pid] {
        if previous.birth==birth {return}
        notify_cancel(previous.token);admissionWatches.removeValue(forKey:pid)
    }
    var token:Int32=0
    let result=notify_register_dispatch("hyprwm.admission.v3.cap.\(pid)",&token,DispatchQueue.main){_ in
        guard let current=app(application),current["birth"] as? [Int]==birth else{return}
        emit(["event":"admission_changed","application":current])
    }
    if result==NOTIFY_STATUS_OK {admissionWatches[pid]=(birth,token)}
}
var observers:[NSObjectProtocol]=[]
if !fixture {
    let center=NSWorkspace.shared.notificationCenter
    for (name,kind) in [(NSWorkspace.didLaunchApplicationNotification,"application_launched"),(NSWorkspace.didTerminateApplicationNotification,"application_terminated"),(NSWorkspace.didActivateApplicationNotification,"application_activated")] {
        observers.append(center.addObserver(forName:name,object:nil,queue:.main){ note in
            guard let application=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else{return}
            let pid=application.processIdentifier
            if kind=="application_terminated" {
                let event=terminationEvent(knownApplications[pid],application.launchDate?.timeIntervalSince1970)
                emit(event)
                if event["event"] as? String==kind {
                    knownApplications.removeValue(forKey:pid)
                    if let watch=admissionWatches.removeValue(forKey:pid) {notify_cancel(watch.token)}
                }
            } else if let snapshot=app(application) {knownApplications[pid]=snapshot;observeAdmission(application,snapshot);emit(["event":kind,"application":snapshot])}
        })
    }
    for name in [NSWorkspace.didWakeNotification,NSWorkspace.activeSpaceDidChangeNotification] {
        observers.append(center.addObserver(forName:name,object:nil,queue:.main){note in
            emit(["event":"workspace","notification":note.name.rawValue,"front":NSWorkspace.shared.frontmostApplication.flatMap(app) ?? [:]])
        })
    }
}
var context=FSEventStreamContext(version:0,info:nil,retain:nil,release:nil,copyDescription:nil)
let callback:FSEventStreamCallback={ _,_,count,paths,flags,_ in
    let values=unsafeBitCast(paths,to:NSArray.self) as? [String] ?? []
    for (index,path) in values.prefix(count).enumerated() {
        if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs|kFSEventStreamEventFlagUserDropped|kFSEventStreamEventFlagKernelDropped|kFSEventStreamEventFlagRootChanged) != 0 {emit(["event":"runtime_rescan"]);continue}
        let url=URL(fileURLWithPath:path).standardizedFileURL
        if url==runtime.appendingPathComponent("state.json") {emit(["event":"state_changed"])}
        else if url==runtime.appendingPathComponent("settings.json") {emit(["event":"settings_changed"])}
        else if url==runtime.appendingPathComponent("native-companion/install-manifest.json") {emit(["event":"companion_install_changed"])}
        else if url==runtime.appendingPathComponent("native-toolbar-session/desired.json") || url==runtime.appendingPathComponent("native-toolbar-session/settings.json") {emit(["event":"toolbar_owner_changed"])}
        else if url==runtime.appendingPathComponent("native-menus/grant.json") || url==runtime.appendingPathComponent("native-menus/grant.key") {emit(["event":"menu_grant_changed"])}
        else if url==runtime.appendingPathComponent("palette.json") {emit(["event":"palette_changed"])}
        else if url.lastPathComponent=="journal.json",url.path.hasPrefix(runtime.appendingPathComponent("transactions").path+"/") {emit(["event":"transaction_changed","path":url.path])}
    }
}
guard let stream=FSEventStreamCreate(kCFAllocatorDefault,callback,&context,[runtime.path] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.1,FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes|kFSEventStreamCreateFlagFileEvents|kFSEventStreamCreateFlagNoDefer)) else {exit(3)}
FSEventStreamSetDispatchQueue(stream,DispatchQueue.main)
guard FSEventStreamStart(stream) else {exit(3)}
// Install observation before the initial snapshot: a transaction committing
// during startup must still produce its final journal event.
let initial=applications.prefix(512).compactMap(app)
for snapshot in initial {if let pid=snapshot["pid"] as? Int {knownApplications[pid_t(pid)]=snapshot}}
for application in applications.prefix(512) {if let snapshot=knownApplications[application.processIdentifier] {observeAdmission(application,snapshot)}}
emit(["event":"startup","applications":initial,"complete":applications.count<=512,"schema":1])
signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN)
let stop=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
stop.setEventHandler{FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream);exit(0)};stop.resume()
let interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:.main)
interrupt.setEventHandler{FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream);exit(0)};interrupt.resume()
RunLoop.main.run()
