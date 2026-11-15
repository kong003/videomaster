import SwiftUI
import AVFoundation
import Combine

enum AnalysisStatus: Equatable {
    case idle
    case running(Double)
    case done
    case unavailable(String)
    case failed(String)
}

enum MeterMode: String, CaseIterable, Identifiable {
    case shortTerm, momentary
    var id: String { rawValue }
    var title: String { self == .shortTerm ? "Kurzzeit (3 s)" : "Momentan (400 ms)" }
}

enum LoudClass { case silent, ok, nearHigh, high, nearLow, low }

struct ComplianceStats {
    var inRange = 0.0
    var tooLoud = 0.0
    var tooQuiet = 0.0
}

/// Wiedergabezustand getrennt vom restlichen Modell, damit 30 Hz Updates nicht alles neu zeichnen.
@MainActor
final class Playback: ObservableObject {
    @Published var time: Double = 0
    @Published var isPlaying = false
    @Published var scopeImage: CGImage?
    @Published var scopeStats = ScopeStats()
}

@MainActor
final class AppModel: ObservableObject {
    let player = AVPlayer()
    let playback = Playback()
    let filmstrip = FilmstripStore()

    @Published var url: URL?
    @Published var duration: Double = 0
    @Published var audio: LoudnessAnalysis?
    @Published var audioStatus: AnalysisStatus = .idle
    @Published var exposure: ExposureData?
    @Published var exposureStatus: AnalysisStatus = .idle
    @Published var markers: [Marker] = []
    @Published var stats = ComplianceStats()
    @Published var showImporter = false

    @Published var viewStart = 0.0
    @Published var viewSpan = 1.0

    @Published var scopeMode: ScopeMode {
        didSet { UserDefaults.standard.set(scopeMode.rawValue, forKey: "scopeMode"); scopeDirty = true; pollFrame() }
    }
    @Published var meterMode: MeterMode {
        didSet { UserDefaults.standard.set(meterMode.rawValue, forKey: "meterMode"); recomputeStats() }
    }

    // Lautheits-Ziel
    @Published var audioPresetID: String
    private var applying = false
    @Published var target: Double { didSet { if target != oldValue { targetEdited() } } }
    @Published var tolerance: Double { didSet { if tolerance != oldValue { targetEdited() } } }
    @Published var truePeakLimit: Double { didSet { if truePeakLimit != oldValue { targetEdited() } } }

    // Belichtung
    @Published var exposurePresetID: String
    @Published var exposureSettings: ExposureSettings {
        didSet {
            if !applying { exposurePresetID = ExposurePreset.customID }
            saveDefaults(); recomputeMarkers(); scopeDirty = true
        }
    }

    private var videoOutput: AVPlayerItemVideoOutput?
    private var lastBuffer: CVPixelBuffer?
    private var scopeDirty = true
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var audioTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var pollTimer: Timer?

    init() {
        let d = UserDefaults.standard
        audioPresetID = d.string(forKey: "audioPreset") ?? "r128"
        let p = LoudnessPresets.preset(id: d.string(forKey: "audioPreset") ?? "r128") ?? LoudnessPresets.all[0]
        target = d.object(forKey: "target") as? Double ?? p.target
        tolerance = d.object(forKey: "tolerance") as? Double ?? p.tolerance
        truePeakLimit = d.object(forKey: "truePeak") as? Double ?? p.truePeak
        exposurePresetID = d.string(forKey: "exposurePreset") ?? "standard"
        exposureSettings = ExposurePreset.preset(id: d.string(forKey: "exposurePreset") ?? "standard")?.settings ?? ExposureSettings()
        if let raw = d.string(forKey: "scopeMode"), let m = ScopeMode(rawValue: raw) { scopeMode = m } else { scopeMode = .combined }
        if let raw = d.string(forKey: "meterMode"), let m = MeterMode(rawValue: raw) { meterMode = m } else { meterMode = .shortTerm }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.timeTick(t.seconds) }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.playback.isPlaying = (s != .paused) }
            .store(in: &cancellables)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    // MARK: Laden

    func load(_ url: URL) {
        audioTask?.cancel(); videoTask?.cancel()
        self.url = url
        audio = nil; exposure = nil; markers = []; stats = ComplianceStats()
        audioStatus = .running(0); exposureStatus = .running(0)
        playback.time = 0; playback.scopeImage = nil; lastBuffer = nil

        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(out)
        videoOutput = out
        player.replaceCurrentItem(with: item)
        scopeDirty = true

        Task { [weak self] in
            let d = (try? await item.asset.load(.duration).seconds) ?? 0
            guard let self, self.url == url else { return }
            self.duration = d.isFinite ? d : 0
            self.viewStart = 0; self.viewSpan = max(self.duration, 1)
            self.filmstrip.setURL(url, duration: self.duration)
        }

        audioTask = Task { [weak self] in
            do {
                let res = try await LoudnessAnalyzer.analyze(url: url) { p in
                    Task { @MainActor in
                        if case .running = self?.audioStatus { self?.audioStatus = .running(p) }
                    }
                }
                guard let self, self.url == url else { return }
                if let res {
                    self.audio = res
                    self.audioStatus = .done
                    self.recomputeStats(); self.recomputeMarkers()
                } else {
                    self.audioStatus = .unavailable("Keine Audiospur")
                }
            } catch is CancellationError {
            } catch {
                self?.audioStatus = .failed(error.localizedDescription)
            }
        }
        videoTask = Task { [weak self] in
            do {
                let res = try await ExposureAnalyzer.scan(url: url) { p in
                    Task { @MainActor in
                        if case .running = self?.exposureStatus { self?.exposureStatus = .running(p) }
                    }
                }
                guard let self, self.url == url else { return }
                if let res {
                    self.exposure = res
                    self.exposureStatus = .done
                    self.recomputeMarkers()
                } else {
                    self.exposureStatus = .unavailable("Keine Videospur")
                }
            } catch is CancellationError {
            } catch {
                self?.exposureStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Wiedergabe

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if playback.isPlaying { player.pause() } else {
            if duration > 0, playback.time >= duration - 0.05 { seek(0) }
            player.play()
        }
    }

    func seek(_ t: Double) {
        let c = min(max(0, t), max(duration, 0))
        playback.time = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        scopeDirty = true
    }

    func skip(_ dt: Double) { seek(playback.time + dt) }

    func step(_ n: Int) {
        player.pause()
        player.currentItem?.step(byCount: n)
        scopeDirty = true
    }

    func nextMarker() { if let m = markers.first(where: { $0.start > playback.time + 0.2 }) { seek(m.start) } }
    func previousMarker() { if let m = markers.last(where: { $0.start < playback.time - 0.5 }) { seek(m.start) } }

    private func timeTick(_ t: Double) {
        guard t.isFinite else { return }
        playback.time = t
        if playback.isPlaying, viewSpan < duration - 0.01 {
            if t > viewStart + viewSpan * 0.97 || t < viewStart {
                viewStart = min(max(0, t - viewSpan * 0.05), duration - viewSpan)
            }
        }
    }

    // MARK: Zoom

    func zoom(by factor: Double) {
        guard duration > 0 else { return }
        let center = playback.time
        let newSpan = min(duration, max(2, viewSpan * factor))
        let frac = viewSpan > 0 ? (center - viewStart) / viewSpan : 0.5
        let clampedFrac = min(max(frac, 0), 1)
        viewSpan = newSpan
        viewStart = min(max(0, center - clampedFrac * newSpan), max(0, duration - newSpan))
    }

    func fitAll() { viewStart = 0; viewSpan = max(duration, 1) }

    // MARK: Standards

    func applyAudioPreset(_ id: String) {
        guard let p = LoudnessPresets.preset(id: id) else { audioPresetID = LoudnessPresets.customID; return }
        applying = true
        target = p.target; tolerance = p.tolerance; truePeakLimit = p.truePeak
        audioPresetID = id
        applying = false
        saveDefaults(); recomputeStats(); recomputeMarkers()
    }

    func applyExposurePreset(_ id: String) {
        guard let p = ExposurePreset.preset(id: id) else { return }
        applying = true
        exposureSettings = p.settings
        exposurePresetID = id
        applying = false
        saveDefaults(); recomputeMarkers()
    }

    private func targetEdited() {
        if !applying { audioPresetID = LoudnessPresets.customID }
        saveDefaults(); recomputeStats(); recomputeMarkers()
    }

    private func saveDefaults() {
        let d = UserDefaults.standard
        d.set(audioPresetID, forKey: "audioPreset")
        d.set(target, forKey: "target"); d.set(tolerance, forKey: "tolerance"); d.set(truePeakLimit, forKey: "truePeak")
        d.set(exposurePresetID, forKey: "exposurePreset")
    }

    // MARK: Auswertung

    func classify(_ v: Float) -> LoudClass {
        if v < -70 { return .silent }
        let d = Double(v) - target
        if abs(d) <= tolerance { return .ok }
        let near = max(1.0, tolerance)
        if d > 0 { return d - tolerance <= near ? .nearHigh : .high }
        return -d - tolerance <= near ? .nearLow : .low
    }

    var activeSeries: [Float] {
        guard let a = audio else { return [] }
        return meterMode == .shortTerm ? a.shortTerm : a.momentary
    }

    func recomputeStats() {
        let s = activeSeries
        var ok = 0, hi = 0, lo = 0, n = 0
        for v in s {
            switch classify(v) {
            case .silent: continue
            case .ok: ok += 1
            case .nearHigh, .high: hi += 1
            case .nearLow, .low: lo += 1
            }
            n += 1
        }
        let t = Double(max(1, n))
        stats = ComplianceStats(inRange: Double(ok) / t * 100, tooLoud: Double(hi) / t * 100, tooQuiet: Double(lo) / t * 100)
    }

    func recomputeMarkers() {
        var m: [Marker] = []
        if let e = exposure { m += ExposureAnalyzer.markers(data: e, settings: exposureSettings) }
        if let a = audio {
            var start: Int?
            var peak: Float = -200
            func flush(_ end: Int) {
                guard let s = start else { return }
                m.append(Marker(start: Double(s) * a.blockDuration, end: Double(end) * a.blockDuration, kind: .truePeak,
                                label: String(format: "True Peak %+.1f dBTP", peak)))
                start = nil; peak = -200
            }
            for (i, v) in a.truePeakBlocks.enumerated() {
                if Double(v) > truePeakLimit {
                    if start == nil { start = i }
                    peak = max(peak, v)
                } else { flush(i) }
            }
            flush(a.truePeakBlocks.count)
        }
        markers = m.sorted { $0.start < $1.start }
    }

    // MARK: Scope

    func pollFrame() {
        guard let out = videoOutput, let item = player.currentItem else { return }
        let t = item.currentTime()
        var buffer: CVPixelBuffer?
        if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            lastBuffer = pb
            buffer = pb
        } else if scopeDirty, let pb = lastBuffer {
            buffer = pb
        } else if scopeDirty, let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            lastBuffer = pb
            buffer = pb
        }
        guard let pb = buffer else { return }
        scopeDirty = false
        if let (img, st) = ScopeRenderer.render(pb, mode: scopeMode, settings: exposureSettings) {
            playback.scopeImage = img
            playback.scopeStats = st
        }
    }

    // Lesewerte für die Anzeige an der aktuellen Position
    func value(at time: Double, in series: [Float]) -> Float? {
        guard !series.isEmpty else { return nil }
        let i = min(series.count - 1, max(0, Int(time / 0.1)))
        return series[i]
    }
}
