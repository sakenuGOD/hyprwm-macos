import Foundation

struct ViewportPan {
    let wid:Int,pid:Int,birth:String,space:Int,box:Rect
    var x:Double,y:Double,nonce:UInt64,lastSent:Double,deadline:Double
    var accepted=false
}
extension WM {
    /// Cached notification state only: no AX, native query or lease heartbeat.
    public func cachedViewportEventState() -> JSON {
        .array(viewportPans.keys.sorted().compactMap {wid in
            guard let value=viewportPans[wid] else{return nil}
            return .object([("wid",.int(wid)),("x",.double(value.x)),("y",.double(value.y)),("accepted",.bool(value.accepted))])
        })
    }
    private func viewportCandidate(_ wid:Int,_ space:Int,_ windows:[WinInfo]) -> (WinInfo,String,EngWin)? {
        guard space>0,sp(space).tree?.contains(wid)==true,
              !hidden.contains(where:{$0.wid==wid}),!closing.contains(wid),
              let window=windows.first(where:{$0.wid==wid && $0.space==space && $0.on && $0.layer==0 && $0.alpha>=0.05 && !$0.nativeFullscreen}),
              !floatingWindow(window),!sys.protectedProcess(window.pid),!ignored(window),let birth=sys.processBirth(window.pid),
              sys.winPidLevel(wid).pid==window.pid,
              let slot=eng.c.wins().first(where:{$0.wid==wid}),slot.geo != 0,slot.geo != 2,
              !slot.posActive,!slot.sizeActive,!slot.alphaActive,!slot.held,slot.curAlpha==1,
              cfgSink?.busy(wid) != true,dragSession?.wid != wid else{return nil}
        return (window,birth,slot)
    }
    func viewportStatus(_ space:Int,_ windows:[WinInfo]) -> JSON {
        let supported=eng.c.viewportSupported
        var result=JSON.object([("supported",.bool(supported))])
        guard supported,let wid=toolbarSelectedWindows(windows)[String(space)]?["wid"]?.int,
              let (window,birth,slot)=viewportCandidate(wid,space,windows) else{return result}
        let box=slot.visible,state=viewportPans[wid]
        result=result.setting("window",.object([("wid",.int(wid)),("pid",.int(window.pid)),("birth",.string(birth)),("space",.int(space)),
            ("x",.double(state?.x ?? 0)),("y",.double(state?.y ?? 0)),
            ("max_x",.double(max(0,slot.real.w-box.w))),("max_y",.double(max(0,slot.real.h-box.h))),
            ("pending",.bool(state.map{!$0.accepted} ?? false))]))
        return result
    }
    func viewportCommand(_ args:[String],_ space:Int,_ windows:[WinInfo],_ rects:OrderedMap<Int,Rect>) throws -> String {
        guard args.count==2 || args.count==6,["left","right","up","down","reset"].contains(args[1]) else {
            throw CmdError("pan: expected left/right/up/down/reset, optionally followed by window ID, PID, process identity and Space")
        }
        guard eng.c.viewportSupported else{return "Content panning is unavailable in the current engine"}
        let wid:Int
        if args.count==6 {
            wid=try CommandArguments.windowID(args[2])
            guard let pid=Int(args[3]),pid>0,pid<=Int(Int32.max),Int(args[5])==space,
                  windows.contains(where:{$0.wid==wid && $0.pid==pid}),sys.processBirth(pid)==args[4],
                  toolbarSelectedWindows(windows)[String(space)]?["wid"]?.int==wid else{return "pan refused: window selection changed"}
        } else {
            guard let native=nativeCommandWindow(space,windows,rects) else{return "pan refused: select a tiled window"}
            wid=native.wid
        }
        guard enabled,!sys.mouseDown(),!sys.interactionOverlay(),!sys.sessionLocked(),
              let (window,birth,slot)=viewportCandidate(wid,space,windows),primaryCommandWindow(window,space:space),
              let box=rects[wid],box.maxDiff(slot.visible)<=TOL else{return "pan refused: window is busy or no longer eligible"}
        let maxX=max(0,slot.real.w-box.w),maxY=max(0,slot.real.h-box.h)
        guard maxX>1 || maxY>1 || args[1]=="reset" else{return "All window content already fits"}
        let previous=viewportPans[wid].flatMap {prior in
            prior.pid==window.pid && prior.birth==birth && prior.space==space && prior.box.maxDiff(box)<=TOL ? prior:nil
        }
        var x=previous?.x ?? 0,y=previous?.y ?? 0
        switch args[1] {
        case "left":x-=64
        case "right":x+=64
        case "up":y-=64
        case "down":y+=64
        default:x=0;y=0
        }
        x=min(maxX,max(0,x));y=min(maxY,max(0,y))
        viewportNonce &+= 1;if viewportNonce==0{viewportNonce=1}
        let now=sys.now(),state=ViewportPan(wid:wid,pid:window.pid,birth:birth,space:space,box:box,
            x:x,y:y,nonce:viewportNonce,lastSent:now,deadline:now+1)
        guard eng.c.viewport(wid,nonce:state.nonce,offset:(x,y),box:box,enabled:true) else{return "pan refused: command queue unavailable"}
        viewportPans[wid]=state;eng.c.commit()
        return "content pan queued: \(wid) → \(Int(x)), \(Int(y))"
    }
    func observeViewport(_ event:EngEvent) {
        let value=event.rect
        guard value.arr.allSatisfy(\.isFinite),value.x>=0,value.x<=Double(UInt32.max),value.y>=0,value.y<=Double(UInt32.max),
              value.x.rounded()==value.x,value.y.rounded()==value.y,value.w>=0,value.h>=0,value.w<=65536,value.h<=65536,
              var state=viewportPans[event.wid],
              (UInt64(value.x)|(UInt64(value.y)<<32))==state.nonce,
              sys.processBirth(state.pid)==state.birth,sys.winPidLevel(event.wid).pid==state.pid else{return}
        if value.w==0 && value.h==0 {viewportPans[event.wid]=nil;return}
        state.x=value.w;state.y=value.h;state.accepted=true;viewportPans[event.wid]=state
    }
    func pollViewports(_ space:Int,_ windows:[WinInfo]) {
        guard !viewportPans.isEmpty else{return}
        var published=false
        for (wid,var state) in viewportPans {
            let current=viewportCandidate(wid,space,windows)
            let valid=eng.c.viewportSupported && state.space==space && current?.0.pid==state.pid && current?.1==state.birth &&
                current.map{state.box.maxDiff($0.2.visible)<=TOL}==true
            if !valid || (!state.accepted && sys.now()>=state.deadline) {
                if eng.c.viewportSupported,sys.processBirth(state.pid)==state.birth,sys.winPidLevel(wid).pid==state.pid {
                    published=eng.c.viewport(wid,nonce:state.nonce,offset:(0,0),box:state.box,enabled:false) || published
                }
                viewportPans[wid]=nil;continue
            }
            if sys.now()-state.lastSent>=0.4 {
                // Absolute offsets and the same nonce make retries idempotent.
                // The native lease resets the viewport if this writer stops.
                if eng.c.viewport(wid,nonce:state.nonce,offset:(state.x,state.y),box:state.box,enabled:true) {
                    state.lastSent=sys.now();viewportPans[wid]=state;published=true
                }
            }
        }
        if published {eng.c.commit()}
    }
}
