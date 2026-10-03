import SwiftUI

struct AnalysisTimeAxis {
    static let pointsPerSecond: CGFloat = 40
    let duration: Double
    let viewportWidth: CGFloat
    var trailingPadding: CGFloat = 0

    var contentWidth: CGFloat { max(viewportWidth, CGFloat(max(0, duration)) * Self.pointsPerSecond + 1 + trailingPadding) }

    func offset(at time: Double) -> CGFloat {
        let bounded = min(max(0, time.isFinite ? time : 0), duration)
        return min(max(0, CGFloat(bounded) * Self.pointsPerSecond - viewportWidth / 2),
                   max(0, contentWidth - viewportWidth))
    }

    static func preciseClock(_ time: Double) -> String {
        let tenths = Int((max(0, time) * 10).rounded())
        return String(format: "%d:%04.1f", tenths / 600, Double(tenths % 600) / 10)
    }
}

struct AnalysisTimelineRow {
    enum Data {
        case spans([TimeSpan])
        case rhythm(beats: [Double], bars: [Double])
        case keys([KeySpan])
    }

    let name: String
    let color: Color
    let data: Data

    static func rows(for analysis: MusicAnalysis, at time: Double) -> [Self] {
        return [Self(name: "大きな区間", color: .cyan, data: .spans(analysis.sections)),
         Self(name: "小さな区間", color: .blue, data: .spans(analysis.segments)),
         Self(name: "フレーズ", color: .purple, data: .spans(analysis.phrases)),
         Self(name: "拍・小節", color: .cyan, data: .rhythm(beats: analysis.beats, bars: analysis.bars)),
         Self(name: "歌声の区間", color: .pink, data: .spans(analysis.instrumentRanges.vocal)),
         Self(name: "ドラムの区間", color: .purple, data: .spans(analysis.instrumentRanges.drums)),
         Self(name: "低音の区間", color: .cyan, data: .spans(analysis.instrumentRanges.bass)),
         Self(name: "その他の区間", color: .blue, data: .spans(analysis.instrumentRanges.other)),
         Self(name: "調性の区間", color: .orange, data: .keys(analysis.keys))]
    }

    func currentValue(at time: Double) -> String {
        switch data {
        case .spans(let spans):
            guard !spans.isEmpty else { return "未取得" }
            if let index = spans.firstIndex(where: { $0.start <= time && time < $0.end }) {
                return "\(index + 1) / \(spans.count)"
            }
            return "区間外"
        case .rhythm(let beats, let bars):
            return beats.isEmpty && bars.isEmpty ? "未取得" : "拍 \(beats.count) / 小節 \(bars.count)"
        case .keys(let keys):
            return keys.first(where: { $0.range.start <= time && time < $0.range.end })?.label ?? "未取得"
        }
    }

    /// Every sample is a vertex. No stride, resampling, or averaging for display.
    static func valuePath(_ values: [TimeValue], range: ClosedRange<Float>, height: CGFloat, clampToRange: Bool = true) -> Path {
        Path { path in
            for (index, sample) in values.enumerated() {
                let rawFraction = (sample.value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let fraction = clampToRange ? min(1, max(0, rawFraction)) : rawFraction
                let point = CGPoint(x: CGFloat(sample.time) * AnalysisTimeAxis.pointsPerSecond,
                                    y: (1 - CGFloat(fraction)) * height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// Return the latest actual observation, with its original timestamp.
    static func sample(_ values: [TimeValue], at time: Double) -> TimeValue? {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if values[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? values[lower - 1] : nil
    }
}

struct AnalysisTimelinePlot: View {
    static let axisHeight: CGFloat = 24
    static let rowPitch: CGFloat = 22
    static let graphHeight: CGFloat = 14
    let rows: [AnalysisTimelineRow]
    let time: Double
    let duration: Double

    static func height(rowCount: Int) -> CGFloat { axisHeight + CGFloat(rowCount) * rowPitch }

    var body: some View {
        Canvas { context, size in
            let scale = AnalysisTimeAxis.pointsPerSecond
            for second in 0...Int(max(0, duration)) {
                let x = CGFloat(second) * scale
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: Self.axisHeight))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(grid, with: .color(.white.opacity(second % 5 == 0 ? 0.12 : 0.04)), lineWidth: 0.5)
                if second % 5 == 0 {
                    context.draw(Text(clock(Double(second))).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 8), anchor: .topLeading)
                }
            }
            for (index, row) in rows.enumerated() {
                var local = context
                local.translateBy(x: 0, y: Self.axisHeight + CGFloat(index) * Self.rowPitch + 4)
                draw(row, in: &local)
            }
            var playhead = Path()
            let x = CGFloat(min(max(0, time), duration)) * scale
            playhead.move(to: CGPoint(x: x, y: 0))
            playhead.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(playhead, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ row: AnalysisTimelineRow, in context: inout GraphicsContext) {
        let scale = AnalysisTimeAxis.pointsPerSecond
        switch row.data {
        case .spans(let spans):
            for span in spans { block(span, label: nil, color: row.color, in: &context) }
        case .keys(let keys):
            for key in keys { block(key.range, label: key.label, color: row.color, in: &context) }
        case .rhythm(let beats, let bars):
            for time in beats {
                var line = Path()
                line.move(to: CGPoint(x: CGFloat(time) * scale, y: 6))
                line.addLine(to: CGPoint(x: CGFloat(time) * scale, y: Self.graphHeight))
                context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            for (index, time) in bars.enumerated() {
                var line = Path()
                let x = CGFloat(time) * scale
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: Self.graphHeight))
                context.stroke(line, with: .color(.cyan), lineWidth: 2)
                context.draw(Text("\(index + 1)").font(.system(size: 8).monospacedDigit()).foregroundStyle(.cyan),
                             at: CGPoint(x: x + 4, y: 0), anchor: .topLeading)
            }
        }
    }

    private func block(_ span: TimeSpan, label: String?, color: Color, in context: inout GraphicsContext) {
        let x = CGFloat(span.start) * AnalysisTimeAxis.pointsPerSecond
        let width = CGFloat(span.duration) * AnalysisTimeAxis.pointsPerSecond
        context.fill(Path(roundedRect: CGRect(x: x, y: 1, width: max(1, width - 2), height: 12), cornerRadius: 2),
                     with: .color(color.opacity(time >= span.start && time < span.end ? 0.85 : 0.3)))
        if let label {
            context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.white),
                         at: CGPoint(x: x + 5, y: 7), anchor: .leading)
        }
    }
}
