import SwiftUI
import AVKit
import UniformTypeIdentifiers

enum Palette {
    static let ok = Color(red: 0.25, green: 0.80, blue: 0.40)
    static let nearHigh = Color(red: 1.0, green: 0.65, blue: 0.15)
    static let high = Color(red: 0.95, green: 0.25, blue: 0.25)
    static let nearLow = Color(red: 0.35, green: 0.80, blue: 0.95)
    static let low = Color(red: 0.25, green: 0.45, blue: 0.95)
    static let silent = Color(white: 0.45)
    static let over = Color(red: 1.0, green: 0.95, blue: 0.35)
    static let under = Color(red: 0.70, green: 0.40, blue: 0.95)
    static let truePeak = Color(red: 1.0, green: 0.30, blue: 0.70)
    static let panel = Color(white: 0.13)

    /// Stufenloser Verlauf: grün im Ziel, über Gelb/Orange nach Rot (zu laut) bzw. Cyan nach Blau (zu leise).
    static func gradient(_ dev: Double, tol: Double) -> Color {
        let e = max(0, abs(dev) - tol) / max(3.0, tol * 2)   // 0 = am Rand des Zielbereichs, 1 = deutlich daneben
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
            let t = min(1, max(0, t))
            return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
        }
        let g = (0.25, 0.80, 0.40)
        if dev >= 0 {
            return e < 0.5 ? mix(g, (1.0, 0.65, 0.15), e * 2) : mix((1.0, 0.65, 0.15), (0.95, 0.2, 0.2), (e - 0.5) * 2)
        }
        return e < 0.5 ? mix(g, (0.35, 0.80, 0.95), e * 2) : mix((0.35, 0.80, 0.95), (0.25, 0.4, 0.95), (e - 0.5) * 2)
    }

    static func color(_ c: LoudClass) -> Color {
        switch c {
        case .silent: return silent
        case .ok: return ok
        case .nearHigh: return nearHigh
        case .high: return high
        case .nearLow: return nearLow
        case .low: return low
        }
    }

    static func color(_ k: Marker.Kind) -> Color {
        switch k {
        case .over: return over
        case .under: return under
        case .truePeak: return truePeak
        }
    }
}

extension View {
    func panel() -> some View {
        self.background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
    }
}

func timecode(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "00:00:00.00" }
    let cs = Int((t * 100).rounded())
    return String(format: "%02d:%02d:%02d.%02d", cs / 360000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showMarkers = false
    @State private var showExposure = false
    @State private var showLegend = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                VideoPane().panel()
                ScopePane().frame(width: 360).panel()
                LoudnessPane().frame(width: 200).panel()
            }
            TransportBar().panel()
            TimelinePane().frame(height: 260).panel()
        }
        .padding(8)
        .background(Color(white: 0.08))
        .toolbar {
            ToolbarItem {
                Button { model.showImporter = true } label: { Label("Öffnen", systemImage: "folder") }
            }
            ToolbarItem {
                Picker("Audio-Standard", selection: Binding(get: { model.audioPresetID }, set: { model.applyAudioPreset($0) })) {
                    if model.audioPresetID == LoudnessPresets.customID {
                        Text("Benutzerdefiniert").tag(LoudnessPresets.customID)
                    }
                    ForEach(LoudnessPresets.groups, id: \.0) { group, presets in
                        Section(group) {
                            ForEach(presets) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                .frame(width: 260)
                .help(LoudnessPresets.preset(id: model.audioPresetID)?.note ?? "Eigene Werte")
            }
            ToolbarItem {
                Button { showExposure.toggle() } label: { Label("Belichtung", systemImage: "sun.max") }
                    .popover(isPresented: $showExposure) { ExposurePopover() }
            }
            ToolbarItem {
                Button { showMarkers.toggle() } label: { Label("Markierungen (\(model.markers.count))", systemImage: "flag") }
                    .popover(isPresented: $showMarkers) { MarkerPopover() }
            }
            ToolbarItem {
                Button { showLegend.toggle() } label: { Label("Legende", systemImage: "questionmark.circle") }
                    .popover(isPresented: $showLegend) { LegendPopover() }
            }
            ToolbarItem { StatusBadge().frame(minWidth: 20, minHeight: 20) }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.movie, .audiovisualContent]) { result in
            if case .success(let url) = result { model.load(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            model.load(u)
            return true
        }
    }
}

struct StatusBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            badge("Audio", model.audioStatus)
            badge("Video", model.exposureStatus)
        }
    }

    @ViewBuilder func badge(_ name: String, _ s: AnalysisStatus) -> some View {
        switch s {
        case .idle: EmptyView()
        case .running(let p):
            HStack(spacing: 4) { ProgressView(value: p).frame(width: 50); Text("\(name) \(Int(p * 100)) %").font(.caption) }
        case .done: Label(name, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .unavailable(let m): Text("\(name): \(m)").font(.caption).foregroundStyle(.secondary)
        case .failed(let m): Text("\(name): \(m)").font(.caption).foregroundStyle(.red).lineLimit(1)
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

struct VideoPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black
            if model.url == nil {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 40))
                    Text("Video hierher ziehen oder ⌘O").font(.headline)
                }.foregroundStyle(.secondary)
            } else {
                PlayerView(player: model.player)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var playback: Playback

    var body: some View {
        HStack(spacing: 10) {
            Button { model.previousMarker() } label: { Image(systemName: "flag.slash") }.help("Vorherige Markierung")
            Button { model.skip(-5) } label: { Image(systemName: "gobackward.5") }.keyboardShortcut(.leftArrow, modifiers: .option)
            Button { model.step(-1) } label: { Image(systemName: "backward.frame") }.keyboardShortcut(.leftArrow, modifiers: [])
            Button { model.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }.keyboardShortcut(.space, modifiers: [])
            Button { model.step(1) } label: { Image(systemName: "forward.frame") }.keyboardShortcut(.rightArrow, modifiers: [])
            Button { model.skip(5) } label: { Image(systemName: "goforward.5") }.keyboardShortcut(.rightArrow, modifiers: .option)
            Button { model.nextMarker() } label: { Image(systemName: "flag") }.help("Nächste Markierung")

            Text("\(timecode(playback.time)) / \(timecode(model.duration))")
                .font(.system(.body, design: .monospaced))
                .padding(.leading, 8)

            Spacer()

            ViewThatFits(in: .horizontal) {
                CompactLegend()
                EmptyView()
            }

            if model.viewSpan < model.duration - 0.01 {
                Slider(value: Binding(get: { model.viewStart },
                                      set: { model.viewStart = min($0, max(0, model.duration - model.viewSpan)) }),
                       in: 0...max(0.1, model.duration - model.viewSpan))
                    .frame(width: 160)
            }
            Button { model.zoom(by: 2) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { model.zoom(by: 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { model.fitAll() } label: { Text("Alles") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct MarkerPopover: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automatische Markierungen").font(.headline)
            HStack(spacing: 12) {
                legend(Palette.over, "Überbelichtet"); legend(Palette.under, "Unterbelichtet"); legend(Palette.truePeak, "True Peak")
            }.font(.caption)
            Divider()
            if model.markers.isEmpty {
                Text("Keine Auffälligkeiten gefunden (oder Analyse läuft noch).").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.markers) { m in
                            Button { model.seek(m.start); } label: {
                                HStack {
                                    Circle().fill(Palette.color(m.kind)).frame(width: 9, height: 9)
                                    Text(timecode(m.start)).font(.system(.caption, design: .monospaced))
                                    Text(m.label).font(.caption)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 320)
            }
        }
        .padding(12).frame(width: 340)
    }
    func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }
}

struct ExposurePopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Belichtungs-Erkennung").font(.headline)
            Picker("Standard", selection: Binding(get: { model.exposurePresetID }, set: { model.applyExposurePreset($0) })) {
                if model.exposurePresetID == ExposurePreset.customID { Text("Benutzerdefiniert").tag(ExposurePreset.customID) }
                ForEach(ExposurePreset.all) { Text($0.name).tag($0.id) }
            }
            Divider()
            row("Überbelichtet ab Luma", $model.exposureSettings.overLevel, 0.8...1.0, "%.2f")
            row("… bei Flächenanteil (%)", $model.exposureSettings.overPercent, 0.5...50, "%.1f")
            row("Mittlere Helligkeit über", $model.exposureSettings.meanOver, 0.5...1.0, "%.2f")
            row("Unterbelichtet bis Luma", $model.exposureSettings.underLevel, 0...0.2, "%.2f")
            row("… bei Flächenanteil (%)", $model.exposureSettings.underPercent, 5...100, "%.0f")
            row("Mittlere Helligkeit unter", $model.exposureSettings.meanUnder, 0...0.3, "%.2f")
            Text("Gemessen an Rec.709-Luma des dekodierten Bildes (0 = Schwarz, 1 = Weiß). Die Markierungen aktualisieren sich sofort.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 340)
    }

    func row(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 150, alignment: .leading)
            Slider(value: v, in: r)
            Text(String(format: f, v.wrappedValue)).font(.system(.caption, design: .monospaced)).frame(width: 40)
        }
    }
}


struct CompactLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(Palette.low, "zu leise")
            item(Palette.ok, "im Ziel")
            item(Palette.high, "zu laut")
            Divider().frame(height: 12)
            item(Palette.over, "überbelichtet")
            item(Palette.under, "unterbelichtet")
            item(Palette.truePeak, "True Peak")
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize()
    }
    func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10); Text(t) }
    }
}

struct LegendPopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Legende").font(.headline)

            section("Audio-Waveform (Farbe = Lautheit vs. Ziel)")
            row(Palette.low, "Blau", String(format: "Zu leise: mehr als %.1f LU unter dem Ziel (%.1f LUFS)", model.tolerance, model.target))
            row(Palette.ok, "Grün", "Im Zielbereich")
            row(Color(red: 1.0, green: 0.85, blue: 0.2), "Gelb", "Im Zielbereich, aber nahe an der oberen Grenze (gelbe Spitze)")
            row(Palette.high, "Rote Spitze", "Zu laut: die Höhe des roten Teils entspricht dem Überschuss in dB – so viel müsste man absenken")
            row(Palette.silent, "Grau", "Stille (unter -70 LUFS)")

            section("Markierungen (unterste Spur)")
            row(Palette.over, "Gelb", "Überbelichtet: zu viele ausgebrannte Pixel oder Bild insgesamt zu hell")
            row(Palette.under, "Lila", "Unterbelichtet: zu viele abgesoffene Pixel oder Bild insgesamt zu dunkel")
            row(Palette.truePeak, "Pink", String(format: "True Peak über dem Limit (%.1f dBTP)", model.truePeakLimit))

            section("Lautstärke-Kurve und Meter")
            row(.white, "Weiße Kurve", "Lautheit über die Zeit (Kurzzeit 3 s bzw. Momentan, je nach Auswahl)")
            row(Palette.ok.opacity(0.5), "Grüne Zone", "Zielbereich (Ziel ± Toleranz)")
            row(.yellow, "Gelbe Linie", "Integrated-Lautheit des ganzen Videos (im Meter)")

            Text("Klick auf eine Markierung in der Liste (Flaggen-Symbol) springt an die Stelle.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 420)
    }

    func section(_ t: String) -> some View {
        Text(t).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
    }

    func row(_ c: Color, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: 14).padding(.top, 1)
            Text(name).font(.callout.bold()).frame(width: 90, alignment: .leading)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
