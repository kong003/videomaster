import Foundation

/// Lautheits-Standard (Zielwert in LUFS/LKFS, Toleranz in LU, True-Peak-Limit in dBTP).
struct LoudnessPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String
    let target: Double
    let tolerance: Double
    let truePeak: Double
    let note: String
}

enum LoudnessPresets {
    static let customID = "custom"

    static let all: [LoudnessPreset] = [
        // Streaming / Online
        .init(id: "youtube", name: "YouTube", group: "Streaming & Online", target: -14, tolerance: 1, truePeak: -1,
              note: "YouTube normalisiert laute Inhalte auf ca. -14 LUFS herunter (leise werden nicht angehoben). True Peak ≤ -1 dBTP empfohlen."),
        .init(id: "spotify", name: "Spotify (Normal)", group: "Streaming & Online", target: -14, tolerance: 1, truePeak: -1,
              note: "Spotify normalisiert auf -14 LUFS. True Peak ≤ -1 dBTP (≤ -2 dBTP bei lauteren Masters)."),
        .init(id: "spotify-loud", name: "Spotify (Laut)", group: "Streaming & Online", target: -11, tolerance: 1, truePeak: -2,
              note: "Spotify-Einstellung „Laut“: ca. -11 LUFS, True Peak ≤ -2 dBTP."),
        .init(id: "spotify-quiet", name: "Spotify (Leise)", group: "Streaming & Online", target: -19, tolerance: 1, truePeak: -1,
              note: "Spotify-Einstellung „Leise“: ca. -19 LUFS."),
        .init(id: "apple-music", name: "Apple Music (Sound Check)", group: "Streaming & Online", target: -16, tolerance: 1, truePeak: -1,
              note: "Sound Check normalisiert auf ca. -16 LUFS. Für AAC-Overs eher -1 bis -2 dBTP."),
        .init(id: "amazon", name: "Amazon Music", group: "Streaming & Online", target: -14, tolerance: 1, truePeak: -2,
              note: "Ca. -14 LUFS (Quellen uneinheitlich)."),
        .init(id: "tidal", name: "TIDAL", group: "Streaming & Online", target: -14, tolerance: 1, truePeak: -1,
              note: "Ca. -14 LUFS."),
        .init(id: "deezer", name: "Deezer", group: "Streaming & Online", target: -15, tolerance: 1, truePeak: -1,
              note: "Ca. -15 LUFS."),
        .init(id: "soundcloud", name: "SoundCloud", group: "Streaming & Online", target: -14, tolerance: 1, truePeak: -1,
              note: "Ca. -14 LUFS (keine offizielle Normalisierung)."),
        .init(id: "social", name: "Social Media (Instagram / TikTok / Facebook)", group: "Streaming & Online", target: -14, tolerance: 1.5, truePeak: -1,
              note: "Faustwert ca. -14 LUFS – die Plattformen veröffentlichen keine offiziellen Werte."),
        .init(id: "podcast", name: "Podcast (Apple / AES TD1004)", group: "Streaming & Online", target: -16, tolerance: 1, truePeak: -1,
              note: "-16 LUFS (Stereo), -19 LUFS bei Mono."),

        // Broadcast
        .init(id: "r128", name: "EBU R128 (EU / ARD, ZDF, ORF, SRF)", group: "Broadcast / Fernsehen", target: -23, tolerance: 0.5, truePeak: -1,
              note: "-23 LUFS ±0,5 LU (Programm-Loudness), True Peak ≤ -1 dBTP."),
        .init(id: "r128-1", name: "EBU R128 (±1 LU, Live)", group: "Broadcast / Fernsehen", target: -23, tolerance: 1, truePeak: -1,
              note: "Wie R128, aber ±1 LU (Live-Produktionen)."),
        .init(id: "atsc", name: "ATSC A/85 (USA)", group: "Broadcast / Fernsehen", target: -24, tolerance: 2, truePeak: -2,
              note: "-24 LKFS ±2 LU (Dialog-gated), True Peak ≤ -2 dBTP. Hier wird Integrated (BS.1770) gemessen."),
        .init(id: "arib", name: "ARIB TR-B32 (Japan)", group: "Broadcast / Fernsehen", target: -24, tolerance: 1, truePeak: -1,
              note: "-24 LKFS ±1 LU. True Peak laut Quellen -1 oder -2 dBTP."),
        .init(id: "op59", name: "OP-59 (Australien)", group: "Broadcast / Fernsehen", target: -24, tolerance: 1, truePeak: -2,
              note: "-24 LKFS ±1 LU, True Peak ≤ -2 dBTP."),

        // Film / Streaming-Dienste
        .init(id: "netflix", name: "Netflix", group: "Film & VoD", target: -27, tolerance: 2, truePeak: -2,
              note: "-27 LKFS ±2 LU, **dialog-gated** gemessen (hier nur Integrated), True Peak ≤ -2 dBTP. Bitte gegen die aktuelle Netflix-Spec prüfen."),
    ]

    static func preset(id: String) -> LoudnessPreset? { all.first { $0.id == id } }

    static var groups: [(String, [LoudnessPreset])] {
        var order: [String] = []
        for p in all where !order.contains(p.group) { order.append(p.group) }
        return order.map { g in (g, all.filter { $0.group == g }) }
    }
}

/// Schwellwerte für die automatische Erkennung von Über-/Unterbelichtung.
/// Luma-Werte sind 0…1 (Rec.709-Luma auf dem dekodierten Bild).
struct ExposureSettings: Equatable, Hashable {
    var overLevel: Double = 0.97      // Pixel ab diesem Luma-Wert gelten als „ausgebrannt“
    var overPercent: Double = 8       // Anteil dieser Pixel (%) ab dem das Bild markiert wird
    var underLevel: Double = 0.03     // Pixel bis zu diesem Luma-Wert gelten als „abgesoffen“
    var underPercent: Double = 60     // Anteil (%) ab dem markiert wird
    var meanOver: Double = 0.85       // mittlere Helligkeit ab der markiert wird
    var meanUnder: Double = 0.06      // mittlere Helligkeit bis zu der markiert wird
}

struct ExposurePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let settings: ExposureSettings
    let note: String

    static let customID = "custom"

    static let all: [ExposurePreset] = [
        .init(id: "standard", name: "Standard", settings: ExposureSettings(),
              note: "Markiert deutlich über- oder unterbelichtete Stellen."),
        .init(id: "broadcast", name: "Broadcast streng (an EBU R103 angelehnt)",
              settings: ExposureSettings(overLevel: 0.95, overPercent: 1, underLevel: 0.02, underPercent: 20, meanOver: 0.80, meanUnder: 0.08),
              note: "Schon kleine Flächen mit Clipping werden markiert."),
        .init(id: "web", name: "Web / Kreativ (tolerant)",
              settings: ExposureSettings(overLevel: 0.98, overPercent: 20, underLevel: 0.03, underPercent: 80, meanOver: 0.90, meanUnder: 0.04),
              note: "Nur sehr extreme Stellen werden markiert."),
    ]

    static func preset(id: String) -> ExposurePreset? { all.first { $0.id == id } }
}
