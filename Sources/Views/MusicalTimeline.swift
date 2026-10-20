import SwiftUI

struct MusicalTimeline: View {
    @Bindable var store: PlayerStore
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color.cyan : Color(red: 0.01, green: 0.43, blue: 0.64)
    }
    private var time: Double { store.previewTime ?? store.position }
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let duration = max(0.001, store.duration)
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        guard let analysis = store.analysis else { return }
                        for beat in analysis.beats {
                            let x = beat / duration * size.width
                            var p = Path(); p.move(to: CGPoint(x: x, y: 8)); p.addLine(to: CGPoint(x: x, y: 11))
                            context.stroke(p, with: .color(Color.primary.opacity(0.2)), lineWidth: 1)
                        }
                        for bar in analysis.bars {
                            let x = bar / duration * size.width
                            var p = Path(); p.move(to: CGPoint(x: x, y: 4)); p.addLine(to: CGPoint(x: x, y: 12))
                            context.stroke(p, with: .color(accent.opacity(0.5)), lineWidth: 1)
                        }
                        for section in analysis.sections {
                            let x = section.start / duration * size.width
                            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: 20))
                            context.stroke(p, with: .color(Color.primary.opacity(0.65)), lineWidth: 1.5)
                        }
                    }
                    Capsule().fill(Color.primary.opacity(0.18)).frame(height: 3).offset(y: 10)
                    Capsule().fill(accent.opacity(0.8)).frame(width: max(0, min(width, time / duration * width)), height: 3).offset(y: 10)
                    Circle().fill(Color.primary).frame(width: 8, height: 8)
                        .shadow(color: accent.opacity(0.5 + Double(store.moment.beat) * 0.5), radius: 5)
                        .offset(x: max(0, min(width - 8, time / duration * width - 4)), y: 10)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { store.previewTime = min(max(0, $0.location.x / width), 1) * store.duration }
                    .onEnded { store.seek(min(max(0, $0.location.x / width), 1) * store.duration) })
                .accessibilityElement()
                .accessibilityLabel("再生位置")
                .accessibilityValue(clock(time))
                .accessibilityAdjustableAction { direction in store.seek(time + (direction == .increment ? 5 : -5)) }
                .help(store.isAppleMusicActive ? "ドラッグして再生位置を変更します" : "ドラッグ中は映像を確認し、離すとその位置から再生します")
                .allowsHitTesting(store.canSeekPlayback)
                .disabled(!store.canSeekPlayback)
            }.frame(height: 30)
            HStack {
                Text(clock(time))
                Spacer()
                if store.previewTime != nil { Text("離すと、この位置から再生").foregroundStyle(accent.opacity(0.8)) }
                Spacer()
                Text(clock(store.duration))
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.5))
        }
    }
}

func clock(_ seconds: Double) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
