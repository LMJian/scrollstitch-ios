import Foundation
import ScrollStitchCore
import Darwin

// CLI fixture for actual process contention and crash tests; never included in either iOS target.
let args = CommandLine.arguments
guard args.count >= 4 else { exit(64) }
let root = URL(fileURLWithPath: args[1]), operation = args[2], signal = args[3]
do {
    if operation == "capture-capability" {
        let store=try TaskStore(root:root)
        do {
            let (task,owner)=try store.beginCapture()
            guard BuildMode.captureCreationEnabled,task.kind == .capture else {exit(70)}
            withExtendedLifetime(owner) {}
            print("capture enabled")
        } catch ScrollStitchError.invalidSelection {
            guard !BuildMode.captureCreationEnabled,try store.current()==nil else {exit(70)}
            print("capture excluded without creating a task")
        }
        exit(0)
    }
    if operation == "create" {
        let store = try TaskStore(root: root)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: signal) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard Date() < deadline else { exit(65) }
        _ = try store.createCollage()
        exit(0)
    }
    let point: StoreFaultPoint
    switch operation {
    case "crash-write": point = .afterAssetWrite
    case "crash-rename": point = .afterAssetRename
    case "crash-before": point = .beforeSnapshotReplace
    case "crash-after": point = .afterSnapshotReplace
    default: exit(64)
    }
    let store = try TaskStore(root: root) { observed in if observed == point { exit(73) } }
    let (task, owner) = try store.beginCapture()
    _ = try store.appendFrame(taskID: task.taskID, owner: owner, png: Data(contentsOf: URL(fileURLWithPath: signal)),
                              size: PixelSize(width: 20, height: 10), pts: 1)
    exit(66)
} catch ScrollStitchError.existingTask { exit(4) }
catch { exit(5) }
