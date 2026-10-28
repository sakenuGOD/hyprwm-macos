import Darwin
import Foundation
import HyprCore

/// Optional executable startup guard. Read-only; call BEFORE constructing WM.
enum EngineStatePreflight {
    static func check(_ path:String) throws {
        _ = try read(path)
    }

    static func read(_ path:String) throws -> JSON? {
        let parent=URL(fileURLWithPath:path).deletingLastPathComponent().path
        var dir=stat()
        if lstat(parent,&dir) != 0 {
            if errno==ENOENT{return nil};throw CmdError("Engine state directory unavailable")
        }
        guard dir.st_mode&S_IFMT==S_IFDIR,dir.st_uid==getuid(),dir.st_mode&0o022==0 else{throw CmdError("Engine state directory ownership is unsafe")}
        let fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        if fd<0 {if errno==ENOENT{return nil};throw CmdError("Engine state unavailable; preserved")}
        defer{close(fd)}
        var before=stat()
        guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_nlink==1,
              before.st_mode&0o022==0,before.st_size>0,before.st_size<=4*1024*1024 else{throw CmdError("Engine state must be a bounded owned regular file")}
        var bytes=[UInt8](repeating:0,count:Int(before.st_size)),used=0
        while used<bytes.count {
            let count=bytes.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress!.advanced(by:used),$0.count-used)}
            guard count>0 else{throw CmdError("Engine state changed during read; preserved")};used+=count
        }
        var after=stat()
        guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw CmdError("Engine state changed during read; preserved")}
        // Bound recursion before either parser sees attacker-controlled nesting.
        var depth=0,inString=false,escaped=false
        for byte in bytes {
            if inString {
                if escaped {escaped=false} else if byte==92 {escaped=true} else if byte==34 {inString=false}
            } else if byte==34 {inString=true}
            else if byte==123 || byte==91 {depth+=1;guard depth<=64 else{throw CmdError("Engine state nesting is excessive")}}
            else if byte==125 || byte==93 {depth-=1}
        }
        let value:JSON
        do {
            _ = try JSONSerialization.jsonObject(with:Data(bytes),options:[])
            value=try JSON.parse(bytes)
        }catch{throw CmdError("Engine state JSON is malformed; preserved")}
        func exactInt(_ value:JSON?) -> Int? {
            guard let value=value else{return nil}
            switch value {
            case let .int(number):return number
            case let .double(number):return Int(exactly:number)
            default:return nil
            }
        }
        func boundedNumbers(_ node:JSON,_ depth:Int=0)throws {
            guard depth<=64 else{throw CmdError("Engine state nesting is excessive")}
            switch node {
            case let .double(number):guard number.isFinite,abs(number)<=9_007_199_254_740_991 else{throw CmdError("Engine state number is unsafe")}
            case let .array(values):for child in values{try boundedNumbers(child,depth+1)}
            case let .object(values):for (_,child) in values{try boundedNumbers(child,depth+1)}
            default:break
            }
        }
        try boundedNumbers(value)
        guard value.object != nil,value["spaces"]?.object != nil,value["floating"]?.array != nil,
              let hidden=value["hidden"]?.array,hidden.count<=1024 else{throw CmdError("Engine state document is invalid; preserved")}
        var seen=Set<Int>()
        for row in hidden {
            guard row.object != nil,let wid=exactInt(row["wid"]),wid>0,wid<=Int(UInt32.max),seen.insert(wid).inserted,
                  let pid=exactInt(row["pid"]),pid>1,pid<=Int(Int32.max),row["owner"]?.string != nil,
                  let rawRect=row["rect"]?.array,rawRect.count==4,
                  case let numbers=rawRect.compactMap(\.double),numbers.count==4,
                  numbers.allSatisfy(\.isFinite),numbers[2]>0,numbers[3]>0,numbers[2]<=32768,numbers[3]<=32768,
                  abs(numbers[0])<=1_048_576,abs(numbers[1])<=1_048_576 else{throw CmdError("Engine hidden ledger row is invalid; preserved")}
            if let birth=row["swift_birth"] {
                guard let text=birth.string,text.utf8.count<=128 else{throw CmdError("Engine hidden-window process identity is invalid; state preserved")}
                let parts=text.split(separator:":",omittingEmptySubsequences:false)
                guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.allSatisfy({$0.isASCII && $0.isNumber})}),
                      Int(parts[0])==pid,let seconds=Int(parts[1]),seconds>0,
                      let micros=Int(parts[2]),(0..<1_000_000).contains(micros) else{throw CmdError("Engine hidden-window process identity is invalid; state preserved")}
            }else{
                guard let generation=row["generation"]?.array,generation.count==4,
                      exactInt(generation[0])==pid,exactInt(generation[1])==Int(getuid()),
                      let seconds=exactInt(generation[2]),seconds>0,
                      let micros=exactInt(generation[3]),(0..<1_000_000).contains(micros) else{throw CmdError("Engine hidden ledger identity is missing; preserved")}
            }
        }
        return value
    }
}
