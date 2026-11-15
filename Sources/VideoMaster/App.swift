import SwiftUI
import AppKit

@main
struct VideoMasterApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let path = ProcessInfo.processInfo.environment["VIDEOMASTER_RENDER"] {
            Task { @MainActor in await VideoMasterApp.renderTest(URL(fileURLWithPath: path), out: ProcessInfo.processInfo.environment["VIDEOMASTER_OUT"] ?? "/tmp/tl.png"); exit(0) }
        }
        if let path = ProcessInfo.processInfo.environment["VIDEOMASTER_SELFTEST"] {
            Task { await VideoMasterApp.selfTest(URL(fileURLWithPath: path)); exit(0) }
        }
    }

    var body: some Scene {
        WindowGroup("VideoMaster") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.playback)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
                    if let first = args.first, FileManager.default.fileExists(atPath: first), model.url == nil {
                        model.load(URL(fileURLWithPath: first))
                    }
                }
                .onOpenURL { model.load($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Video öffnen…") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

extension VideoMasterApp {
    @MainActor static func renderTest(_ url: URL, out: String) async {
        let model = AppModel()
        model.load(url)
        while model.audioStatus != .done || model.exposureStatus != .done { try? await Task.sleep(nanoseconds: 200_000_000) }
        let view = TimelinePane().environmentObject(model).environmentObject(model.playback)
            .frame(width: 1200, height: 210).background(Color(white: 0.13)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 1
        if let img = r.cgImage {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }

    /// Headless-Test: VIDEOMASTER_SELFTEST=/pfad/video.mp4 .../VideoMaster
    static func selfTest(_ url: URL) async {
        do {
            if let a = try await LoudnessAnalyzer.analyze(url: url, progress: { _ in }) {
                print(String(format: "Integrated %.2f LUFS, LRA %.1f, TruePeak %.2f dBTP, SamplePeak %.2f dBFS", a.integrated, a.lra, a.truePeak, a.samplePeak))
                for t in [5.0, 20.0, 35.0] { print(String(format: "t=%.0f s  S=%.1f  M=%.1f", t, a.shortTerm[Int(t * 10)], a.momentary[Int(t * 10)])) }
            }
            if let e = try await ExposureAnalyzer.scan(url: url, progress: { _ in }) {
                if ProcessInfo.processInfo.environment["VM_DEBUG"] != nil {
                    for (i, t) in e.times.enumerated() { print(String(format: "  t=%.1f mean=%.3f", t, e.mean[i])) }
                }
                for m in ExposureAnalyzer.markers(data: e, settings: ExposureSettings()) {
                    print(String(format: "Marker %@ %.1f–%.1f s", m.label, m.start, m.end))
                }
            }
        } catch { print("Fehler:", error) }
    }
}
