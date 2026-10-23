@testable import HyprCore
import XCTest

final class PublicOverviewEvidenceTests:XCTestCase {
    let display=Rect(0,0,1470,956)
    func surface(_ rect:Rect,layer:Int=20,on:Bool=true,alpha:Double=1)->WinInfo {
        var w=WinInfo(wid:8,pid:42,owner:"",x:rect.x,y:rect.y,w:rect.w,h:rect.h,on:on,space:0)
        w.layer=layer;w.alpha=alpha;return w
    }
    func testCapturedOpenCloseSequenceDoesNotLatchOnRetainedAXRoot() {
        let open=[surface(display),surface(Rect(20,520,649,86))]
        XCTAssertTrue(PublicOverviewEvidence.active(containerPresent:true,surfaces:open,displays:[display]))
        XCTAssertFalse(PublicOverviewEvidence.active(containerPresent:true,surfaces:[],displays:[display]))
    }
    func testOrdinaryDockAndOffscreenTransparentOrDesktopSurfacesCannotFreezeTiling() {
        for windows in [[surface(Rect(20,870,649,86))],[surface(display,on:false)],
                        [surface(display,alpha:0)],[surface(display,layer:-1)]] {
            XCTAssertFalse(PublicOverviewEvidence.active(containerPresent:true,surfaces:windows,displays:[display]))
        }
    }
}
