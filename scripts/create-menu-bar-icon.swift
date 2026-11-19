import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Convert the supplied monochrome artwork into an alpha template, without redrawing it.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read the supplied icon")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        fatalError("Cannot create icon bitmap")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = buffer.bindMemory(to: UInt8.self)
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        let luminance = (Int(bytes[offset]) * 2126 + Int(bytes[offset + 1]) * 7152 + Int(bytes[offset + 2]) * 722) / 10000
        // Clear the near-white background as well as white interiors. Preserve antialiased edges.
        let alpha = luminance >= 248 ? 0 : 255 - luminance
        bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = UInt8(alpha)
    }
    guard let result = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write menu icon")
    }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finish menu icon") }
    precondition(bytes[3] == 0)
    precondition(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] == 255 })
}
print("Transparent menu template: \(width)×\(height)")
