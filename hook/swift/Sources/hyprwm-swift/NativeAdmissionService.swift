import CAX
import CryptoKit
import Darwin
import Foundation
import HyprCore

/// Existing AppKit first-order client transport; neither the socket queue nor
/// its identity checks message application main threads or query AX.
final class NativeAdmissionService {
    let gateway=FirstMapAdmission()
    let path:String
    private let sys:LiveSys,listener:Int32,queue=DispatchQueue(label:"hyprwm.first-map",qos:.userInteractive)
    private let stopLock=NSLock()
    private var stopped=false
    private let socketDevice:dev_t,socketInode:ino_t
    private struct Peer {let fd:Int32,pid:Int,birth:String,owner:String,expires:Double;var input=Data(),output=Data(),sent=0}
    private var owners:[Int:(birth:String,owner:String)]=[:]
    init(sys:LiveSys,path:String="/tmp/hyprwm-admission-\(getuid())/service.sock") throws {
        self.sys=sys;self.path=path
        let parent=URL(fileURLWithPath:path).deletingLastPathComponent().path
        if mkdir(parent,0o700) != 0 && errno != EEXIST {throw CmdError("cannot create admission directory")}
        var directory=stat()
        guard lstat(parent,&directory)==0,directory.st_mode&S_IFMT==S_IFDIR,directory.st_uid==getuid(),directory.st_mode&0o077==0 else{throw CmdError("admission directory must be private and owned")}
        var existing=stat()
        if lstat(path,&existing)==0 {
            guard existing.st_mode&S_IFMT==S_IFSOCK,existing.st_uid==getuid(),!CommandServer.isAlive(path),unlink(path)==0 else{throw CmdError("admission path already occupied")}
        }
        let fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else{throw CmdError("admission socket failed")}
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(path.utf8)
        guard bytes.count<MemoryLayout.size(ofValue:address.sun_path) else{Darwin.close(fd);throw CmdError("admission path too long")}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes);$0[bytes.count]=0}
        address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard bound==0,chmod(path,0o600)==0,listen(fd,16)==0 else{Darwin.close(fd);throw CmdError("admission bind/listen failed")}
        _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);_=fcntl(fd,F_SETFD,FD_CLOEXEC)
        var info=stat();guard lstat(path,&info)==0 else{Darwin.close(fd);throw CmdError("admission socket identity unavailable")}
        listener=fd;socketDevice=info.st_dev;socketInode=info.st_ino
        gateway.makePresentationName={key,service in
            let values:[JSON]=[.string(service),.int(key.pid),.string(key.launch),.int(key.generation),.int(key.object),.int(key.wid),.int(key.attempt)]
            let canonical="["+values.map{$0.dumps(ensureASCII:true)}.joined(separator:",")+"]"
            let digest=SHA256.hash(data:Data(canonical.utf8)).prefix(16).map{String(format:"%02x",$0)}.joined()
            return "hyprwm.admit.\(key.pid).\(key.wid).\(digest)"
        }
        gateway.signalClaim={name in hs_notify_publish_state(name,1)==0}
        queue.async { [self] in run() }
    }
    func close() {
        gateway.suspend();stopLock.lock();stopped=true;stopLock.unlock()
        var info=stat()
        if lstat(path,&info)==0,info.st_dev==socketDevice,info.st_ino==socketInode {unlink(path)}
    }
    private var shouldStop:Bool {stopLock.lock();defer{stopLock.unlock()};return stopped}
    private func identity(_ pid:Int)->(birth:String,path:String)? {
        // Kernel path/birth only. NSRunningApplication/LaunchServices can wait
        // on the very application main thread currently awaiting this reply.
        guard let row=try? VerifiedPublicWorkspace.identity(pid).array,row.count==5,row[0].int==pid,row[1].int==Int(getuid()),
              let sec=row[2].int,sec>0,let usec=row[3].int,(0..<1000000).contains(usec),let path=row[4].string else{return nil}
        return("\(pid):\(sec):\(usec)",path)
    }
    private func owner(_ pid:Int,_ identity:(birth:String,path:String))->String? {
        if let cached=owners[pid],cached.birth==identity.birth{return cached.owner}
        owners[pid]=nil
        guard let suffix=identity.path.range(of:".app/Contents/MacOS/",options:.backwards) else{return nil}
        let bundle=String(identity.path[..<suffix.lowerBound])+".app"
        let url=URL(fileURLWithPath:bundle+"/Contents/Info.plist")
        var before=stat(),after=stat()
        guard lstat(url.path,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_size>0,before.st_size<=65536,
              let data=try? Data(contentsOf:url),data.count<=65536,lstat(url.path,&after)==0,
              before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              let values=(try? PropertyListSerialization.propertyList(from:data,options:[],format:nil)) as? [String:Any],
              let executable=values["CFBundleExecutable"] as? String,!executable.contains("/"),bundle+"/Contents/MacOS/"+executable==identity.path,
              !SystemUI.protected(executable:identity.path,bundle:values["CFBundleIdentifier"] as? String),pid != getpid() else{return nil}
        let name=(values["CFBundleDisplayName"] as? String) ?? (values["CFBundleName"] as? String) ?? URL(fileURLWithPath:bundle).deletingPathExtension().lastPathComponent
        guard !name.isEmpty,name.count<=512 else{return nil}
        if owners.count>=128 {owners.removeAll(keepingCapacity:true)}
        owners[pid]=(identity.birth,name);return name
    }
    private func run() {
        var peers=[Int32:Peer]()
        defer{for fd in peers.keys{Darwin.close(fd)};Darwin.close(listener)}
        while !shouldStop {
            let now=sys.now()
            for (fd,peer) in peers where now>=peer.expires {Darwin.close(fd);peers[fd]=nil}
            let ids=Array(peers.keys)
            var polls=[pollfd(fd:listener,events:Int16(POLLIN),revents:0)]+ids.map {fd in pollfd(fd:fd,events:Int16(peers[fd]!.output.isEmpty ? POLLIN:POLLOUT),revents:0)}
            let timeout: Int32=peers.isEmpty ? 100:12
            if poll(&polls,nfds_t(polls.count),timeout)<0 {if errno==EINTR{continue};break}
            if polls[0].revents&Int16(POLLIN) != 0 {
                for _ in 0..<8 {
                    let fd=accept(listener,nil,nil);if fd<0{break}
                    guard peers.count<32 else{Darwin.close(fd);continue}
                    var uid:uid_t=0,gid:gid_t=0,pid:pid_t=0,length=socklen_t(MemoryLayout<pid_t>.size)
                    guard getpeereid(fd,&uid,&gid)==0,uid==getuid(),getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&length)==0,pid>0,
                          let first=identity(Int(pid)),let owner=owner(Int(pid),first),identity(Int(pid))?.birth==first.birth else{Darwin.close(fd);continue}
                    _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);_=fcntl(fd,F_SETFD,FD_CLOEXEC)
                    var one:Int32=1;_=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
                    peers[fd]=Peer(fd:fd,pid:Int(pid),birth:first.birth,owner:owner,expires:sys.now()+0.012)
                }
            }
            // New accepted sockets are checked once immediately; silent peers
            // never occupy the application-main budget of later ready clients.
            let ready=Set(ids.enumerated().compactMap{polls[$0.offset+1].revents != 0 ? $0.element:nil}).union(Set(peers.keys).subtracting(ids))
            for fd in ready.prefix(16) {
                guard var peer=peers[fd] else{continue};var finished=false
                if peer.output.isEmpty {
                    var bytes=[UInt8](repeating:0,count:4096)
                    let count=recv(fd,&bytes,bytes.count,0)
                    if count>0 {
                        peer.input.append(contentsOf:bytes.prefix(count))
                        if peer.input.count>8192 {finished=true}
                        else if let newline=peer.input.firstIndex(of:10) {
                            let data=peer.input[..<newline]
                            if let request=try? JSON.parse(Data(data)),let key=request["key"],case let .int(wid)?=key["wid"],wid>0,
                               identity(peer.pid)?.birth==peer.birth,sys.winPidLevel(wid).pid==peer.pid,sys.winPidLevel(wid).level==0,
                               !sys.sessionLocked(),sys.overviewGuard?() != true,!OverviewNativeMode.active(hs_overview10_mode()),gateway.expectedSpace.map({UInt64($0)==sys.activeSpace()})==true {
                                let reply=gateway.handle(request,now:sys.now(),pid:peer.pid,birth:peer.birth,owner:peer.owner)
                                if identity(peer.pid)?.birth==peer.birth,sys.now()<peer.expires {
                                    peer.output=Data((reply.dumps(ensureASCII:true)+"\n").utf8);finished=peer.output.count>8192
                                } else{finished=true}
                            } else{finished=true}
                        }
                    } else if count==0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {finished=true}
                }
                if !finished && !peer.output.isEmpty {
                    let sent=peer.output.withUnsafeBytes{send(fd,$0.baseAddress!.advanced(by:peer.sent),peer.output.count-peer.sent,0)}
                    if sent>0 {peer.sent+=sent;finished=peer.sent==peer.output.count}
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {finished=true}
                }
                if finished {Darwin.close(fd);peers[fd]=nil}else{peers[fd]=peer}
            }
        }
    }
}
