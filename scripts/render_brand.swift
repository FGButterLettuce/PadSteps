// Deterministic project-created vector artwork. Run on macOS: swift scripts/render_brand.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let forest = NSColor(srgbRed: 21/255, green: 61/255, blue: 50/255, alpha: 1)
let lime = NSColor(srgbRed: 214/255, green: 242/255, blue: 129/255, alpha: 1)
let paper = NSColor(srgbRed: 244/255, green: 242/255, blue: 235/255, alpha: 1)

func png(width: Int, height: Int, alpha: Bool, to path: String, draw: (CGContext) -> Void) throws {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Coordinates share the 160-unit SVG canvas, with an 18-unit mark inset.
func mark(_ ctx: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat) {
    ctx.saveGState(); ctx.translateBy(x: x, y: y); ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: 18, y: 18)
    ctx.setStrokeColor(lime.cgColor); ctx.setLineWidth(20)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 20, y: 88)); ctx.addLine(to: CGPoint(x: 20, y: 20))
    ctx.addLine(to: CGPoint(x: 62, y: 20))
    ctx.addCurve(to: CGPoint(x: 98, y: 54), control1: CGPoint(x: 84, y: 20), control2: CGPoint(x: 98, y: 34))
    ctx.addCurve(to: CGPoint(x: 62, y: 88), control1: CGPoint(x: 98, y: 74), control2: CGPoint(x: 84, y: 88))
    ctx.addLine(to: CGPoint(x: 44, y: 88)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 20, y: 114)); ctx.addLine(to: CGPoint(x: 44, y: 114)); ctx.strokePath()
    ctx.restoreGState()
}

let iconset = ".local/PadSteps.iconset"
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        try png(width: pixels, height: pixels, alpha: true,
            to: "\(iconset)/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png") { ctx in
            let w = CGFloat(pixels)
            ctx.setFillColor(forest.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: w*0.06, y: w*0.06, width: w*0.88, height: w*0.88),
                cornerWidth: w*0.2, cornerHeight: w*0.2, transform: nil)); ctx.fillPath()
            mark(ctx, x: w*0.06, y: w*0.94, scale: w*0.88/160)
        }
    }
}
let iconutil = Process(); iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "apps/macOS/Resources/AppIcon.icns"]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try png(width: 1024, height: 1024, alpha: false, to: "apps/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png") { ctx in
    ctx.setFillColor(forest.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    mark(ctx, x: 0, y: 1024, scale: 1024/160)
}

try png(width: 1280, height: 640, alpha: false, to: "assets/brand/github-hero.png") { ctx in
    ctx.setFillColor(forest.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 640))
    mark(ctx, x: 72, y: 582, scale: 0.62)
    func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
            .kern: size > 40 ? -2 : 0])
    }
    text("PadSteps", x: 205, y: 486, size: 60, color: paper, weight: .semibold)
    text("Your desk walk,", x: 84, y: 314, size: 76, color: paper, weight: .medium)
    text("counted.", x: 84, y: 221, size: 76, color: lime, weight: .medium)
    text("Sperax steps. Fitbit heart rate. Apple Health.", x: 88, y: 100, size: 25, color: paper, weight: .regular)
    ctx.saveGState(); ctx.translateBy(x: 896, y: 418); ctx.scaleBy(x: 1, y: -1)
    ctx.rotate(by: -.pi * 16 / 180)
    ctx.setStrokeColor(lime.cgColor); ctx.setLineWidth(2)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 12, y: 0, width: 204, height: 264), cornerWidth: 76, cornerHeight: 76, transform: nil)); ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 45, y: 33, width: 138, height: 198), cornerWidth: 48, cornerHeight: 48, transform: nil)); ctx.strokePath()
    ctx.setLineCap(.round); ctx.setLineWidth(17)
    for (x, y) in [(85.0,82.0),(69.0,122.0),(85.0,162.0)] {
        ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x+63, y: y)); ctx.strokePath()
    }
    ctx.restoreGState()
}
print("Rendered Mac icon, iPhone icon and 1280 × 640 GitHub/social header.")
