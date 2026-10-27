import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import ScrollStitchCore
@testable import ScrollStitchImaging

final class CapturePipelineTests: XCTestCase {
    private let width=256,height=640,bar=80
    private let fingerprint=String(repeating:"a",count:64)
    private func pixel(_ y:Int,_ x:Int) -> [UInt8] {
        let block=y/5*73856093 ^ (x/5)*19349663
        let value=UInt32(truncatingIfNeeded:block) &* 1274126177
        return [UInt8(truncatingIfNeeded:value>>16),UInt8(truncatingIfNeeded:value>>8),UInt8(truncatingIfNeeded:value),255]
    }
    private func image(_ offset:Int) throws -> CGImage {
        var bytes=[UInt8]();bytes.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width {
            bytes += y<bar || y>=height-bar ? [40,70,150,255]:pixel(y-bar+offset,x)
        }}
        let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    private func storage() throws -> TaskStore {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return try TaskStore(root:root)
    }

    private func jpeg(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
    private func record(_ pages: [[Int]], axis: ScrollAxis = .vertical, complete: Bool = true) throws -> (TaskStore, UUID) {
        let store = try storage(), pair = try store.beginCapture()
        let archive = try ScrollFrameArchive(store: store, taskID: pair.0.taskID, owner: pair.1,
            options: ScrollCaptureOptions(axis: axis), topCropRatio: 0.075)
        var time = 0.0
        for (page, offsets) in pages.enumerated() {
            if page > 0 { XCTAssertTrue(try archive.togglePage()); XCTAssertFalse(try archive.togglePage()) }
            for offset in offsets {
                var cg = try image(offset)
                if axis == .horizontal {
                    let ci = CIImage(cgImage: cg).oriented(.leftMirrored)
                    cg = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
                }
                XCTAssertTrue(try archive.append(jpeg: jpeg(cg), size: PixelSize(width: cg.width, height: cg.height), pts: time))
                time += 0.3
            }
        }
        try archive.finish(complete: complete)
        return (store, pair.0.taskID)
    }
    private func run(_ record: (TaskStore, UUID), cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> CaptureResultSet {
        try await CapturePipeline.run(store: record.0, taskID: record.1, selectionFingerprint: fingerprint, cancelled: cancelled).result
    }
    private func output(_ set: CaptureResultSet, store: TaskStore) throws -> CGImage {
        let page = try XCTUnwrap(set.pages.first)
        let path = try page.result.path.resolved(in: store.taskDirectory(set.taskID))
        XCTAssertEqual(try TaskStore.digest(url: path), page.result.sha256)
        return try ImageDecoder.normalized(path)
    }
    func testCapturePauseResumeSealAndHostVisibilityUseCommittedJPEGs() throws {
        let store=try storage(), pair=try store.beginCapture()
        let archive=try ScrollFrameArchive(store:store,taskID:pair.0.taskID,owner:pair.1,
            options:ScrollCaptureOptions(),topCropRatio:0.075)
        let bytes=try jpeg(image(0)),size=try PixelSize(width:width,height:height)
        XCTAssertFalse(try archive.append(jpeg:bytes,size:size,pts:0,hostForeground:true))
        XCTAssertTrue(try archive.append(jpeg:bytes,size:size,pts:0))
        XCTAssertFalse(try archive.append(jpeg:bytes,size:size,pts:0.1))
        XCTAssertTrue(try archive.togglePage())
        XCTAssertFalse(try archive.append(jpeg:bytes,size:size,pts:1))
        XCTAssertFalse(try archive.togglePage())
        XCTAssertTrue(try archive.append(jpeg:bytes,size:size,pts:2))
        archive.seal()
        XCTAssertFalse(try archive.append(jpeg:bytes,size:size,pts:3))
        try archive.finish(complete:true)
        let snapshot=try store.captureSnapshot(taskID:pair.0.taskID,verifyFiles:true)
        XCTAssertEqual(snapshot.frames.map(\.monotonicPTS),[0,2])
        for frame in snapshot.frames { XCTAssertEqual(try Data(contentsOf:store.assetURL(frame.asset,taskID:pair.0.taskID)),bytes) }
        let input=try JSONDecoder().decode(ScrollFrameInput.self,from:Data(contentsOf:store.taskDirectory(pair.0.taskID).appendingPathComponent("scroll-frames.json")))
        XCTAssertTrue(input.complete);XCTAssertEqual(input.segmentStarts,[0,1])
        XCTAssertThrowsError(try archive.togglePage())
    }
    func testEmptyPauseTransitionsDoNotInventPages() throws {
        let store=try storage(),pair=try store.beginCapture()
        let archive=try ScrollFrameArchive(store:store,taskID:pair.0.taskID,owner:pair.1,
            options:ScrollCaptureOptions(),topCropRatio:0.075)
        for _ in 0..<3 { _=try archive.togglePage();_=try archive.togglePage() }
        XCTAssertEqual(archive.page,0)
        try archive.finish(complete:true)
        let data=try Data(contentsOf:store.taskDirectory(pair.0.taskID).appendingPathComponent("scroll-frames.json"))
        XCTAssertFalse(try JSONDecoder().decode(ScrollFrameInput.self,from:data).complete)
    }
    func testReverseAndRevisitsPreserveFullExtent() async throws {
        let forward=try record([[0,160,320,480,640,800]])
        let reverse=try record([[800,640,480,320,160,0]])
        let repeated=try record([[0,160,320,480,640,800,640,480,320,160,0,160,320,480,640,800]])
        var outputs=[CGImage]()
        for value in [forward,reverse,repeated] {
            let set=try await run(value)
            XCTAssertEqual(set.status,.complete);XCTAssertEqual(set.pages.count,1)
            outputs.append(try output(set,store:value.0))
        }
        XCTAssertEqual(outputs.map(\.width),[width,width,width])
        XCTAssertEqual(outputs.map(\.height),[1392,1392,1392])
        let rasters=try outputs.map {try FrameRaster(image:$0).rgba}
        XCTAssertEqual(rasters[0],rasters[1]);XCTAssertEqual(rasters[0],rasters[2])
    }
    func testExplicitPagesRemainOrderedEvenWhenIdentical() async throws {
        let single=try record([[0,160,320]])
        let twice=try record([[0,160,320],[0,160,320]])
        let a=try await run(single),b=try await run(twice)
        XCTAssertEqual(b.status,.complete)
        let baseline=try output(a,store:single.0),result=try output(b,store:twice.0)
        XCTAssertEqual(result.height,baseline.height*2+8)
        XCTAssertEqual(result.width,baseline.width)
    }
    func testHorizontalAndExplicitStaticPageKeepAxisAndBothExtents() async throws {
        let w=390,h=844,shift=120
        let context=try XCTUnwrap(CGContext(data:nil,width:w+shift,height:h,bitsPerComponent:8,
            bytesPerRow:(w+shift)*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:w+shift,height:h))
        for row in 0..<25 { for column in 0..<18 {
            let shade=CGFloat((row*41+column*67+row*column*13)%193)/255
            context.setFillColor(gray:shade,alpha:1)
            context.fill(CGRect(x:column*31+3,y:row*29+106,
                width:7+(column*7+row*11)%19,height:7+(column*3+row*13)%17))
        }}
        let world=try XCTUnwrap(context.makeImage()),store=try storage()
        let taskID: UUID = try {
        let pair=try store.beginCapture()
        let archive=try ScrollFrameArchive(store:store,taskID:pair.0.taskID,owner:pair.1,
            options:ScrollCaptureOptions(axis:.horizontal,keepsStatusBar:true),topCropRatio:0.075)
        for (i,x) in [0,shift,0].enumerated() {
            if i==2 { _=try archive.togglePage();_=try archive.togglePage() }
            let cg=try XCTUnwrap(world.cropping(to:CGRect(x:x,y:0,width:w,height:h)))
            XCTAssertTrue(try archive.append(jpeg:jpeg(cg),size:PixelSize(width:w,height:h),pts:Double(i)))
        }
        try archive.finish(complete:true)
        return pair.0.taskID
        }()
        let result=try await run((store,taskID))
        XCTAssertEqual(result.status,.complete)
        let image=try output(result,store:store)
        XCTAssertEqual(image.width,w*2+shift+15)
        XCTAssertEqual(image.height,h)
    }
    func testSingleStationaryPageDoesNotPublishFalseLongScreenshot() async throws {
        let value=try record([[0,0,0]])
        let set=try await run(value)
        XCTAssertEqual(set.status,.noUsableContent);XCTAssertTrue(set.pages.isEmpty)
        XCTAssertEqual(try value.0.captureSnapshot(taskID:value.1,verifyFiles:true).frames.count,3)
    }
    func testHorizontalTallFixedHeaderIsRenderedOnlyOnce() async throws {
        let w=390,h=844,shift=120,header=340,footer=180
        let store=try storage()
        let taskID:UUID=try {
            let pair=try store.beginCapture()
            let archive=try ScrollFrameArchive(store:store,taskID:pair.0.taskID,owner:pair.1,
                options:ScrollCaptureOptions(axis:.horizontal,keepsStatusBar:true),topCropRatio:0.075)
            for (i,offset) in [0,shift,0,shift].enumerated() {
                var bytes=[UInt8]();bytes.reserveCapacity(w*h*4)
                for y in 0..<h {for x in 0..<w {
                    bytes += y<header || y>=h-footer ? [40,70,150,255] : pixel(y,x+offset)
                }}
                let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
                let cg=try XCTUnwrap(CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,
                    bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,
                    decode:nil,shouldInterpolate:false,intent:.defaultIntent))
                _=try archive.append(jpeg:jpeg(cg),size:PixelSize(width:w,height:h),pts:Double(i))
            }
            try archive.finish(complete:true);return pair.0.taskID
        }()
        let result=try await run((store,taskID))
        XCTAssertEqual(result.status,.complete)
        let raster=try FrameRaster(image:output(result,store:store))
        XCTAssertEqual(raster.size.width,w+shift)
        XCTAssertEqual(raster.size.height,h)
        func rgb(_ x:Int,_ y:Int)->[UInt8] {
            let index=(y*raster.size.width+x)*4;return Array(raster.rgba[index..<(index+3)])
        }
        XCTAssertLessThan(rgb(100,300)[0],60) // authentic fixed header remains
        XCTAssertTrue(rgb(w+40,300).allSatisfy{$0>245}) // no repeated header strip
        XCTAssertTrue(rgb(w+40,h-100).allSatisfy{$0>245}) // footer also appears once
        XCTAssertFalse(rgb(w+40,450).allSatisfy{$0>245}) // moving content is retained
    }
    func testInterruptedInputCannotBecomeACompleteResult() async throws {
        let value=try record([[0,160,320]],complete:false)
        let set=try await run(value)
        XCTAssertEqual(set.status,.recoverableFailure)
        XCTAssertTrue(set.pages.allSatisfy {$0.result.completenessNote != nil})
    }
    func testCrashBetweenSettingsAndSnapshotSealCannotPublishComplete() async throws {
        let store = try storage()
        let taskID: UUID = try {
            let pair = try store.beginCapture()
            let archive = try ScrollFrameArchive(store:store, taskID:pair.0.taskID, owner:pair.1,
                options:ScrollCaptureOptions(), topCropRatio:0.075)
            for (i, offset) in [0,160,320].enumerated() {
                _ = try archive.append(jpeg:jpeg(image(offset)), size:PixelSize(width:width,height:height), pts:Double(i))
            }
            let path = try store.taskDirectory(pair.0.taskID).appendingPathComponent("scroll-frames.json")
            var input = try JSONDecoder().decode(ScrollFrameInput.self, from:Data(contentsOf:path))
            input.complete = true
            try JSONEncoder().encode(input).write(to:path, options:.atomic)
            // Simulate the process disappearing before the capture snapshot's
            // finish transaction. The next owner must discover interruption.
            return pair.0.taskID
        }()
        let result = try await run((store,taskID))
        XCTAssertEqual(result.status,.recoverableFailure)
        XCTAssertEqual(try store.captureSnapshot(taskID:taskID,verifyFiles:true).phase,.interrupted)
    }
    func testCancellationAndRetryPreserveOriginalBytes() async throws {
        let value=try record([[0,160,320,480]])
        let before=try value.0.captureSnapshot(taskID:value.1,verifyFiles:true)
        do { _=try await run(value,cancelled:{true});XCTFail("Expected cancellation") }
        catch ScrollStitchError.cancelled {}
        let set=try await run(value)
        XCTAssertEqual(set.status,.complete)
        XCTAssertEqual(try value.0.captureSnapshot(taskID:value.1,verifyFiles:true),before)
    }
    func testResumeReconstructsFailedCurrentRecipeInsteadOfReusingFailure() async throws {
        let recording = try record([[0, 120, 240, 360]])
        let snapshot = try recording.0.captureSnapshot(taskID: recording.1, verifyFiles: true)
        let failed = CaptureResultSet(taskID: recording.1, revision: snapshot.sequence,
            sourceIdentity: fingerprint, recipe: CapturePipeline.recipe, selectionFingerprint: fingerprint,
            status: .recoverableFailure, pages: [], gaps: ["Previous attempt failed"])
        try recording.0.publishCaptureResultSet(failed)
        let result = try await CapturePipeline.resume(store: recording.0, taskID: recording.1,
                                                      selectionFingerprint: fingerprint)
        XCTAssertTrue(result.readyForPhotoSave)
        XCTAssertGreaterThan(try output(result, store: recording.0).height, height)
        XCTAssertEqual(try recording.0.captureResultSet(taskID: recording.1,
                       selectionFingerprint: fingerprint), result)
        XCTAssertEqual(try recording.0.captureSnapshot(taskID: recording.1, verifyFiles: true).frames, snapshot.frames)
    }
    func testResumeKeepsSuccessfulResultAndPhotoSaveIdentity() async throws {
        let recording = try record([[0, 120, 240]])
        let result = try await run(recording)
        let page = try XCTUnwrap(result.pages.first)
        let access = try recording.0.openResult(taskID: recording.1, resultID: page.result.id)
        let pending = try recording.0.beginPhotoSave(access)
        try recording.0.finishPhotoSave(access, operationID: pending.operationID, success: true)
        let resumed = try await CapturePipeline.resume(store: recording.0, taskID: recording.1,
                                                       selectionFingerprint: fingerprint)
        XCTAssertEqual(resumed, result)
        XCTAssertEqual(try recording.0.photoSaveRecord(access)?.phase, .saved)
        withExtendedLifetime(access) {}
    }
    func testRecoveryRecreatesMissingDerivedOutputDirectory() async throws {
        let value = try record([[0,160,320]])
        try FileManager.default.removeItem(at: value.0.taskDirectory(value.1).appendingPathComponent("exports"))
        let result = try await run(value)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(try output(result, store:value.0).height, 912)
    }
    func testOptionalPNGPreservesDefaultJPEGDecodedPixels() async throws {
        let value = try record([[0,160,320]])
        let jpeg = try await run(value)
        let png = try await CapturePipeline.run(store:value.0, taskID:value.1,
            selectionFingerprint:fingerprint, format:.png).result
        XCTAssertEqual(jpeg.pages.first?.result.format, "jpeg")
        XCTAssertEqual(png.pages.first?.result.format, "png")
        XCTAssertEqual(try FrameRaster(image:output(jpeg, store:value.0)).rgba,
                       try FrameRaster(image:output(png, store:value.0)).rgba)
    }
    func testDeadlineNeverPublishesPartialSuccess() async throws {
        let value=try record([[0,160,320,480]])
        do {
            _=try await CapturePipeline.run(store:value.0,taskID:value.1,selectionFingerprint:fingerprint,workBudget:0.000001)
            XCTFail("Expected bounded attempt to expire")
        } catch CaptureProcessingError.deadline {}
        XCTAssertNil(try value.0.captureResultSet(taskID:value.1,selectionFingerprint:fingerprint))
        XCTAssertEqual(try value.0.captureSnapshot(taskID:value.1,verifyFiles:true).frames.count,4)
    }
    func testPreparedFramesMatchUncachedOutputAndCorruptCacheFallsBack() throws {
        let value=try record([[0,160,320,480]])
        let directory=try value.0.taskDirectory(value.1)
        let frames=try value.0.captureSnapshot(taskID:value.1,verifyFiles:true).frames.map {try $0.asset.path.resolved(in:directory)}
        for url in frames {
            let prepared=try FrameStitcher().prepareFrame(at:url,encodedData:Data(contentsOf:url))
            try FramePreparationCache.store(prepared,for:url)
        }
        let plain=try FrameStitcher(usePreparedFrames:false).stitch(frameURLs:frames,sessionURL:directory.appendingPathComponent("plain"))
        let cached=try FrameStitcher().stitch(frameURLs:frames,sessionURL:directory.appendingPathComponent("cached"))
        XCTAssertEqual(cached.preparedFrameCount,frames.count)
        XCTAssertEqual(try Data(contentsOf:plain.outputURLs[0]),try Data(contentsOf:cached.outputURLs[0]))
        try Data("invalid derived cache".utf8).write(to:FramePreparationCache.cacheURL(for:frames[0]))
        let recovered=try FrameStitcher().stitch(frameURLs:frames,sessionURL:directory.appendingPathComponent("recovered"))
        XCTAssertEqual(try Data(contentsOf:plain.outputURLs[0]),try Data(contentsOf:recovered.outputURLs[0]))
    }
    func testPreprocessorBoundsPendingFramesWithoutBlockingCapture() {
        let gate = DispatchSemaphore(value:0)
        let completed = expectation(description:"Only accepted cache jobs execute")
        completed.expectedFulfillmentCount = 2
        let cache = FramePreprocessor { _,_ in
            guard gate.wait(timeout:.now()+2) == .success else { return }
            completed.fulfill()
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(cache.enqueue(Data(),for:path))
        XCTAssertTrue(cache.enqueue(Data(),for:path))
        XCTAssertFalse(cache.enqueue(Data(),for:path))
        gate.signal();gate.signal()
        wait(for:[completed],timeout:3)
    }
    func testChangingDimensionsRejectsOutputAndRetainsInput() throws {
        let value=try record([[0,160]])
        let directory=try value.0.taskDirectory(value.1)
        var frames=try value.0.captureSnapshot(taskID:value.1,verifyFiles:true).frames.map {try $0.asset.path.resolved(in:directory)}
        let changed=directory.appendingPathComponent("changed.jpg")
        try jpeg(XCTUnwrap(image(320).cropping(to:CGRect(x:0,y:0,width:width-1,height:height)))).write(to:changed)
        frames.append(changed)
        XCTAssertThrowsError(try FrameStitcher().stitch(frameURLs:frames,sessionURL:directory.appendingPathComponent("invalid")))
        XCTAssertTrue(FileManager.default.fileExists(atPath:changed.path))
    }
}
