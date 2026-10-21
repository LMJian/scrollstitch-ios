import XCTest
import ScrollStitchCore
@testable import ScrollStitchImaging

final class LayoutTests: XCTestCase {
    private func item(_ w: Int,_ h: Int) throws -> LayoutInput {
        LayoutInput(asset:SourceAsset(path:try AssetPath("assets/a.png"),size:try PixelSize(width:w,height:h),sha256:String(repeating:"a",count:64)))
    }
    private func ready(_ inputs: [LayoutInput], spacing: Int = 0) throws -> CompositionPlan {
        guard case .ready(let plan) = try LayoutEngine.propose(taskID:UUID(),revision:1,inputs:inputs,spacingPx:spacing) else {
            throw ScrollStitchError.budgetExceeded
        }
        return plan
    }
    func testIndependentDimensionsAndHalfUpRounding() throws {
        let plan = try ready([item(1000,500),item(500,1000)],spacing:8)
        XCTAssertEqual(plan.size,try PixelSize(width:500,height:1258))
        XCTAssertEqual(plan.items.map(\.y),[0,258]); XCTAssertEqual(plan.items.map(\.height),[250,1000])
        let half = try ready([item(4,3),item(2,1)])
        XCTAssertEqual(half.items[0].height,2)
    }
    func testNoUpsamplingAndCountBoundaries() throws {
        XCTAssertEqual(try ready([item(200,100),item(1000,1000)]).size.width,200)
        XCTAssertThrowsError(try ready([item(100,100)]))
        XCTAssertThrowsError(try ready((0..<21).map { _ in try item(100,100) }))
        XCTAssertEqual(try ready((0..<20).map { _ in try item(100,100) }).items.count,20)
    }
    func testBudgetConsentKeepsFinalPixelSpacingAndEntireTail() throws {
        let items = try (0..<20).map { _ in try item(1080,2000) }
        guard case .requiresConsent(let width,let height,let plan) = try LayoutEngine.propose(taskID:UUID(),revision:1,inputs:items,spacingPx:24) else {
            return XCTFail("must require explicit downscale consent")
        }
        XCTAssertEqual(width,1080); XCTAssertEqual(height,40_456)
        XCTAssertTrue(plan.acceptedDownscale); XCTAssertEqual(plan.items.count,20)
        XCTAssertLessThanOrEqual(plan.size.pixels,24_000_000); XCTAssertLessThanOrEqual(plan.size.height,32_000)
        for i in 1..<20 { XCTAssertEqual(plan.items[i].y-plan.items[i-1].y-plan.items[i-1].height,24) }
        XCTAssertEqual(plan.items.last!.y+plan.items.last!.height,plan.size.height)
        XCTAssertThrowsError(try ready((0..<20).map { _ in try item(400,10000) }))
    }
    func testCropCannotEscapeOrProduceEmptyImage() throws {
        let asset = try item(100,100).asset
        XCTAssertThrowsError(try ready([LayoutInput(asset:asset,crop:PixelCrop(x:99,width:2,height:1)),item(100,100)]))
        XCTAssertThrowsError(try ready([LayoutInput(asset:asset,crop:PixelCrop(width:0,height:1)),item(100,100)]))
    }
    func testAsynchronousCompletionKeepsSelectionOrderAndFailureSlots() throws {
        let token = OperationToken(taskID:UUID(),revision:1), slots = [ImportSlot(),ImportSlot(),ImportSlot()]
        var batch = try ImportBatch(token:token,slots:slots)
        let assets = try [item(100,100).asset,item(200,200).asset,item(300,300).asset]
        for i in [2,0] { XCTAssertTrue(batch.resolve(id:slots[i].id,state:.ready(assets[i]),token:token)) }
        XCTAssertNil(batch.readyAssets)
        batch.resolve(id:slots[1].id,state:.failed(.unavailable),token:token); XCTAssertNil(batch.readyAssets)
        batch.resolve(id:slots[1].id,state:.ready(assets[1]),token:token)
        XCTAssertEqual(batch.readyAssets?.map(\.id),assets.map(\.id))
        batch.cancel(); XCTAssertFalse(batch.resolve(id:slots[1].id,state:.loading,token:token))
    }
    func testOnlyKnownSelectionIdentifiersAreDeduplicated() throws {
        let slots = [ImportSlot(selectionIdentifier:"known"),ImportSlot(selectionIdentifier:"known"),ImportSlot(),ImportSlot()]
        let batch = try ImportBatch(token:OperationToken(taskID:UUID(),revision:0),slots:slots)
        XCTAssertEqual(batch.slots.count,3)
    }
}
