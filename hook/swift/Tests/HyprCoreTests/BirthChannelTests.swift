import CChan
import Foundation
@testable import HyprCore
import XCTest

final class BirthChannelTests:XCTestCase {
    private func channel() throws -> LiveChannel {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let result=try LiveChannel(path:path,create:true)
        unlink(path)
        return result
    }
    func testBirthEventRejectsInvalidNativeWordsBeforeIntegerConversion() {
        func notice(_ x:Double,_ y:Double,_ pid:Double=42,_ state:Double=1,_ wid:Int=77) -> BirthNotice? {
            BirthNotice(EngEvent(type:Int(EV_BIRTH),wid:wid,t:1,rect:Rect(x,y,pid,state)))
        }
        let maximum=Double(UInt32.max)
        XCTAssertEqual(notice(maximum,maximum)?.token,UInt64.max)
        XCTAssertEqual(notice(1,0)?.phase,.held)
        for value in [Double.nan,Double.infinity,-1,0.5,maximum+1] {
            XCTAssertNil(notice(value,1));XCTAssertNil(notice(1,value))
        }
        XCTAssertNil(notice(0,0));XCTAssertNil(notice(1,0,0))
        XCTAssertNil(notice(1,0,Double(Int32.max)+1))
        XCTAssertNil(notice(1,0,42,0));XCTAssertNil(notice(1,0,42,9));XCTAssertNil(notice(1,0,42,1,-1))
        XCTAssertNil(notice(1,0,42,1,Int(UInt32.max)+1))
    }
    func testOldConsumerNeverReceivesBirthCommandsAndABIStaysCompatible() throws {
        let c=try channel()
        XCTAssertFalse(c.birthSupported)
        XCTAssertFalse(c.birth(.policy(epoch:1,enabled:true)))
        c.commit();XCTAssertEqual(c.raw.pointee.cmd_head,0)
        XCTAssertEqual(MemoryLayout<ch_cmd>.stride,0x88)
        XCTAssertEqual(MemoryLayout<ch_evt>.stride,0x30)
        XCTAssertEqual(MemoryLayout<ch_hdr>.stride,0xf8)
        XCTAssertEqual(ChannelCapabilities.abi(c.raw.pointee.version|UInt32(CH_CAP_BIRTH)),6)
        XCTAssertEqual(c.raw.pointee.version,6)
    }
    func testClaimPublishesGeometryAlphaAndFullTokenInOneCommand() throws {
        let c=try channel();c.raw.pointee.version|=UInt32(CH_CAP_BIRTH)
        let claim=BirthClaim(wid:77,token:0xfedcba9876543210,target:Rect(12,44,720,900),from:Rect(120,180,480,640),
                             positionCurve:1,sizeCurve:2,alphaCurve:3,positionDuration:0.2,sizeDuration:0.3,
                             alphaDuration:0.4,opacity:0.9)
        XCTAssertTrue(c.birth(.claim(claim)))
        XCTAssertEqual(c.raw.pointee.cmd_head,0)
        c.commit();XCTAssertEqual(c.raw.pointee.cmd_head,1)
        let command=(c.base+MemoryLayout<CChan.ch>.offset(of:\CChan.ch.cmd)!).assumingMemoryBound(to:ch_cmd.self).pointee
        XCTAssertEqual(command.op,UInt32(OP_BIRTH));XCTAssertEqual(command.wid,77)
        XCTAssertEqual(command.pad0,0x76543210);XCTAssertEqual(command.pad1,0xfedcba98)
        XCTAssertEqual(command.flags,UInt32(BIRTH_CLAIM)|UInt32(F_FROM)|UInt32(F_MOVE)|UInt32(F_STRETCH))
        XCTAssertEqual([command.x,command.y,command.w,command.h,command.fx,command.fy,command.fw,command.fh],[12,44,720,900,120,180,480,640])
        XCTAssertEqual([command.a,command.fa,command.dpos,command.dsize,command.dalpha],[0.9,0,0.2,0.3,0.4])
    }
    func testFullRingReturnsFailureWithoutOverwritingOrPublishingPartialClaim() throws {
        let c=try channel();c.raw.pointee.version|=UInt32(CH_CAP_BIRTH)
        for wid in 1...Int(CH_NCMD) {c.forget(wid)}
        c.commit()
        let commands=(c.base+MemoryLayout<CChan.ch>.offset(of:\CChan.ch.cmd)!).assumingMemoryBound(to:ch_cmd.self)
        let first=commands[0]
        XCTAssertFalse(c.birth(.prepare(wid:77,token:1,target:Rect(12,44,720,900))))
        c.commit();XCTAssertEqual(c.raw.pointee.cmd_head,UInt32(CH_NCMD))
        XCTAssertEqual(commands[0].op,first.op);XCTAssertEqual(commands[0].wid,first.wid)
        c.raw.pointee.cmd_tail=UInt32(CH_NCMD)
        XCTAssertTrue(c.birth(.prepare(wid:77,token:1,target:Rect(12,44,720,900))))
        c.commit();XCTAssertEqual(c.raw.pointee.cmd_head,UInt32(CH_NCMD)+1)
    }
    func testInvalidRequestDoesNotConsumeRingCapacity() throws {
        let c=try channel();c.raw.pointee.version|=UInt32(CH_CAP_BIRTH)
        XCTAssertFalse(c.birth(.prepare(wid:Int(UInt32.max)+1,token:1,target:Rect(0,0,720,900))))
        XCTAssertFalse(c.birth(.prepare(wid:77,token:0,target:Rect(0,0,720,900))))
        XCTAssertFalse(c.birth(.prepare(wid:77,token:1,target:Rect(.nan,0,720,900))))
        c.commit();XCTAssertEqual(c.raw.pointee.cmd_head,0)
        XCTAssertTrue(c.birth(.policy(epoch:UInt64.max,enabled:true)))
        c.commit();XCTAssertEqual(c.raw.pointee.cmd_head,1)
    }
}
