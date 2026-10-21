import Foundation
import ImageIO
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public enum ImportFailure: String, Codable, Sendable { case unsupported, decode, unavailable, tooLarge }
public enum ImportState: Equatable, Sendable { case loading, ready(SourceAsset), failed(ImportFailure) }
public struct ImportSlot: Identifiable, Sendable {
    public let id: UUID
    public let selectionIdentifier: String?
    public var state: ImportState
    public init(id: UUID = UUID(), selectionIdentifier: String? = nil) {
        self.id = id; self.selectionIdentifier = selectionIdentifier; self.state = .loading
    }
}
public struct ImportBatch: Sendable {
    public let token: OperationToken
    public private(set) var slots: [ImportSlot] = []
    private var active = true
    public init(token: OperationToken, slots: [ImportSlot]) throws {
        self.token = token
        var identifiers = Set<String>(), ids = Set<UUID>()
        for slot in slots {
            guard ids.insert(slot.id).inserted else { throw ScrollStitchError.invalidSelection }
            if let identifier = slot.selectionIdentifier, !identifiers.insert(identifier).inserted { continue }
            self.slots.append(slot)
        }
        guard self.slots.count <= 20 else { throw ScrollStitchError.invalidSelection }
    }
    @discardableResult public mutating func resolve(id: UUID, state: ImportState, token: OperationToken) -> Bool {
        guard active, token == self.token, let index = slots.firstIndex(where: { $0.id == id }) else { return false }
        slots[index].state = state; return true
    }
    public mutating func remove(id: UUID) { slots.removeAll { $0.id == id } }
    public mutating func cancel() { active = false }
    public var readyAssets: [SourceAsset]? {
        guard active, (2...20).contains(slots.count) else { return nil }
        var assets: [SourceAsset] = []
        for slot in slots {
            guard case .ready(let asset) = slot.state else { return nil }
            assets.append(asset)
        }
        return assets
    }
}
public struct ImageInfo: Sendable {
    public let size: PixelSize
    public let orientation: Int
    public let typeIdentifier: String
}
public enum ImageImporter {
    public static func inspect(_ url: URL) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg","public.png","public.heic","public.heif"].contains(type),
              CGImageSourceGetCount(source) == 1 else { throw ScrollStitchError.unsupportedInput }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ScrollStitchError.corruptData
        }
        let raw = try PixelSize(width:w,height:h)
        guard raw.pixels <= 48_000_000 else { throw ScrollStitchError.budgetExceeded }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation),
              CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                  kCGImageSourceThumbnailMaxPixelSize:64,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) != nil else {
            throw ScrollStitchError.corruptData
        }
        return try ImageInfo(size:PixelSize(width:orientation >= 5 ? h : w,height:orientation >= 5 ? w : h),
                             orientation:orientation,typeIdentifier:type)
    }
    public static func ingest(_ url: URL, store: TaskStore, taskID: UUID) throws -> SourceAsset {
        let info = try inspect(url)
        return try store.importAsset(from:url,taskID:taskID,size:info.size)
    }
}
