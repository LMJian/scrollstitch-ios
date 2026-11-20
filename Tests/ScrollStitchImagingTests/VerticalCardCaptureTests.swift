import XCTest
import CoreGraphics
import CoreText
import ImageIO
import ScrollStitchCore
@testable import ScrollStitchImaging

final class VerticalCardCaptureTests: XCTestCase {
    func testPastelCardsPreserveEveryRow() async throws {
        let scale = 3
        let width = 402 * scale, height = 874 * scale, header = 160 * scale, footer = 20 * scale
        let rowHeight = 140 * scale, rowCount = 36
        let bodyHeight = rowHeight * rowCount
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let body = try XCTUnwrap(CGContext(data: nil, width: width, height: bodyHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors: [[CGFloat]] = [
            [0.95, 0.7125, 0.7125], [0.95, 0.83125, 0.7125], [0.95, 0.95, 0.7125],
            [0.83125, 0.95, 0.7125], [0.7125, 0.95, 0.7125], [0.7125, 0.95, 0.83125],
            [0.7125, 0.95, 0.95], [0.7125, 0.83125, 0.95], [0.7125, 0.7125, 0.95],
            [0.83125, 0.7125, 0.95], [0.95, 0.7125, 0.95], [0.95, 0.7125, 0.83125]
        ]
        for row in 0..<rowCount {
            let color = colors[row % colors.count]
            let bottom = bodyHeight - (row + 1) * rowHeight
            body.setFillColor(CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1))
            body.fill(CGRect(x: 0, y: bottom, width: width, height: rowHeight))
            for (text, x, size) in [(String(format: "ROW %03d", row), 24, 28), ("CAPTURE CONTENT", 225, 14)] {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size * scale), nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]
                body.textPosition = CGPoint(x: x * scale, y: bottom + 60 * scale)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), body)
            }
        }
        let bodyImage = try XCTUnwrap(body.makeImage())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskStore(root: root)
        let viewportHeight = height - header - footer
        let end = bodyHeight - viewportHeight
        let offsets = Array(Set(stride(from: 0, to: end, by: 270 * scale).flatMap { start in
            [0, 17, 73, 169, 246].map { min(end, start + $0 * scale) }
        } + [end])).sorted()
        let taskID: UUID
        do {
            let pair = try store.beginCapture()
            taskID = pair.0.taskID
            let archive = try ScrollFrameArchive(store: store, taskID: pair.0.taskID, owner: pair.1,
                options: ScrollCaptureOptions(keepsStatusBar: true), topCropRatio: 0.075)
            for (index, offset) in offsets.enumerated() {
                let frame = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                frame.setFillColor(CGColor(gray: 0.96, alpha: 1))
                frame.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let view = try XCTUnwrap(bodyImage.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewportHeight)))
                frame.draw(view, in: CGRect(x: 0, y: footer, width: width, height: viewportHeight))
                let data = NSMutableData()
                let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
                CGImageDestinationAddImage(writer, try XCTUnwrap(frame.makeImage()),
                    [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(writer))
                XCTAssertTrue(try archive.append(jpeg: data as Data, size: PixelSize(width: width, height: height), pts: Double(index) * 0.3))
            }
            try archive.finish(complete: true)
        }
        let processing = try await CapturePipeline.run(store: store, taskID: taskID,
            selectionFingerprint: String(repeating: "b", count: 64))
        let result = processing.result
        XCTAssertEqual(result.status, .complete)
        let page = try XCTUnwrap(result.pages.first)
        let image = try ImageDecoder.normalized(page.result.path.resolved(in: store.taskDirectory(taskID)))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, bodyHeight + header + footer)
        let actual = try FrameRaster(image: image)
        let expected = try FrameRaster(image: bodyImage)
        guard image.height == bodyHeight + header + footer else { return }
        // Compare every body's decoded pixel against an independent source canvas.
        // JPEG rounding is tolerated, but shifting, duplicating or omitting a card is not.
        for row in 0..<rowCount {
            var difference = 0
            for y in (row * rowHeight)..<((row + 1) * rowHeight) {
                for x in 0..<width {
                    let a = ((header + y) * width + x) * 4
                    let e = (y * width + x) * 4
                    for channel in 0..<3 {
                        difference += abs(Int(actual.rgba[a + channel]) - Int(expected.rgba[e + channel]))
                    }
                }
            }
            XCTAssertLessThan(Double(difference) / Double(rowHeight * width * 3), 2.5, "ROW \(row) pixels differ")
            let label = CGRect(x: 24 * scale, y: row * rowHeight + 40 * scale,
                width: 176 * scale, height: 60 * scale)
            let sourceLabel = try FrameRaster(image: XCTUnwrap(bodyImage.cropping(to: label)))
            let outputLabel = try FrameRaster(image: XCTUnwrap(image.cropping(to: label.offsetBy(dx: 0, dy: CGFloat(header)))))
            let labelDifference = zip(sourceLabel.rgba, outputLabel.rgba).reduce(0) {
                $0 + abs(Int($1.0) - Int($1.1))
            }
            XCTAssertLessThan(Double(labelDifference) / Double(sourceLabel.rgba.count), 2.5, "ROW \(row) label differs")
        }
        if ProcessInfo.processInfo.environment["SCROLLSTITCH_CAPTURE_METRICS"] == "1",
           let metricsPath = ProcessInfo.processInfo.environment["HARNESS_METRICS_FILE"] {
            let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                store.taskDirectory(taskID).appendingPathComponent("capture-analysis.json"))) as? [String: Any])
            let candidates = try XCTUnwrap(diagnostic["refinedCandidates"] as? Int)
            let metrics: [String: Any] = [
                "workload": ["frames": offsets.count, "rows": rowCount, "output_pixels": image.width * image.height],
                "measurements": [
                    "capture.refinement_windows": ["value": candidates, "unit": "windows"],
                    "capture.processing_seconds": ["value": processing.seconds, "unit": "seconds"]
                ]
            ]
            try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: metricsPath), options: .atomic)
        }
    }
}
