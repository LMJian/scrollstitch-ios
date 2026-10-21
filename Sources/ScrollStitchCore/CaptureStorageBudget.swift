import Foundation

/// Shared local storage limits; independent of the capture backend.
public enum CaptureStorageBudget {
    public static let taskBudget=1536*1024*1024
    // Leave room for one maximum-size image and file transactions after capture.
    public static let materialBudget=1024*1024*1024
    public static let captureBudget=materialBudget-1024*1024
    public static let chunkReserve=8*1024*1024
    public static func diskBytes(in directory:URL) throws -> Int {
        let keys:[URLResourceKey]=[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]
        guard let files=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:keys) else { throw ScrollStitchError.storageFailure }
        var result=0
        for case let file as URL in files {
            let values=try file.resourceValues(forKeys:Set(keys))
            guard values.isSymbolicLink != true else { throw ScrollStitchError.invalidPath }
            if values.isRegularFile == true { result+=values.fileSize ?? 0 }
        }
        return result
    }
}
