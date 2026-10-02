import Foundation

struct AudioFeatures: Sendable {
    var hostTime: UInt64 = 0
    var rms: Float = 0
    var peak: Float = 0
    var bass: Float = 0
    var lowMid: Float = 0
    var mid: Float = 0
    var highMid: Float = 0
    var treble: Float = 0
    var spectralFlux: Float = 0
    var spectralCentroid: Float = 0
    var spectrum: [Float] = Array(repeating: 0, count: 64)
}

struct TimeValue: Codable, Sendable { var time: Double; var value: Float }
struct TimeSpan: Codable, Sendable {
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}
struct PaceSpan: Codable, Sendable { var range: TimeSpan; var value: Float }
struct KeySpan: Codable, Sendable { var range: TimeSpan; var label: String; var hue: Float; var minor: Bool }

struct MusicAnalysis: Codable, Sendable {
    var version = 2
    var fingerprint: String = ""
    var duration: Double = 0
    var beats: [Double] = []
    var bars: [Double] = []
    var bpm: Float?
    var sections: [TimeSpan] = []
    var segments: [TimeSpan] = []
    var phrases: [TimeSpan] = []
    var pace: [PaceSpan] = []
    var vocal: [TimeValue] = []
    var drums: [TimeValue] = []
    var bass: [TimeValue] = []
    var other: [TimeValue] = []
    var momentary: [TimeValue] = []
    var shortTerm: [TimeValue] = []
    var integrated: Float?
    var peak: TimeValue?
    var keys: [KeySpan] = []
}

struct MusicalMoment: Sendable, Equatable {
    var bpm: Float?
    var key: String?
    var section: Int?
    var pace: Float?
    var vocal: Float?
    var drums: Float?
    var bass: Float?
    var other: Float?
    var momentary: Float?
    var shortTerm: Float?
    var integrated: Float?
    var peak: Float = 0
    var beat: Float = 0
    var bar: Float = 0
    var beatPhase: Float = 0
    var barPhase: Float = 0
    var sectionProgress: Float = 0
    var segmentProgress: Float = 0
    var phraseProgress: Float = 0
    var sectionTransition: Float = 0
    var hue: Float = 0
    var modeBias: Float = 0
}

enum VisualizerStyle: String, CaseIterable, Identifiable, Sendable {
    case ribbons
    case cassette
    var id: Self { self }
    var title: String { self == .ribbons ? "リボン" : "カセット" }
}

struct VisualFrame: Sendable {
    var trackID: UUID?
    var style = VisualizerStyle.ribbons
    var duration: Double = 0
    var title = ""
    var artist = ""
    var artwork: Data?
    var isPlaying = false
    var camera = CameraPose()
    var time: Float = 0
    var tempo: Float = 1
    var beatPhase: Float = 0
    var barPhase: Float = 0
    var sectionSeparation: Float = 0.5
    var sectionThickness: Float = 0.5
    var sectionDepth: Float = 0.5
    var sectionGlow: Float = 0.5
    var sectionWater: Float = 0.5
    var rms: Float = 0
    var peak: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var beat: Float = 0
    var bar: Float = 0
    var pace: Float = 0.35
    var vocal: Float = 0
    var drums: Float = 0
    var bassInstrument: Float = 0
    var other: Float = 0
    var sectionProgress: Float = 0
    var segmentProgress: Float = 0
    var phraseProgress: Float = 0
    var sectionTransition: Float = 0
    var hue: Float = 0
    var modeBias: Float = 0
    var loudness: Float = 0
    var density: Float = 0
    var hasAnalysis: Float = 0
    var presence: Float = 1
    var spectrum: [Float] = Array(repeating: 0, count: 64)
}

struct SectionScene: Sendable {
    var separation: Float = 0.5
    var thickness: Float = 0.5
    var depth: Float = 0.5
    var glow: Float = 0.5
    var water: Float = 0.5
}

/// UI and the render loop exchange snapshots, never shared mutable buffers.
final class VisualFrameSource: @unchecked Sendable {
    let waterInteractions = WaterInteractions()
    private let lock = NSLock()
    private var frame = VisualFrame()
    private var observer: (() -> Void)?
    func publish(_ frame: VisualFrame) {
        lock.lock()
        self.frame = frame
        let observer = self.observer
        lock.unlock()
        observer?()
    }
    func observeFrames(_ observer: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.observer = observer
    }
    func snapshot() -> VisualFrame { lock.lock(); defer { lock.unlock() }; return frame }
}

struct Track: Identifiable, Sendable {
    let id: UUID
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var artwork: Data?
    init(url: URL, title: String? = nil, artist: String = "", album: String = "", duration: Double = 0, artwork: Data? = nil) {
        self.id = UUID(); self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.artist = artist; self.album = album; self.duration = duration; self.artwork = artwork
    }
}

enum RepeatSetting: Int, CaseIterable { case off, all, one }
