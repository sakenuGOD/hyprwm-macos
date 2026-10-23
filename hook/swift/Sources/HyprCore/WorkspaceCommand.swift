import Foundation

extension WM {
    /// History follows observed ordinary desktops, never a requested switch.
    func observeWorkspaceHistory(_ current:Int) {
        if let old=workspaceHistoryCurrent,old != current {workspaceHistoryPrevious=old}
        workspaceHistoryCurrent=current
    }

    func workspaceCommand(_ args:[String],_ current:Int) -> String {
        func refused(_ reason:String) -> String {"workspace unavailable: "+reason}
        guard args.count==2 else{return refused("workspace <ordinal1..10|previous>; wsstep <-1|1>")}
        guard !sys.sessionLocked(),!sys.interactionOverlay(),!sys.mouseDown(),launcherTransfers.isEmpty,
              let catalog=sys.launcherCatalog(),catalog.active==current else{return refused("fresh stable ordinary native catalog required")}
        if let generation=workspaceHistoryGeneration,generation != catalog.generation {
            workspaceHistoryCurrent=nil;workspaceHistoryPrevious=nil
        }
        workspaceHistoryGeneration=catalog.generation
        observeWorkspaceHistory(current)
        if args[0]=="workspace",let submit=workspaceCommandSubmit,
           args[1]=="new" || (1...10).contains(where:{String($0)==args[1]}) {
            if args[1] != "new" {
                let rows=catalog.spaces.filter{$0.kind==0},ordinal=Int(args[1])!
                guard rows.indices.contains(ordinal-1) else{return refused("existing ordinary workspace required")}
                if rows[ordinal-1].sid==current{return "workspace\(ordinal) already active"}
            }
            guard submit(args[1],current) else{return refused("explicit workspace worker busy or source unavailable")}
            cancelFocusRecovery();consumeLauncher("explicit-workspace");activationIntent=nil
            return "workspace request queued: \(args[1]); acknowledgement pending"
        }
        let ordinary=Array(catalog.spaces.filter{$0.kind==0}.prefix(10))
        if let previous=workspaceHistoryPrevious,!ordinary.contains(where:{$0.sid==previous}) {workspaceHistoryPrevious=nil}
        let sid:Int
        if args[0]=="wsstep" {
            guard args[1]=="-1" || args[1]=="1" else{return refused("wsstep requires direction -1 or 1")}
            let ordinal=ordinary.firstIndex(where:{$0.sid==current}).map{$0+1} ?? 1
            let start=(1...5).contains(ordinal) ? ordinal:1
            let next=1+((start-1+(args[1]=="1" ? 1:-1)+5)%5)
            guard ordinary.indices.contains(next-1) else{return refused("workspace\(next) does not exist; native Space creation is unsupported")}
            sid=ordinary[next-1].sid
        } else if args[1]=="previous" {
            guard let previous=workspaceHistoryPrevious else{return refused("no previous existing ordinary workspace")}
            sid=previous
        } else {
            guard let ordinal=(1...10).first(where:{String($0)==args[1]}),ordinary.indices.contains(ordinal-1) else {
                return refused("existing ordinary workspace ordinal1..10 required")
            }
            let requested=ordinary[ordinal-1].sid
            let back=cfg.raw["config"]?["binds"]?["workspace_back_and_forth"]?.truthy ?? true
            sid=requested==current && back ? workspaceHistoryPrevious ?? requested:requested
        }
        if sid==current {return "workspace\((try? catalog.ordinal(sid)) ?? 0) already active"}
        guard let provider=workspaceFocus,provider(sid,true) else{return refused("native workspace focus backend is unverified/unavailable; no mutation performed")}
        guard let fresh=sys.launcherCatalog(),fresh.sameSession(catalog),fresh.active==current,
              (try? fresh.target(sid)) != nil,!sys.sessionLocked(),!sys.interactionOverlay(),!sys.mouseDown(),
              overviewFrozen?() != true else{return refused("native workspace target/current changed at focus commit; no mutation performed")}
        guard provider(sid,false) else{return refused("native workspace focus backend rejected target; history waits for real Space observation")}
        return "workspace focus requested: ordinal\((try? catalog.ordinal(sid)) ?? 0)/native\(sid); acknowledgement pending"
    }
}
