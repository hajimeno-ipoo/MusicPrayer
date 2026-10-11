import SwiftUI

/// Every value is derived from the current playback snapshot, including after a seek.
struct LyricMotionParameters: Equatable, Sendable {
    var opacity: Double
    var scale: Double
    var blur: Double
    var x: Double
    var y: Double
    var progress: Double
    var glowOpacity: Double
    var glowRadius: Double
}

enum LyricMotion {
    /// Prepare the row for reading within its current musical frame and bar.
    /// These are presentation times; Speech/character times remain untouched.
    static func displayStarts(_ timeline: LyricTimeline, analysis: MusicAnalysis?) -> [Int: Double] {
        guard let analysis, analysis.fingerprint == timeline.analysisFingerprint else { return [:] }
        var starts: [Int: Double] = [:]
        var previousEnd = 0.0
        for line in timeline.lines {
            defer { previousEnd = line.end }
            guard let frame = timeline.frames.first(where: {
                $0.start <= line.start && line.start < $0.end && $0.lineOrdinals.contains(line.ordinal)
            }), let voice = analysis.instrumentRanges.vocal.first(where: {
                $0.start <= line.start && line.start < $0.end
            }), let bar = analysis.bars.last(where: { $0 <= line.start }) else { continue }
            starts[line.ordinal] = max(frame.start, voice.start, bar, previousEnd)
        }
        return starts
    }

    static func visibleLines(_ timeline: LyricTimeline, at time: Double,
                             displayStarts: [Int: Double] = [:]) -> [TimedLyricLine] {
        guard time.isFinite else { return [] }
        // Include neighbouring frames for the existing entrance/exit fades.
        let ordinals = Set(timeline.frames.filter {
            $0.start <= time + 0.35 && $0.end >= time - 0.40
        }.flatMap(\.lineOrdinals))
        return select(timeline.lines.filter { ordinals.contains($0.ordinal) }, at: time,
                      displayStarts: displayStarts)
    }

    static func parameters(for line: TimedLyricLine, time: Double, vocal: Float?,
                           beat: Float, beatPhase: Float, barPhase: Float,
                           displayStart: Double? = nil) -> LyricMotionParameters? {
        let entranceEnd = displayStart ?? line.start
        guard time.isFinite, line.start.isFinite, line.end.isFinite, line.end > line.start,
              entranceEnd.isFinite, entranceEnd >= 0, entranceEnd <= line.start,
              time >= entranceEnd - 0.35, time <= line.end + 0.40 else { return nil }
        let progress = clamp((time - line.start) / (line.end - line.start))
        let entrance = smoothstep((time - entranceEnd + 0.35) / 0.35)
        let exit = smoothstep((time - line.end) / 0.40)
        let singing = time >= line.start && time < line.end
        let activity = vocal.map { clamp(Double($0)) } ?? 0
        let pulse = singing ? 0.02 * clamp(Double(beat)) * (1 - clamp(Double(beatPhase))) : 0
        return LyricMotionParameters(
            opacity: entrance * (1 - exit), scale: (0.94 + 0.06 * entrance) * (1 + pulse),
            blur: 10 * (1 - entrance) + 8 * exit,
            x: singing ? 2 * sin(2 * .pi * clamp(Double(barPhase))) : 0,
            y: 16 * (1 - entrance) - 16 * exit, progress: progress,
            glowOpacity: 0.15 + 0.30 * activity, glowRadius: 2 + 4 * activity)
    }

    static func visibleLines(_ lines: [TimedLyricLine], at time: Double) -> [TimedLyricLine] {
        select(lines, at: time, displayStarts: [:])
    }

    private static func select(_ lines: [TimedLyricLine], at time: Double,
                               displayStarts: [Int: Double]) -> [TimedLyricLine] {
        guard time.isFinite else { return [] }
        var candidates: [(line: TimedLyricLine, opacity: Double, singing: Bool)] = []
        for line in lines {
            if let motion = parameters(for: line, time: time, vocal: nil, beat: 0, beatPhase: 0, barPhase: 0,
                                       displayStart: displayStarts[line.ordinal]),
               motion.opacity > 0 {
                candidates.append((line, motion.opacity, time >= line.start && time < line.end))
            }
        }
        return candidates.sorted {
            if $0.singing != $1.singing { return $0.singing }
            if $0.opacity != $1.opacity { return $0.opacity > $1.opacity }
            return $0.line.ordinal < $1.line.ordinal
        }.prefix(2).map(\.line).sorted { $0.ordinal < $1.ordinal }
    }

    static func emphasis(time: Double, timing: LyricCharacterTiming) -> Double {
        guard time.isFinite else { return 0 }
        if timing.end == timing.start { return time >= timing.end ? 1 : 0 }
        return clamp((time - timing.start) / (timing.end - timing.start))
    }

    /// Presentation colour starts with the prepared row; native Speech times stay saved.
    /// Missing leading spelling uses the pre-Speech gap as one shared interval.
    static func colourTimings(for line: TimedLyricLine, displayStart: Double?) -> [LyricCharacterTiming] {
        guard line.hasValidCharacterTimings, let start = displayStart,
              start.isFinite, start >= 0, start < line.start,
              let missing = line.unrecognizedLeadingCharacters else { return line.characterTimings }
        let original = Array(line.text)
        let weighted = original.indices.filter { LyricParser.characterWeight(original[$0]) > 0 }
        let firstRecognized = weighted[missing]
        let first = line.characterTimings[firstRecognized]
        // Preserve the existing correction for a pause inside a long first token.
        guard first.start == line.start else { return line.characterTimings }
        var result = line.characterTimings
        if missing > 0 {
            for index in weighted.prefix(missing) {
                result[index] = LyricCharacterTiming(start: start, end: first.start)
            }
            for index in 0..<firstRecognized where LyricParser.characterWeight(original[index]) == 0 {
                result[index] = LyricCharacterTiming(start: first.start, end: first.start)
            }
        } else {
            // One Speech token can cover several characters. Keep that grouping.
            for index in weighted.prefix(while: { line.characterTimings[$0] == first }) {
                result[index].start = start
            }
        }
        return result
    }

    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private static func smoothstep(_ value: Double) -> Double {
        let x = clamp(value)
        return x * x * (3 - 2 * x)
    }
}

struct LyricProgressAttribute: TextAttribute {
    var timing: LyricCharacterTiming
}

private struct LyricTextRenderer: TextRenderer {
    var time: Double
    private let cyan = Color(red: 0.24, green: 0.87, blue: 1)

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                for slice in run {
                    context.draw(slice)
                    guard let weight = slice[LyricProgressAttribute.self] else { continue }
                    let emphasis = LyricMotion.emphasis(time: time, timing: weight.timing)
                    if emphasis > 0 {
                        var highlight = context
                        highlight.opacity *= emphasis
                        highlight.addFilter(.colorMultiply(cyan))
                        highlight.draw(slice)
                    }
                }
            }
        }
    }
}

/// Measures SwiftUI's actual text layout at each supported font size.
private struct LyricFittingLayout: Layout {
    var progress: Double

    struct Cache {
        var viewport: CGSize = .zero
        var selected = 0
        var textSize: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let viewport = CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
        measure(viewport, subviews: subviews, cache: &cache)
        return viewport
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(bounds.size, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            if index == cache.selected {
                let overflow = max(0, cache.textSize.height - bounds.height)
                let y = overflow > 0 ? -overflow * progress : (bounds.height - cache.textSize.height) / 2
                subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: bounds.width, height: cache.textSize.height))
            } else {
                // Unselected font samples remain outside the clipped viewport.
                subviews[index].place(at: CGPoint(x: bounds.maxX + bounds.width + 1, y: bounds.maxY + bounds.height + 1),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: bounds.width, height: cache.textSize.height))
            }
        }
    }

    private func measure(_ viewport: CGSize, subviews: Subviews, cache: inout Cache) {
        guard cache.viewport != viewport || cache.textSize == .zero else { return }
        cache.viewport = viewport
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: viewport.width, height: nil))
            cache.selected = index
            cache.textSize = size
            if size.height <= viewport.height { break }
        }
    }
}

private struct LyricMotionLineView: View {
    let line: TimedLyricLine
    let colourTimings: [LyricCharacterTiming]
    let motion: LyricMotionParameters
    let time: Double
    let viewport: CGSize
    private let cyan = Color(red: 0.24, green: 0.87, blue: 1)

    private var lyricText: Text {
        return line.text.enumerated().reduce(Text("")) { text, element in
            let fragment = Text(String(element.element))
                .customAttribute(LyricProgressAttribute(timing: colourTimings[element.offset]))
            return Text("\(text)\(fragment)")
        }
    }

    var body: some View {
        let text = lyricText
        LyricFittingLayout(progress: motion.progress) {
            ForEach(Array(stride(from: 32, through: 14, by: -1)), id: \.self) { size in
                text.font(.system(size: CGFloat(size), weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textRenderer(LyricTextRenderer(time: time))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
        .shadow(color: cyan.opacity(motion.glowOpacity), radius: motion.glowRadius)
        .blur(radius: motion.blur)
        .scaleEffect(motion.scale)
        .offset(x: motion.x, y: motion.y)
        .opacity(motion.opacity)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
    }
}

struct LyricMotionView: View {
    let store: PlayerStore

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: max(0, geometry.size.width - 48), height: max(0, geometry.size.height - 32))
            if let timeline = store.lyricTimeline, !timeline.lines.isEmpty,
               timeline.lines.allSatisfy(\.hasValidCharacterTimings), viewport.width > 0, viewport.height > 0 {
                let displayStarts = LyricMotion.displayStarts(timeline, analysis: store.analysis)
                let colours = Dictionary(uniqueKeysWithValues: timeline.lines.map {
                    ($0.ordinal, LyricMotion.colourTimings(for: $0, displayStart: displayStarts[$0.ordinal]))
                })
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !store.isPlaying)) { _ in
                    if let frame = store.visualSource.snapshot().lyrics,
                       frame.trackID == store.currentTrack?.id,
                       frame.playbackGeneration == store.playbackGeneration,
                       let fingerprint = store.lyricFingerprint, frame.audioFingerprint == fingerprint,
                       timeline.analysisFingerprint == fingerprint,
                       frame.time >= 0, frame.time <= frame.duration {
                        ZStack {
                            ForEach(LyricMotion.visibleLines(timeline, at: frame.time, displayStarts: displayStarts)) { line in
                                if let motion = LyricMotion.parameters(for: line, time: frame.time, vocal: frame.vocal,
                                                                       beat: frame.beat, beatPhase: frame.beatPhase,
                                                                       barPhase: frame.barPhase,
                                                                       displayStart: displayStarts[line.ordinal]) {
                                    LyricMotionLineView(line: line, colourTimings: colours[line.ordinal]!,
                                                       motion: motion, time: frame.time, viewport: viewport)
                                }
                            }
                        }
                        .frame(width: viewport.width, height: viewport.height)
                    }
                }
                .id(store.lyricFrameRevision)
                .frame(width: viewport.width, height: viewport.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
