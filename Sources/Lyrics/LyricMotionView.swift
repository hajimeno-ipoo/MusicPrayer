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

struct LyricDisplayWindow: Equatable, Sendable {
    var start: Double
    var entranceEnd: Double
    var exitStart: Double
    var end: Double
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

    /// Split only presentation windows; lyric and character timestamps stay intact.
    static func displayWindows(_ lines: [TimedLyricLine], displayStarts: [Int: Double] = [:]) -> [Int: LyricDisplayWindow] {
        let ordered = lines.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted {
                let lhs = displayStarts[$0.ordinal] ?? $0.start
                let rhs = displayStarts[$1.ordinal] ?? $1.start
                return lhs == rhs ? $0.ordinal < $1.ordinal : lhs < rhs
            }
        var windows: [Int: LyricDisplayWindow] = [:]
        for line in ordered {
            let entranceEnd = displayStarts[line.ordinal] ?? line.start
            windows[line.ordinal] = LyricDisplayWindow(start: entranceEnd - 0.35, entranceEnd: entranceEnd,
                                                       exitStart: line.end, end: line.end + 0.40)
        }
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            guard let outgoing = windows[previous.ordinal], let incoming = windows[next.ordinal],
                  outgoing.end > incoming.start else { continue }
            let nextStart = displayStarts[next.ordinal] ?? next.start
            // Fit both fades inside the vocal gap. With no gap, switch directly
            // at the next entrance instead of fading through sung words.
            let gap = max(0, nextStart - previous.end)
            let boundary = nextStart - gap * (0.35 / 0.75)
            windows[previous.ordinal]?.exitStart = min(previous.end, boundary)
            windows[previous.ordinal]?.end = boundary
            windows[next.ordinal]?.start = boundary
        }
        return windows
    }

    static func visibleLines(_ timeline: LyricTimeline, at time: Double,
                             displayStarts: [Int: Double] = [:],
                             windows: [Int: LyricDisplayWindow]? = nil) -> [TimedLyricLine] {
        guard time.isFinite else { return [] }
        // Include neighbouring frames for the existing entrance/exit fades.
        var ordinals = Set(timeline.frames.filter {
            $0.start <= time + 0.35 && $0.end >= time - 0.40
        }.flatMap(\.lineOrdinals))
        if let first = timeline.frames.first, let last = timeline.frames.last {
            // Edge rows use Speech times, including fades crossing into the
            // observed structure even when the row has no frame overlap.
            ordinals.formUnion(timeline.lines.filter {
                $0.start < first.start || $0.end > last.end
            }.map(\.ordinal))
        }
        return select(timeline.lines.filter { ordinals.contains($0.ordinal) }, at: time,
                      displayStarts: displayStarts, windows: windows ?? displayWindows(timeline.lines, displayStarts: displayStarts))
    }

    static func parameters(for line: TimedLyricLine, time: Double, vocal: Float?,
                           beat: Float, beatPhase: Float, barPhase: Float,
                           displayStart: Double? = nil, window: LyricDisplayWindow? = nil) -> LyricMotionParameters? {
        let entranceEnd = displayStart ?? line.start
        let window = window ?? LyricDisplayWindow(start: entranceEnd - 0.35, entranceEnd: entranceEnd,
                                                          exitStart: line.end, end: line.end + 0.40)
        guard time.isFinite, line.start.isFinite, line.end.isFinite, line.end > line.start,
              entranceEnd.isFinite, entranceEnd >= 0, entranceEnd <= line.start,
              window.end > window.start, time >= window.start, time <= window.end else { return nil }
        let progress = clamp((time - line.start) / (line.end - line.start))
        let entranceDuration = window.entranceEnd - window.start
        let exitDuration = window.end - window.exitStart
        let entrance = entranceDuration > 0 ? smoothstep((time - window.start) / entranceDuration) : 1
        let exit = exitDuration > 0 ? smoothstep((time - window.exitStart) / exitDuration) : (time >= window.end ? 1.0 : 0.0)
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

    static func visibleLines(_ lines: [TimedLyricLine], at time: Double,
                             windows: [Int: LyricDisplayWindow]? = nil) -> [TimedLyricLine] {
        select(lines, at: time, displayStarts: [:], windows: windows ?? displayWindows(lines))
    }

    private static func select(_ lines: [TimedLyricLine], at time: Double,
                               displayStarts: [Int: Double], windows: [Int: LyricDisplayWindow]) -> [TimedLyricLine] {
        guard time.isFinite else { return [] }
        return lines.filter { line in
            guard let window = windows[line.ordinal],
                  let motion = parameters(for: line, time: time, vocal: nil, beat: 0, beatPhase: 0, barPhase: 0,
                                          displayStart: displayStarts[line.ordinal], window: window) else { return false }
            return motion.opacity > 0
        }
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

private struct LyricEstimatedProgressAttribute: TextAttribute {
    var start: Double
    var end: Double
}

private struct LyricTextRenderer: TextRenderer {
    var time: Double
    var estimatedProgress: Double?
    private let cyan = Color(red: 0.24, green: 0.87, blue: 1)

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                for slice in run {
                    context.draw(slice)
                    let emphasis: Double
                    if let weight = slice[LyricProgressAttribute.self] {
                        emphasis = LyricMotion.emphasis(time: time, timing: weight.timing)
                    } else if let weight = slice[LyricEstimatedProgressAttribute.self], let progress = estimatedProgress {
                        emphasis = weight.end > weight.start
                            ? LyricMotion.clamp((progress - weight.start) / (weight.end - weight.start))
                            : (progress >= weight.end ? 1 : 0)
                    } else { continue }
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

struct LyricMotionLineView: View {
    let line: TimedLyricLine
    let colourTimings: [LyricCharacterTiming]
    let motion: LyricMotionParameters
    let time: Double
    let viewport: CGSize
    let font: LyricFont
    var estimatedProgress: Double? = nil
    private let cyan = Color(red: 0.24, green: 0.87, blue: 1)

    private func lyricText(breakOffset: Int? = nil) -> Text {
        let total = max(1, line.text.reduce(0.0) { $0 + LyricParser.characterWeight($1) })
        var offset = 0.0
        return line.text.enumerated().reduce(Text("")) { text, element in
            let character = Text(String(element.element))
            let end = offset + LyricParser.characterWeight(element.element) / total
            let fragment = colourTimings.indices.contains(element.offset)
                ? character.customAttribute(LyricProgressAttribute(timing: colourTimings[element.offset]))
                : (estimatedProgress != nil
                    ? character.customAttribute(LyricEstimatedProgressAttribute(start: offset, end: end)) : character)
            offset = end
            if element.offset == breakOffset { return Text("\(text)\n\(fragment)") }
            return Text("\(text)\(fragment)")
        }
    }

    private func styledText(size: CGFloat, breakOffset: Int? = nil) -> some View {
        lyricText(breakOffset: breakOffset)
            .font(font.font(size: size))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .textRenderer(LyricTextRenderer(time: time, estimatedProgress: estimatedProgress))
            .accessibilityHidden(true)
    }

    var body: some View {
        Group {
            if let presentation = LyricLineWrapping.presentation(text: line.text, viewport: viewport, font: font) {
                styledText(size: presentation.fontSize, breakOffset: presentation.breakOffset)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                LyricFittingLayout(progress: motion.progress) {
                    ForEach(Array(stride(from: 32, through: 14, by: -1)), id: \.self) { size in
                        styledText(size: CGFloat(size))
                    }
                }
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
    var font: LyricFont = .system

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: max(0, geometry.size.width - 48), height: max(0, geometry.size.height - 32))
            Group {
                if store.isAppleMusicActive {
                    if let lyrics = store.appleMusic.lyrics,
                       lyrics.songID == store.currentQueueTrack?.appleMusicSong?.id {
                        if lyrics.lines.isEmpty {
                            Text(lyrics.text)
                                .font(font.font(size: 28))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(12)
                        } else {
                            let windows = LyricMotion.displayWindows(lyrics.lines)
                            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !store.isPlaying)) { _ in
                                lyricLines(LyricMotion.visibleLines(lyrics.lines, at: store.position, windows: windows),
                                           time: store.position, viewport: viewport, windows: windows)
                            }
                        }
                    }
                } else if let timeline = store.lyricTimeline, !timeline.lines.isEmpty,
                          timeline.lines.allSatisfy(\.hasValidCharacterTimings), viewport.width > 0, viewport.height > 0 {
                    let displayStarts = LyricMotion.displayStarts(timeline, analysis: store.analysis)
                    let windows = LyricMotion.displayWindows(timeline.lines, displayStarts: displayStarts)
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !store.isPlaying)) { _ in
                        if let frame = store.visualSource.snapshot().lyrics,
                           frame.trackID == store.currentTrack?.id,
                           frame.playbackGeneration == store.playbackGeneration,
                           let fingerprint = store.lyricFingerprint, frame.audioFingerprint == fingerprint,
                           timeline.analysisFingerprint == fingerprint,
                           frame.time >= 0, frame.time <= frame.duration {
                            lyricLines(LyricMotion.visibleLines(timeline, at: frame.time, displayStarts: displayStarts, windows: windows),
                                       time: frame.time, viewport: viewport, frame: frame, displayStarts: displayStarts, windows: windows)
                        }
                    }
                    .id(store.lyricFrameRevision)
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .overlay(alignment: .bottom) {
                if store.isAppleMusicActive, let message = store.appleMusic.lyricTimingStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func lyricLines(_ lines: [TimedLyricLine], time: Double, viewport: CGSize,
                            frame: LyricPlaybackFrame? = nil, displayStarts: [Int: Double] = [:],
                            windows: [Int: LyricDisplayWindow]) -> some View {
        ZStack {
            ForEach(lines) { line in
                if let motion = LyricMotion.parameters(for: line, time: time, vocal: frame?.vocal,
                                                       beat: frame?.beat ?? 0, beatPhase: frame?.beatPhase ?? 0,
                                                       barPhase: frame?.barPhase ?? 0,
                                                       displayStart: displayStarts[line.ordinal], window: windows[line.ordinal]) {
                    LyricMotionLineView(line: line,
                                       colourTimings: line.hasValidCharacterTimings
                                           ? LyricMotion.colourTimings(for: line, displayStart: displayStarts[line.ordinal]) : [],
                                       motion: motion, time: time, viewport: viewport, font: font,
                                       estimatedProgress: store.isAppleMusicActive && !line.hasValidCharacterTimings
                                           ? store.analysis.map { LyricMusicContext(analysis: $0).colourProgress(
                                                in: LyricCharacterTiming(start: line.start, end: line.end), at: time) } ?? motion.progress : nil)
                }
            }
        }
        .frame(width: viewport.width, height: viewport.height)
    }
}
