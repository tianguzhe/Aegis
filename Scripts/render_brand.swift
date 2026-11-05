import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let navy = NSColor(srgbRed: 0.043, green: 0.11, blue: 0.17, alpha: 1)
let gold = NSColor(srgbRed: 0.79, green: 0.63, blue: 0.37, alpha: 1)
func icon(_ size: Int, mac: Bool = false) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    if mac { context.translateBy(x: 52, y: 52); context.scaleBy(x: 0.9, y: 0.9) }
    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: mac ? 230 : 0, yRadius: mac ? 230 : 0)
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.29, alpha: 1), ending: navy)!.draw(in: background, angle: -45)
    let shield = NSBezierPath()
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 1024-y) }
    shield.move(to: point(512,226)); shield.line(to: point(774,328)); shield.line(to: point(746,557))
    shield.curve(to: point(512,798), controlPoint1: point(729,678), controlPoint2: point(609,752))
    shield.curve(to: point(278,557), controlPoint1: point(415,752), controlPoint2: point(295,678))
    shield.line(to: point(250,328)); shield.close()
    shield.lineWidth = 38; shield.lineJoinStyle = .round
    gold.setStroke(); shield.stroke()
    gold.setFill()
    NSBezierPath(ovalIn: NSRect(x:453,y:1024-525,width:118,height:118)).fill()
    let hole = NSBezierPath()
    hole.move(to: point(480,501)); hole.line(to: point(544,501)); hole.line(to: point(566,622)); hole.line(to: point(458,622)); hole.close(); hole.fill()
    NSGraphicsContext.restoreGraphicsState()
    return image
}
func write(_ bitmap: NSBitmapImageRep, _ path: String) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(path))
}
let assetDir = "App/Assets.xcassets/AppIcon.appiconset"
try write(icon(1024), "\(assetDir)/AppIcon-iOS.png")
try write(icon(1024, mac: true), "Brand/Aegis-Icon.png")
var images: [[String: Any]] = [["filename":"AppIcon-iOS.png","idiom":"universal","platform":"ios","size":"1024x1024"]]
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let name = "mac-\(size)@\(scale)x.png"
        try write(icon(size*scale, mac: true), "\(assetDir)/\(name)")
        images.append(["filename":name,"idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x"])
    }
}
try JSONSerialization.data(withJSONObject:["images": images, "info":["author":"xcode","version":1]], options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("\(assetDir)/Contents.json"))
try JSONSerialization.data(withJSONObject:["info":["author":"xcode","version":1]], options:.prettyPrinted).write(to:root.appendingPathComponent("App/Assets.xcassets/Contents.json"))

let board = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1600,pixelsHigh:1000,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:board)
NSColor(srgbRed:0.96,green:0.95,blue:0.92,alpha:1).setFill(); NSRect(x:0,y:0,width:1600,height:1000).fill()
navy.setFill(); NSRect(x:0,y:0,width:760,height:1000).fill()
let mark = NSImage(size:NSSize(width:1024,height:1024)); mark.addRepresentation(icon(1024, mac:true))
mark.draw(in:NSRect(x:150,y:300,width:460,height:460))
func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ font:NSFont,_ color:NSColor) {
    (value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:font,.foregroundColor:color])
}
text("A E G I S", 200, 230, NSFont(name:"Baskerville",size:48)!, .white)
text("THE SHIELD OF ATHENA", 224, 190, .systemFont(ofSize:12,weight:.medium), gold)
text("Aegis", 860, 720, NSFont(name:"Baskerville",size:94)!, navy)
text("将秘密，交给神盾。", 864, 650, .systemFont(ofSize:28,weight:.light), navy)
text("雅典娜的神盾 · 你的私人保险库", 864, 590, .systemFont(ofSize:17), .secondaryLabelColor)
text("iPhone  +  Mac", 864, 515, .monospacedSystemFont(ofSize:15,weight:.medium), navy)
for (index,color) in [navy,gold,NSColor(srgbRed:0.18,green:0.44,blue:0.43,alpha:1)].enumerated() {
    color.setFill(); NSBezierPath(roundedRect:NSRect(x:864+index*110,y:340,width:86,height:86),xRadius:18,yRadius:18).fill()
}
text("深海蓝       暖金         青绿",864,300,.systemFont(ofSize:14),navy)
text("PRIVATE BY DESIGN.",864,180,.systemFont(ofSize:13,weight:.semibold),navy)
NSGraphicsContext.restoreGraphicsState()
try write(board,"Brand/Aegis-Brand.png")
print("Rendered Aegis icons and brand board.")
