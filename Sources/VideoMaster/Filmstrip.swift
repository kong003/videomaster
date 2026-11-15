import SwiftUI
import AVFoundation

/// Lädt Vorschaubilder für die Video-Spur der Timeline (nur für den sichtbaren Bereich, mit Cache).
@MainActor
final class FilmstripStore: ObservableObject {
    struct Key: Hashable { let step: Double; let k: Int }

    @Published private(set) var images: [Key: CGImage] = [:]
    private var generator: AVAssetImageGenerator?
    private var pending = Set<Key>()
    private var duration = 0.0
    private var generation = 0

    func setURL(_ url: URL?, duration: Double) {
        generation += 1
        images = [:]; pending = []
        self.duration = duration
        guard let url else { generator = nil; return }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 240, height: 135)
        generator = g
    }

    func setDuration(_ d: Double) { duration = d }

    func time(for key: Key) -> Double { min(max(0, (Double(key.k) + 0.5) * key.step), max(0, duration - 0.05)) }

    func request(_ keys: [Key]) {
        guard let g = generator else { return }
        let missing = keys.filter { images[$0] == nil && !pending.contains($0) }
        guard !missing.isEmpty else { return }
        if images.count > 600 { images = [:] }
        missing.forEach { pending.insert($0) }
        let gen = generation
        var byMs: [Int: Key] = [:]
        var times: [CMTime] = []
        for key in missing {
            let t = time(for: key)
            byMs[Int((t * 1000).rounded())] = key
            times.append(CMTime(seconds: t, preferredTimescale: 600))
        }
        let step = missing[0].step
        let tol = CMTime(seconds: step / 3, preferredTimescale: 600)
        g.requestedTimeToleranceBefore = tol
        g.requestedTimeToleranceAfter = tol
        Task { [weak self] in
            for await result in g.images(for: times) {
                guard let self, self.generation == gen else { return }
                let ms = Int((result.requestedTime.seconds * 1000).rounded())
                if let key = byMs[ms] {
                    self.pending.remove(key)
                    if let img = try? result.image { self.images[key] = img }
                }
            }
            guard let self, self.generation == gen else { return }
            for key in missing { self.pending.remove(key) }
        }
    }
}

struct FilmstripView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: FilmstripStore

    struct Request: Hashable { var start: Double; var span: Double; var width: Double; var url: URL?; var duration: Double }

    static let steps: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    func layout(_ w: CGFloat, _ h: CGFloat) -> (step: Double, range: ClosedRange<Int>)? {
        guard model.duration > 0, model.viewSpan > 0, w > 0 else { return nil }
        let pxPerSec = Double(w) / model.viewSpan
        let tileW = Double(h) * 16 / 9
        let step = Self.steps.first { $0 * pxPerSec >= tileW } ?? Self.steps.last!
        let k0 = max(0, Int(floor(model.viewStart / step)))
        let k1 = min(Int(floor(model.duration / step)), Int(floor((model.viewStart + model.viewSpan) / step)))
        guard k1 >= k0 else { return nil }
        return (step, k0...k1)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.05)))
                guard let (step, range) = layout(size.width, size.height) else { return }
                let pxPerSec = Double(size.width) / model.viewSpan
                for k in range {
                    let x = CGFloat((Double(k) * step - model.viewStart) * pxPerSec)
                    let tw = CGFloat(step * pxPerSec)
                    let rect = CGRect(x: x, y: 0, width: tw, height: size.height)
                    guard let img = store.images[.init(step: step, k: k)] else {
                        ctx.fill(Path(rect.insetBy(dx: 0.5, dy: 0)), with: .color(Color(white: 0.09)))
                        continue
                    }
                    // Aspect-Fill in die Kachel
                    let ia = CGFloat(img.width) / CGFloat(img.height)
                    var fill = rect
                    if ia > rect.width / rect.height {
                        fill.size.width = rect.height * ia; fill.origin.x = rect.midX - fill.width / 2
                    } else {
                        fill.size.height = rect.width / ia; fill.origin.y = rect.midY - fill.height / 2
                    }
                    var c = ctx
                    c.clip(to: Path(rect))
                    c.draw(Image(decorative: img, scale: 1), in: fill)
                    var edge = Path(); edge.move(to: CGPoint(x: x, y: 0)); edge.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(edge, with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
            .task(id: Request(start: model.viewStart, span: model.viewSpan, width: Double(geo.size.width), url: model.url, duration: model.duration)) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
                store.setDuration(model.duration)
                guard let (step, range) = layout(geo.size.width, geo.size.height) else { return }
                store.request(range.map { .init(step: step, k: $0) })
            }
        }
        .allowsHitTesting(false)
    }
}
