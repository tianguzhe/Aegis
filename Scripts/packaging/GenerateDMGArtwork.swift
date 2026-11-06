import AppKit

/// Renders the Aegis installer window background headlessly, with 1× and 2× representations.
/// Icon positions must match `dmg-settings.py`, which places the real Finder icons on top.
@main @MainActor
struct GenerateDMGArtwork {
    private static let canvas = NSSize(width: 680, height: 460)

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw failure("Usage: GenerateDMGArtwork <output-directory> <version> <brand-png>")
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard let brand = NSImage(contentsOfFile: arguments[3]) else {
            throw failure("Cannot open brand image: \(arguments[3])")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let representations = [1, 2].map { render(scale: $0, version: arguments[2], brand: brand) }
        let image = NSImage(size: canvas)
        for representation in representations { image.addRepresentation(representation) }
        guard let tiff = image.tiffRepresentation,
            let preview = representations[1].representation(using: .png, properties: [:])
        else { throw failure("Could not encode the DMG artwork.") }
        try tiff.write(to: output.appendingPathComponent("background.tiff"), options: .atomic)
        try preview.write(to: output.appendingPathComponent("background@2x.png"), options: .atomic)
        print("Rendered DMG background at 680×460 pt and 1360×920 px.")
    }

    private static func render(scale: Int, version: String, brand: NSImage) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        // AppKit derives the Retina scale from this logical size; do not scale the context again.
        bitmap.size = canvas
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.setAllowsAntialiasing(true)

        // Palette from AegisTheme (App/Views/DesignSystem.swift).
        let paper = color(0xF7F8F5)
        let ink = color(0x23352F)
        let teal = color(0x27635B)
        let secondary = color(0x53645A)
        let gold = color(0xD9B778)
        paper.setFill()
        NSRect(origin: .zero, size: canvas).fill()

        // Header band: deep navy with faint concentric shield outlines.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: 680, height: 128))
        gradient([color(0x173634), color(0x0E2221)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 680, y: 128), in: context)
        context.setStrokeColor(gold.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(0.75)
        for inset in [0.0, 16.0, 32.0, 48.0] {
            let width = 150 - inset * 2, left = 520 + inset, top = -22 + inset
            context.move(to: CGPoint(x: left, y: top))
            context.addLine(to: CGPoint(x: left + width, y: top))
            context.addLine(to: CGPoint(x: left + width, y: top + 70 - inset / 2))
            context.addQuadCurve(to: CGPoint(x: left + width / 2, y: top + 170 - inset * 2),
                                 control: CGPoint(x: left + width, y: top + 140 - inset * 1.5))
            context.addQuadCurve(to: CGPoint(x: left, y: top + 70 - inset / 2),
                                 control: CGPoint(x: left, y: top + 140 - inset * 1.5))
            context.closePath()
            context.strokePath()
        }
        context.restoreGState()

        let brandRect = NSRect(x: 38, y: 29, width: 48, height: 48)
        context.saveGState()
        NSBezierPath(roundedRect: brandRect, xRadius: 11, yRadius: 11).addClip()
        brand.draw(in: brandRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGState()
        text("Aegis", in: NSRect(x: 102, y: 31, width: 300, height: 36),
             font: .systemFont(ofSize: 26, weight: .semibold), color: color(0xF2EFE4))
        text("你的保险库，只由你掌握。", in: NSRect(x: 40, y: 93, width: 430, height: 22),
             font: .systemFont(ofSize: 13), color: color(0xC9D8D2))

        let versionRect = NSRect(x: 420, y: 36, width: 86, height: 27)
        color(0xF2EFE4).withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: versionRect, xRadius: 13.5, yRadius: 13.5).fill()
        text("v\(version)", in: versionRect.offsetBy(dx: 0, dy: 6),
             font: .monospacedSystemFont(ofSize: 10, weight: .medium), color: gold, alignment: .center)

        text("将 Aegis 拖入 Applications 文件夹", in: NSRect(x: 40, y: 151, width: 600, height: 28),
             font: .systemFont(ofSize: 16, weight: .medium), color: ink, alignment: .center)

        // Finder draws the real app and Applications icons on these halos (see dmg-settings.py).
        for x in [180.0, 500.0] {
            let halo = NSRect(x: x - 70, y: 180, width: 140, height: 140)
            color(0xFFFFFF).setFill()
            NSBezierPath(ovalIn: halo).fill()
            color(0xE4E9E2).setStroke()
            let outline = NSBezierPath(ovalIn: halo)
            outline.lineWidth = 0.8
            outline.stroke()
        }
        context.setStrokeColor(teal.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: 307, y: 250))
        context.addLine(to: CGPoint(x: 373, y: 250))
        context.move(to: CGPoint(x: 363, y: 240))
        context.addLine(to: CGPoint(x: 373, y: 250))
        context.addLine(to: CGPoint(x: 363, y: 260))
        context.strokePath()
        text("拖动安装", in: NSRect(x: 290, y: 275, width: 100, height: 20),
             font: .systemFont(ofSize: 11), color: secondary, alignment: .center)

        context.setStrokeColor(color(0xE4E9E2).cgColor)
        context.setLineWidth(0.7)
        context.move(to: CGPoint(x: 40, y: 365))
        context.addLine(to: CGPoint(x: 640, y: 365))
        context.strokePath()
        // The package is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch.
        text("首次打开如被拦截：系统设置 › 隐私与安全性 › 仍要打开", in: NSRect(x: 40, y: 383, width: 600, height: 24),
             font: .systemFont(ofSize: 13), color: secondary, alignment: .center)
        text("macOS 14+  ·  Apple Silicon & Intel  ·  未经公证的独立分发版", in: NSRect(x: 40, y: 425, width: 600, height: 18),
             font: .systemFont(ofSize: 11), color: secondary.withAlphaComponent(0.85), alignment: .center)
        return bitmap
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func text(_ string: String, in rect: NSRect, font: NSFont, color: NSColor,
                             alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(in: rect)
    }

    private static func gradient(_ colors: [NSColor], from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Aegis.DMGArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
