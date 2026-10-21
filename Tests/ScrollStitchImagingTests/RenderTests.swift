import XCTest
import CoreGraphics
import ImageIO
import ScrollStitchCore
@testable import ScrollStitchImaging

final class RenderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return root
    }
    private func fixture(root: URL, width: Int = 10, height: Int = 20, color: [UInt8], type: String = "public.png",
                         properties: [CFString:Any] = [:], pixels: [UInt8]? = nil) throws -> URL {
        let bytes = pixels ?? Array(repeating:color,count:width*height).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let url = root.appendingPathComponent(UUID().uuidString)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,type as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }
    private func setup(colors: [[UInt8]], spacing: Int = 0, background: CanvasBackground = .white) throws -> (TaskStore,CompositionPlan) {
        let root = try directory(), store = try TaskStore(root:root)
        let task = try store.createCollage()
        let assets = try colors.map { color in try ImageImporter.ingest(fixture(root:root,color:color),store:store,taskID:task.taskID) }
        var edit = EditSnapshot(taskID:task.taskID,assets:assets,spacingPx:spacing,background:background)
        edit = try store.commitEdit(edit,expectedRevision:0)
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,
            inputs:assets.map { LayoutInput(asset:$0) },spacingPx:spacing,background:background) else { throw ScrollStitchError.budgetExceeded }
        return (store,plan)
    }
    private func rgb(_ raster: FrameRaster,x: Int = 0,y: Int) -> [UInt8] {
        let i = (y*raster.size.width+x)*4; return Array(raster.rgba[i..<(i+3)])
    }
    func testInterruptedImportLedgerSurvivesRestartAndBlocksRenderingUntilExplicitRemoval() throws {
        let (store, oldPlan) = try setup(colors:[[255,0,0,255],[0,0,255,255]])
        var edit = try store.editSnapshot(taskID:oldPlan.taskID)
        var first = ImportRecord(selectionIdentifier:"one"), missing = ImportRecord(selectionIdentifier:"two"), last = ImportRecord(selectionIdentifier:"three")
        first.asset = edit.assets[0]; first.issue = nil
        missing.issue = .unavailable
        last.asset = edit.assets[1]; last.issue = nil
        edit.imports = [first,missing,last]
        edit = try store.commitEdit(edit,expectedRevision:edit.revision)
        // A fresh store reads the on-disk ledger, including the missing middle selection.
        let reopened = try TaskStore(root:store.root)
        let restored = try reopened.editSnapshot(taskID:edit.taskID)
        XCTAssertEqual(restored.imports.map(\.selectionIdentifier),["one","two","three"])
        XCTAssertEqual(restored.unresolvedImports,1)
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:edit.taskID,revision:edit.revision,inputs:edit.assets.map { LayoutInput(asset:$0) }) else { return XCTFail() }
        XCTAssertThrowsError(try ImageRenderer.render(plan,store:reopened,format:.png)) {
            XCTAssertEqual($0 as? ScrollStitchError,.invalidSelection)
        }
        edit.imports.removeAll { $0.id == missing.id }
        edit = try reopened.commitEdit(edit,expectedRevision:edit.revision)
        guard case .ready(let updated) = try LayoutEngine.propose(taskID:edit.taskID,revision:edit.revision,inputs:edit.assets.map { LayoutInput(asset:$0) }) else { return XCTFail() }
        let output = try ImageDecoder.raster(ImageRenderer.render(updated,store:reopened,format:.png).url)
        XCTAssertEqual(rgb(output,y:0),[255,0,0]); XCTAssertEqual(rgb(output,y:39),[0,0,255])
    }
    func testImportLedgerRejectsSilentReorderAndContradictoryState() throws {
        let (store, plan) = try setup(colors:[[255,0,0,255],[0,0,255,255]])
        var edit = try store.editSnapshot(taskID:plan.taskID)
        var first = ImportRecord(), last = ImportRecord()
        first.asset = edit.assets[0]; first.issue = nil
        last.asset = edit.assets[1]; last.issue = nil
        edit.imports = [last,first]
        XCTAssertThrowsError(try store.commitEdit(edit,expectedRevision:edit.revision))
        first.issue = .cancelled; edit.imports = [first,last]
        XCTAssertThrowsError(try store.commitEdit(edit,expectedRevision:edit.revision))
        XCTAssertEqual(try store.editSnapshot(taskID:plan.taskID).revision,plan.revision)
    }
    func testHEICFileIsActuallyEncodedImportedAndRendered() throws {
        let root = try directory(), store = try TaskStore(root:root), task = try store.createCollage()
        let source = try fixture(root:root,width:640,height:480,color:[200,60,30,255],type:"public.heic")
        XCTAssertEqual(try ImageImporter.inspect(source).typeIdentifier,"public.heic")
        let assets = try (0..<2).map { _ in try ImageImporter.ingest(source,store:store,taskID:task.taskID) }
        let edit = try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:assets),expectedRevision:0)
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,inputs:assets.map { LayoutInput(asset:$0) }) else { return XCTFail() }
        let image = try ImageDecoder.raster(ImageRenderer.render(plan,store:store,format:.png).url)
        XCTAssertEqual(image.size,try PixelSize(width:640,height:960))
        for y in [0,959] {
            for (actual,expected) in zip(rgb(image,y:y),[200,60,30]) { XCTAssertLessThan(abs(Int(actual)-expected),16) }
        }
    }
    func testPNGPreservesTopToBottomOrderGapAndOpaqueBackground() throws {
        for background in [CanvasBackground.white,.black] {
            let (store,plan) = try setup(colors:[[255,0,0,255],[0,0,0,0]],spacing:8,background:background)
            let result = try ImageRenderer.render(plan,store:store,format:.png)
            let image = try ImageDecoder.raster(result.url)
            XCTAssertEqual(image.size,try PixelSize(width:10,height:48))
            XCTAssertEqual(rgb(image,y:0),[255,0,0])
            XCTAssertEqual(rgb(image,y:19),[255,0,0])
            let expected: [UInt8] = background == .white ? [255,255,255] : [0,0,0]
            XCTAssertEqual(rgb(image,y:20),expected); XCTAssertEqual(rgb(image,y:47),expected)
            XCTAssertEqual(result.sizeBytes,try Data(contentsOf:result.url).count)
            XCTAssertEqual(result.sha256,try TaskStore.digest(url:result.url))
        }
    }
    func testTwentyImagesAndLastPixelRemainPresent() throws {
        let colors = (0..<20).map { [UInt8($0*10),UInt8(0),UInt8(0),UInt8(255)] }
        let (store,plan) = try setup(colors:colors)
        let output = try ImageDecoder.raster(ImageRenderer.render(plan,store:store,format:.png).url)
        XCTAssertEqual(output.size.height,400)
        for i in 0..<20 { XCTAssertEqual(rgb(output,y:i*20),Array(colors[i].prefix(3))) }
        XCTAssertEqual(rgb(output,y:399),[190,0,0])
    }
    func testJPEGAndOrientationAreNormalizedAndMetadataRemoved() throws {
        let root = try directory(), store = try TaskStore(root:root), task = try store.createCollage()
        let source = try fixture(root:root,color:[240,30,20,255],type:"public.jpeg",properties:[
            kCGImagePropertyOrientation:6,
            kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.0,kCGImagePropertyGPSLatitudeRef:"N"],
            kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2026:01:01 00:00:00"]
        ])
        let first = try ImageImporter.ingest(source,store:store,taskID:task.taskID)
        XCTAssertEqual(first.size,try PixelSize(width:20,height:10))
        let second = try ImageImporter.ingest(source,store:store,taskID:task.taskID)
        let edit = try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:[first,second]),expectedRevision:0)
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,inputs:[first,second].map { LayoutInput(asset:$0) }) else { return XCTFail() }
        for format in ImageFormat.allCases {
            let result = try ImageRenderer.render(plan,store:store,format:format)
            let decoded = try ImageImporter.inspect(result.url)
            XCTAssertEqual(decoded.orientation,1); XCTAssertEqual(decoded.size,try PixelSize(width:20,height:20))
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL,nil))
            let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded,0,nil) as? [CFString:Any])
            XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
            let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString:Any]
            XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
            let raster = try ImageDecoder.raster(result.url)
            for (actual,expected) in zip(rgb(raster,y:0),[240,30,20]) { XCTAssertLessThan(abs(Int(actual)-expected),20) }
        }
    }
    func testJPEGKeepsColorAtUnalignedImageAndGapBoundaries() throws {
        // Odd heights place solid-color boundaries at different codec block positions.
        // Expected colors come directly from the fixtures, not a second rendering.
        let colors: [[UInt8]] = [[30,180,230,255],[230,40,90,255],[70,210,40,255],[190,80,220,255]]
        for background in [CanvasBackground.black,.white] {
            for spacing in [0,8] {
                let root = try directory(), store = try TaskStore(root:root), task = try store.createCollage()
                let heights = (0..<20).map { 31 + $0*2 }
                let assets = try heights.enumerated().map { index,height in
                    try ImageImporter.ingest(fixture(root:root,width:200,height:height,color:colors[index%4]),store:store,taskID:task.taskID)
                }
                let edit = try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:assets,spacingPx:spacing,background:background),expectedRevision:0)
                guard case .ready(let plan) = try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,
                    inputs:assets.map { LayoutInput(asset:$0) },spacingPx:spacing,background:background) else { return XCTFail() }
                let output = try ImageDecoder.raster(ImageRenderer.render(plan,store:store,format:.jpeg).url)
                XCTAssertEqual(output.size,try PixelSize(width:200,height:heights.reduce(0,+)+19*spacing))
                var y = 0, maximumError = 0
                for (index,height) in heights.enumerated() {
                    for dy in [1,height/2,height-2] {
                        for x in [3,33,100,166,196] {
                            for (actual,expected) in zip(rgb(output,x:x,y:y+dy),colors[index%4].prefix(3)) {
                                maximumError = max(maximumError,abs(Int(actual)-Int(expected)))
                            }
                        }
                    }
                    y += height
                    if index < heights.count-1 {
                        for gap in 0..<spacing {
                            let expected = background == .black ? 0 : 255
                            for actual in rgb(output,x:100,y:y+gap) { maximumError = max(maximumError,abs(Int(actual)-expected)) }
                        }
                        y += spacing
                    }
                }
                XCTAssertLessThanOrEqual(maximumError,8,"JPEG boundary colors: \(background), gap \(spacing)")
            }
        }
    }
    func testJPEGQualityChangeKeepsPreviouslyPublishedExport() throws {
        let (store,plan) = try setup(colors:[[30,180,230,255],[230,40,90,255]],spacing:8)
        // Preserve the legacy file-name contract to detect replacement on a quality upgrade.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var oldKey = try encoder.encode(plan); oldKey.append(contentsOf:"jpeg".utf8)
        let oldURL = try store.taskDirectory(plan.taskID).appendingPathComponent("exports/"+TaskStore.digest(data:oldKey)+".jpeg")
        let previous = Data("previous export must remain available".utf8)
        try previous.write(to:oldURL)
        let output = try ImageRenderer.render(plan,store:store,format:.jpeg)
        XCTAssertNotEqual(output.url,oldURL)
        XCTAssertEqual(try Data(contentsOf:oldURL),previous)
        XCTAssertEqual(try ImageImporter.inspect(output.url).size,plan.size)
        let repeated = try ImageRenderer.render(plan,store:store,format:.jpeg)
        XCTAssertEqual(repeated.url,output.url)
        XCTAssertEqual(repeated.sha256,output.sha256)
    }
    func testUnsupportedCorruptAndStaleInputsNeverBecomePublishedExports() throws {
        let root = try directory()
        XCTAssertThrowsError(try ImageImporter.inspect(fixture(root:root,color:[0,0,0,255],type:"com.compuserve.gif")))
        let bad = root.appendingPathComponent("bad.png"); try Data("not a photo".utf8).write(to:bad)
        XCTAssertThrowsError(try ImageImporter.inspect(bad))
        let (store,plan) = try setup(colors:[[0,0,255,255],[255,0,0,255]])
        XCTAssertThrowsError(try ImageRenderer.render(plan,store:store,format:.png,cancelled:{true}))
        var edit = try store.editSnapshot(taskID:plan.taskID); edit.spacingPx = 8
        _ = try store.commitEdit(edit,expectedRevision:edit.revision)
        XCTAssertThrowsError(try ImageRenderer.render(plan,store:store,format:.png))
        let exports = try store.taskDirectory(plan.taskID).appendingPathComponent("exports")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:exports.path).isEmpty)
    }
    func testEncodingFailureKeepsSourcesAndCleansTemporaryFiles() throws {
        let (store,plan) = try setup(colors:[[0,0,255,255],[255,0,0,255]])
        let directory = try store.taskDirectory(plan.taskID)
        try FileManager.default.removeItem(at:directory.appendingPathComponent("exports"))
        try Data("not a directory".utf8).write(to:directory.appendingPathComponent("exports"))
        XCTAssertThrowsError(try ImageRenderer.render(plan,store:store,format:.png))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent("temporary").path).isEmpty)
        XCTAssertEqual(try store.editSnapshot(taskID:plan.taskID).assets.count,2)
    }
    func testCaptureReadbackCanEncodeWhileRecoveryRunsUnderReaderLease() throws {
        let root = try directory(), store = try TaskStore(root:root)
        var session: (TaskManifest,FileLease)? = try store.beginCapture()
        let id = session!.0.taskID
        let url = try fixture(root:root,color:[255,0,0,255])
        _ = try store.appendFrame(taskID:id,owner:session!.1,png:Data(contentsOf:url),size:PixelSize(width:10,height:20),pts:0)
        try store.finishCapture(taskID:id,owner:session!.1,reason:.userStopped)
        session = nil
        let capture = try store.reconcileCapture(taskID:id)
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:id,revision:capture.sequence,
            inputs:capture.frames.map { LayoutInput(asset:$0.asset) },kind:.capture) else { return XCTFail() }
        let result = try ImageRenderer.render(plan,store:store,format:.png)
        XCTAssertTrue(FileManager.default.fileExists(atPath:result.url.path))
        XCTAssertEqual(try ImageDecoder.raster(result.url).size,try PixelSize(width:10,height:20))
    }
    func testOrientationSixRotatesActualPixelContentClockwise() throws {
        let root = try directory(), store = try TaskStore(root:root), task = try store.createCollage()
        let colors: [[UInt8]] = [[255,0,0,255],[0,255,0,255],[0,0,255,255],[255,255,0,255],[0,255,255,255],[255,0,255,255]]
        var pixels: [UInt8] = []
        for y in 0..<120 { for x in 0..<80 { pixels += colors[(y/40)*2+x/40] } }
        let source = try fixture(root:root,width:80,height:120,color:[],type:"public.jpeg",
            properties:[kCGImagePropertyOrientation:6],pixels:pixels)
        let assets = try (0..<2).map { _ in try ImageImporter.ingest(source,store:store,taskID:task.taskID) }
        let edit = try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:assets),expectedRevision:0)
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,
            inputs:assets.map { LayoutInput(asset:$0) }) else { return XCTFail() }
        let result = try ImageDecoder.raster(ImageRenderer.render(plan,store:store,format:.png).url)
        let expected = [colors[4],colors[2],colors[0],colors[5],colors[3],colors[1]]
        for i in 0..<6 {
            let actual = rgb(result,x:(i%3)*40+20,y:(i/3)*40+20)
            for (a,b) in zip(actual,expected[i]) { XCTAssertLessThan(abs(Int(a)-Int(b)),20) }
        }
    }
    func testM2PersistedCropReorderAndSpacingReachBothEncodedFormats() throws {
        let root=try directory(), store=try TaskStore(root:root), task=try store.createCollage()
        let pixels: [UInt8]=(0..<80).flatMap { y -> [UInt8] in
            let color: [UInt8]=y<40 ? [240,20,20,255]:[20,20,240,255]
            return Array(repeating:color,count:40).flatMap { $0 }
        }
        let first=try ImageImporter.ingest(fixture(root:root,width:40,height:80,color:[],pixels:pixels),store:store,taskID:task.taskID)
        let second=try ImageImporter.ingest(fixture(root:root,width:40,height:40,color:[20,240,20,255]),store:store,taskID:task.taskID)
        var edit=try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:[first,second]),expectedRevision:0)
        edit=try store.applyEdit(taskID:task.taskID,expectedRevision:edit.revision,command:.crop(first.id,CropRect(x:8,y:40,width:24,height:40)))
        edit=try store.applyEdit(taskID:task.taskID,expectedRevision:edit.revision,command:.reorder(edit.imports.map(\.id).reversed()))
        edit=try store.applyEdit(taskID:task.taskID,expectedRevision:edit.revision,command:.options(spacing:8,background:.black,width:nil))
        let restored=try TaskStore(root:root).reconcileEdit(taskID:task.taskID)
        guard case .ready(let plan)=try LayoutEngine.propose(taskID:task.taskID,revision:restored.revision,
            inputs:LayoutEngine.inputs(for:restored),spacingPx:restored.spacingPx,background:restored.background) else { return XCTFail() }
        XCTAssertEqual(plan.size,try PixelSize(width:24,height:72))
        for format in [ImageFormat.png,.jpeg] {
            let raster=try ImageDecoder.raster(ImageRenderer.render(plan,store:store,format:format).url)
            XCTAssertEqual(raster.size,plan.size)
            for (y,expected) in [(12,[20,240,20]),(27,[0,0,0]),(52,[20,20,240])] {
                for (actual,wanted) in zip(rgb(raster,x:12,y:y),expected) { XCTAssertLessThanOrEqual(abs(Int(actual)-wanted),format == .png ? 0:8) }
            }
        }
        edit=try store.undoEdit(taskID:task.taskID,expectedRevision:edit.revision)
        XCTAssertThrowsError(try ImageRenderer.render(plan,store:store,format:.png))
        XCTAssertEqual(edit.crop(for:first),CropRect(x:8,y:40,width:24,height:40))
    }

}
