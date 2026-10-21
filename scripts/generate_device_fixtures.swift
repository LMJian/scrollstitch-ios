// Self-authored synthetic test material, never private photos. Run on macOS.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import CryptoKit

let arguments = CommandLine.arguments
precondition(arguments.count == 2, "Usage: swift scripts/generate_device_fixtures.swift OUTPUT_DIRECTORY")
let root = URL(fileURLWithPath:arguments[1],isDirectory:true)
precondition(!FileManager.default.fileExists(atPath:root.path), "Refuse to overwrite existing material")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var items: [[String:Any]] = []
for index in 0..<20 {
    let width = index == 19 ? 200 : 640, height = 480 + (index%3)*80
    let format = ["png","jpeg","heic"][index%3]
    let orientation = index == 1 ? 6 : 1
    let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    if index != 0 {
        context.setFillColor(CGColor(red:CGFloat(index%5)/5,green:0.35,blue:CGFloat(index%7)/7,alpha:1))
        context.fill(CGRect(x:0,y:0,width:width,height:height))
    }
    for row in 0..<12 {
        context.setFillColor(CGColor(red:CGFloat((index*31+row*17)%255)/255,green:CGFloat(row)/12,blue:0.8,alpha:1))
        context.fill(CGRect(x:0,y:row*(height/12),width:width/3,height:height/12))
    }
    context.textPosition = CGPoint(x:CGFloat(width)/3+12,y:CGFloat(height)/2)
    let text = NSAttributedString(string:String(format:"ID %02d",index+1),attributes:[
        NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica-Bold" as CFString,36,nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
    CTLineDraw(CTLineCreateWithAttributedString(text),context)
    let url = root.appendingPathComponent(String(format:"image-%02d.%@",index+1,format))
    guard let writer = CGImageDestinationCreateWithURL(url as CFURL,("public."+format) as CFString,1,nil) else {
        fatalError("ImageIO cannot create \(format); report this as a fixture blocker")
    }
    CGImageDestinationAddImage(writer,context.makeImage()!,[kCGImagePropertyOrientation:orientation,kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
    precondition(CGImageDestinationFinalize(writer),"Fixture encoding failed")
    let data = try Data(contentsOf:url)
    let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
    precondition(CGImageSourceCreateImageAtIndex(source,0,nil) != nil,"Fixture readback failed")
    items.append(["file":url.lastPathComponent,"selection_label":index+1,"orientation":orientation,
        "oriented_width":orientation == 6 ? height : width,"oriented_height":orientation == 6 ? width : height,
        "sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()])
}
let cases = [
    ("01-continuous","慢速向下，每次约四分之一屏", ""),
    ("02-half-screen","向下每次约半屏", ""),
    ("03-slow","极慢向下，包含重复帧", ""),
    ("04-duplicate","停留同屏5秒再向下", ""),
    ("05-similar","观察重复纹理，不能凭相似自动删正文", "repeat"),
    ("06-gap","快速跳过两屏，缺口必须待确认", ""),
    ("07-reverse","向下两屏后反向一屏，再向下", ""),
    ("08-black","黑色无纹理页，单帧或待确认，不能伪造长图", "black"),
    ("09-white","白色无纹理页，单帧或待确认，不能伪造长图", "white"),
    ("10-overlay","滚动时切换测试浮层，不使用私人通知", "overlay"),
    ("11-fixed","存在固定顶栏，记录待确认与误接受", "fixed"),
    ("12-dynamic","动态测试块变化，不能错误高置信度拼接", "dynamic")
]
var links: [String] = []
for (name,instruction,kind) in cases {
    let rows = (0..<160).map { row -> String in
        let label = kind == "repeat" ? "SAME ROW" : String(format:"ROW %03d • %08X",row,UInt32(row) &* 2654435761)
        let color = kind == "repeat" ? "#d9e9ed" : "hsl(\(row*137%360),55%,85%)"
        return "<div class='row' style='background:\(color)'>\(label)<span>┃┃┃┃┃┃┃┃┃┃</span></div>"
    }.joined(separator:"\n")
    let overlay = kind == "overlay" ? "<button onclick=\"document.querySelector('aside').hidden=!document.querySelector('aside').hidden\">测试浮层</button><aside hidden>仅测试遮挡</aside>" : ""
    let fixed = kind == "fixed" ? "<header>固定测试顶栏</header>" : ""
    let dynamic = kind == "dynamic" ? "<aside id='dynamic'></aside><script>setInterval(()=>document.getElementById('dynamic').textContent=Date.now(),250)</script>" : ""
    let content = (kind == "black" || kind == "white") ? "<div style='height:16000px;background:\(kind)'></div>" : rows
    let html = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(name)</title>
    <style>body{margin:0;font-family:monospace} .row{height:100px;box-sizing:border-box;border-bottom:2px solid #111;padding:10px;font-size:18px;overflow:hidden}.row span{display:block;letter-spacing:3px}header,button{position:fixed;top:0;left:0;right:0;background:#333;color:white;padding:20px;z-index:2}aside{position:fixed;top:30%;right:0;background:#f08;padding:40px;z-index:2}</style>
    <!-- Test instruction: \(instruction). Browser chrome is a real device variable; record it. -->
    \(fixed)\(overlay)\(dynamic)\(content)</html>
    """
    try html.write(to:root.appendingPathComponent(name+".html"),atomically:true,encoding:.utf8)
    links.append("<li><a href='\(name).html'>\(name)</a>：\(instruction)</li>")
}
try ("<!doctype html><meta charset='utf-8'><h1>M0 自制测试页</h1><p>每组采集5–15屏；记录行号、实际滚动及系统固定栏。这里是测试输入，不是通过报告。</p><ol>"+links.joined()+"</ol>").write(to:root.appendingPathComponent("index.html"),atomically:true,encoding:.utf8)
let manifest: [String:Any] = ["schema_version":1,"images":items,"source":"self-authored synthetic fixtures",
    "selection_order_1based":[20,1,19,2,18,3,17,4,16,5,15,6,14,7,13,8,12,9,11,10],
    "purpose":"DV-05/06 inputs, no device execution claimed; 48MP stress fixtures must be separately recorded"]
try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("manifest.json"))
print("Created and decoded 20 PNG/JPEG/HEIC images; 12 device pages; manifest with per-image SHA256. No device test executed.")
