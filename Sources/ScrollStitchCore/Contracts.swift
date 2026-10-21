import Foundation

public enum ScrollStitchError: Error, Equatable, Sendable {
    case invalidDimensions, invalidPath, unsupportedSchema, corruptData
    case existingTask, noTask, wrongTask, revisionConflict, staleOperation
    case captureActive, resourceBusy, storageFailure, unsupportedInput
    case invalidSelection, budgetExceeded, cancelled, unresolvedSeams
}

public struct PixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: Int { width * height }
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 1_000_000, height <= 1_000_000,
              !width.multipliedReportingOverflow(by: height).overflow else {
            throw ScrollStitchError.invalidDimensions
        }
        self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
    }
}

public struct AssetPath: Codable, Hashable, Sendable {
    public let value: String
    public init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/").contains($0) }) else {
            throw ScrollStitchError.invalidPath
        }
        self.value = value
    }
    public func resolved(in root: URL) throws -> URL {
        let base = root.standardizedFileURL
        guard base.resolvingSymlinksInPath().path == base.path else { throw ScrollStitchError.invalidPath }
        var cursor = base
        for part in value.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            guard cursor.resolvingSymlinksInPath().path == cursor.standardizedFileURL.path else {
                throw ScrollStitchError.invalidPath
            }
        }
        return cursor
    }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(value)
    }
}

public enum TaskKind: String, Codable, Sendable { case capture, collage }
public enum CapturePhase: String, Codable, Sendable { case capturing, ended, interrupted, reconciling }
public enum CaptureEndReason: String, Codable, Sendable {
    case userStopped, paused, sizeChanged, timeBudget, frameBudget, storageBudget, memoryPressure, writeFailure, ownerLost, unknown
}
public enum WidthMode: String, Codable, Sendable { case standard, original }
public enum CanvasBackground: String, Codable, Sendable { case white, black }

public struct SourceAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let path: AssetPath
    public let size: PixelSize
    public let sha256: String
    public init(id: UUID = UUID(), path: AssetPath, size: PixelSize, sha256: String) {
        self.id = id; self.path = path; self.size = size; self.sha256 = sha256
    }
    public func validate() throws {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }), path.value.hasPrefix("assets/") else {
            throw ScrollStitchError.corruptData
        }
    }
}

public struct FrameRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { asset.id }
    public let asset: SourceAsset
    public let ordinal: Int
    public let monotonicPTS: Double
    public let orientation: Int
    public init(asset: SourceAsset, ordinal: Int, monotonicPTS: Double, orientation: Int = 1) {
        self.asset = asset; self.ordinal = ordinal; self.monotonicPTS = monotonicPTS; self.orientation = orientation
    }
}

public struct CaptureSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let taskID: UUID
    public let generation: UUID
    public var sequence: UInt64 = 0
    public let startedAt: Date
    public var lastFrameAt: Date?
    public var frames: [FrameRecord] = []
    public var phase: CapturePhase = .capturing
    public var endReason: CaptureEndReason?
    public init(taskID: UUID, startedAt: Date) {
        self.taskID = taskID; self.generation = UUID(); self.startedAt = startedAt
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ScrollStitchError.unsupportedSchema }
        guard frames.count <= 4000, Set(frames.map(\.id)).count == frames.count else { throw ScrollStitchError.corruptData }
        for (i, frame) in frames.enumerated() {
            try frame.asset.validate()
            guard frame.ordinal == i, frame.monotonicPTS.isFinite, frame.monotonicPTS >= 0,
                  (1...8).contains(frame.orientation),
                  i == 0 || frame.monotonicPTS >= frames[i-1].monotonicPTS else { throw ScrollStitchError.corruptData }
        }
        guard (phase == .capturing || phase == .reconciling) ? endReason == nil : endReason != nil else {
            throw ScrollStitchError.corruptData
        }
    }
}

public enum ImportIssue: String, Codable, Sendable { case loading, unavailable, unsupported, tooLarge, cancelled }
public struct ImportRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let selectionIdentifier: String?
    public var asset: SourceAsset?
    public var issue: ImportIssue?
    public init(id: UUID = UUID(), selectionIdentifier: String? = nil) {
        self.id = id; self.selectionIdentifier = selectionIdentifier; self.issue = .loading
    }
}

public struct EditSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let taskID: UUID
    public var revision: UInt64
    public var assets: [SourceAsset]
    public var imports: [ImportRecord]
    public var crops: [AssetCropRecord] = []
    public var undo: EditUndo?
    public var activeImport: ImportBatchState?
    public var committedAt: Date?
    public var unresolvedImports: Int { imports.filter { $0.asset == nil }.count }
    public var spacingPx: Int
    public var background: CanvasBackground
    public var widthMode: WidthMode
    public init(taskID: UUID, revision: UInt64 = 0, assets: [SourceAsset] = [],
                spacingPx: Int = 0, background: CanvasBackground = .white, widthMode: WidthMode = .standard) {
        self.taskID = taskID; self.revision = revision; self.assets = assets; self.imports = []
        self.spacingPx = spacingPx; self.background = background; self.widthMode = widthMode
    }
    public func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw ScrollStitchError.unsupportedSchema }
        try payload.validate()
        if schemaVersion == 1 {
            guard crops.isEmpty, undo == nil, activeImport == nil, committedAt == nil else { throw ScrollStitchError.corruptData }
        } else {
            guard imports.compactMap(\.asset)==assets, let committedAt, committedAt.timeIntervalSince1970.isFinite else { throw ScrollStitchError.corruptData }
        }
        if let undo { try undo.payload.validate() }
        if let batch=activeImport {
            guard !batch.itemIDs.isEmpty, Set(batch.itemIDs).count==batch.itemIDs.count,
                  batch.itemIDs.allSatisfy({ id in imports.contains(where:{$0.id==id}) }) else { throw ScrollStitchError.corruptData }
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, taskID, revision, assets, imports, spacingPx, background, widthMode, crops, undo, activeImport, committedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey:.schemaVersion)
        taskID = try c.decode(UUID.self, forKey:.taskID)
        revision = try c.decode(UInt64.self, forKey:.revision)
        assets = try c.decode([SourceAsset].self, forKey:.assets)
        imports = try c.decodeIfPresent([ImportRecord].self, forKey:.imports) ?? []
        spacingPx = try c.decode(Int.self, forKey:.spacingPx)
        background = try c.decode(CanvasBackground.self, forKey:.background)
        widthMode = try c.decode(WidthMode.self, forKey:.widthMode)
        crops = schemaVersion == 2 ? try c.decode([AssetCropRecord].self,forKey:.crops) : (try c.decodeIfPresent([AssetCropRecord].self,forKey:.crops) ?? [])
        undo = try c.decodeIfPresent(EditUndo.self,forKey:.undo)
        activeImport = try c.decodeIfPresent(ImportBatchState.self,forKey:.activeImport)
        committedAt = try c.decodeIfPresent(Date.self,forKey:.committedAt)
    }
}

public struct TaskManifest: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let taskID: UUID
    public let kind: TaskKind
    public var lastInteractionAt: Date
    public var pendingCleanup = false
    public var deleting = false
    public init(taskID: UUID = UUID(), kind: TaskKind, now: Date) {
        self.taskID = taskID; self.kind = kind; self.lastInteractionAt = now
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ScrollStitchError.unsupportedSchema }
    }
}

public struct OperationToken: Equatable, Sendable {
    public let taskID: UUID
    public let revision: UInt64
    public let operationID: UUID
    public init(taskID: UUID, revision: UInt64, operationID: UUID = UUID()) {
        self.taskID = taskID; self.revision = revision; self.operationID = operationID
    }
}

/// Value gate owned by the caller's actor, never a cross-process lock.
public struct OperationGate: Sendable {
    public private(set) var current: OperationToken?
    public init() {}
    public mutating func begin(taskID: UUID, revision: UInt64) -> OperationToken {
        let token = OperationToken(taskID: taskID, revision: revision)
        current = token; return token
    }
    public func accepts(_ token: OperationToken) -> Bool { current == token }
    public mutating func invalidate() { current = nil }
}
