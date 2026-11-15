import SwiftUI

struct ScopePane: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var playback: Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WAVEFORM").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.scopeMode) {
                    ForEach(ScopeMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 170)
            }
            ZStack {
                Color.black
                if let img = playback.scopeImage {
                    Image(decorative: img, scale: 1)
                        .resizable().interpolation(.medium)
                }
                ScopeGraticule(parade: model.scopeMode == .parade)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            let s = playback.scopeStats
            HStack(spacing: 10) {
                stat("Ø Luma", String(format: "%.0f %%", s.mean * 100), .primary)
                stat("Hell", String(format: "%.1f %%", s.over), s.over >= model.exposureSettings.overPercent ? Palette.over : .secondary)
                stat("Dunkel", String(format: "%.1f %%", s.under), s.under >= model.exposureSettings.underPercent ? Palette.under : .secondary)
            }
        }
        .padding(8)
    }

    func stat(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(.callout, design: .monospaced)).foregroundStyle(c)
        }
    }
}

struct ScopeGraticule: View {
    let parade: Bool
    var body: some View {
        Canvas { ctx, size in
            for pct in [0, 25, 50, 75, 100] {
                let y = size.height * (1 - CGFloat(pct) / 100)
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                ctx.draw(Text("\(pct)").font(.system(size: 9)).foregroundColor(.white.opacity(0.6)),
                         at: CGPoint(x: 12, y: min(max(y - 6, 7), size.height - 7)))
            }
            // Legaler Bereich 16–235
            for code in [16.0, 235.0] {
                let y = size.height * (1 - CGFloat(code / 255))
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.orange.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
            if parade {
                for i in 1...2 {
                    let x = size.width * CGFloat(i) / 3
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                }
                let names = [("R", Color.red), ("G", Color.green), ("B", Color.blue)]
                for (i, n) in names.enumerated() {
                    ctx.draw(Text(n.0).font(.system(size: 10, weight: .bold)).foregroundColor(n.1),
                             at: CGPoint(x: size.width * (CGFloat(i) + 0.9) / 3, y: 10))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct LoudnessPane: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var playback: Playback

    private let minL = -60.0, maxL = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAUTSTÄRKE").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: $model.meterMode) {
                ForEach(MeterMode.allCases) { Text($0.title).tag($0) }
            }.labelsHidden()

            HStack(spacing: 6) {
                meter
                VStack(alignment: .leading, spacing: 6) { readouts }
            }

            Divider()
            targetFields
        }
        .padding(8)
    }

    // aktuelle Werte an der Playhead-Position
    var currentM: Float? { model.audio.flatMap { model.value(at: playback.time, in: $0.momentary) } }
    var currentS: Float? { model.audio.flatMap { model.value(at: playback.time, in: $0.shortTerm) } }

    var meter: some View {
        Canvas { ctx, size in
            let barX: CGFloat = 26
            let barW = size.width - barX
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((min(max(v, minL), maxL) - minL) / (maxL - minL))) }

            // Skala
            for v in stride(from: -60, through: 0, by: 10) {
                let yy = y(Double(v))
                var p = Path(); p.move(to: CGPoint(x: barX - 4, y: yy)); p.addLine(to: CGPoint(x: barX, y: yy))
                ctx.stroke(p, with: .color(.white.opacity(0.5)), lineWidth: 1)
                ctx.draw(Text("\(v)").font(.system(size: 9)).foregroundColor(.white.opacity(0.6)),
                         at: CGPoint(x: 10, y: min(max(yy, 6), size.height - 6)))
            }
            ctx.fill(Path(CGRect(x: barX, y: 0, width: barW, height: size.height)), with: .color(.black))

            // Zielbereich
            let top = y(model.target + model.tolerance), bot = y(model.target - model.tolerance)
            ctx.fill(Path(CGRect(x: barX, y: top, width: barW, height: max(2, bot - top))), with: .color(Palette.ok.opacity(0.28)))
            var tl = Path(); tl.move(to: CGPoint(x: barX, y: y(model.target))); tl.addLine(to: CGPoint(x: size.width, y: y(model.target)))
            ctx.stroke(tl, with: .color(Palette.ok), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Short-term-/Momentary-Balken
            if let s = currentS {
                let v = Double(s)
                let yy = y(v)
                ctx.fill(Path(CGRect(x: barX + barW * 0.15, y: yy, width: barW * 0.45, height: size.height - yy)),
                         with: .color(Palette.color(model.classify(s))))
            }
            if let m = currentM {
                let yy = y(Double(m))
                ctx.fill(Path(CGRect(x: barX + barW * 0.68, y: yy, width: barW * 0.2, height: size.height - yy)),
                         with: .color(.white.opacity(0.75)))
            }
            // Integrated-Marke
            if let a = model.audio, a.integrated > -100 {
                let yy = y(a.integrated)
                var p = Path(); p.move(to: CGPoint(x: barX, y: yy)); p.addLine(to: CGPoint(x: size.width, y: yy))
                ctx.stroke(p, with: .color(.yellow), lineWidth: 1.5)
            }
        }
        .frame(minWidth: 70)
    }

    @ViewBuilder var readouts: some View {
        let a = model.audio
        value("S", currentS.map { fmt(Double($0)) } ?? "–", Palette.color(currentS.map { model.classify($0) } ?? .silent))
        value("M", currentM.map { fmt(Double($0)) } ?? "–", .white)
        Divider()
        let ok = a.map { abs($0.integrated - model.target) <= model.tolerance }
        value("Integr.", a.map { fmt($0.integrated) } ?? "–", ok == nil ? .secondary : (ok! ? Palette.ok : Palette.high))
        value("LRA", a.map { String(format: "%.1f LU", $0.lra) } ?? "–", .white)
        let tpOK = a.map { $0.truePeak <= model.truePeakLimit }
        value("True Peak", a.map { String(format: "%+.1f", $0.truePeak) } ?? "–", tpOK == nil ? .secondary : (tpOK! ? Palette.ok : Palette.truePeak))
        Divider()
        if a != nil {
            Text(String(format: "Im Ziel %.0f %%", model.stats.inRange)).font(.caption).foregroundStyle(Palette.ok)
            Text(String(format: "Zu laut %.0f %%", model.stats.tooLoud)).font(.caption).foregroundStyle(Palette.high)
            Text(String(format: "Zu leise %.0f %%", model.stats.tooQuiet)).font(.caption).foregroundStyle(Palette.low)
        }
        Spacer(minLength: 0)
    }

    func fmt(_ v: Double) -> String { v <= -100 ? "–∞" : String(format: "%.1f", v) }

    func value(_ title: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(.callout, design: .monospaced).bold()).foregroundStyle(c)
        }
    }

    var targetFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ZIELWERT").font(.caption.bold()).foregroundStyle(.secondary)
            numberRow("Ziel (LUFS)", $model.target, -50...0)
            numberRow("± Toleranz (LU)", $model.tolerance, 0...10)
            numberRow("True Peak max", $model.truePeakLimit, -10...0)
        }
    }

    func numberRow(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            TextField("", value: v, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 58)
            Stepper("", value: v, in: range, step: 0.5).labelsHidden()
        }
    }
}
