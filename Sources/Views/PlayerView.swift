import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlayerView: View {
    @Bindable var store: PlayerStore
    var fileDropSession = PlayerFileDrop.Session()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LyricFont.preferenceKey) private var lyricFont = LyricFont.system
    @State private var showQueue = false
    @State private var showQueueAfterSearch = false
    @State private var showAnalysis = false
    @State private var showLyrics = false
    @State private var lyricDraft = ""
    @State private var lyricFileImportError: String?
    @State private var lyricDraftGeneration: UInt64?
    @State private var headerHeight: CGFloat = 58
    @State private var engaged = true
    @State private var hideTask: Task<Void, Never>?
    private var dropTarget: Bool { fileDropSession.isTargeted }
    private let cyan = Color(red: 0.24, green: 0.87, blue: 1)
    private var overlayVisible: Bool { store.isAppleMusicActive || engaged || !store.isPlaying }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if store.isAppleMusicActive || store.appleMusic.isInitialized {
                    AppleMusicWebView(store: store.appleMusic)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ZStack {
                    MetalVisualizerView(source: store.visualSource, backgroundOpacity: reduceTransparency ? 1 : 0.18)
                        .ignoresSafeArea()
                    if store.isAppleMusicActive && store.visualizerStyle != .cassette {
                        appleMusicArtwork
                            .frame(width: min(240, geometry.size.height * 0.26), height: min(240, geometry.size.height * 0.26))
                            .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.55)
                    }
                    PlayerLyricRegion(store: store, size: geometry.size, headerHeight: headerHeight, font: lyricFont)
                    VStack(spacing: 0) {
                        header
                        if store.tracks.isEmpty && !store.isAppleMusicActive {
                            welcome
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 50).padding(.trailing, 24)
                                .padding(.top, 28)
                        }
                        Spacer(minLength: 20)
                        VStack(spacing: 18) {
                            trackInformation
                                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                                .opacity(overlayVisible ? 1 : 0)
                                .allowsHitTesting(overlayVisible)
                                .accessibilityHidden(!overlayVisible)
                            if let error = store.playbackError { errorRow(error, retry: nil) }
                            if store.isAppleMusicActive, let error = store.appleMusic.audioCaptureError { errorRow(error, retry: nil) }
                            if store.isAppleMusicActive, let error = store.appleMusic.lyricTimingError {
                                errorRow(error, retry: store.appleMusic.retryLyricTiming)
                            }
                            if store.isAppleMusicActive, let error = store.appleMusic.errorMessage {
                                HStack(spacing: 10) {
                                    Label(error, systemImage: "exclamationmark.circle")
                                        .font(.callout).foregroundStyle(.orange)
                                    Button("接続を確認", action: store.openAppleMusicSignIn)
                                        .buttonStyle(.glass)
                                }
                            }
                            if let error = store.analysisError { errorRow("曲の詳しい解析ができませんでした：\(error)", retry: store.retryAnalysis) }
                            if showAnalysis {
                                AnalysisPanel(analysis: store.analysis, time: store.previewTime ?? store.position,
                                              duration: store.duration, isPlaying: store.isPlaying)
                                    .frame(height: min(400, max(280, geometry.size.height - 460)))
                            }
                            MusicalTimeline(store: store)
                                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                                .opacity(overlayVisible ? 1 : 0)
                                .allowsHitTesting(overlayVisible)
                                .accessibilityHidden(!overlayVisible)
                            controls
                        }
                        .padding(.horizontal, geometry.size.width < 1000 ? 32 : 58)
                        .padding(.bottom, 26)
                    }
                    if dropTarget {
                        RoundedRectangle(cornerRadius: 24).stroke(cyan, style: StrokeStyle(lineWidth: 2, dash: [8, 8])).padding(14)
                            .overlay { Label("曲・歌詞ファイルをここへドロップ", systemImage: "doc.badge.plus").font(.title2).padding(24).glassEffect() }
                            .allowsHitTesting(false)
                    }
                }
                .opacity(store.isAppleMusicBrowserVisible ? 0 : 1)
                .allowsHitTesting(!store.isAppleMusicBrowserVisible)
                .accessibilityHidden(store.isAppleMusicBrowserVisible)

                if store.isAppleMusicSearchVisible || store.isAppleMusicBrowserVisible || store.appleMusicBrowser.isInitialized {
                    AppleMusicBrowserView(store: store.appleMusicBrowser, onAdd: { song in
                        store.addAppleMusicSong(song, selectIfEmpty: false)
                    }, onReturnToPlayer: store.showAppleMusicPlayer)
                        .opacity(store.isAppleMusicBrowserVisible ? 1 : 0)
                        .allowsHitTesting(store.isAppleMusicBrowserVisible)
                        .accessibilityHidden(!store.isAppleMusicBrowserVisible)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 800)
        .preferredColorScheme(store.isAppleMusicSearchVisible || store.isAppleMusicBrowserVisible ? nil : .dark)
        .sheet(isPresented: $store.isAppleMusicSearchVisible, onDismiss: {
            if showQueueAfterSearch {
                showQueueAfterSearch = false
                showQueue = true
            }
        }) {
            AppleMusicSearchView(store: store.appleMusicBrowser, onAdd: { song in
                showQueueAfterSearch = true
                store.addAppleMusicSong(song)
            }, onSignIn: store.openAppleMusicSignIn,
               onClose: { store.isAppleMusicSearchVisible = false })
        }
        .onChange(of: store.isAppleMusicActive) { _, active in
            if active { showLyrics = false }
        }
        .onContinuousHover { _ in revealControls() }
        .onTapGesture { revealControls() }
        .onChange(of: fileDropSession.request) { _, request in
            guard let request else { return }
            Task { @MainActor in
                await importDroppedFiles(request.urls, generation: request.generation)
            }
        }
        .onChange(of: store.isPlaying) { _, _ in revealControls() }
        .onChange(of: store.visualizerStyle) { _, _ in revealControls() }
        .onPreferenceChange(PlayerChromeHeightKey.self) { values in
            if let value = values["header"] { headerHeight = value }
        }
        .onChange(of: store.playbackGeneration) { _, generation in
            if lyricDraftGeneration != generation {
                showLyrics = false
                lyricDraft = ""
                lyricFileImportError = nil
                lyricDraftGeneration = nil
            }
        }
        .onChange(of: showLyrics) { _, _ in revealControls() }
        .onChange(of: store.hasPendingLyricSaveFailure) { _, failed in
            if failed && store.lyricsAcceptingRequests {
                if !showLyrics { openLyricEditor() }
                revealControls()
            }
        }
        .onChange(of: store.lyricsAcceptingRequests, initial: true) { _, accepting in
            if accepting && store.hasPendingLyricSaveFailure {
                if !showLyrics { openLyricEditor() }
                revealControls()
            }
        }
        .onChange(of: store.previewTime) { _, value in
            if value == nil { revealControls() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("MUSIC PRAYER").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 70)
            Spacer()
            HStack(spacing: 8) {
                Button(action: store.openAppleMusic) {
                    Label("Apple Music", systemImage: "music.note")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).frame(height: 28)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel("Apple Musicを開く")
                iconButton("曲を追加", "plus", action: store.openFiles)
                iconButton("曲の一覧", "list.bullet", action: { showQueue.toggle() })
                    .popover(isPresented: $showQueue, arrowEdge: .bottom) { QueueView(store: store) }
                iconButton("詳しい解析", "waveform.path", active: showAnalysis, action: { withAnimation(.easeInOut(duration: 0.3)) { showAnalysis.toggle() } })
                iconButton("歌詞", "text.quote", active: showLyrics, action: {
                    if showLyrics { showLyrics = false }
                    else { openLyricEditor() }
                })
                    .disabled(store.currentTrack == nil && !store.hasPendingLyricSaveFailure)
                    .popover(isPresented: $showLyrics, arrowEdge: .bottom) {
                        LyricEditorView(store: store, draft: $lyricDraft, fileImportError: $lyricFileImportError,
                                        onFileDrop: { urls in
                            let generation = store.playbackGeneration
                            Task { @MainActor in await importDroppedFiles(urls, generation: generation) }
                        })
                    }
                Menu {
                    Picker("歌詞フォント", selection: $lyricFont) {
                        ForEach(LyricFont.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }.pickerStyle(.inline)
                } label: {
                    Image(systemName: "textformat")
                        .font(.system(size: 13, weight: .medium)).frame(width: 30, height: 28)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("歌詞フォント：\(lyricFont.title)")
                .help("歌詞フォントを選びます")
                Menu {
                    Picker("ビジュアライザー", selection: $store.visualizerStyle) {
                        ForEach(VisualizerStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }.pickerStyle(.inline)
                } label: {
                    Label(store.visualizerStyle.title, systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).frame(height: 28)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("ビジュアライザー：\(store.visualizerStyle.title)")
                .help("ビジュアライザーを選びます")
                iconButton("フルスクリーン", "arrow.up.left.and.arrow.down.right", action: { NSApp.keyWindow?.toggleFullScreen(nil) })
            }
            .padding(6).glassEffect(.regular, in: .capsule)
        }
        .padding(.trailing, 24).padding(.top, 18)
        .opacity(overlayVisible ? 1 : 0)
        .allowsHitTesting(overlayVisible)
        .accessibilityHidden(!overlayVisible)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PlayerChromeHeightKey.self, value: ["header": proxy.size.height])
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("曲を追加して、再生をはじめる")
                .font(.system(size: 20, weight: .semibold))
            Text("音声ファイルを選ぶか、この画面へドロップしてください。")
                .font(.system(size: 13)).opacity(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.primary)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .frame(maxWidth: 360, alignment: .leading)
        .padding(20)
    }

    private var trackInformation: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if store.isAppleMusicActive {
                VStack(alignment: .leading, spacing: 7) {
                    Text(appleMusicTitle)
                        .font(.system(size: 27, weight: .medium)).lineLimit(1).textSelection(.enabled)
                    if !appleMusicArtist.isEmpty {
                        Text(appleMusicArtist).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                    }
                    analysisInformation
                }
                Spacer(minLength: 20)
                activityIndicators
            } else if let track = store.currentTrack {
                if let data = track.artwork, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(track.title).font(.system(size: 27, weight: .medium)).lineLimit(1).textSelection(.enabled)
                    if !track.artist.isEmpty { Text(track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)) }
                    analysisInformation
                }
                Spacer(minLength: 20)
                activityIndicators
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var analysisInformation: some View {
        HStack(spacing: 14) {
            if store.isAppleMusicActive, let song = store.currentQueueTrack?.appleMusicSong,
               store.appleMusic.preanalysis.isAnalyzing(songID: song.id) {
                AnalysisProgressView(status: store.appleMusic.preanalysis.status(for: song),
                                     progress: store.appleMusic.preanalysis.progress(for: song))
                    .tint(cyan).frame(width: 240)
            } else if store.analyzing {
                ProgressView().controlSize(.mini)
                Text(store.isAppleMusicActive ? "再生しながら解析中" : "曲を解析中 · 再生できます").font(.system(size: 14)).foregroundStyle(.white.opacity(0.9))
            } else {
                if let section = store.moment.section ?? (store.position == 0 && store.analysis?.sections.isEmpty == false ? 1 : nil) { Text("SECTION \(section)") }
                if let bpm = store.moment.bpm { Text("\(Int(bpm.rounded())) BPM") }
                if let key = store.moment.key ?? (store.position == 0 ? store.analysis?.keys.first?.label : nil) { Text(key) }
                if store.analysis == nil && store.analysisError == nil {
                    if store.isAppleMusicActive, let song = store.currentQueueTrack?.appleMusicSong {
                        Text(store.appleMusic.preanalysis.status(for: song))
                    } else { Text("解析結果なし") }
                }
            }
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(cyan)
    }

    private var appleMusicTitle: String {
        if let song = store.currentQueueTrack?.appleMusicSong { return song.title }
        return store.appleMusic.playback.title.isEmpty ? "Apple Music" : store.appleMusic.playback.title
    }

    private var appleMusicArtist: String {
        store.currentQueueTrack?.appleMusicSong?.artist ?? store.appleMusic.playback.artist
    }

    private var appleMusicArtworkURL: String? {
        if let song = store.currentQueueTrack?.appleMusicSong { return song.artworkURL }
        return store.appleMusic.playback.artworkURL
    }

    private var appleMusicArtwork: some View {
        AsyncImage(url: appleMusicArtworkURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.07))
                Image(systemName: "music.note").font(.system(size: 72, weight: .light)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("Apple Musicのジャケット")
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
                        .disabled(!store.canSkipPrevious)
                    Button(action: store.togglePlayback) {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold)).frame(width: 58, height: 50)
                    }.buttonStyle(.plain).help(store.isPlaying ? "一時停止（Space）" : "再生（Space）")
                        .accessibilityLabel(store.isPlaying ? "一時停止" : "再生")
                        .disabled(!store.canTogglePlayback)
                    iconButton("次の曲", "forward.end.fill", action: store.next)
                        .disabled(!store.canSkipNext)
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
                        Picker("出力先", selection: Binding(get: { store.selectedOutputID }, set: store.chooseOutput)) {
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
                .opacity(overlayVisible ? 1 : 0)
                .allowsHitTesting(overlayVisible)
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
            Button { store.playbackError = nil; store.analysisError = nil; store.appleMusic.audioCaptureError = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("閉じる")
        }
        .foregroundStyle(.orange.opacity(0.95)).padding(12).glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
    private func openLyricEditor() {
        lyricDraft = LyricInput.clean(store.lyricText)
        lyricFileImportError = nil
        lyricDraftGeneration = store.playbackGeneration
        showLyrics = true
    }

    @MainActor
    private func importDroppedFiles(_ urls: [URL], generation: UInt64) async {
        do {
            switch try PlayerFileDrop.destination(for: urls) {
            case .audio(let audio):
                await store.add(urls: audio)
            case .songAndLyrics(let audio, let lyrics):
                guard let text = try await PlayerFileDrop.importPair(audio: audio, lyrics: lyrics,
                                                                    store: store, generation: generation) else { return }
                guard store.currentTrack?.url == audio, store.lyricsAcceptingRequests else { return }
                openLyricEditor()
                lyricDraft = text
                revealControls()
            case .lyrics(let lyrics):
                guard generation == store.playbackGeneration else { return }
                guard store.lyricsAcceptingRequests, store.currentTrack != nil else {
                    store.playbackError = "歌詞を読み込む前に曲を選んでください。"
                    return
                }
                if !showLyrics { openLyricEditor() }
                do {
                    lyricDraft = try LyricTextFile.read([lyrics])
                    lyricFileImportError = nil
                } catch {
                    lyricFileImportError = error.localizedDescription
                }
                revealControls()
            }
        } catch {
            if showLyrics { lyricFileImportError = error.localizedDescription }
            else { store.playbackError = error.localizedDescription }
        }
    }

    private func revealControls() {
        withAnimation(.easeOut(duration: 0.25)) { engaged = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, store.isPlaying, !showQueue, !showAnalysis, !showLyrics, store.previewTime == nil else { return }
            withAnimation(.easeInOut(duration: 0.6)) { engaged = false }
        }
    }
}

/// The second reference image places the lyric centre at 24% of the window height.
/// The analysis panel is independent of this region.
struct PlayerLyricRegion: View {
    let store: PlayerStore
    let size: CGSize
    let headerHeight: CGFloat
    var font: LyricFont = .system

    var body: some View {
        LyricMotionView(store: store, font: font)
            .frame(width: size.width, height: max(0, size.height * 0.48 - 2 * headerHeight))
            .position(x: size.width / 2, y: size.height * 0.24)
            .allowsHitTesting(false)
    }
}

private struct PlayerChromeHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
