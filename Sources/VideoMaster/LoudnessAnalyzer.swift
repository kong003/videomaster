import AVFoundation
import Foundation

struct LoudnessAnalysis {
    var duration: Double
    var blockDuration: Double = 0.1
    /// LUFS pro 100-ms-Block (Momentary, 400 ms Fenster)
    var momentary: [Float]
    /// LUFS pro 100-ms-Block (Short-term, 3 s Fenster)
    var shortTerm: [Float]
    /// True Peak (dBTP) pro 100-ms-Block
    var truePeakBlocks: [Float]
    var waveMin: [Float]
    var waveMax: [Float]
    var waveBucket: Double
    var integrated: Double
    var lra: Double
    var truePeak: Double
    var samplePeak: Double
}

/// ITU-R BS.1770-4 / EBU R128 Messung (K-Gewichtung, Gating, LRA, True Peak 4x).
enum LoudnessAnalyzer {
    struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
        @inline(__always) mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    static func lufs(_ power: Double) -> Double {
        power <= 1e-12 ? -120 : -0.691 + 10 * log10(power)
    }

    /// 4x-Oversampling-Koeffizienten (3 Zwischenphasen, 12 Taps).
    static let tpCoef: [[Double]] = {
        var res: [[Double]] = []
        for p in 1...3 {
            var c = [Double](repeating: 0, count: 12)
            var sum = 0.0
            for k in 0..<12 {
                let t = Double(p + 4 * (5 - k))
                let x = t / 4.0
                let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let w = 0.5 * (1 + cos(Double.pi * t / 24.0))
                c[k] = sinc * w
                sum += c[k]
            }
            res.append(c.map { $0 / sum })
        }
        return res
    }()

    static func analyze(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessAnalysis? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else { return nil }
        let dur = try await asset.load(.duration).seconds
        var ch = 2
        if let desc = try await first.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            ch = asbd.pointee.mChannelsPerFrame == 1 ? 1 : 2
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: ch,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var s1 = [Biquad](repeating: Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                            a1: -1.69065929318241, a2: 0.73248077421585), count: ch)
        var s2 = [Biquad](repeating: Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621), count: ch)
        var hist = [[Double]](repeating: [Double](repeating: 0, count: 12), count: ch)
        let coef = tpCoef

        var blockMS: [Double] = []
        var tpBlocks: [Float] = []
        var waveMin: [Float] = [], waveMax: [Float] = []
        var blkSum = 0.0, blkTP = 0.0, tpAll = 0.0, samplePeak = 0.0
        var blkCount = 0, wCount = 0
        var wMin = 0.0, wMax = 0.0
        var lastReport = 0.0

        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            let n = len / 4
            if n == 0 { continue }
            var data = [Float](repeating: 0, count: n)
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: raw.baseAddress!)
            }
            let frames = n / ch
            data.withUnsafeBufferPointer { p in
                for f in 0..<frames {
                    for c in 0..<ch {
                        let x = Double(p[f * ch + c])
                        let ax = abs(x)
                        if ax > samplePeak { samplePeak = ax }
                        if x < wMin { wMin = x }
                        if x > wMax { wMax = x }
                        let y = s2[c].process(s1[c].process(x))
                        blkSum += y * y

                        for k in 0..<11 { hist[c][k] = hist[c][k + 1] }
                        hist[c][11] = x
                        var tp = ax
                        var m = 0.0
                        for k in 3...8 { m = max(m, abs(hist[c][k])) }
                        if m > 0.25 {
                            for ph in 0..<3 {
                                var sum = 0.0
                                let cf = coef[ph]
                                for k in 0..<12 { sum += cf[k] * hist[c][k] }
                                tp = max(tp, abs(sum))
                            }
                        }
                        if tp > blkTP { blkTP = tp }
                    }
                    blkCount += 1
                    wCount += 1
                    if wCount == 480 {
                        waveMin.append(Float(wMin)); waveMax.append(Float(wMax))
                        wMin = 0; wMax = 0; wCount = 0
                    }
                    if blkCount == 4800 {
                        blockMS.append(blkSum / 4800)
                        tpBlocks.append(blkTP <= 1e-6 ? -120 : Float(20 * log10(blkTP)))
                        if blkTP > tpAll { tpAll = blkTP }
                        blkSum = 0; blkTP = 0; blkCount = 0
                    }
                }
            }
            if dur > 0 {
                let pt = CMSampleBufferGetPresentationTimeStamp(sb).seconds / dur
                if pt - lastReport > 0.01 { lastReport = pt; progress(min(1, pt)) }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        if wCount > 0 { waveMin.append(Float(wMin)); waveMax.append(Float(wMax)) }
        if blkTP > tpAll { tpAll = blkTP }
        guard !blockMS.isEmpty else { return nil }

        // Prefix sums
        var pre = [Double](repeating: 0, count: blockMS.count + 1)
        for i in 0..<blockMS.count { pre[i + 1] = pre[i] + blockMS[i] }
        func window(_ i: Int, _ size: Int) -> Double {
            let lo = max(0, i + 1 - size)
            return (pre[i + 1] - pre[lo]) / Double(i + 1 - lo)
        }
        let momentary = (0..<blockMS.count).map { Float(lufs(window($0, 4))) }
        let shortTerm = (0..<blockMS.count).map { Float(lufs(window($0, 30))) }

        // Integrated loudness with gating
        var gated: [Double] = []
        if blockMS.count >= 4 {
            for i in 3..<blockMS.count {
                let p = (pre[i + 1] - pre[i - 3]) / 4
                if lufs(p) > -70 { gated.append(p) }
            }
        }
        var integrated = -120.0
        if !gated.isEmpty {
            let thr = lufs(gated.reduce(0, +) / Double(gated.count)) - 10
            let rel = gated.filter { lufs($0) > thr }
            if !rel.isEmpty { integrated = lufs(rel.reduce(0, +) / Double(rel.count)) }
        }

        // Loudness range
        var lra = 0.0
        if blockMS.count >= 30 {
            var st: [Double] = []
            for i in 29..<blockMS.count {
                let p = (pre[i + 1] - pre[i - 29]) / 30
                if lufs(p) > -70 { st.append(p) }
            }
            if !st.isEmpty {
                let thr = lufs(st.reduce(0, +) / Double(st.count)) - 20
                let v = st.map { lufs($0) }.filter { $0 > thr }.sorted()
                if v.count > 1 {
                    lra = v[Int(0.95 * Double(v.count - 1))] - v[Int(0.10 * Double(v.count - 1))]
                }
            }
        }

        return LoudnessAnalysis(
            duration: dur, momentary: momentary, shortTerm: shortTerm, truePeakBlocks: tpBlocks,
            waveMin: waveMin, waveMax: waveMax, waveBucket: 480.0 / 48000.0,
            integrated: integrated, lra: lra,
            truePeak: tpAll <= 1e-6 ? -120 : 20 * log10(tpAll),
            samplePeak: samplePeak <= 1e-6 ? -120 : 20 * log10(samplePeak)
        )
    }
}
