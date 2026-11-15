import SwiftUI

struct TimelinePane: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var playback: Playback

    static let rulerH: CGFloat = 18
    static let stripH: CGFloat = 44
    static let waveH: CGFloat = 92
    static let loudH: CGFloat = 52
    static let markH: CGFloat = 22
    static let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                TimelineCanvas()
                FilmstripView(store: model.filmstrip)
                    .frame(height: TimelinePane.stripH)
                    .offset(y: TimelinePane.rulerH + TimelinePane.gap)
                PlayheadView()
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard model.duration > 0 else { return }
                let frac = min(max(0, v.location.x / geo.size.width), 1)
                model.seek(model.viewStart + frac * model.viewSpan)
            })
            .simultaneousGesture(MagnifyGesture().onEnded { v in model.zoom(by: 1 / max(0.2, v.magnification)) })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct PlayheadView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var playback: Playback

    var body: some View {
        Canvas { ctx, size in
            guard model.duration > 0, model.viewSpan > 0 else { return }
            let x = CGFloat((playback.time - model.viewStart) / model.viewSpan) * size.width
            guard x >= 0, x <= size.width else { return }
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(.white), lineWidth: 1.5)
            var tri = Path()
            tri.move(to: CGPoint(x: x - 5, y: 0)); tri.addLine(to: CGPoint(x: x + 5, y: 0)); tri.addLine(to: CGPoint(x: x, y: 8)); tri.closeSubpath()
            ctx.fill(tri, with: .color(.white))
        }
        .allowsHitTesting(false)
    }
}

struct TimelineCanvas: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let rulerH = TimelinePane.rulerH, waveH = TimelinePane.waveH
            let loudH = TimelinePane.loudH, markH = TimelinePane.markH, gap = TimelinePane.gap
            let waveTop = rulerH + gap + TimelinePane.stripH + gap
            let loudTop = waveTop + waveH + gap
            let markTop = loudTop + loudH + gap

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.10)))
            for (top, h) in [(waveTop, waveH), (loudTop, loudH), (markTop, markH)] {
                ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: h)), with: .color(Color(white: 0.06)))
            }

            let start = model.viewStart, span = max(model.viewSpan, 0.001)
            guard model.duration > 0 else {
                ctx.draw(Text("Kein Video geladen").font(.caption).foregroundColor(.secondary), at: CGPoint(x: w / 2, y: size.height / 2))
                return
            }

            drawRuler(ctx, w, rulerH, start, span)

            // Audio-Waveform, eingefärbt nach Lautstärke-Ziel
            if let a = model.audio {
                let series = model.activeSeries
                let cols = Int(w)
                let mid = waveTop + waveH / 2
                let half = waveH / 2 - 1
                let count = a.waveMin.count
                let block = 4
                var blockDev: Double? = nil
                for px in 0..<cols {
                    let t0 = start + Double(px) / Double(w) * span
                    let t1 = start + Double(px + 1) / Double(w) * span
                    let b0 = max(0, Int(t0 / a.waveBucket))
                    if b0 >= count { break }
                    let b1 = min(count - 1, max(b0, Int(t1 / a.waveBucket)))
                    var amp: Float = 0
                    for b in b0...b1 { amp = max(amp, -a.waveMin[b], a.waveMax[b]) }
                    let hgt = CGFloat(min(1, amp)) * half
                    if px % block == 0 {
                        // Farbe aus geglättetem Lautheitswert (±1,5 s um die Blockmitte)
                        let tc = start + (Double(px) + Double(block) / 2) / Double(w) * span
                        let c = Int(tc / 0.1)
                        var sum = 0.0, n = 0
                        let lo = max(0, c - 15), hi = min(series.count - 1, c + 15)
                        if lo <= hi {
                            for i in lo...hi where series[i] > -70 { sum += Double(series[i]); n += 1 }
                        }
                        blockDev = n == 0 ? nil : sum / Double(n) - model.target
                    }
                    let h2 = max(1, hgt)
                    let x = CGFloat(px)
                    if let dev = blockDev {
                        let tol = model.tolerance
                        func band(_ from: CGFloat, _ to: CGFloat, _ col: Color) {
                            guard to > from else { return }
                            ctx.fill(Path(CGRect(x: x, y: mid - to, width: 1, height: to - from)), with: .color(col))
                            ctx.fill(Path(CGRect(x: x, y: mid + from, width: 1, height: to - from)), with: .color(col))
                        }
                        let yellow = Color(red: 1.0, green: 0.85, blue: 0.2)
                        if dev < -tol {
                            band(0, h2, Palette.gradient(dev, tol: tol))        // zu leise: blau
                        } else if dev <= tol {
                            // Im Ziel: grün, zum oberen Rand hin zunehmend gelbe Spitze (max. 3 dB)
                            let pos = tol > 0 ? (dev + tol) / (2 * tol) : 1
                            let g = h2 * CGFloat(pow(10, -3 * pos / 20))
                            band(0, g, Palette.ok); band(g, h2, yellow)
                        } else {
                            // Zu laut: Spitze um den Überschuss rot, darunter 3 dB gelb, Rest grün
                            let c = h2 * CGFloat(pow(10, -(dev - tol) / 20))
                            let g = c * CGFloat(pow(10, -3.0 / 20))
                            band(0, g, Palette.ok); band(g, c, yellow); band(c, h2, Palette.high)
                        }
                    } else {
                        ctx.fill(Path(CGRect(x: x, y: mid - h2, width: 1, height: h2 * 2)), with: .color(Palette.silent))
                    }
                }
                // Mittellinie
                var ml = Path(); ml.move(to: CGPoint(x: 0, y: mid)); ml.addLine(to: CGPoint(x: w, y: mid))
                ctx.stroke(ml, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

                drawLoudness(ctx, w, loudTop, loudH, series, start, span)
            } else {
                ctx.draw(Text(audioText()).font(.caption).foregroundColor(.secondary),
                         at: CGPoint(x: w / 2, y: waveTop + waveH / 2))
            }

            // Markierungen
            for m in model.markers {
                let x0 = CGFloat((m.start - start) / span) * w
                let x1 = CGFloat((m.end - start) / span) * w
                if x1 < 0 || x0 > w { continue }
                let r = CGRect(x: max(0, x0), y: markTop + 2, width: max(4, min(w, x1) - max(0, x0)), height: markH - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Palette.color(m.kind)))
            }
            ctx.draw(Text("Markierungen").font(.system(size: 9)).foregroundColor(.white.opacity(0.35)),
                     at: CGPoint(x: 42, y: markTop + markH / 2))
        }
    }

    func audioText() -> String {
        switch model.audioStatus {
        case .running(let p): return "Audio wird analysiert … \(Int(p * 100)) %"
        case .unavailable(let m): return m
        case .failed(let m): return m
        default: return ""
        }
    }

    func drawLoudness(_ ctx: GraphicsContext, _ w: CGFloat, _ top: CGFloat, _ h: CGFloat, _ series: [Float], _ start: Double, _ span: Double) {
        let minL = -60.0, maxL = 0.0
        func y(_ v: Double) -> CGFloat { top + h * (1 - CGFloat((min(max(v, minL), maxL) - minL) / (maxL - minL))) }
        // Zielbereich
        let yt = y(model.target + model.tolerance), yb = y(model.target - model.tolerance)
        ctx.fill(Path(CGRect(x: 0, y: yt, width: w, height: max(2, yb - yt))), with: .color(Palette.ok.opacity(0.25)))
        var tl = Path(); tl.move(to: CGPoint(x: 0, y: y(model.target))); tl.addLine(to: CGPoint(x: w, y: y(model.target)))
        ctx.stroke(tl, with: .color(Palette.ok.opacity(0.7)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3]))
        ctx.draw(Text(String(format: "%.0f LUFS", model.target)).font(.system(size: 9)).foregroundColor(Palette.ok),
                 at: CGPoint(x: w - 30, y: y(model.target) - 7))

        guard !series.isEmpty else { return }
        var segStart = true
        var path = Path()
        var px = 0
        while px < Int(w) {
            let t = start + (Double(px) + 0.5) / Double(w) * span
            let idx = min(series.count - 1, max(0, Int(t / 0.1)))
            let v = Double(series[idx])
            if t > Double(series.count) * 0.1 { break }
            if v < -70 { segStart = true } else {
                let pt = CGPoint(x: CGFloat(px), y: y(v))
                if segStart { path.move(to: pt); segStart = false } else { path.addLine(to: pt) }
            }
            px += 2
        }
        ctx.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1)
    }

    func drawRuler(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ start: Double, _ span: Double) {
        let steps: [Double] = [0.1, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let pxPerSec = Double(w) / span
        let step = steps.first { $0 * pxPerSec >= 70 } ?? steps.last!
        var t = (start / step).rounded(.up) * step
        while t <= start + span {
            let x = CGFloat((t - start) / span) * w
            var p = Path(); p.move(to: CGPoint(x: x, y: h - 5)); p.addLine(to: CGPoint(x: x, y: h))
            ctx.stroke(p, with: .color(.white.opacity(0.5)), lineWidth: 1)
            let total = Int(t.rounded())
            let label = step < 1 ? String(format: "%d:%04.1f", total / 60, t.truncatingRemainder(dividingBy: 60))
                : (total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                   : String(format: "%d:%02d", total / 60, total % 60))
            ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.6)), at: CGPoint(x: x + 22, y: h / 2 - 1))
            t += step
        }
    }
}
