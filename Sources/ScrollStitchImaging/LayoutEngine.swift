import Foundation
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public struct PixelCrop: Codable, Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int = 0, y: Int = 0, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func validate(in size: PixelSize) throws {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= size.width, y <= size.height, width <= size.width-x, height <= size.height-y else {
            throw ScrollStitchError.invalidDimensions
        }
    }
}
public struct LayoutInput: Codable, Equatable, Sendable {
    public let asset: SourceAsset
    public let crop: PixelCrop
    public init(asset: SourceAsset, crop: PixelCrop? = nil) {
        self.asset = asset
        self.crop = crop ?? PixelCrop(width: asset.size.width, height: asset.size.height)
    }
}
public struct PlacedImage: Codable, Equatable, Sendable {
    public let input: LayoutInput
    public let y: Int
    public let height: Int
}
public struct CompositionPlan: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let revision: UInt64
    public let kind: TaskKind
    public let items: [PlacedImage]
    public let size: PixelSize
    public let spacingPx: Int
    public let background: CanvasBackground
    public let acceptedDownscale: Bool
    public func validate() throws {
        guard !items.isEmpty, items.count <= (kind == .capture ? 200 : 20),
              kind == .capture || items.count >= 2,
              [0,8,16,24].contains(spacingPx),
              size.width <= 2160, size.height <= 32_000, size.pixels <= 24_000_000 else { throw ScrollStitchError.budgetExceeded }
        var y = 0
        for item in items {
            try item.input.asset.validate(); try item.input.crop.validate(in: item.input.asset.size)
            guard item.y == y, item.height == LayoutEngine.scaledHeight(item.input.crop, width:size.width),
                  size.width <= item.input.crop.width else { throw ScrollStitchError.invalidDimensions }
            y += item.height + spacingPx
        }
        guard y-spacingPx == size.height else { throw ScrollStitchError.invalidDimensions }
    }
}
public enum LayoutDecision: Sendable {
    case ready(CompositionPlan)
    case requiresConsent(originalWidth: Int, originalHeight: Int, proposed: CompositionPlan)
}
public enum LayoutEngine {
    static func scaledHeight(_ crop: PixelCrop, width: Int) -> Int {
        let product = crop.height * width, quotient = product / crop.width, remainder = product % crop.width
        return max(1,quotient + (remainder * 2 >= crop.width ? 1 : 0))
    }
    public static func propose(taskID: UUID, revision: UInt64, inputs: [LayoutInput], kind: TaskKind = .collage,
                               widthMode: WidthMode = .standard, spacingPx: Int = 0,
                               background: CanvasBackground = .white) throws -> LayoutDecision {
        guard inputs.count >= (kind == .capture ? 1 : 2), inputs.count <= (kind == .capture ? 200 : 20),
              [0,8,16,24].contains(spacingPx), Set(inputs.map { $0.asset.id }).count == inputs.count else {
            throw ScrollStitchError.invalidSelection
        }
        for input in inputs {
            try input.asset.validate(); try input.crop.validate(in: input.asset.size)
            guard input.asset.size.pixels <= 48_000_000 else { throw ScrollStitchError.budgetExceeded }
        }
        let width = min(widthMode == .standard ? 1080 : 2160, inputs.map(\.crop.width).min()!)
        func height(_ w: Int) -> Int { inputs.reduce(0) { $0 + scaledHeight($1.crop,width:w) } + (inputs.count-1)*spacingPx }
        func fits(_ w: Int) -> Bool { height(w) <= 32_000 && w*height(w) <= 24_000_000 }
        func plan(_ w: Int, scaled: Bool) throws -> CompositionPlan {
            var y = 0
            let items = inputs.map { input -> PlacedImage in
                let h = scaledHeight(input.crop,width:w)
                defer { y += h + spacingPx }
                return PlacedImage(input:input,y:y,height:h)
            }
            let value = try CompositionPlan(taskID:taskID,revision:revision,kind:kind,items:items,
                size:PixelSize(width:w,height:height(w)),spacingPx:spacingPx,background:background,acceptedDownscale:scaled)
            try value.validate(); return value
        }
        if fits(width) { return .ready(try plan(width,scaled:false)) }
        var low = 1, high = width, best = 0
        while low <= high {
            let middle = low + (high-low)/2
            if fits(middle) { best = middle; low = middle+1 } else { high = middle-1 }
        }
        guard best >= 360 else { throw ScrollStitchError.budgetExceeded }
        return .requiresConsent(originalWidth:width,originalHeight:height(width),proposed:try plan(best,scaled:true))
    }
}

public extension LayoutEngine {
    static func inputs(for edit: EditSnapshot) throws -> [LayoutInput] {
        try edit.validate()
        guard edit.activeImport == nil, edit.unresolvedImports==0, (2...20).contains(edit.assets.count) else {
            throw ScrollStitchError.invalidSelection
        }
        return edit.assets.map { asset in
            let rect=edit.crop(for:asset)
            return LayoutInput(asset:asset,crop:PixelCrop(x:rect.x,y:rect.y,width:rect.width,height:rect.height))
        }
    }
}
