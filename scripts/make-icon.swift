// Makes the app icon from square artwork: the artwork fills the rounded square of the macOS icon grid,
// at every size of an .icns file. scripts/build-app.sh runs it.
// Usage: swift scripts/make-icon.swift <artwork.png> <output.icns>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: swift scripts/make-icon.swift <artwork.png> <output.icns>\n", stderr)
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
    let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else {
    fputs("error: cannot read \(source.path)\n", stderr)
    exit(1)
}

/// The icon at `size` pixels. On the 1024-pixel grid of macOS, the rounded square is 824 pixels wide with
/// corners of 185 pixels, and the space around it stays transparent.
func render(size: Int) -> CGImage? {
    let canvas = CGFloat(size)
    let side = canvas * 824 / 1024
    let square = CGRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    let radius = side * 185 / 824
    context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(artwork, in: square)
    return context.makeImage()
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
var status: Int32 = 0
do {
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
            guard let image = render(size: points * scale),
                let destination = CGImageDestinationCreateWithURL(
                    iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    status = iconutil.terminationStatus
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    status = 1
}
try? fileManager.removeItem(at: iconset)
exit(status)
