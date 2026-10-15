import Foundation

/// Complete native occupancy: ordered-out/hidden application windows still count.
public enum OrdinaryWorkspaceWitness {
    public static func validate(_ raw:JSON,space:Int) -> Bool {
        guard let count=OverviewBinding.integer(raw["ordinary_window_count"]),count>=0,
              let d=raw["ordinary_descriptor"],d["schema"] == .int(1),d["scope"] == .string("native-layer0-application-windows"),
              d["complete"] == .bool(true),d["titles_read"] == .bool(false),d["owner_labels_used"] == .bool(false),
              OverviewBinding.integer(d["space"])==space,let ordinary=d["ordinary"]?.array,ordinary.count==count,
              let excluded=d["excluded"]?.array,OverviewBinding.integer(d["all_window_count"])==ordinary.count+excluded.count else{return false}
        var seen=Set<Int>()
        for (rows,isOrdinary) in [(ordinary,true),(excluded,false)] {
            for row in rows {
                guard let wid=OverviewBinding.integer(row["wid"]),wid>0,wid<Int(UInt32.max),seen.insert(wid).inserted,
                      let pid=OverviewBinding.integer(row["pid"]),pid>0,let birth=row["birth"]?.array,birth.count==4,
                      OverviewBinding.integer(birth[0])==pid,let uid=OverviewBinding.integer(birth[1]),uid>=0,
                      let sec=OverviewBinding.integer(birth[2]),sec>0,let us=OverviewBinding.integer(birth[3]),(0..<1_000_000).contains(us),
                      let path=row["executable"]?.string,path.hasPrefix("/"),!path.contains("\0"),
                      let layer=OverviewBinding.integer(row["layer"]),OverviewBinding.integer(row["space"])==space else{return false}
                if isOrdinary {guard layer==0,row["reason"]==nil else{return false}}
                else {
                    switch row["reason"]?.string {
                    case "nonzero-native-layer":guard layer != 0 else{return false}
                    case "immutable-platform-shell":guard SystemUI.protected(executable:path,bundle:row["bundle_id"]?.string) else{return false}
                    case "verified-own-menu-ui":guard row["bundle_id"] == .string("dev.hyprwm.HyprWM"),row["role"] == .string("menu-only"),path.hasSuffix("/dist/HyprWM.app/Contents/MacOS/hyprwm-swift") else{return false}
                    default:return false
                    }
                }
            }
        }
        return true
    }
}
