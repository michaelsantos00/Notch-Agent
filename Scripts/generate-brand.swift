#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText

// Run from the repository root. All artwork is drawn locally; no network,
// downloaded fonts, or image-generation service is involved.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Brand/NotchAgent")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let ink = NSColor(calibratedWhite: 0.055, alpha: 1)
let paper = NSColor(calibratedWhite: 0.97, alpha: 1)
let markData = "M56 128H456C420 128 408 146 408 180V276C408 338 358 384 296 384H216C154 384 104 338 104 276V180C104 146 92 128 56 128Z"
let holeData = [200, 256, 312].map { x in
    "M\(x-16) 256a16 16 0 1 0 32 0a16 16 0 1 0 -32 0Z"
}.joined(separator: " ")

func markPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 56, y: 128))
    p.addLine(to: CGPoint(x: 456, y: 128))
    p.addCurve(to: CGPoint(x: 408, y: 180), control1: CGPoint(x: 420, y: 128), control2: CGPoint(x: 408, y: 146))
    p.addLine(to: CGPoint(x: 408, y: 276))
    p.addCurve(to: CGPoint(x: 296, y: 384), control1: CGPoint(x: 408, y: 338), control2: CGPoint(x: 358, y: 384))
    p.addLine(to: CGPoint(x: 216, y: 384))
    p.addCurve(to: CGPoint(x: 104, y: 276), control1: CGPoint(x: 154, y: 384), control2: CGPoint(x: 104, y: 338))
    p.addLine(to: CGPoint(x: 104, y: 180))
    p.addCurve(to: CGPoint(x: 56, y: 128), control1: CGPoint(x: 104, y: 146), control2: CGPoint(x: 92, y: 128))
    p.closeSubpath()
    return p
}

func drawMark(_ c: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat,
              color: NSColor, cutout: NSColor? = nil, quiet: Bool = false) {
    c.saveGState()
    c.translateBy(x: x, y: y)
    c.scaleBy(x: scale, y: scale)
    c.setFillColor(color.cgColor)
    c.addPath(markPath())
    c.fillPath()
    if let cutout { c.setFillColor(cutout.cgColor) }
    else { c.setBlendMode(.clear) }
    if quiet {
        c.addPath(CGPath(roundedRect: CGRect(x: 184, y: 240, width: 144, height: 32),
                         cornerWidth: 16, cornerHeight: 16, transform: nil))
        c.fillPath()
    } else {
        for dot in [CGFloat(200), 256, 312] {
            c.fillEllipse(in: CGRect(x: dot - 16, y: 240, width: 32, height: 32))
        }
    }
    c.restoreGState()
}

func png(_ url: URL, width: Int, height: Int, draw: (CGContext) -> Void) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 1, y: -1)
    draw(c)
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func drawIcon(_ c: CGContext, size: CGFloat, inverse: Bool = false, quiet: Bool = false) {
    c.saveGState()
    c.scaleBy(x: size / 1024, y: size / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                      cornerWidth: 200, cornerHeight: 200, transform: nil)
    c.setShadow(offset: CGSize(width: 0, height: 8), blur: 18,
                color: NSColor.black.withAlphaComponent(0.15).cgColor)
    c.setFillColor((inverse ? ink : paper).cgColor)
    c.addPath(tile)
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0)
    drawMark(c, x: 128, y: 128, scale: 1.5,
             color: inverse ? paper : ink, cutout: inverse ? ink : paper, quiet: quiet)
    c.restoreGState()
}

func label(_ text: String, at: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
    ]
    (text as NSString).draw(at: at, withAttributes: attributes)
}

func withAppKit(_ c: CGContext, height: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

for (name, inverse, quiet) in [("signal", false, false), ("inverse", true, false), ("quiet", false, true)] {
    try png(output.appendingPathComponent("icon-\(name).png"), width: 1024, height: 1024) {
        drawIcon($0, size: 1024, inverse: inverse, quiet: quiet)
    }
}

// Portable vector masters, with genuine cutouts for template rendering.
for (name, fill) in [("mark-black", "#0e0e0e"), ("mark-white", "#f7f7f7")] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="NotchAgent mark">
      <path fill="\(fill)" fill-rule="evenodd" d="\(markData) \(holeData)"/>
    </svg>
    """
    try svg.write(to: output.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
}
try png(output.appendingPathComponent("mark-black.png"), width: 1024, height: 1024) {
    drawMark($0, x: 0, y: 0, scale: 2, color: ink)
}
try png(output.appendingPathComponent("mark-white.png"), width: 1024, height: 1024) {
    drawMark($0, x: 0, y: 0, scale: 2, color: paper)
}

// Outlined wordmarks contain no font dependency.
func svgPath(_ path: CGPath) -> String {
    var data = ""
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        func point(_ i: Int) -> String { "\(e.points[i].x) \(e.points[i].y)" }
        switch e.type {
        case .moveToPoint: data += "M" + point(0)
        case .addLineToPoint: data += "L" + point(0)
        case .addQuadCurveToPoint: data += "Q" + point(0) + " " + point(1)
        case .addCurveToPoint: data += "C" + point(0) + " " + point(1) + " " + point(2)
        case .closeSubpath: data += "Z"
        @unknown default: break
        }
    }
    return data
}
let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 72, nil)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "NotchAgent", attributes: [.font: font]))
var letters = ""
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    for i in 0..<count {
        if let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
            letters += "<path transform=\"translate(\(positions[i].x) \(positions[i].y))\" d=\"\(svgPath(path))\"/>"
        }
    }
}
for (name, fill) in [("wordmark-black", "#0e0e0e"), ("wordmark-white", "#f7f7f7")] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 540 120" role="img" aria-label="NotchAgent">
      <g transform="translate(0 0) scale(.234375)" fill="\(fill)"><path fill-rule="evenodd" d="\(markData) \(holeData)"/></g>
      <g transform="translate(132 83) scale(1 -1)" fill="\(fill)">\(letters)</g>
    </svg>
    """
    try svg.write(to: output.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
}

try png(output.appendingPathComponent("brand-board.png"), width: 1600, height: 1000) { c in
    c.setFillColor(NSColor(calibratedWhite: 0.93, alpha: 1).cgColor)
    c.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
    withAppKit(c, height: 1000) {
        label("NotchAgent", at: CGPoint(x: 80, y: 70), size: 64, color: ink, weight: .semibold)
        label("MONOCHROME / AGENT ACTIVITY AT A GLANCE", at: CGPoint(x: 84, y: 150), size: 17, color: .darkGray)
    }
    for (i, name) in ["signal", "inverse", "quiet"].enumerated() {
        let x = CGFloat(70 + i * 510)
        c.saveGState()
        c.translateBy(x: x, y: 210)
        drawIcon(c, size: 450, inverse: i == 1, quiet: i == 2)
        c.restoreGState()
        withAppKit(c, height: 1000) {
            label(name.capitalized, at: CGPoint(x: x + 30, y: 690), size: 27, color: ink, weight: .medium)
        }
    }
    c.setFillColor(ink.cgColor)
    c.fill(CGRect(x: 80, y: 780, width: 1440, height: 150))
    drawMark(c, x: 104, y: 794, scale: 0.234375, color: paper, cutout: ink)
    withAppKit(c, height: 1000) {
        label("NotchAgent", at: CGPoint(x: 238, y: 810), size: 54, color: paper, weight: .semibold)
        label("Private by design. Present at a glance.", at: CGPoint(x: 700, y: 834), size: 25, color: paper)
    }
}

try png(output.appendingPathComponent("banner.png"), width: 1600, height: 600) { c in
    c.setFillColor(ink.cgColor)
    c.fill(CGRect(x: 0, y: 0, width: 1600, height: 600))
    drawMark(c, x: 86, y: 90, scale: 0.82, color: paper, cutout: ink)
    withAppKit(c, height: 600) {
        label("NotchAgent", at: CGPoint(x: 570, y: 196), size: 100, color: paper, weight: .semibold)
        label("Your agents. Your limits. One notch.", at: CGPoint(x: 578, y: 330), size: 30,
              color: NSColor(calibratedWhite: 0.67, alpha: 1))
    }
}

// Installation is explicit: generate previews first; pass --install to apply Inverse.
if CommandLine.arguments.contains("--install") {
    let catalog = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
    let sizes: [(String, Int)] = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),
        ("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)]
    for (name, size) in sizes {
        try png(catalog.appendingPathComponent("icon_\(name).png"), width: size, height: size) {
            drawIcon($0, size: CGFloat(size), inverse: true)
        }
    }
    let windows = root.appendingPathComponent("windows/codenotch/icons")
    for (name, size) in [("32x32.png",32),("128x128.png",128),("128x128@2x.png",256),
                         ("icon.png",1024),("tray-color.png",32)] {
        try png(windows.appendingPathComponent(name), width: size, height: size) {
            drawIcon($0, size: CGFloat(size), inverse: true)
        }
    }
    try png(windows.appendingPathComponent("tray.png"), width: 32, height: 32) {
        drawMark($0, x: 0, y: 0, scale: 0.0625, color: ink)
    }
    try FileManager.default.removeItem(at: root.appendingPathComponent("windows/codenotch/ui/tray.png"))
    try FileManager.default.copyItem(at: windows.appendingPathComponent("tray-color.png"),
                                    to: root.appendingPathComponent("windows/codenotch/ui/tray.png"))
    // ICO supports PNG frames on current Windows; no third-party encoder needed.
    var ico = Data()
    func little(_ value: Int, bytes: Int) {
        for shift in 0..<bytes { ico.append(UInt8((value >> (shift * 8)) & 255)) }
    }
    little(0, bytes: 2); little(1, bytes: 2); little(4, bytes: 2)
    let frames = [(16,"icon_16x16.png"),(32,"icon_32x32.png"),
                  (128,"icon_128x128.png"),(256,"icon_256x256.png")]
    var payloads: [Data] = []
    var offset = 6 + frames.count * 16
    for (size, name) in frames {
        let data = try Data(contentsOf: catalog.appendingPathComponent(name))
        little(size == 256 ? 0 : size, bytes: 1)
        little(size == 256 ? 0 : size, bytes: 1)
        little(0, bytes: 1); little(0, bytes: 1)
        little(1, bytes: 2); little(32, bytes: 2)
        little(data.count, bytes: 4); little(offset, bytes: 4)
        payloads.append(data); offset += data.count
    }
    for data in payloads { ico.append(data) }
    try ico.write(to: windows.appendingPathComponent("icon.ico"))
    let menu = root.appendingPathComponent("Sources/Assets.xcassets/MenuBarIcon.imageset")
    let svg = try String(contentsOf: output.appendingPathComponent("mark-black.svg"), encoding: .utf8)
    // Use a square viewBox: StatusItemController sizes template icons to 18×18.
    try svg.replacingOccurrences(of: "0 0 512 512", with: "48 48 416 416")
        .write(to: menu.appendingPathComponent("menubar-notchagent.svg"), atomically: true, encoding: .utf8)
}
print("Generated monochrome NotchAgent assets at \(output.path)")
