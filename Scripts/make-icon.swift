// Draws Plugboard's app icon and writes Resources/AppIcon.icns.
// Run with: make icon   (compiles this file with swiftc; the swift interpreter can't link AppKit)
//
// Three rack modules with knobs on a dark squircle, joined by a patch cable.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appending(path: "Plugboard-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ context: CGContext, in path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

/// Draws at 1024×1024 in a flipped coordinate space (y grows downward), then scales.
func drawIcon(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    // Background squircle on Apple's 824-point icon grid, with its drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(squircle)
    context.setFillColor(color(0x1B1E2E))
    context.fillPath()
    context.restoreGState()
    linearGradient(context, in: squircle, colors: [color(0x353A57), color(0x15172A)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))

    // Hairline highlight along the top edge.
    context.saveGState()
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // Rack modules.
    let moduleX: CGFloat = 214
    let moduleWidth: CGFloat = 596
    let moduleHeight: CGFloat = 150
    let tops: [CGFloat] = [262, 437, 612]
    let knobAngles: [CGFloat] = [-140, -40, 30]
    let meters: [[CGFloat]] = [[0.55, 0.8, 0.65, 0.35], [0.85, 0.5, 0.7, 0.9], [0.4, 0.6, 0.3, 0.5]]
    let meterColors = [color(0x2BC4A8), color(0x5B8CFF), color(0xB07CFF)]
    var jacks: [CGPoint] = []

    for (index, top) in tops.enumerated() {
        let rect = CGRect(x: moduleX, y: top, width: moduleWidth, height: moduleHeight)
        let module = CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: color(0x000000, 0.35))
        context.addPath(module)
        context.setFillColor(color(0xE9EBF2))
        context.fillPath()
        context.restoreGState()
        linearGradient(context, in: module, colors: [color(0xF7F8FB), color(0xD3D7E2)], from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY))

        // Knob with its pointer.
        let knobCenter = CGPoint(x: rect.minX + 92, y: rect.midY)
        let knob = CGPath(ellipseIn: CGRect(x: knobCenter.x - 48, y: knobCenter.y - 48, width: 96, height: 96), transform: nil)
        linearGradient(context, in: knob, colors: [color(0x4A5070), color(0x1E2236)], from: CGPoint(x: 0, y: knobCenter.y - 48), to: CGPoint(x: 0, y: knobCenter.y + 48))
        let angle = knobAngles[index] * .pi / 180
        context.setStrokeColor(color(0xFFFFFF))
        context.setLineWidth(10)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: knobCenter.x + cos(angle) * 10, y: knobCenter.y + sin(angle) * 10))
        context.addLine(to: CGPoint(x: knobCenter.x + cos(angle) * 34, y: knobCenter.y + sin(angle) * 34))
        context.strokePath()

        // Level meter.
        for (bar, level) in meters[index].enumerated() {
            let barHeight = 84 * level
            let barRect = CGRect(x: rect.minX + 186 + CGFloat(bar) * 34, y: rect.midY + 42 - barHeight, width: 20, height: barHeight)
            context.addPath(CGPath(roundedRect: barRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.setFillColor(meterColors[index])
            context.fillPath()
        }

        // Jack socket on the right.
        let jack = CGPoint(x: rect.maxX - 70, y: rect.midY)
        jacks.append(jack)
        context.addPath(CGPath(ellipseIn: CGRect(x: jack.x - 28, y: jack.y - 28, width: 56, height: 56), transform: nil))
        context.setFillColor(color(0x2A2E44))
        context.fillPath()
        context.addPath(CGPath(ellipseIn: CGRect(x: jack.x - 13, y: jack.y - 13, width: 26, height: 26), transform: nil))
        context.setFillColor(color(0x0E1020))
        context.fillPath()
    }

    // Patch cable from the top module's jack, out past the edge and into the bottom one.
    let start = jacks[0]
    let end = jacks[2]
    let cable = CGMutablePath()
    cable.move(to: start)
    cable.addCurve(to: end, control1: CGPoint(x: start.x + 180, y: start.y + 40), control2: CGPoint(x: end.x + 180, y: end.y - 40))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 8), blur: 12, color: color(0x000000, 0.4))
    context.addPath(cable)
    context.setStrokeColor(color(0xC2410C))
    context.setLineWidth(34)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
    context.addPath(cable)
    context.setStrokeColor(color(0xFB8B3C))
    context.setLineWidth(24)
    context.setLineCap(.round)
    context.strokePath()

    // Plug heads over the jacks.
    for jack in [start, end] {
        context.addPath(CGPath(ellipseIn: CGRect(x: jack.x - 24, y: jack.y - 24, width: 48, height: 48), transform: nil))
        context.setFillColor(color(0xFB8B3C))
        context.fillPath()
        context.addPath(CGPath(ellipseIn: CGRect(x: jack.x - 11, y: jack.y - 11, width: 22, height: 22), transform: nil))
        context.setFillColor(color(0xFFD2A8))
        context.fillPath()
    }

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    try write(drawIcon(size: points), to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try write(drawIcon(size: points * 2), to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
try write(drawIcon(size: 1024), to: root.appending(path: "Resources/AppIcon-1024.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "iconutil failed")
exit(process.terminationStatus)
