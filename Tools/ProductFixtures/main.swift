import CaptureTestSupport
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import ScrollStitchCore
import ScrollStitchImaging

// Self-made test data only. Refuse existing directories, never touch a live store.
let args=CommandLine.arguments
guard args.count == 2 else {
    fatalError("Usage: ProductFixtures NEW_OUTPUT_DIRECTORY")
}
let root=URL(fileURLWithPath:args[1]).standardizedFileURL.resolvingSymlinksInPath()
guard !FileManager.default.fileExists(atPath:root.path) else { fatalError("Destination must not exist") }
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let input=root.appendingPathComponent("input.png")
func page(width:Int,height:Int,offset:Int,title:String) throws -> CGImage {
    let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.setFillColor(CGColor(red:0.96,green:0.97,blue:1,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
    // Global row markers make continuity objectively verifiable, not repeated textures.
    for y in stride(from:offset/180*180,to:offset+height,by:180) {
        let row=y/180, top=y-offset
        c.setFillColor(CGColor(red:CGFloat((row*47)%150+50)/255,green:0.4,blue:0.8,alpha:1))
        c.fill(CGRect(x:20,y:height-top-150,width:18,height:130))
        let text="\(title)  ·  ROW \(String(format:"%03d",row))"
        let attr=NSAttributedString(string:text,attributes:[
            NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica-Bold" as CFString,30,nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.12,alpha:1)])
        c.textPosition=CGPoint(x:60,y:height-top-65);CTLineDraw(CTLineCreateWithAttributedString(attr),c)
        for band in 0..<5 {
            let n=(row*73+band*31)%255
            c.setFillColor(CGColor(red:CGFloat(n)/255,green:CGFloat(255-n)/255,blue:0.6,alpha:1))
            c.fill(CGRect(x:60+band*(width-100)/5,y:height-top-130,width:(width-120)/5,height:24))
        }
    }
    return c.makeImage()!
}
func write(_ image:CGImage) throws {
    let w=CGImageDestinationCreateWithURL(input as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(w,image,nil)
    guard CGImageDestinationFinalize(w) else { throw ScrollStitchError.storageFailure }
}
let capture=try TaskStore(root:root.appendingPathComponent("capture"))
let session=try CaptureSession(store:capture,uptime:0)
for i in 0..<22 {
    try autoreleasepool {
        try BenchmarkFixtures.writePNG(input,width:884,height:1920,offset:i*1000,seed:37)
        _ = try session.process(.video,uptime:Double(i)) {
            try OwnedVideoFrame(png:Data(contentsOf:input),size:PixelSize(width:884,height:1920),pts:Double(i))
        }
    }
}
try session.finish(.unknown)
for name in ["collage","unknown"] {
    let store=try TaskStore(root:root.appendingPathComponent(name)),task=try store.createCollage()
    var assets=[SourceAsset](),imports=[ImportRecord]()
    for i in 0..<2 {
        try write(page(width:640,height:700,offset:i*700,title:i == 0 ? "FIRST" : "SECOND"))
        let asset=try ImageImporter.ingest(input,store:store,taskID:task.taskID)
        assets.append(asset);var record=ImportRecord();record.asset=asset;record.issue=nil;imports.append(record)
    }
    var edit=EditSnapshot(taskID:task.taskID,assets:assets,spacingPx:8,background:.black)
    edit.imports=imports;edit=try store.commitEdit(edit,expectedRevision:0)
    if name == "unknown" {
        guard case .ready(let plan)=try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,
            inputs:assets.map { LayoutInput(asset:$0) },spacingPx:8,background:.black) else { fatalError("Fixture exceeds budget") }
        let a=try ImageRenderer.render(plan,store:store,format:.png)
        let fingerprint=TaskStore.digest(data:Data("\(task.taskID.uuidString)|\(edit.revision)|0|0|0|0|0|0".utf8))
        let r=try ResultManifest(taskID:task.taskID,revision:edit.revision,selectionFingerprint:fingerprint,
            path:AssetPath("exports/"+a.url.lastPathComponent),format:"png",size:a.size,sizeBytes:a.sizeBytes,sha256:a.sha256)
        try store.publishResult(r)
        _ = try store.beginPhotoSave(store.openResult(taskID:task.taskID,resultID:r.id))
    }
}
try FileManager.default.removeItem(at:input)
print("Created isolated capture, collage, empty and injected-unknown fixtures; no Photos operation performed.")
