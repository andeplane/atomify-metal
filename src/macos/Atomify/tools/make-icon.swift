// Makes the Mac app icon from the iOS one: the square picture clipped to
// the macOS icon shape (an 824 pt rounded square on a 1024 pt canvas).
//   swift src/macos/Atomify/tools/make-icon.swift <ios AppIcon.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: make-icon.swift <ios AppIcon.png> <out.png>")
}
let size = 1024, inset = 100.0, side = 824.0, radius = 185.0
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: inset, y: inset, width: side, height: side)
// A soft shadow under the shape, as macOS icons have.
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.setFillColor(CGColor(gray: 0.2, alpha: 1))
context.fillPath()
context.setShadow(offset: .zero, blur: 0)
context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.clip()
context.draw(cg, in: rect)
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
