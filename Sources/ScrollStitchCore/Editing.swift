import Foundation

/// Coordinates always refer to the orientation-normalized source pixels.
public struct CropRect: Codable, Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int = 0, y: Int = 0, width: Int, height: Int) {
        self.x=x; self.y=y; self.width=width; self.height=height
    }
    public func validate(in size: PixelSize) throws {
        guard x>=0, y>=0, width>0, height>0, x<=size.width, y<=size.height,
              width<=size.width-x, height<=size.height-y else { throw ScrollStitchError.invalidDimensions }
    }
}
public struct AssetCropRecord: Codable, Equatable, Sendable {
    public let assetID: UUID
    public let rect: CropRect
    public init(assetID: UUID, rect: CropRect) { self.assetID=assetID; self.rect=rect }
}
public struct EditPayload: Codable, Equatable, Sendable {
    public var assets: [SourceAsset]
    public var imports: [ImportRecord]
    public var crops: [AssetCropRecord]
    public var spacingPx: Int
    public var background: CanvasBackground
    public var widthMode: WidthMode
    public func validate() throws {
        guard assets.count<=20, Set(assets.map(\.id)).count==assets.count,
              imports.count<=20, Set(imports.map(\.id)).count==imports.count,
              [0,8,16,24].contains(spacingPx),
              imports.allSatisfy({($0.asset == nil) == ($0.issue != nil)}),
              imports.isEmpty || imports.compactMap(\.asset)==assets,
              crops.count<=assets.count, Set(crops.map(\.assetID)).count==crops.count else { throw ScrollStitchError.corruptData }
        try assets.forEach { try $0.validate() }
        for crop in crops {
            guard let asset=assets.first(where:{$0.id==crop.assetID}) else { throw ScrollStitchError.corruptData }
            try crop.rect.validate(in:asset.size)
        }
    }
}
public struct EditUndo: Codable, Equatable, Sendable {
    public let payload: EditPayload
    public let label: String
}
public struct ImportBatchState: Codable, Equatable, Sendable {
    public let id: UUID
    public let itemIDs: [UUID]
}
public enum EditCommand: Sendable {
    case reorder([UUID]), remove(UUID), crop(UUID, CropRect?)
    case options(spacing: Int?, background: CanvasBackground?, width: WidthMode?)
}
public extension EditSnapshot {
    var orderedImports: [ImportRecord] {
        if !imports.isEmpty || assets.isEmpty { return imports }
        return assets.map { asset in
            var record=ImportRecord(id:asset.id); record.asset=asset; record.issue=nil; return record
        }
    }
    var payload: EditPayload {
        get { EditPayload(assets:assets,imports:orderedImports,crops:crops,spacingPx:spacingPx,background:background,widthMode:widthMode) }
        set {
            assets=newValue.assets; imports=newValue.imports; crops=newValue.crops
            spacingPx=newValue.spacingPx; background=newValue.background; widthMode=newValue.widthMode
        }
    }
    func crop(for asset: SourceAsset) -> CropRect {
        crops.first(where:{$0.assetID==asset.id})?.rect ?? CropRect(width:asset.size.width,height:asset.size.height)
    }
    /// No-op operations deliberately leave revision and the previous undo untouched.
    func applying(_ command: EditCommand) throws -> (EditSnapshot, String) {
        guard activeImport == nil else { throw ScrollStitchError.resourceBusy }
        var next=self; next.imports=orderedImports
        let label: String
        switch command {
        case .reorder(let ids):
            guard ids.count==next.imports.count, Set(ids)==Set(next.imports.map(\.id)) else { throw ScrollStitchError.invalidSelection }
            let records=Dictionary(uniqueKeysWithValues:next.imports.map { ($0.id,$0) })
            next.imports=ids.compactMap { records[$0] }; label="排序"
        case .remove(let id):
            guard next.imports.contains(where:{$0.id==id}) else { throw ScrollStitchError.invalidSelection }
            next.imports.removeAll { $0.id==id }; label="移除图片"
        case .crop(let assetID,let rect):
            guard let asset=assets.first(where:{$0.id==assetID}) else { throw ScrollStitchError.invalidSelection }
            if let rect { try rect.validate(in:asset.size) }
            next.crops.removeAll { $0.assetID==assetID }
            if let rect, rect != CropRect(width:asset.size.width,height:asset.size.height) {
                next.crops.append(AssetCropRecord(assetID:assetID,rect:rect))
            }
            label="裁剪"
        case .options(let spacing,let background,let width):
            if let spacing { next.spacingPx=spacing }
            if let background { next.background=background }
            if let width { next.widthMode=width }
            label="排版"
        }
        next.assets=next.imports.compactMap(\.asset)
        next.crops.removeAll { crop in !next.assets.contains(where:{$0.id==crop.assetID}) }
        next.crops.sort { $0.assetID.uuidString < $1.assetID.uuidString }
        try next.payload.validate()
        return (next,label)
    }
}

public struct ImportSelection: Sendable {
    public let id: UUID
    public let identifier: String?
    public init(id: UUID = UUID(), identifier: String? = nil) { self.id=id; self.identifier=identifier }
}
public struct ImportBatchSlot: Sendable {
    public let inputID: UUID
    public let itemID: UUID
}
/// Owns source files until provider callbacks and the batch worker have unwound.
public final class ImportBatchAccess: @unchecked Sendable {
    public let taskID: UUID, batchID: UUID
    public let slots: [ImportBatchSlot]
    let lease: FileLease
    init(taskID: UUID, batchID: UUID, slots: [ImportBatchSlot], lease: FileLease) {
        self.taskID=taskID; self.batchID=batchID; self.slots=slots; self.lease=lease
    }
}

public extension CaptureInsets {
    func adjustingForCollage(edge: String, to value: Int, in size: PixelSize) -> CaptureInsets {
        var next=self
        switch edge {
        case "top": next.top=max(0,min(value,size.height-bottom-1))
        case "bottom": next.bottom=max(0,min(value,size.height-top-1))
        case "left": next.left=max(0,min(value,size.width-right-1))
        case "right": next.right=max(0,min(value,size.width-left-1))
        default: break
        }
        return next
    }
    func draggingForCollage(edge: String, translation: Double, displayedLength: Double, in size: PixelSize) -> CaptureInsets {
        guard translation.isFinite,displayedLength.isFinite,displayedLength>0 else { return self }
        let vertical=edge == "top" || edge == "bottom"
        let base=edge == "top" ? top:edge == "bottom" ? bottom:edge == "left" ? left:right
        let delta=translation/displayedLength*Double(vertical ? size.height:size.width)
        let value=Double(base)+((edge == "right" || edge == "bottom") ? -delta:delta)
        // Floor each removed margin: the kept far edge consequently rounds outward.
        let bounded=max(0,min(value,Double(vertical ? size.height:size.width)))
        return adjustingForCollage(edge:edge,to:Int(bounded.rounded(.down)),in:size)
    }
}
