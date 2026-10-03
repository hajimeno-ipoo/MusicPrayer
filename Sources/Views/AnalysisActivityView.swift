import SwiftUI

struct AnalysisActivityScale {
    let range: ClosedRange<Float>
    let tickStep: Float
    var ticks: [Float] {
        stride(from: range.upperBound, through: range.lowerBound, by: -tickStep).map { $0 }
    }

    static let strength = Self(range: 0...1, tickStep: 0.5)

    static func pace(_ ranges: [PaceSpan], window: ClosedRange<Double>? = nil) -> Self? {
        let observations = ranges.filter { span in
            guard let window else { return true }
            return span.range.start <= window.upperBound && span.range.end > window.lowerBound
        }
        let values = observations.map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        let span = max(1, maximum - minimum)
        let middle = (minimum + maximum) / 2
        let roughStep = span / 5
        let power = pow(Float(10), floor(log10(roughStep)))
        let fraction = roughStep / power
        let step = power * (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10)
        let lower = max(0, floor((middle - span * 0.6) / step) * step)
        let upper = ceil((middle + span * 0.6) / step) * step
        return Self(range: lower...upper, tickStep: step)
    }

    func y(_ value: Float, height: CGFloat) -> CGFloat {
        CGFloat((range.upperBound - value) / (range.upperBound - range.lowerBound)) * height
    }

    func label(_ value: Float) -> String {
        value == 0 ? "0" : String(format: tickStep < 1 ? "%.1f" : "%.0f", value)
    }
}

struct AnalysisActivityRow {
    enum Data {
        case pace([PaceSpan])
        case values([TimeValue])
    }

    let name: String
    let color: Color
    let data: Data

    static func rows(for analysis: MusicAnalysis) -> [Self] {
        [Self(name: "活動量", color: .cyan, data: .pace(analysis.pace)),
         Self(name: "歌声", color: .pink, data: .values(analysis.vocal)),
         Self(name: "ドラム", color: .purple, data: .values(analysis.drums)),
         Self(name: "低音", color: .cyan, data: .values(analysis.bass)),
         Self(name: "その他", color: .blue, data: .values(analysis.other))]
    }

    var scale: AnalysisActivityScale? { scale(window: nil) }

    func scale(window: ClosedRange<Double>?) -> AnalysisActivityScale? {
        switch data {
        case .pace(let ranges): return .pace(ranges, window: window)
        case .values(let values): return values.isEmpty ? nil : .strength
        }
    }

    func path(height: CGFloat, window: ClosedRange<Double>? = nil) -> Path {
        guard let scale = scale(window: window) else { return Path() }
        switch data {
        case .values(let values):
            return AnalysisTimelineRow.valuePath(values, range: scale.range, height: height, clampToRange: false)
        case .pace(let ranges):
            return Path { path in
                var previousEnd: Double?
                for span in ranges {
                    let y = scale.y(span.value, height: height)
                    let start = CGPoint(x: CGFloat(span.range.start) * AnalysisTimeAxis.pointsPerSecond, y: y)
                    if previousEnd == span.range.start { path.addLine(to: start) }
                    else { path.move(to: start) }
                    path.addLine(to: CGPoint(x: CGFloat(span.range.end) * AnalysisTimeAxis.pointsPerSecond, y: y))
                    previousEnd = span.range.end
                }
            }
        }
    }

    func currentReading(at time: Double) -> (value: String, time: String?) {
        switch data {
        case .values(let values):
            guard let sample = AnalysisTimelineRow.sample(values, at: time) else { return ("未取得", nil) }
            return (String(format: "%.3f / 1", sample.value), AnalysisTimeAxis.preciseClock(sample.time))
        case .pace(let ranges):
            guard let span = ranges.first(where: { $0.range.start <= time && time < $0.range.end }) else {
                return ("未取得", nil)
            }
            return (String(format: "%.2f回/分", span.value),
                    "\(AnalysisTimeAxis.preciseClock(span.range.start))〜\(AnalysisTimeAxis.preciseClock(span.range.end))")
        }
    }
}

struct AnalysisActivityView: View {
    let analysis: MusicAnalysis
    let time: Double
    let duration: Double
    let isPlaying: Bool
    @State private var position = ScrollPosition(x: 0)
    @State private var horizontalOffset: CGFloat = 0
    private let labelWidth: CGFloat = 154

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let rows = AnalysisActivityRow.rows(for: analysis)
                let viewport = max(1, geometry.size.width - labelWidth - 8)
                let axis = AnalysisTimeAxis(duration: duration, viewportWidth: viewport)
                let start = min(duration, max(0, Double(horizontalOffset / AnalysisTimeAxis.pointsPerSecond)))
                let end = min(duration, max(start, Double((horizontalOffset + viewport) / AnalysisTimeAxis.pointsPerSecond)))
                let window = start...end
                let graphHeight = max(80, min(120, (geometry.size.height - 30) / 2 - 24))
                let plotHeight = AnalysisActivityPlot.height(graphHeight: graphHeight, rowCount: rows.count, showsTimeAxis: false)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("活動量：表示範囲\n楽器：0〜1").font(.system(size: 8)).foregroundStyle(.secondary)
                            .frame(width: labelWidth)
                        timeAxis().frame(width: viewport)
                    }.frame(height: AnalysisTimelinePlot.axisHeight + 6)
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 0) {
                                ForEach(rows.indices, id: \.self) { index in
                                    HStack(spacing: 5) {
                                        reading(rows[index])
                                            .frame(width: 112, height: graphHeight, alignment: .leading)
                                        ZStack(alignment: .topTrailing) {
                                            if let scale = rows[index].scale(window: window) {
                                                ForEach(scale.ticks, id: \.self) { value in
                                                    Text(scale.label(value)).font(.system(size: 9).monospacedDigit())
                                                        .position(x: 17, y: scale.y(value, height: graphHeight))
                                                }
                                            }
                                        }.foregroundStyle(.secondary).frame(width: 34, height: graphHeight)
                                    }.frame(height: graphHeight + 24, alignment: .top)
                                }
                            }.frame(width: labelWidth)
                            ScrollView(.horizontal) {
                                AnalysisActivityPlot(rows: rows, time: time, duration: duration, graphHeight: graphHeight, showsTimeAxis: false, scaleWindow: window)
                                    .frame(width: axis.contentWidth, height: plotHeight)
                            }
                            .frame(width: viewport, height: plotHeight)
                            .scrollPosition($position)
                            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
                                horizontalOffset = offset
                            }
                            .onAppear { follow(axis) }
                            .onChange(of: time) { _, _ in follow(axis) }
                            .onChange(of: isPlaying) { _, playing in if playing { follow(axis) } }
                            .onChange(of: viewport) { _, _ in follow(axis) }
                            .onChange(of: analysis.fingerprint) { _, _ in follow(axis) }
                            .accessibilityLabel("活動量・楽器の時間軸")
                            .accessibilityValue("表示 \(clock(Double(horizontalOffset / AnalysisTimeAxis.pointsPerSecond)))〜\(clock(min(duration, Double((horizontalOffset + viewport) / AnalysisTimeAxis.pointsPerSecond))))")
                        }.padding(.top, 8).padding(.bottom, 8)
                    }
                }
            }
            Text("活動量は区間ごとの感じる速さ（回/分・events/min）。目盛りは表示範囲に追従します。楽器は活動強度0〜1です。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func reading(_ row: AnalysisActivityRow) -> some View {
        let current = row.currentReading(at: time)
        return VStack(alignment: .leading, spacing: 4) {
            Text(row.name)
            Text(current.value)
            if let time = current.time { Text(time).lineLimit(2) }
        }.font(.system(size: 10).monospacedDigit()).foregroundStyle(row.color)
    }

    private func timeAxis() -> some View {
        Canvas { context, size in
            for second in stride(from: 0, through: Int(max(0, duration)), by: 5) {
                let x = CGFloat(second) * AnalysisTimeAxis.pointsPerSecond - horizontalOffset
                context.draw(Text(clock(Double(second))).font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 8), anchor: .topLeading)
            }
            var playhead = Path()
            let x = CGFloat(min(max(0, time), duration)) * AnalysisTimeAxis.pointsPerSecond - horizontalOffset
            playhead.move(to: CGPoint(x: x, y: 0))
            playhead.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(playhead, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }.clipped().accessibilityHidden(true)
    }

    private func follow(_ axis: AnalysisTimeAxis) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            horizontalOffset = axis.offset(at: time)
            position.scrollTo(x: horizontalOffset)
        }
    }
}

struct AnalysisActivityPlot: View {
    static func height(graphHeight: CGFloat, rowCount: Int, showsTimeAxis: Bool = true) -> CGFloat {
        (showsTimeAxis ? AnalysisTimelinePlot.axisHeight + 6 : 0) + (graphHeight + 24) * CGFloat(rowCount)
    }
    let rows: [AnalysisActivityRow]
    let time: Double
    let duration: Double
    let graphHeight: CGFloat
    var showsTimeAxis = true
    var scaleWindow: ClosedRange<Double>? = nil

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = showsTimeAxis ? AnalysisTimelinePlot.axisHeight + 6 : 0
            let points = AnalysisTimeAxis.pointsPerSecond
            for second in 0...Int(max(0, duration)) {
                let x = CGFloat(second) * points
                if showsTimeAxis && second % 5 == 0 {
                    context.draw(Text(clock(Double(second))).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 8), anchor: .topLeading)
                }
                for index in rows.indices {
                    let y = top + CGFloat(index) * (graphHeight + 24)
                    var grid = Path()
                    grid.move(to: CGPoint(x: x, y: y))
                    grid.addLine(to: CGPoint(x: x, y: y + graphHeight))
                    context.stroke(grid, with: .color(.white.opacity(second % 5 == 0 ? 0.18 : 0.06)), lineWidth: 0.5)
                }
            }
            for (index, row) in rows.enumerated() {
                guard let scale = row.scale(window: scaleWindow) else { continue }
                var chart = context
                chart.translateBy(x: 0, y: top + CGFloat(index) * (graphHeight + 24))
                chart.clip(to: Path(CGRect(x: 0, y: -1, width: size.width, height: graphHeight + 2)))
                for tick in scale.ticks {
                    let y = scale.y(tick, height: graphHeight)
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    chart.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                }
                chart.stroke(row.path(height: graphHeight, window: scaleWindow), with: .color(row.color), lineWidth: 1.5)
            }
            var playhead = Path()
            let x = CGFloat(min(max(0, time), duration)) * points
            playhead.move(to: CGPoint(x: x, y: 0))
            playhead.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(playhead, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }.accessibilityHidden(true)
    }
}
