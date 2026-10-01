import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlayerView: View {
    @Bindable var store: PlayerStore
    @State private var showQueue = false
    @State private var showAnalysis = false
    @State private var engaged = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dropTarget = false
    private let cyan = Color(red: 0.24, green: 0.87, blue: 1)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MetalVisualizerView(source: store.visualSource).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 20)
                    if store.tracks.isEmpty { welcome; Spacer(minLength: 30) }
                    VStack(spacing: 18) {
                        trackInformation
                        if let error = store.playbackError { errorRow(error, retry: nil) }
                        if let error = store.analysisError { errorRow("曲の詳しい解析ができませんでした：\(error)", retry: store.retryAnalysis) }
                        if showAnalysis { AnalysisPanel(analysis: store.analysis, time: store.previewTime ?? store.position, duration: store.duration) }
                        MusicalTimeline(store: store)
                        controls
                    }
                    .padding(.horizontal, geometry.size.width < 1000 ? 32 : 58)
                    .padding(.bottom, 26)
                    .background {
                        LinearGradient(colors: [.clear, Color(red: 0.005, green: 0.012, blue: 0.06).opacity(0.85)], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -38)
                            .allowsHitTesting(false)
                    }
                }
                if dropTarget {
                    RoundedRectangle(cornerRadius: 24).stroke(cyan, style: StrokeStyle(lineWidth: 2, dash: [8, 8])).padding(14)
                        .overlay { Label("曲をここへドロップ", systemImage: "music.note").font(.title2).padding(24).glassEffect() }
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 860, minHeight: showAnalysis ? 850 : 660)
        .preferredColorScheme(.dark)
        .onContinuousHover { _ in revealControls() }
        .onTapGesture { revealControls() }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await store.add(urls: [url]) }
                }
            }
            return !providers.isEmpty
        }
        .onChange(of: store.isPlaying) { _, _ in revealControls() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("MUSIC PRAYER").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 70)
            Spacer()
            HStack(spacing: 8) {
                iconButton("曲を追加", "plus", action: store.openFiles)
                iconButton("曲の一覧", "list.bullet", action: { showQueue.toggle() })
                    .popover(isPresented: $showQueue, arrowEdge: .bottom) { QueueView(store: store) }
                iconButton("詳しい解析", "waveform.path", active: showAnalysis, action: { withAnimation(.easeInOut(duration: 0.3)) { showAnalysis.toggle() } })
                iconButton("フルスクリーン", "arrow.up.left.and.arrow.down.right", action: { NSApp.keyWindow?.toggleFullScreen(nil) })
            }
            .padding(6).glassEffect(.regular, in: .capsule)
            .opacity(engaged || !store.isPlaying ? 1 : 0)
            .allowsHitTesting(engaged || !store.isPlaying)
        }
        .padding(.trailing, 24).padding(.top, 18)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Text("音楽が、光になる。").font(.system(size: 30, weight: .light)).tracking(3)
            Text("曲を追加するか、音声ファイルをここへドロップ").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            Button(action: store.openFiles) { Label("曲を追加", systemImage: "plus").padding(.horizontal, 20).padding(.vertical, 8) }
                .buttonStyle(.glass).padding(.top, 8)
        }
    }

    private var trackInformation: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if let track = store.currentTrack {
                if let data = track.artwork, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(track.title).font(.system(size: 27, weight: .medium)).lineLimit(1).textSelection(.enabled)
                    if !track.artist.isEmpty { Text(track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)) }
                    HStack(spacing: 14) {
                        if store.analyzing {
                            ProgressView().controlSize(.mini)
                            Text("曲を解析中 · 再生できます").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        } else {
                            if let section = store.moment.section { Text("SECTION \(section)") }
                            if let bpm = store.moment.bpm { Text("\(Int(bpm.rounded())) BPM") }
                            if let key = store.moment.key { Text(key) }
                            if store.analysis == nil && store.analysisError == nil { Text("解析結果なし") }
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(cyan.opacity(0.9))
                }
                Spacer(minLength: 20)
                activityIndicators
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityIndicators: some View {
        HStack(alignment: .bottom, spacing: 8) {
            activity("歌声", value: store.moment.vocal, color: .pink)
            activity("低音", value: store.moment.bass, color: cyan)
            activity("ドラム", value: store.moment.drums, color: .purple)
            activity("その他", value: store.moment.other, color: .blue)
        }
        .opacity(engaged ? 0.8 : 0.35)
        .accessibilityElement(children: .combine)
    }
    private func activity(_ label: String, value: Float?, color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(color).frame(height: CGFloat(value ?? 0) * 25)
            }.frame(width: 3, height: 25)
            Text(label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
        }
        .accessibilityLabel("\(label)：\(value.map { "\(Int($0 * 100))%" } ?? "未取得")")
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                HStack(spacing: 10) {
                    iconButton("シャッフル", "shuffle", active: store.shuffle, action: { store.shuffle.toggle() })
                    iconButton("前の曲", "backward.end.fill", action: store.previous)
                    Button(action: store.togglePlayback) {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold)).frame(width: 58, height: 50)
                    }.buttonStyle(.plain).help(store.isPlaying ? "一時停止（Space）" : "再生（Space）")
                        .accessibilityLabel(store.isPlaying ? "一時停止" : "再生")
                    iconButton("次の曲", "forward.end.fill", action: store.next)
                    iconButton("リピート", store.repeatSetting == .one ? "repeat.1" : "repeat", active: store.repeatSetting != .off,
                               action: { store.repeatSetting = RepeatSetting(rawValue: (store.repeatSetting.rawValue + 1) % 3)! })
                }
                .padding(.horizontal, 14).padding(.vertical, 5).glassEffect(.regular.interactive(), in: .capsule)

                HStack(spacing: 10) {
                    Button(action: store.toggleMute) {
                        Image(systemName: store.isMuted || store.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .font(.system(size: 12)).frame(width: 24, height: 28)
                            .foregroundStyle(store.isMuted ? cyan : .white)
                    }
                    .buttonStyle(.plain)
                    .help(store.isMuted ? "ミュートを解除" : "ミュート")
                    .accessibilityLabel(store.isMuted ? "ミュートを解除" : "ミュート")
                    .accessibilityValue(store.isMuted ? "オン" : "オフ")
                    Slider(value: $store.volume, in: 0...1).frame(width: 100).tint(cyan).accessibilityLabel("音量")
                    Menu {
                        Picker("出力先", selection: Binding(get: { store.outputID }, set: store.chooseOutput)) {
                            Text("Macの既定の出力先").tag(UInt32(0))
                            ForEach(store.devices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("一覧を更新", action: store.refreshDevices)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "hifispeaker")
                            Text(store.outputDeviceName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 180, height: 28, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 180)
                    .help("音の出力先：\(store.outputName)")
                    .accessibilityLabel("音の出力先：\(store.outputName)")
                }
                .padding(.horizontal, 18).padding(.vertical, 16).glassEffect(.regular, in: .capsule)
                .opacity(engaged || !store.isPlaying ? 1 : 0)
                .allowsHitTesting(engaged || !store.isPlaying)
            }
        }
    }
    private func iconButton(_ label: String, _ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30).foregroundStyle(active ? cyan : .white.opacity(0.85)) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private func errorRow(_ error: String, retry: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(error).font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
            Spacer()
            if let retry { Button("解析をやり直す", action: retry).buttonStyle(.glass) }
            Button { store.playbackError = nil; store.analysisError = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("閉じる")
        }
        .foregroundStyle(.orange.opacity(0.95)).padding(12).glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
    private func revealControls() {
        withAnimation(.easeOut(duration: 0.25)) { engaged = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, store.isPlaying, !showQueue, !showAnalysis else { return }
            withAnimation(.easeInOut(duration: 0.6)) { engaged = false }
        }
    }
}
