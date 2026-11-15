import AVFoundation
import CoreVideo
import Foundation

struct Marker: Identifiable {
    enum Kind { case over, under, truePeak }
    let id = UUID()
    var start: Double
    var end: Double
    var kind: Kind
    var label: String
}

/// Luma-Histogramme (256 Bins) in regelmäßigen Abständen über das ganze Video.
struct ExposureData {
    var interval: Double
    var times: [Double]
    var hist: [UInt16]      // times.count * 256
    var mean: [Float]
}

enum ExposureAnalyzer {
    static func scan(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExposureData? {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return nil }
        let dur = try await asset.load(.duration).seconds
        guard dur > 0 else { return nil }
        let interval = max(0.5, dur / 3000.0)
        let count = max(1, Int(dur / interval))
        let times = (0..<count).map { CMTime(seconds: Double($0) * interval, preferredTimescale: 600) }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 192, height: 192)
        let tol = CMTime(seconds: interval / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        var hists = [[UInt16]?](repeating: nil, count: count)
        var means = [Float](repeating: 0, count: count)
        var done = 0
        for await result in gen.images(for: times) {
            try Task.checkCancellation()
            done += 1
            if done % 20 == 0 { progress(Double(done) / Double(count)) }
            guard let img = try? result.image else { continue }
            let idx = min(count - 1, max(0, Int((result.requestedTime.seconds / interval).rounded())))
            let (h, m) = histogram(of: img)
            hists[idx] = h
            means[idx] = m
        }
        var outTimes: [Double] = [], outHist: [UInt16] = [], outMean: [Float] = []
        for i in 0..<count {
            guard let h = hists[i] else { continue }
            outTimes.append(Double(i) * interval)
            outHist.append(contentsOf: h)
            outMean.append(means[i])
        }
        guard !outTimes.isEmpty else { return nil }
        return ExposureData(interval: interval, times: outTimes, hist: outHist, mean: outMean)
    }

    static func histogram(of img: CGImage) -> ([UInt16], Float) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var hist = [UInt16](repeating: 0, count: 256)
        var sum = 0.0
        for i in 0..<(w * h) {
            let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let bin = min(255, max(0, Int(y.rounded())))
            hist[bin] &+= 1
            sum += y
        }
        return (hist, Float(sum / Double(max(1, w * h)) / 255.0))
    }

    static func markers(data: ExposureData, settings s: ExposureSettings) -> [Marker] {
        var out: [Marker] = []
        let overBin = Int((s.overLevel * 255).rounded())
        let underBin = Int((s.underLevel * 255).rounded())
        var cur: (kind: Marker.Kind, start: Double, end: Double, peak: Double)?

        func flush() {
            guard let c = cur else { return }
            let pct = Int(c.peak.rounded())
            let label = c.kind == .over ? "Überbelichtet (bis \(pct) % Fläche)" : "Unterbelichtet (bis \(pct) % Fläche)"
            out.append(Marker(start: c.start, end: c.end, kind: c.kind, label: label))
            cur = nil
        }

        for i in 0..<data.times.count {
            let base = i * 256
            var total = 0, over = 0, under = 0
            for b in 0..<256 {
                let c = Int(data.hist[base + b])
                total += c
                if b >= overBin { over += c }
                if b <= underBin { under += c }
            }
            let ov = Double(over) / Double(max(1, total)) * 100
            let un = Double(under) / Double(max(1, total)) * 100
            let mean = Double(data.mean[i])
            var kind: Marker.Kind?
            var strength = 0.0
            if ov >= s.overPercent || mean >= s.meanOver { kind = .over; strength = max(ov, mean >= s.meanOver ? mean * 100 : 0) }
            else if un >= s.underPercent || mean <= s.meanUnder { kind = .under; strength = max(un, mean <= s.meanUnder ? (1 - mean) * 100 : 0) }

            let t = data.times[i]
            if let k = kind {
                if var c = cur, c.kind == k, t - c.end <= data.interval * 1.5 {
                    c.end = t + data.interval
                    c.peak = max(c.peak, strength)
                    cur = c
                } else {
                    flush()
                    cur = (k, t, t + data.interval, strength)
                }
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}

// MARK: - Live-Waveform-Monitor

enum ScopeMode: String, CaseIterable, Identifiable {
    case combined, overlay, parade
    var id: String { rawValue }
    var title: String {
        switch self {
        case .combined: return "Kombiniert (Luma)"
        case .overlay: return "RGB überlagert"
        case .parade: return "RGB einzeln"
        }
    }
}

struct ScopeStats {
    var mean: Double = 0
    var over: Double = 0   // % Pixel
    var under: Double = 0
}

enum ScopeRenderer {
    static let cols = 320

    static func render(_ pb: CVPixelBuffer, mode: ScopeMode, settings: ExposureSettings) -> (CGImage, ScopeStats)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { return nil }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let cols = Self.cols
        let rowsN = min(h, 120)
        let xsN = max(1, min(4, w / cols))
        var cr = [Int32](repeating: 0, count: cols * 256)
        var cg = cr, cb = cr, cy = cr

        var sumY = 0.0, overN = 0, underN = 0, total = 0
        let overT = settings.overLevel * 255, underT = settings.underLevel * 255

        for c in 0..<cols {
            let colStart = c * w / cols
            let colW = max(1, (c + 1) * w / cols - colStart)
            for ry in 0..<rowsN {
                let y = ry * h / rowsN
                let row = ptr + y * bpr
                for k in 0..<xsN {
                    let x = min(w - 1, colStart + k * colW / xsN)
                    let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                    let yl = (2126 * r + 7152 * g + 722 * b) / 10000
                    cr[c * 256 + r] += 1
                    cg[c * 256 + g] += 1
                    cb[c * 256 + b] += 1
                    cy[c * 256 + yl] += 1
                    sumY += Double(yl)
                    total += 1
                    if Double(yl) >= overT { overN += 1 }
                    if Double(yl) <= underT { underN += 1 }
                }
            }
        }
        let perCol = Double(rowsN * xsN)
        let norm = 1.0 / (perCol * 0.05)
        func level(_ v: Int32) -> Double { min(1, pow(Double(v) * norm, 0.55)) }

        let panels = mode == .parade ? 3 : 1
        let width = cols * panels, height = 256
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { px[i * 4 + 3] = 255 }

        func put(_ x: Int, _ bin: Int, _ r: Double, _ g: Double, _ b: Double) {
            let yy = 255 - bin
            let o = (yy * width + x) * 4
            px[o] = UInt8(min(255, Int(r * 255) + Int(px[o])))
            px[o + 1] = UInt8(min(255, Int(g * 255) + Int(px[o + 1])))
            px[o + 2] = UInt8(min(255, Int(b * 255) + Int(px[o + 2])))
        }

        for c in 0..<cols {
            for bin in 0..<256 {
                let i = c * 256 + bin
                switch mode {
                case .combined:
                    let v = level(cy[i])
                    if v > 0 { put(c, bin, v * 0.55, v, v * 0.55) }
                case .overlay:
                    let r = level(cr[i]), g = level(cg[i]), b = level(cb[i])
                    if r + g + b > 0 { put(c, bin, r, g, b) }
                case .parade:
                    let r = level(cr[i]), g = level(cg[i]), b = level(cb[i])
                    if r > 0 { put(c, bin, r, r * 0.25, r * 0.25) }
                    if g > 0 { put(cols + c, bin, g * 0.25, g, g * 0.25) }
                    if b > 0 { put(2 * cols + c, bin, b * 0.3, b * 0.45, b) }
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let t = Double(max(1, total))
        return (img, ScopeStats(mean: sumY / t / 255, over: Double(overN) / t * 100, under: Double(underN) / t * 100))
    }
}
