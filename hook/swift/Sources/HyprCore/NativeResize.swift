import Foundation

public struct NativeResizeContext {
    public let pid: Int
    public let birth: String
    public let wid: Int
    public let epoch, sequence: UInt64
    public let phase: Int
    public let frame: Rect
    public let point: (Double,Double)
    public let acceptedFrame: Rect?
    public let acceptedTime: Double?
    public let sample: UInt64
    public init(pid: Int,birth: String,wid: Int,epoch: UInt64,sequence: UInt64,phase: Int,frame: Rect,point: (Double,Double),acceptedFrame: Rect? = nil,acceptedTime: Double? = nil,sample:UInt64 = 0) {
        self.pid=pid;self.birth=birth;self.wid=wid;self.epoch=epoch;self.sequence=sequence;self.phase=phase;self.frame=frame;self.point=point
        self.acceptedFrame=acceptedFrame;self.acceptedTime=acceptedTime;self.sample=sample
    }
}
