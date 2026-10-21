// Full-size host smoke test. No result from this executable is physical-device evidence.
import Foundation
import ImageIO
import CryptoKit
import ScrollStitchCore
import ScrollStitchImaging

let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
guard !FileManager.default.fileExists(atPath:root.path) else { fatalError("Refuse to overwrite smoke artifacts") }
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
if CommandLine.arguments.dropFirst(2).contains("--supplemental") {
    var checks=[[String:String]]()
    let lifecycle=root.appendingPathComponent("lifecycle")
    try BoundaryDiagnostics.lifecycle(root:lifecycle,check:{}) { checks.append($0) }
    var refusedExisting=false
    do { try BoundaryDiagnostics.lifecycle(root:lifecycle,check:{},record:{_ in}) }
    catch let error as BoundaryDiagnosticFailure { refusedExisting = error.check == "diagnostic_directory_exists" }
    guard refusedExisting, checks.count == 5 else { fatalError("Isolation or lifecycle oracle failed") }
    let large=root.appendingPathComponent("twenty-48mp")
    let boundary=try BoundaryDiagnostics.twenty48MP(root:large,check:{},progress:{ _ in })
    let store=try TaskStore(root:large.appendingPathComponent("store"))
    let task=try store.current()!, edit=try store.editSnapshot(taskID:task.taskID)
    guard edit.assets.count == 20, Set(edit.assets.map(\.sha256)).count == 20 else { fatalError("Expected twenty distinct sources") }
    let exports=try FileManager.default.contentsOfDirectory(at:store.taskDirectory(task.taskID).appendingPathComponent("exports"),includingPropertiesForKeys:nil)
    guard exports.count == 1,
          let source=CGImageSourceCreateWithURL(exports[0] as CFURL,nil),
          let decoded=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
          decoded.width == 948, decoded.height == 25280 else { fatalError("Full 48MP-workload output decode failed") }
    let report:[String:Any] = ["scope":"Host full-size smoke; NOT phone performance or acceptance",
        "boundary_checks":checks,"refused_existing_directory":refusedExisting,"twenty_48mp_boundary":boundary]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
    print("PASS supplemental host smoke: five lifecycle checks; refused existing directory; twenty distinct 48MP inputs; full JPEG948x25280 decode")
    exit(0)
}
let source=root.appendingPathComponent("fixture.png")
let rStore=try TaskStore(root:root.appendingPathComponent("render")), rTask=try rStore.createCollage()
var assets=[SourceAsset]()
for index in 0..<10 {
    try autoreleasepool {
        try BenchmarkFixtures.writePNG(source,width:3000,height:4000,offset:0,seed:index+31)
        assets.append(try ImageImporter.ingest(source,store:rStore,taskID:rTask.taskID))
    }
}
let edit=try rStore.commitEdit(EditSnapshot(taskID:rTask.taskID,assets:assets),expectedRevision:0)
var outputs=[[String:Any]]()
for large in [false,true] {
    try autoreleasepool {
        let inputs=large ? Array(assets.prefix(4)).enumerated().map { i,a in
            LayoutInput(asset:a,crop:PixelCrop(width:3000,height:i == 3 ? 3432 : 4000))
        } : assets.map { LayoutInput(asset:$0) }
        guard case .ready(let plan)=try LayoutEngine.propose(taskID:rTask.taskID,revision:edit.revision,
            inputs:inputs,widthMode:large ? .original : .standard) else { fatalError("Unexpected scale consent") }
        let expectedWidth=large ? 2160 : 1080, expectedHeight=large ? 11111 : 14400
        guard plan.size.width == expectedWidth, plan.size.height == expectedHeight else { fatalError("Geometry oracle failed") }
        let artifact=try ImageRenderer.render(plan,store:rStore,format:.png)
        let data=try Data(contentsOf:artifact.url)
        let hash=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard hash == artifact.sha256,
              let source=CGImageSourceCreateWithData(data as CFData,nil),
              let decoded=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              decoded.width == expectedWidth, decoded.height == expectedHeight else { fatalError("Full output decode failed") }
        if !large { _=try ImageDecoder.normalized(artifact.url,maxDimension:1600) }
        outputs.append(["width":expectedWidth,"height":expectedHeight,"bytes":data.count,"sha256":hash])
    }
}
let result:[String:Any] = ["scope":"macOS full-size workload smoke only; not device performance or M0 acceptance",

    "preview_input_count":10,"source_pixels_each":12000000,"outputs":outputs]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
print("PASS host smoke: 10 x 12MP preview, 23,999,760-pixel PNG full decode. No device measurements claimed.")
