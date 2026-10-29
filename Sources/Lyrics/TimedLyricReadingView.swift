import SwiftUI

enum LyricReadingPosition {
    static func currentID(in lines: [TimedLyricLine], at time: Double,
                          displayStarts: [Int: Double] = [:]) -> String? {
        guard time.isFinite else { return nil }
        return lines.last(where: { (displayStarts[$0.ordinal] ?? $0.start) <= time })?.id
            ?? lines.first?.id
    }
}

/// Keep the surrounding lyrics in the document while the singing line advances.
struct TimedLyricReadingView: View {
    let lines: [TimedLyricLine]
    let time: Double
    let viewport: CGSize
    var font: LyricFont = .system
    var readings: LyricReadings?
    var analysis: MusicAnalysis?
    var displayStarts: [Int: Double] = [:]
    var usesEstimatedProgress = false
    var centersLyrics = false
    var onSeek: (Double) -> Void
    @State private var positioned = false

    private var currentID: String? {
        LyricReadingPosition.currentID(in: lines, at: time, displayStarts: displayStarts)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: centersLyrics ? .center : .leading, spacing: 28) {
                    ForEach(lines) { line in
                        let current = line.id == currentID
                        Button { onSeek(line.start) } label: {
                            LyricMotionLineView(line: line,
                                colourTimings: current && line.hasValidCharacterTimings
                                    ? LyricMotion.colourTimings(for: line, displayStart: displayStarts[line.ordinal]) : [],
                                motion: LyricMotionParameters(opacity: 1, scale: 1, blur: 0, x: 0, y: 0,
                                    progress: 0, glowOpacity: 0, glowRadius: 0),
                                time: time, viewport: viewport, font: font,
                                estimatedProgress: current ? estimatedProgress(for: line) : nil,
                                readings: readings?.readings(for: line.text) ?? [], columnStyle: true,
                                centersColumnText: centersLyrics)
                                .opacity(current ? 1 : 0.35)
                                .blur(radius: current ? 0 : 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(line.text)
                        .help("この歌詞の位置へ移動")
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, viewport.height * 0.3)
                .padding(.bottom, viewport.height * 0.7)
            }
            .scrollIndicators(.never)
            .onChange(of: currentID, initial: true) { _, id in
                guard let id else { return }
                if positioned {
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                } else {
                    proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3))
                    positioned = true
                }
            }
            .onChange(of: viewport) { _, _ in
                if let currentID { proxy.scrollTo(currentID, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
        .accessibilityLabel("同期歌詞")
    }

    private func estimatedProgress(for line: TimedLyricLine) -> Double? {
        guard usesEstimatedProgress, !line.hasValidCharacterTimings else { return nil }
        return analysis.map { LyricMusicContext(analysis: $0).colourProgress(
            in: LyricCharacterTiming(start: line.start, end: line.end), at: time) }
            ?? LyricMotion.clamp((time - line.start) / (line.end - line.start))
    }
}
