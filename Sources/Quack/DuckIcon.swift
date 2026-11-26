import AppKit

/// The menu bar duck, drawn as a template image so macOS tints it for light and dark bars.
enum DuckIcon {
    enum Style {
        /// Quack is listening.
        case filled
        /// Quack is off or has no permission.
        case outline
        /// Quack is on but asleep.
        case asleep
    }

    private static var cache: [String: NSImage] = [:]

    static func image(_ style: Style, size: CGFloat = 18) -> NSImage {
        let key = "\(style)-\(size)"
        if let hit = cache[key] { return hit }
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [1, 2, 3] {
            image.addRepresentation(bitmap(style, points: size, scale: CGFloat(scale)))
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// The parts of the duck in an 18-unit box, y up, facing right.
    private static func parts(inset: CGFloat) -> [NSBezierPath] {
        // Body, with the tail lifted at the back.
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 1.2 + inset, y: 10.6 - inset))
        body.curve(to: NSPoint(x: 7.6, y: 1.6 + inset),
                   controlPoint1: NSPoint(x: 0.6 + inset, y: 5.2), controlPoint2: NSPoint(x: 3.4, y: 1.6 + inset))
        body.line(to: NSPoint(x: 10.6, y: 1.6 + inset))
        body.curve(to: NSPoint(x: 15.6 - inset, y: 6.2),
                   controlPoint1: NSPoint(x: 13.6, y: 1.6 + inset), controlPoint2: NSPoint(x: 15.6 - inset, y: 3.6))
        body.curve(to: NSPoint(x: 11.4, y: 9.6 - inset),
                   controlPoint1: NSPoint(x: 15.6 - inset, y: 8.2), controlPoint2: NSPoint(x: 13.6, y: 9.6 - inset))
        body.curve(to: NSPoint(x: 5.6, y: 8.4 - inset),
                   controlPoint1: NSPoint(x: 9.2, y: 9.6 - inset), controlPoint2: NSPoint(x: 7.4, y: 8.4 - inset))
        body.curve(to: NSPoint(x: 1.2 + inset, y: 10.6 - inset),
                   controlPoint1: NSPoint(x: 4.0, y: 8.4 - inset), controlPoint2: NSPoint(x: 2.6, y: 9.4 - inset))
        body.close()

        let r = 3.7 - inset
        let head = NSBezierPath(ovalIn: NSRect(x: 11.3 - r, y: 12.3 - r, width: r * 2, height: r * 2))

        let bill = NSBezierPath(
            roundedRect: NSRect(x: 13.6, y: 10.7 + inset * 0.5, width: 4.0 - inset, height: 2.1 - inset),
            xRadius: 1.0 - inset * 0.4, yRadius: 1.0 - inset * 0.4)
        return [body, head, bill]
    }

    private static func bitmap(_ style: Style, points: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
        let pixels = Int((points * scale).rounded())
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: points, height: points)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        // The context already maps points to pixels; this maps the 18-unit drawing to points.
        cg.scaleBy(x: points / 18, y: points / 18)
        NSColor.black.set()

        let eye = NSBezierPath(ovalIn: NSRect(x: 11.6, y: 12.6, width: 1.5, height: 1.5))
        switch style {
        case .filled:
            parts(inset: 0).forEach { $0.fill() }
            cg.setBlendMode(.destinationOut)
            eye.fill()
        case .outline, .asleep:
            // Fill and stroke every part, then erase the fills: what is left is one clean
            // outline around the whole duck, with no lines where the parts overlap.
            let line: CGFloat = 1.15
            let shapes = parts(inset: line)
            for shape in shapes {
                shape.lineWidth = line * 2
                shape.lineJoinStyle = .round
                shape.fill()
                shape.stroke()
            }
            cg.setBlendMode(.destinationOut)
            shapes.forEach { $0.fill() }
            cg.setBlendMode(.normal)
            eye.fill()
            if style == .asleep { drawZ(cg) }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Two small z's above the duck's back.
    private static func drawZ(_ cg: CGContext) {
        func z(x: CGFloat, y: CGFloat, size: CGFloat, width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y + size))
            path.line(to: NSPoint(x: x + size, y: y + size))
            path.line(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + size, y: y))
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        z(x: 3.9, y: 11.2, size: 2.6, width: 1.0)
        z(x: 0.9, y: 14.6, size: 2.0, width: 0.9)
    }

    /// Writes large previews of each style, for checking the drawing.
    static func writePreviews(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, style) in [("filled", Style.filled), ("outline", .outline), ("asleep", .asleep)] {
            for (suffix, scale) in [("large", CGFloat(16)), ("2x", 2)] {
                let rep = bitmap(style, points: 18, scale: scale)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("duck-\(name)-\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
