import SwiftUI

enum AnalysisPanelSection: Hashable {
    case structure, activity, loudness
}

struct AnalysisPanel: View {
    let analysis: MusicAnalysis?
    let time: Double
    let duration: Double
    let isPlaying: Bool
    @State private var position = ScrollPosition(x: 0)
    @State private var horizontalOffset: CGFloat = 0
    @State var section: AnalysisPanelSection = .structure
    private let labelWidth: CGFloat = 82
    private let valueWidth: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("曲の中を、見る").font(.system(size: 12, weight: .medium))
                if analysis != nil {
                    Picker("解析項目", selection: $section) {
                        Text("構造・区間").tag(AnalysisPanelSection.structure)
                        Text("活動量・楽器").tag(AnalysisPanelSection.activity)
                        Text("音量・ピーク").tag(AnalysisPanelSection.loudness)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                }
                Spacer()
                Text("現在 \(clock(time))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let analysis {
                switch section {
                case .loudness:
                    AnalysisLoudnessView(analysis: analysis, time: time, duration: duration, isPlaying: isPlaying)
                case .activity:
                    AnalysisActivityView(analysis: analysis, time: time, duration: duration, isPlaying: isPlaying)
                case .structure:
                    Text("白：拍　青：小節の先頭（番号）")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    timeline(analysis)
                }
                HStack(spacing: 18) {
                    Text(analysis.bpm.map { String(format: "%.1f BPM", $0) } ?? "BPM：未取得")
                    Text("曲全体の平均音量 \(lufs(analysis.integrated))")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("解析が完了すると、曲の区切りや楽器の動きを表示します。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(16).glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func timeline(_ analysis: MusicAnalysis) -> some View {
        let rows = AnalysisTimelineRow.rows(for: analysis, at: time)
        return GeometryReader { geometry in
            let viewport = max(1, geometry.size.width - labelWidth - valueWidth - 24)
            let axis = AnalysisTimeAxis(duration: duration, viewportWidth: viewport)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: AnalysisTimelinePlot.axisHeight)
                        ForEach(rows.indices, id: \.self) { index in
                            Text(rows[index].name).font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: AnalysisTimelinePlot.rowPitch, alignment: .leading)
                        }
                    }
                    ScrollView(.horizontal) {
                        AnalysisTimelinePlot(rows: rows, time: time, duration: duration)
                            .frame(width: axis.contentWidth, height: AnalysisTimelinePlot.height(rowCount: rows.count))
                    }
                    .frame(width: viewport, height: AnalysisTimelinePlot.height(rowCount: rows.count))
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
                        horizontalOffset = offset
                    }
                    .onAppear { follow(axis) }
                    .onChange(of: time) { _, _ in follow(axis) }
                    .onChange(of: isPlaying) { _, playing in if playing { follow(axis) } }
                    .onChange(of: viewport) { _, _ in follow(axis) }
                    .onChange(of: analysis.fingerprint) { _, _ in follow(axis) }
                    .accessibilityLabel("解析の時間軸")
                    .accessibilityValue("表示 \(clock(Double(horizontalOffset / AnalysisTimeAxis.pointsPerSecond)))〜\(clock(min(duration, Double((horizontalOffset + viewport) / AnalysisTimeAxis.pointsPerSecond))))")
                    VStack(alignment: .trailing, spacing: 0) {
                        Color.clear.frame(height: AnalysisTimelinePlot.axisHeight)
                        ForEach(rows.indices, id: \.self) { index in
                            Text(rows[index].currentValue(at: time))
                                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: valueWidth, height: AnalysisTimelinePlot.rowPitch, alignment: .trailing)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func follow(_ axis: AnalysisTimeAxis) {
        // User scrolling while paused is retained until playback, seek or resize.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(x: axis.offset(at: time)) }
    }

    private func lufs(_ value: Float?) -> String {
        value.map { String(format: "%.1f LUFS", $0) } ?? "未取得"
    }

}
