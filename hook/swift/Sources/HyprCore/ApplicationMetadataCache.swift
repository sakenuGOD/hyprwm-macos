import Foundation

/// LaunchServices application metadata is static for a verified process birth.
/// Window state, AX context, activation policy and input never enter this cache.
public struct ApplicationMetadata {
    public let executable:String
    public let bundlePath:String?
    public let bundleIdentifier:String?
    public init(executable:String,bundlePath:String?,bundleIdentifier:String?) {
        self.executable=executable;self.bundlePath=bundlePath;self.bundleIdentifier=bundleIdentifier
    }
}
public final class ApplicationMetadataCache {
    private struct Entry {let birth:String,value:ApplicationMetadata;var used:UInt64}
    private let lock=NSLock(),limit:Int
    private var entries:[Int:Entry]=[:],clock:UInt64=0
    public init(limit:Int=128){self.limit=max(1,limit)}
    public func read(pid:Int,birth:String) -> ApplicationMetadata? {
        lock.lock();defer{lock.unlock()}
        guard var entry=entries[pid],entry.birth==birth else {entries[pid]=nil;return nil}
        clock &+= 1;entry.used=clock;entries[pid]=entry;return entry.value
    }
    public func store(pid:Int,birth:String,value:ApplicationMetadata) {
        lock.lock();defer{lock.unlock()}
        if entries[pid]==nil,entries.count>=limit,let oldest=entries.min(by:{$0.value.used<$1.value.used})?.key {entries[oldest]=nil}
        clock &+= 1;entries[pid]=Entry(birth:birth,value:value,used:clock)
    }
    public func remove(_ pid:Int){lock.lock();entries[pid]=nil;lock.unlock()}
    public var count:Int {lock.lock();defer{lock.unlock()};return entries.count}
}
