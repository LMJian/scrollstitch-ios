import Foundation

public struct ScrollCaptureOptions: Codable, Equatable, Sendable {
    public var axis: ScrollAxis
    public var keepsStatusBar: Bool
    public init(axis: ScrollAxis = .vertical, keepsStatusBar: Bool = false) {
        self.axis = axis; self.keepsStatusBar = keepsStatusBar
    }
}

/// Immutable capture choices and explicit page boundaries. Pixels and PTS live
/// in the TaskStore snapshot; caches are never authoritative inputs.
public struct ScrollFrameInput: Codable, Equatable, Sendable {
    public var version = 1
    public let options: ScrollCaptureOptions
    public let topCropRatio: Double
    public var segmentStarts: [Int] = [0]
    public var complete = false
    public init(options: ScrollCaptureOptions, topCropRatio: Double) throws {
        self.options = options; self.topCropRatio = topCropRatio
        try validate(frameCount: 0)
    }
    public func validate(frameCount: Int) throws {
        guard version == 1 else { throw ScrollStitchError.unsupportedSchema }
        guard topCropRatio.isFinite, (0...0.2).contains(topCropRatio),
              segmentStarts.first == 0, segmentStarts.count <= 512,
              segmentStarts == Array(Set(segmentStarts)).sorted(),
              segmentStarts.allSatisfy({ $0 >= 0 && $0 <= frameCount }) else {
            throw ScrollStitchError.corruptData
        }
    }
}
