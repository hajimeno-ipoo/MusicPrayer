import SwiftUI

struct AnalysisPanel: View {
    let analysis: MusicAnalysis?
    let time: Double
    let duration: Double
    private let rowSpacing: CGFloat = 12
    private let valueColumnWidth: CGFloat = 72
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text("曲の中を、見る").font(.system(size: 12, weight: .medium)); Spacer(); Text("現在 \(clock(time))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if let analysis {
                let moment = TimelineSampler.sample(analysis, at: time)
                spanRow("大きな区間", analysis.sections, color: .cyan)
                spanRow("小さな区間", analysis.segments, color: .blue)
                spanRow("フレーズ", analysis.phrases, color: .purple)
                graphRow("活動量", analysis.pace.flatMap { [TimeValue(time: $0.range.start, value: $0.value), TimeValue(time: $0.range.end, value: $0.value)] }, color: .cyan, range: 0...200)
                graphRow("歌声", analysis.vocal, color: .pink, range: 0...1)
                graphRow("ドラム", analysis.drums, color: .purple, range: 0...1)
                graphRow("低音", analysis.bass, color: .cyan, range: 0...1)
                graphRow("その他", analysis.other, color: .blue, range: 0...1)
                graphRow("瞬間の音量", analysis.momentary, color: .mint, range: -60...0, currentValue: lufs(moment.momentary))
                    .help("Momentary：0.4秒の区間で測った、現在位置の音の大きさ")
                graphRow("3秒の音量", analysis.shortTerm, color: .green, range: -60...0, currentValue: lufs(moment.shortTerm))
                    .help("Short-term：3秒の区間で測った、現在位置の音の大きさ")
                HStack {
                    Text("曲全体の平均音量（Integrated）")
                    Spacer()
                    Text(lufs(analysis.integrated)).monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("LUFSは耳で感じる音の大きさの目安です。−10は−20より大きな音です。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else { Text("解析が完了すると、曲の区切りや楽器の動きを表示します。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 15) }
        }
        .padding(16).glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    private func spanRow(_ name: String, _ spans: [TimeSpan], color: Color) -> some View {
        HStack(spacing: rowSpacing) {
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Canvas { context, size in
                for span in spans {
                    let x = span.start / max(duration, 0.001) * size.width
                    let w = span.duration / max(duration, 0.001) * size.width
                    context.fill(Path(roundedRect: CGRect(x: x, y: 1, width: max(1, w - 2), height: 10), cornerRadius: 2), with: .color(color.opacity(time >= span.start && time < span.end ? 0.85 : 0.3)))
                }
                playhead(&context, size)
            }.frame(height: 13)
        }
        .padding(.trailing, valueColumnWidth + rowSpacing)
    }
    private func graphRow(_ name: String, _ values: [TimeValue], color: Color, range: ClosedRange<Float>, currentValue: String? = nil) -> some View {
        HStack(spacing: rowSpacing) {
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            if values.isEmpty { Text("未取得").font(.system(size: 9)).foregroundStyle(.tertiary); Spacer() }
            else {
                Canvas { context, size in
                    var p = Path()
                    // Decimate only for display; the original analysis is retained for sampling.
                    let step = max(1, values.count / max(1, Int(size.width)))
                    for i in stride(from: 0, to: values.count, by: step) {
                        let point = values[i]
                        let x = point.time / max(duration, 0.001) * size.width
                        let y = size.height * (1 - CGFloat(min(1, max(0, (point.value - range.lowerBound) / (range.upperBound - range.lowerBound)))))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(p, with: .color(color.opacity(0.8)), lineWidth: 1)
                    playhead(&context, size)
                }.frame(height: 14)
            }
            // Every row reserves the same value column, so all time axes share one width.
            Text(currentValue ?? "").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: valueColumnWidth, alignment: .trailing)
                .accessibilityHidden(currentValue == nil)
        }
    }
    private func lufs(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "未取得" }
        return String(format: "%.1f LUFS", value)
    }
    private func playhead(_ context: inout GraphicsContext, _ size: CGSize) {
        let x = time / max(duration, 0.001) * size.width
        var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(p, with: .color(.white.opacity(0.6)), lineWidth: 1)
    }
}
