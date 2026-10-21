// Draws Plain's logo: a rounded square in the light `Tokens.colorBlue` (#8599AE) with a white "P".
// Usage: swift scripts/make-logo.swift <output.png> [size]   (size defaults to 256)
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-logo.swift <output.png> [size]\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
let size = arguments.count >= 3 ? Int(arguments[2]) ?? 256 : 256
let side = CGFloat(size)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let blue = NSColor(srgbRed: 0x85 / 255.0, green: 0x99 / 255.0, blue: 0xAE / 255.0, alpha: 1)
let inset = side * 0.06
let square = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
blue.setFill()
NSBezierPath(roundedRect: square, xRadius: side * 0.2, yRadius: side * 0.2).fill()

let font = NSFont.systemFont(ofSize: side * 0.62, weight: .semibold)
let letter = NSAttributedString(string: "P", attributes: [.font: font, .foregroundColor: NSColor.white])
let bounds = letter.size()
letter.draw(at: NSPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2))
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: output)
print(output.path)
