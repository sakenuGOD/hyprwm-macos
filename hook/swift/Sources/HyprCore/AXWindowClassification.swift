import Foundation

/// The census reads cached AX eligibility; an unresponsive client cannot block the WM loop.
public final class AXWindowClassification {
    private struct Identity:Equatable {let pid:Int,birth:String}
    private struct Entry {let identity:Identity,value:Int,time:Double}
    private struct Pending {let identity:Identity,sequence:UInt64}
    private let lock=NSLock()
    private let tracing=ProcessInfo.processInfo.environment["HYPRWM_TIMELINE"] == "1"
    private let queue=DispatchQueue(label:"hyprwm.ax.classification",qos:.userInteractive,attributes:.concurrent)
    private let now:()->Double
    private let capacity:Int,maxPending:Int,ttl:Double
    private var entries:[Int:Entry]=[:],pending:[Int:Pending]=[:]
    private var sequence:UInt64=0,running=0

    public init(capacity:Int=256,maxPending:Int=16,ttl:Double=0.2,
                now:@escaping()->Double={ProcessInfo.processInfo.systemUptime}) {
        self.capacity=max(1,capacity);self.maxPending=max(1,maxPending);self.ttl=max(0,ttl);self.now=now
    }
    public func read(pid:Int,wid:Int,birth:String,load:@escaping()->Int) -> Int {
        let identity=Identity(pid:pid,birth:birth),time=now()
        lock.lock()
        if entries[wid]?.identity != identity {entries[wid]=nil}
        if let loading=pending[wid],loading.identity != identity {pending[wid]=nil}
        let cached=entries[wid]
        if let cached,time-cached.time<ttl {lock.unlock();return cached.value}
        guard pending[wid]==nil,running<maxPending else {lock.unlock();return cached?.value ?? -1}
        sequence &+= 1;let ticket=Pending(identity:identity,sequence:sequence)
        pending[wid]=ticket;running+=1;lock.unlock()
        if tracing {log("timeline classify queue",pid,wid,ticket.sequence,"t",time)}
        queue.async { [weak self] in
            guard let self else{return}
            let started=self.now()
            if self.tracing {log("timeline classify start",pid,wid,ticket.sequence,"t",started)}
            let value=load(),finished=self.now()
            if self.tracing {log("timeline classify done",pid,wid,ticket.sequence,"t",finished,"ms",(finished-started)*1000,"result",value)}
            self.lock.lock();defer{self.lock.unlock()}
            self.running-=1
            guard self.pending[wid]?.sequence==ticket.sequence else{return}
            self.pending[wid]=nil
            if self.entries[wid]==nil,self.entries.count>=self.capacity,
               let oldest=self.entries.min(by:{$0.value.time<$1.value.time})?.key {self.entries[oldest]=nil}
            self.entries[wid]=Entry(identity:identity,value:value,time:finished)
        }
        return cached?.value ?? -1
    }
    public func remove(_ wid:Int) {
        lock.lock();entries[wid]=nil;pending[wid]=nil;lock.unlock()
    }
}
