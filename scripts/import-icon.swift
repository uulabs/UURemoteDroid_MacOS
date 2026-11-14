// Turns a square artwork image into the app icon PNG.
//
//   swift scripts/import-icon.swift <source image> <output 1024 png>
//
// The light background surrounding the artwork is flood-filled from the image
// edges and made transparent (with soft edges), the artwork is trimmed to its
// bounds and centred at 824 px on a 1024 px canvas, the macOS icon grid.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: import-icon.swift <source> <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot read \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let width = image.width
let height = image.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let premultipliedLast = CGImageAlphaInfo.premultipliedLast.rawValue
pixels.withUnsafeMutableBytes { raw in
    let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: space, bitmapInfo: premultipliedLast
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func index(_ x: Int, _ y: Int) -> Int { y * bytesPerRow + x * 4 }
func isBackground(_ i: Int) -> Bool {
    // Already transparent (or nearly) counts as surround too.
    if pixels[i + 3] < 24 { return true }
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    let low = min(r, g, b), high = max(r, g, b)
    return low >= 200 && high - low <= 24
}

// Flood fill the light surround from every edge pixel.
var background = [Bool](repeating: false, count: width * height)
var stack: [(Int, Int)] = []
for x in 0..<width { stack.append((x, 0)); stack.append((x, height - 1)) }
for y in 0..<height { stack.append((0, y)); stack.append((width - 1, y)) }
while let (x, y) = stack.popLast() {
    let flat = y * width + x
    if background[flat] || !isBackground(index(x, y)) { continue }
    background[flat] = true
    if x > 0 { stack.append((x - 1, y)) }
    if x < width - 1 { stack.append((x + 1, y)) }
    if y > 0 { stack.append((x, y - 1)) }
    if y < height - 1 { stack.append((x, y + 1)) }
}

// Clear the surround; give its boundary pixels partial alpha so the
// artwork's anti-aliased edge does not keep a white fringe.
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let flat = y * width + x
        let i = index(x, y)
        if background[flat] {
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
            continue
        }
        var touchesBackground = false
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = x + dx, ny = y + dy
            if nx >= 0, nx < width, ny >= 0, ny < height, background[ny * width + nx] {
                touchesBackground = true
            }
        }
        let lightness = Double(min(pixels[i], pixels[i + 1], pixels[i + 2]))
        // Only fade light, opaque fringe pixels left by a white surround;
        // pixels that already carry their own edge alpha stay as they are.
        if touchesBackground, pixels[i + 3] == 255, lightness > 120 {
            let alpha = max(0, min(1, (255 - lightness) / 200))
            // Premultiplied: scale the dark artwork colour by the alpha.
            let dark = UInt8(18 * alpha)
            pixels[i] = dark; pixels[i + 1] = dark; pixels[i + 2] = dark
            pixels[i + 3] = UInt8(255 * alpha)
        }
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}

let cleaned: CGImage = pixels.withUnsafeMutableBytes { raw in
    let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: space, bitmapInfo: premultipliedLast
    )!
    return context.makeImage()!
}
// CGImage cropping uses top-left origin rows, matching the buffer order.
let crop = cleaned.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

let canvas = 1024
let artwork = 824.0
let output = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: premultipliedLast
)!
output.interpolationQuality = .high
// macOS 26+ shrinks any icon that is not the standard rounded square onto a
// white plate. Fill exactly that shape: an 824 px rounded square (corner
// radius ~185 px) centred on the 1024 canvas, with the artwork covering it.
let tile = CGRect(x: 100, y: 100, width: artwork, height: artwork)
output.addPath(CGPath(roundedRect: tile, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil))
output.clip()
output.setFillColor(CGColor(red: 0.02, green: 0.03, blue: 0.03, alpha: 1))
output.fill(tile)
// Cover, not fit: the artwork's chamfered corners fall inside the rounded
// corners that the mask removes anyway.
let scale = artwork / Double(min(crop.width, crop.height))
let drawWidth = Double(crop.width) * scale
let drawHeight = Double(crop.height) * scale
output.draw(crop, in: CGRect(
    x: (Double(canvas) - drawWidth) / 2,
    y: (Double(canvas) - drawHeight) / 2,
    width: drawWidth,
    height: drawHeight
))
let result = output.makeImage()!

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Wrote \(outputURL.path) (artwork \(crop.width)x\(crop.height) -> \(Int(drawWidth))x\(Int(drawHeight)))")
