// Import the user-approved artwork without changing its pixels or encoding.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/Branding/AppIcon.png")
let checkOnly = CommandLine.arguments.dropFirst() == ["--check"]
let output = CommandLine.arguments.count > 1 && !checkOnly
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let data = try Data(contentsOf: source)
guard let input = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(input) as String? == UTType.png.identifier,
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
      image.width == 1024, image.height == 1024, image.bitsPerComponent == 8,
      image.colorSpace?.model == .rgb,
      [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
    fatalError("App icon source must be an opaque 1024x1024 RGB PNG")
}
if checkOnly {
    guard try Data(contentsOf: output) == data else {
        fatalError("App icon differs from the approved source; run swift scripts/generate_icon.swift")
    }
    print("PASS: AppIcon matches the approved opaque 1024px PNG exactly")
} else {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: output, options: .atomic)
    print("Imported approved opaque 1024px AppIcon without modification")
}
