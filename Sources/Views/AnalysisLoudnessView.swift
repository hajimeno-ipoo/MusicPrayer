import SwiftUI

/// Axis bounds use visible observations; API values and timestamps never change.
struct AnalysisLoudnessScale {
  let range: ClosedRange<Float>
  let tickStep: Float
  var ticks: [Float] {
    stride(from: range.upperBound, through: range.lowerBound, by: -tickStep).map { $0 }
  }

  init?(values: [TimeValue], window: ClosedRange<Double>? = nil) {
    guard !values.isEmpty else { return nil }
    let observations: ArraySlice<TimeValue>
    if let window {
      let first = values.firstIndex(where: { $0.time >= window.lowerBound }) ?? values.count
      let last = values.lastIndex(where: { $0.time <= window.upperBound }) ?? -1
      guard first <= last else { return nil }
      observations = values[first...last]
    } else {
      observations = values[...]
    }
    let levels = observations.map(\.value)
    guard let minimum = levels.min(), let maximum = levels.max() else { return nil }
    let span = max(2, maximum - minimum)
    let middle = (minimum + maximum) / 2
    let roughStep = span / 5
    let power = pow(Float(10), floor(log10(roughStep)))
    let fraction = roughStep / power
    tickStep = power * (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10)
    let lower = floor((middle - span * 0.6) / tickStep) * tickStep
    let upper = ceil((middle + span * 0.6) / tickStep) * tickStep
    range = lower...upper
  }

  func y(_ value: Float, height: CGFloat) -> CGFloat {
    CGFloat((range.upperBound - value) / (range.upperBound - range.lowerBound)) * height
  }

  func tickLabels(height: CGFloat) -> [Float] {
    let multiple = max(
      1, ceil(12 * (range.upperBound - range.lowerBound) / Float(height) / tickStep))
    var labels = stride(from: range.upperBound, through: range.lowerBound, by: -tickStep * multiple)
      .map { $0 }
    if let last = labels.last, last != range.lowerBound {
      if y(range.lowerBound, height: height) - y(last, height: height) < 12 { labels.removeLast() }
      labels.append(range.lowerBound)
    }
    return labels
  }

  func label(_ value: Float) -> String {
    value == 0 ? "0" : String(format: tickStep < 1 ? "%.1f" : "%.0f", value)
  }

}

struct AnalysisLoudnessView: View {
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
        let viewport = max(1, geometry.size.width - labelWidth - 8)
        let axis = AnalysisTimeAxis(duration: duration, viewportWidth: viewport, trailingPadding: 8)
        let start = min(
          duration, max(0, Double(horizontalOffset / AnalysisTimeAxis.pointsPerSecond)))
        let end = min(
          duration,
          max(start, Double((horizontalOffset + viewport) / AnalysisTimeAxis.pointsPerSecond)))
        let window = start...end
        let series = [analysis.momentary, analysis.shortTerm]
        let scales = series.map { AnalysisLoudnessScale(values: $0, window: window) }
        let graphHeight = max(80, min(160, (geometry.size.height - 102) / 2))
        let plotHeight = AnalysisLoudnessPlot.height(graphHeight: graphHeight)
        ScrollView(.vertical) {
          HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
              Text("LUFS · 目盛りは表示区間に追従").font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(height: AnalysisTimelinePlot.axisHeight + 6)
              ForEach(series.indices, id: \.self) { index in
                HStack(spacing: 5) {
                  reading(index, values: series[index], hasObservations: scales[index] != nil)
                    .frame(width: 112, height: graphHeight, alignment: .leading)
                  ZStack(alignment: .topTrailing) {
                    if let scale = scales[index] {
                      ForEach(scale.tickLabels(height: graphHeight), id: \.self) { value in
                        Text(scale.label(value)).font(.system(size: 9).monospacedDigit())
                          .position(x: 17, y: scale.y(value, height: graphHeight))
                      }
                    }
                  }.foregroundStyle(.secondary).frame(width: 34, height: graphHeight)
                }.frame(height: graphHeight + 24, alignment: .top)
              }
              Text("ピークの結果時刻").font(.system(size: 9)).foregroundStyle(.orange)
                .frame(height: 24, alignment: .top)
            }.frame(width: labelWidth)
            ScrollView(.horizontal) {
              AnalysisLoudnessPlot(
                analysis: analysis, scales: scales, time: time, duration: duration,
                graphHeight: graphHeight
              )
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
            .accessibilityLabel("音量の時間軸")
            .accessibilityValue("表示 \(clock(window.lowerBound))〜\(clock(window.upperBound))")
          }.padding(.bottom, 8)
        }
      }
      HStack(spacing: 24) {
        Text(analysis.peak.map { String(format: "ピーク振幅 %.4f dB", $0.value) } ?? "ピーク振幅：未取得")
        Text(
          analysis.peak.map { "解析結果の時刻 \(AnalysisTimeAxis.preciseClock($0.time))" } ?? "解析結果の時刻：未取得"
        )
      }.font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
      Text("LUFSは感じる音量の目安、dBはピーク振幅です。ピークは解析で得た1点を表示します。")
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }

  private func reading(_ index: Int, values: [TimeValue], hasObservations: Bool) -> some View {
    let sample = AnalysisTimelineRow.sample(values, at: time)
    return VStack(alignment: .leading, spacing: 4) {
      Text(index == 0 ? "瞬間の音量（400ms）" : "3秒の音量")
      Text(sample.map { String(format: "%.1f LUFS", $0.value) } ?? "未取得")
      if let sample { Text(AnalysisTimeAxis.preciseClock(sample.time)) }
      if !hasObservations { Text("表示区間：未取得").foregroundStyle(.secondary) }
    }.font(.system(size: 10).monospacedDigit()).foregroundStyle(
      index == 0 ? Color.mint : Color.green)
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

struct AnalysisLoudnessPlot: View {
  static func height(graphHeight: CGFloat) -> CGFloat {
    AnalysisTimelinePlot.axisHeight + 6 + (graphHeight + 24) * 2 + 24
  }
  let analysis: MusicAnalysis
  let scales: [AnalysisLoudnessScale?]
  let time: Double
  let duration: Double
  var graphHeight: CGFloat = 120

  var body: some View {
    Canvas { context, size in
      let top = AnalysisTimelinePlot.axisHeight + 6
      let points = AnalysisTimeAxis.pointsPerSecond
      for second in 0...Int(max(0, duration)) {
        let x = CGFloat(second) * points
        if second % 5 == 0 {
          context.draw(
            Text(clock(Double(second))).font(.system(size: 9).monospacedDigit()).foregroundStyle(
              .secondary),
            at: CGPoint(x: x + 3, y: 8), anchor: .topLeading)
        }
        for index in 0..<2 {
          let y = top + CGFloat(index) * (graphHeight + 24)
          var grid = Path()
          grid.move(to: CGPoint(x: x, y: y))
          grid.addLine(to: CGPoint(x: x, y: y + graphHeight))
          context.stroke(
            grid, with: .color(.white.opacity(second % 5 == 0 ? 0.18 : 0.06)), lineWidth: 0.5)
        }
      }
      for (index, values) in [analysis.momentary, analysis.shortTerm].enumerated() {
        let y = top + CGFloat(index) * (graphHeight + 24)
        guard let scale = scales[index] else {
          context.draw(
            Text("未取得").font(.caption).foregroundStyle(.secondary),
            at: CGPoint(x: CGFloat(time) * points, y: y + graphHeight / 2))
          continue
        }
        var chart = context
        chart.translateBy(x: 0, y: y)
        chart.clip(to: Path(CGRect(x: 0, y: -1, width: size.width, height: graphHeight + 2)))
        for tick in scale.ticks {
          var grid = Path()
          let tickY = scale.y(tick, height: graphHeight)
          grid.move(to: CGPoint(x: 0, y: tickY))
          grid.addLine(to: CGPoint(x: size.width, y: tickY))
          chart.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
        }
        chart.stroke(
          AnalysisTimelineRow.valuePath(
            values, range: scale.range, height: graphHeight, clampToRange: false),
          with: .color(index == 0 ? Color.mint : Color.green), lineWidth: 1.5)
      }
      if let peak = analysis.peak {
        let x = CGFloat(peak.time) * points
        let y = top + (graphHeight + 24) * 2 + 4
        context.fill(
          Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.orange))
        context.draw(
          Text(String(format: "%.4f dB", peak.value)).font(.system(size: 9)).foregroundStyle(
            .orange),
          at: CGPoint(x: x - 8, y: y), anchor: .trailing)
      }
      var playhead = Path()
      let x = CGFloat(min(max(0, time), duration)) * points
      playhead.move(to: CGPoint(x: x, y: 0))
      playhead.addLine(to: CGPoint(x: x, y: size.height))
      context.stroke(playhead, with: .color(.white.opacity(0.8)), lineWidth: 1)
    }.accessibilityHidden(true)
  }
}
