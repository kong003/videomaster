import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Symbolform (macOS-Raster: 824 px in 1024)
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)

    // Schatten
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0, 0, 0, 0.45))
    ctx.addPath(shape); ctx.setFillColor(color(0.1, 0.12, 0.17)); ctx.fillPath()
    ctx.restoreGState()

    // Hintergrund-Verlauf
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [color(0.17, 0.20, 0.29), color(0.05, 0.06, 0.09)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Waveform-Balken
    let heights: [CGFloat] = [0.16, 0.30, 0.22, 0.46, 0.38, 0.66, 0.52, 0.86, 0.60, 0.94, 0.70, 0.48, 0.74, 0.36, 0.50, 0.24, 0.32, 0.14]
    let barW: CGFloat = 30, gap: CGFloat = 14
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let x0 = 512 - total / 2
    let midY: CGFloat = 512
    let maxHalf: CGFloat = 270
    let green = color(0.25, 0.80, 0.40), yellow = color(1.0, 0.85, 0.2), red = color(0.95, 0.25, 0.25), blue = color(0.30, 0.50, 0.98)

    func fillBar(_ x: CGFloat, _ from: CGFloat, _ to: CGFloat, _ c: CGColor) {
        guard to > from else { return }
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: x, y: midY + from, width: barW, height: to - from))
        ctx.fill(CGRect(x: x, y: midY - to, width: barW, height: to - from))
    }

    for (i, h) in heights.enumerated() {
        let x = x0 + CGFloat(i) * (barW + gap)
        let half = h * maxHalf
        // Rundung über Clip
        ctx.saveGState()
        let barPath = CGPath(roundedRect: CGRect(x: x, y: midY - half, width: barW, height: half * 2), cornerWidth: 15, cornerHeight: 15, transform: nil)
        ctx.addPath(barPath); ctx.clip()
        if h < 0.28 {
            fillBar(x, 0, half, blue)
        } else if h < 0.62 {
            fillBar(x, 0, half * 0.82, green); fillBar(x, half * 0.82, half, yellow)
        } else {
            fillBar(x, 0, half * 0.66, green); fillBar(x, half * 0.66, half * 0.82, yellow); fillBar(x, half * 0.82, half, red)
        }
        ctx.restoreGState()
    }

    // Playhead
    let px = x0 + 9 * (barW + gap) + barW / 2
    ctx.setFillColor(color(1, 1, 1, 0.95))
    ctx.fill(CGRect(x: px - 4, y: 190, width: 8, height: 644))
    ctx.move(to: CGPoint(x: px - 26, y: 834)); ctx.addLine(to: CGPoint(x: px + 26, y: 834)); ctx.addLine(to: CGPoint(x: px, y: 796)); ctx.closePath()
    ctx.fillPath()

    // Glanzkante oben
    let hl = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.14), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func save(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes { save(render(size: px), "\(out)/icon_\(name).png") }
