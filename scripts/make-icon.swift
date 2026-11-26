import AppKit

// Draws the Quack app icon: a yellow keycap with a duck on it.
let out = CommandLine.arguments[1]
let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(deviceRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

// Keycap base (the skirt)
let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 190, yRadius: 190)
NSGradient(starting: rgb(214, 140, 16), ending: rgb(160, 96, 8))!.draw(in: base, angle: -90)

// Keycap top, shifted up so the skirt shows below it
let top = NSBezierPath(roundedRect: NSRect(x: 150, y: 190, width: 724, height: 694), xRadius: 150, yRadius: 150)
NSGradient(starting: rgb(255, 224, 92), ending: rgb(250, 186, 40))!.draw(in: top, angle: -90)

// Soft highlight along the top edge
let shine = NSBezierPath(roundedRect: NSRect(x: 190, y: 800, width: 644, height: 50), xRadius: 25, yRadius: 25)
NSColor(white: 1, alpha: 0.35).setFill()
shine.fill()

let duck = NSAttributedString(string: "🦆", attributes: [.font: NSFont.systemFont(ofSize: 430)])
let bounds = duck.size()
duck.draw(at: NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: 190 + (694 - bounds.height) / 2 - 10))

NSGraphicsContext.current?.flushGraphics()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
