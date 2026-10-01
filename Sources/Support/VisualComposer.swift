import Foundation

struct VisualComposer {
    private var frame = VisualFrame()
    private var hue: Float = 0
    private var camera = AutomaticCamera()

    mutating func compose(time: Double, audio: AudioFeatures, moment: MusicalMoment, scene: SectionScene?, analyzed: Bool, presence: Float, dt: Float) -> VisualFrame {
        func smooth(_ old: Float, _ target: Float, attack: Float = 0.025, release: Float = 0.25) -> Float {
            let tau = target > old ? attack : release
            return old + (target - old) * (1 - exp(-max(0, dt) / tau))
        }
        func level(_ x: Float) -> Float { min(1, max(0, x)) }
        frame.time = Float(time)
        frame.tempo = smooth(frame.tempo, moment.bpm.map { min(2, max(0.4, $0 / 120)) } ?? 1, attack: 0.6, release: 0.8)
        frame.beatPhase = moment.beatPhase
        frame.barPhase = moment.barPhase
        let layout = scene ?? SectionScene()
        frame.sectionSeparation = smooth(frame.sectionSeparation, layout.separation, attack: 1.5, release: 1.5)
        frame.sectionThickness = smooth(frame.sectionThickness, layout.thickness, attack: 1.5, release: 1.5)
        frame.sectionDepth = smooth(frame.sectionDepth, layout.depth, attack: 1.5, release: 1.5)
        frame.sectionGlow = smooth(frame.sectionGlow, layout.glow, attack: 1.5, release: 1.5)
        frame.sectionWater = smooth(frame.sectionWater, layout.water, attack: 1.5, release: 1.5)
        frame.rms = smooth(frame.rms, level(audio.rms * 3))
        frame.peak = smooth(frame.peak, level(max(audio.peak, moment.peak)), attack: 0.008, release: 0.08)
        frame.bass = smooth(frame.bass, level(audio.bass + audio.lowMid * 0.2))
        frame.mid = smooth(frame.mid, level(audio.mid))
        frame.treble = smooth(frame.treble, level(audio.treble + audio.highMid * 0.15))
        frame.beat = moment.beat
        frame.bar = moment.bar
        // Pace is a musical activity estimate, not a second BPM.
        frame.pace = smooth(frame.pace, moment.pace.map { level($0 / 180) } ?? 0.35, attack: 0.6, release: 0.8)
        frame.vocal = smooth(frame.vocal, moment.vocal ?? 0, attack: 0.15, release: 0.5)
        frame.drums = smooth(frame.drums, moment.drums ?? 0)
        frame.bassInstrument = smooth(frame.bassInstrument, moment.bass ?? 0)
        frame.other = smooth(frame.other, moment.other ?? 0)
        frame.sectionProgress = moment.sectionProgress
        frame.segmentProgress = moment.segmentProgress
        frame.phraseProgress = moment.phraseProgress
        frame.sectionTransition = moment.sectionTransition
        hue = smooth(hue, moment.hue, attack: 1.5, release: 1.5)
        frame.hue = hue
        frame.modeBias = smooth(frame.modeBias, moment.modeBias, attack: 1.5, release: 1.5)
        // Relative to the song's own integrated loudness; never substitute it into the UI.
        let reference = moment.integrated ?? -18
        frame.loudness = smooth(frame.loudness, moment.momentary.map { level(($0 - reference + 12) / 24) } ?? frame.rms)
        frame.density = smooth(frame.density, moment.shortTerm.map { level(($0 - reference + 12) / 24) } ?? frame.rms, attack: 0.5, release: 0.8)
        frame.hasAnalysis = analyzed ? 1 : 0
        frame.camera = camera.update(time: time, moment: moment, scene: scene, analyzed: analyzed, dt: dt)
        frame.presence = presence
        for index in 0..<64 { frame.spectrum[index] = smooth(frame.spectrum[index], audio.spectrum[index]) }
        return frame
    }
}
