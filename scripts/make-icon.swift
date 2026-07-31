// Generates the Markdown app icon: an indigo gradient tile with a white
// document carrying the markdown "M↓" monogram. Outputs:
//   assets/icon.png          (1024x1024, app icon source -> AppIcon.icns)
//   assets/markdown.icns     (document-type icon for .md files)
//
// Run: swift scripts/make-icon.swift
import AppKit

let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

// ---- Tile: rounded rect with an indigo gradient (accent #432dd7 family).
let tileRect = NSRect(x: 0, y: 0, width: side, height: side)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
tile.addClip()
let gradient = NSGradient(colors: [
    color(108, 93, 245),
    color(80, 60, 224),
    color(58, 39, 190),
])!
gradient.draw(in: tileRect, angle: -90)

// Soft top-left sheen so the tile reads as glass, not flat paint.
let sheen = NSBezierPath(ovalIn: NSRect(x: -260, y: 430, width: 1150, height: 1150))
color(255, 255, 255).withAlphaComponent(0.14).setFill()
sheen.fill()

// ---- Document: white rounded sheet with a folded top-right corner.
let doc = NSBezierPath()
let dx: CGFloat = 232
let dy: CGFloat = 250
let fold = 118
doc.move(to: NSPoint(x: dx, y: dy + 44))
doc.line(to: NSPoint(x: dx, y: 1024 - dy - 44))
doc.line(to: NSPoint(x: 1024 - dx - CGFloat(fold), y: 1024 - dy))
doc.line(to: NSPoint(x: 1024 - dx, y: 1024 - dy - CGFloat(fold)))
doc.line(to: NSPoint(x: 1024 - dx, y: dy + 44))
doc.close()
// rounded bottom corners via manual arcs (top-right fold is already angled)
let docPath = NSBezierPath()
let bottomY = dy
let topY = 1024 - dy - CGFloat(fold)
let leftX = dx
let rightX = 1024 - dx
let r: CGFloat = 44
docPath.move(to: NSPoint(x: leftX, y: topY))
docPath.line(to: NSPoint(x: leftX, y: bottomY + r))
docPath.appendArc(withCenter: NSPoint(x: leftX + r, y: bottomY + r), radius: r, startAngle: 180, endAngle: 270)
docPath.line(to: NSPoint(x: rightX - r, y: bottomY))
docPath.appendArc(withCenter: NSPoint(x: rightX - r, y: bottomY + r), radius: r, startAngle: 270, endAngle: 360)
docPath.line(to: NSPoint(x: rightX, y: topY + CGFloat(fold)))
docPath.line(to: NSPoint(x: rightX - CGFloat(fold), y: topY))
docPath.close()
color(255, 255, 255).setFill()
docPath.fill()

// Folded flap: the corner triangle, slightly darker than the sheet.
let flap = NSBezierPath()
flap.move(to: NSPoint(x: rightX - CGFloat(fold), y: topY))
flap.line(to: NSPoint(x: rightX, y: topY + CGFloat(fold)))
flap.line(to: NSPoint(x: rightX, y: topY))
flap.close()
color(226, 222, 250).setFill()
flap.fill()
// Fold crease line.
color(199, 193, 240).setStroke()
let crease = NSBezierPath()
crease.move(to: NSPoint(x: rightX - CGFloat(fold), y: topY))
crease.line(to: NSPoint(x: rightX, y: topY + CGFloat(fold)))
crease.lineWidth = 10
crease.stroke()

// ---- "M↓" monogram in the app's deep indigo.
let monogram = NSAttributedString(
    string: "M↓",
    attributes: [
        .font: NSFont(name: "SFProDisplay-Bold", size: 330)
            ?? NSFont.boldSystemFont(ofSize: 330),
        .foregroundColor: color(51, 33, 176),
    ]
)
let msize = monogram.size()
let mrect = monogram.boundingRect(with: NSSize(width: 900, height: 500), options: [.usesLineFragmentOrigin])
let origin = NSPoint(
    x: (side - msize.width) / 2,
    y: (side - mrect.height) / 2 - 34
)
monogram.draw(at: origin)

image.unlockFocus()

// ---- Write PNG.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
let assets = URL(fileURLWithPath: "assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try png.write(to: assets.appendingPathComponent("icon.png"))

// ---- Build markdown.icns from a retina icon set.
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("markdown-icon-\(UUID().uuidString)")
    .appendingPathExtension("iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    let resized = NSImage(size: NSSize(width: px, height: px))
    resized.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
               from: NSRect(x: 0, y: 0, width: side, height: side),
               operation: .copy, fraction: 1)
    resized.unlockFocus()
    guard let tiff = resized.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(name)")
    }
    try png.write(to: iconset.appendingPathComponent(name))
}
let icnsPath = assets.appendingPathComponent("markdown.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icnsPath.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote assets/icon.png and assets/markdown.icns")
