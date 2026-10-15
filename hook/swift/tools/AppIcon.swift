// Render the same native tiling mark used by AppMark, without creating windows.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("AppIcon ICONSET_DIRECTORY") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let outputs = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (logical,scale) in outputs {
    let pixels = logical * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,
        samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
        let context = NSGraphicsContext(bitmapImageRep:bitmap) else { fatalError("icon bitmap") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let size = CGFloat(pixels), inset = size * 0.08, width = size - inset * 2
    let card = NSRect(x:inset,y:inset,width:width,height:width)
    let background = NSBezierPath(roundedRect:card,xRadius:width*0.24,yRadius:width*0.24)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = size * 0.025; shadow.shadowOffset = NSSize(width:0,height:-size*0.012)
    NSGraphicsContext.saveGraphicsState(); shadow.set();NSColor(red:0.2,green:0.33,blue:0.7,alpha:1).setFill();background.fill();NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:NSColor(red:0.2,green:0.33,blue:0.7,alpha:1),ending:NSColor(red:0.45,green:0.34,blue:0.82,alpha:1))!.draw(in:background,angle:-45)
    let padding = width * 0.21, gap = width * 0.06, height = width - padding * 2
    let column = (height - gap) / 2, radius = width * 0.06
    let origin = NSPoint(x:inset+padding,y:inset+padding)
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect:NSRect(x:origin.x,y:origin.y,width:column,height:height),xRadius:radius,yRadius:radius).fill()
    NSBezierPath(roundedRect:NSRect(x:origin.x+column+gap,y:origin.y+column+gap,width:column,height:column),xRadius:radius,yRadius:radius).fill()
    NSColor.white.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect:NSRect(x:origin.x+column+gap,y:origin.y,width:column,height:column),xRadius:radius,yRadius:radius).fill()
    context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    guard let png = bitmap.representation(using:.png,properties:[:]) else { fatalError("icon PNG") }
    try png.write(to:directory.appendingPathComponent("icon_\(logical)x\(logical)\(suffix).png"))
}
