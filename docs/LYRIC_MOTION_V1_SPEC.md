# MusicPrayer リリックモーショングラフィックス V1

実装仕様・技術仕様／2026-10-03

状態：構造の表示枠、Apple公式認識と本文による行選択、その他の全Music Understanding解析の補助確認を保持し、認識区間を文字の青色進行へ渡すalignmentVersion 5を実装。行表示、フェード、再生・シーク経路を維持する。検証記録は第24節と `FOR[hazimeno_ipoo].md` を参照。

## 1. 目的と適用範囲

ユーザーがタイムコードのない歌詞全文を入力すると、AppleのSpeech frameworkで音源内の文字と時刻を認識し、その結果と入力した各行を照合する。Music Understandingの大きな区間・小さな区間・フレーズを表示の枠にし、その中で音声認識と本文に対応する行を選ぶ。その他の全解析は同じ枠の補助確認に使う。認識の開始・終了を固定幅で動かさず、Metalビジュアライザーの上へSwiftUIの文字モーションを表示する。

本機能は、音声認識が返した文字と音源区間から「推定した歌詞表示時刻」を生成する。歌詞にない冒頭・途中のボーカル部分を、入力行へ無条件に割り当てない。歌唱音源の認識精度、各行の実際の歌唱時刻との一致、単語・文字の発音時刻は保証しない。入力順序、本文の保持、時刻の範囲、同一の認識結果からの照合・描画の再現性は実装で保証する。Appleのモデル更新等により、再認識の結果が常に同一になるとは保証しない。

実装の基準はコミット済み `master` の `3ff5e2fb14681bc9c05becf8665b2199e3fe4425`。対象環境は既存プロジェクトと同じmacOS 27以降。既存のカセット表示を含むアプリ構造と、今回の歌詞機能の作業中変更を保持して接続する。

## 2. V1で実装すること

- ヘッダーの「歌詞」ボタンと、歌詞編集用popover。
- 非空行をそのまま保持する歌詞パーサー。
- Apple公式の音声認識から取得する時刻付き文字と、歌詞行の順序・非重複を守る全体DP照合。Music Understandingの3階層による表示枠と、その他の全解析による補助確認。
- 行単位・文字単位の決定的なモーションを持つ1種類の表示スタイル。
- 歌詞本文と有効な生成結果のローカル保存・復元。
- 解析待ち、Appleモデル準備、音声認識、本文照合、生成済み、生成失敗、保存失敗の状態表示。
- シーク、プレビュー、一時停止、停止、リピート、曲変更への追従。

## 3. V1の対象外

歌詞検索、自動取得、Whisper等の外部ライブラリー・自前のAIモデル、歌詞本文の修正、入力行の分割・結合・並べ替え、手動タイムコード編集、Metal内の文字描画、複数の演出スタイルは実装しない。

「音声認識を使わない」という制約は、ユーザーの2026-10-02の明示説明に従い、外部ライブラリーを追加しない意味として確定する。Apple公式のSpeech frameworkとシステム管理のモデルは使用できる。モデルの準備にはAppleサーバーからのダウンロード通信が発生し得る。音源の認識は端末内で行い、音声をアップロードしない。保存済みファイルを読むため、マイクは使用しない。旧 `SFSpeechRecognizer` の許可要求は追加しない。

## 4. 保持する既存動作

音声再生、音量・ミュート、出力先、曲一覧、解析パネル、ギャップレス再生、ビジュアライザー選択、Metalの描画・水面操作・カメラ・曲間フェードを保持する。

`PlayerStore.position` の通常更新は約10Hzのままにする。歌詞のためにPlayerStore全体を60Hz更新へ変更しない。既存の `VisualFrameSource.observeFrames` は単一の通知先を持つため、歌詞ビューから登録してMetal側の通知を置き換えない。

## 5. 歌詞入力と文字の定義

`sourceText` はユーザーが適用した文字列をそのまま保存する。解析用の行分解ではCRLFを1改行として扱い、LFとCRも改行として扱う。保存する本文には改行コードの変換を加えない。

空白文字だけの行は空行とする。それ以外の非空行1行を1つの `LyricLine` とする。行の先頭・末尾の空白、句読点、表記は保持する。同じ本文の行も非空行順の番号によって区別する。

連続する空行は1つの段落境界情報へまとめ、空行は表示行へ含めない。`paragraphStart` は本文の構造として保持する。歌詞行の時刻を音楽境界へ動かすためには使わない。空行情報から認識語の時刻を新しく作らない。

`textWeight` はSwiftの `Character`、すなわち結合文字や絵文字のまとまりを含む見た目の文字単位で数える。空白・句読点・制御文字・書式制御だけで構成されるCharacterは0、それ以外は1とする。判定にはUnicode scalarの分類を使用するが、加算はCharacterごとに1回だけ行う。

例：`君の声` は3、`遠い夜の向こうから` は9。句読点だけの非空行も削除せず、`textWeight = 0` のまま保持する。文字重みは照合対象の判定に使い、青色の時間配分には使わない。照合できる文字がない非空行を含む場合は、本文を保持して生成全体を失敗させる。

歌詞表示での折返しはレイアウト処理であり、LyricLineの追加・分割ではない。

## 6. データモデル

```swift
enum LyricAlignmentMode: String, Codable, Sendable {
    case speechRecognition
}

struct RecognizedLyricToken: Codable, Sendable, Equatable {
    var text: String                 // Appleの確定認識結果の文字
    var start: Double                // audioTimeRangeの開始秒
    var end: Double                  // audioTimeRangeの終了秒
    var confidence: Double           // Appleの認識confidence、欠測時0
}

struct LyricLine: Sendable {
    var ordinal: Int                  // 非空行の0始まり順序
    var text: String
    var paragraphStart: Bool
    var textWeight: Double
}

struct TimedLyricLine: Codable, Sendable, Identifiable {
    var id: String                    // 決定的に生成するSHA256文字列
    var ordinal: Int
    var text: String
    var start: Double
    var end: Double
    var textWeight: Double
    var confidence: Float             // 整合度。正答確率ではない
    var characterTimings: [LyricCharacterTiming] // 原文のCharacter順
}

struct LyricCharacterTiming: Codable, Sendable, Hashable {
    var start: Double                 // 青色進行の開始秒
    var end: Double                   // 青色進行の完了秒
}

struct LyricStructureFrame: Codable, Sendable {
    var start: Double
    var end: Double
    var section: Int
    var segment: Int
    var lineOrdinals: [Int]
    var support: LyricFrameSupport    // 同じ枠の全解析補助情報
}

struct LyricTimeline: Codable, Sendable {
    var version: Int                  // alignmentVersion
    var analysisVersion: Int
    var analysisFingerprint: String   // 既存の音源全バイトSHA256
    var analysisDigest: String        // 全MusicAnalysisのsorted-key JSONのSHA256
    var sourceText: String
    var sourceTextHash: String
    var mode: LyricAlignmentMode
    var lines: [TimedLyricLine]
    var confidence: Float
    var frames: [LyricStructureFrame]
}

struct SavedLyrics: Codable, Sendable {
    var schemaVersion: Int
    var audioFingerprint: String
    var sourceText: String
    var sourceTextHash: String
    var timeline: LyricTimeline?       // 解析待ち・生成失敗でも本文は保存する
}
```

`schemaVersion = 1` を維持し、文字ごとの色時刻を保存する `alignmentVersion = 5` とする。使用モードは `speechRecognition` のみ。旧version 1〜4の時刻結果は再利用せず、保存済み本文を保持して再生成する。文字時刻は原文のCharacter数と一致し、有限・行区間内・有効文字の開始と終了がそれぞれ非減少であることを保存・復元時に確認する。複数文字が同じ認識区間を共有できる。音楽解析キャッシュは全4楽器のrangesを保持するversion 3のままで、この色表示の修正による再解析は不要。

行IDは音源fingerprint、alignmentVersion、本文hash、ordinalを、各要素のUTF-8バイト長を付けた固定順のバイト列としてSHA256にする。`UUID()`、Swiftの `Hasher`、ランダム値は使用しない。繰り返しの同文もordinalが異なるため別IDになる。

## 7. 使用する認識・解析情報と役割

| 情報 | 使用する役割 |
|---|---|
| Speechの確定文字列・audioTimeRangeと歌詞本文 | 表示する元の行と、その認識区間、文字の青色進行を決める |
| sections/segments/phrases | 3階層の表示枠を保持し、各行を交差する全フレーズへ関連付ける |
| vocal/drums/bass/otherのranges・activity | 枠内の存在範囲と活動量を補助確認する。長い先頭認識区間では歌声の立上りを色開始の補助確認に使う |
| beats/bars/BPM | 枠内の拍・小節の数と全曲テンポを補助確認する。BPMの1拍は長い先頭認識区間の判定にも使う |
| Pace・Key | 枠と重なる全範囲の値・調性を補助確認する |
| momentary/shortTerm/integrated/peak | 枠内の音量と全曲基準を補助確認する。先頭の色開始ではmomentaryの上昇も確認する |
| version/fingerprint/durationと全解析digest | 曲内時刻、保存・復元時の整合性を確認する |

補助情報は `LyricStructureFrame.support` に保持する。活動量と局所音量は枠内の有効観測の平均、Pace・Keyは重なる範囲の値、peakとintegratedは元の全曲値を保持する。欠測に架空の値を補わない。時刻の重み付き採点、一律の境界補正、本文に対応しない歌声への歌詞割当には使わない。

## 8. 言語判定とAppleモデル準備

1. `SpeechTranscriber.isAvailable` で現在のMacの利用可否を確認する。
2. `NLLanguageRecognizer` で入力した歌詞本文の言語を判定する。判定できない場合は理由を表示して失敗する。
3. `SpeechTranscriber.supportedLocale(equivalentTo:)` で対応ロケールを取得する。対応しない言語を別言語に黙って置き換えない。
4. 状態を `preparingRecognition` とし、`AssetInventory.assetInstallationRequest(supporting:)` で必要なモデルの準備要求を取得する。
5. 要求があれば `downloadAndInstall()` を待つ。導入済みなら要求はnilとなる。必要なロケール予約はAPIが自動で行う。
6. 資産状態が `.installed` であることを確認して認識へ進む。ダウンロード失敗、対応外、予約上限等は失敗として知らせる。

Appleがシステム領域で管理するモデルを使い、アプリへ外部依存やモデルファイルを同梱しない。モデル導入には通信が必要な場合があり、一度導入したモデルはシステム管理のもとで再利用される。ダウンロードの初回試行が失敗した後にシステムが再試行することもある。認識要求を取り消すことがモデルダウンロード自体の停止を保証するとは扱わない。

`AnalysisContext.contextualStrings` に歌詞全文を渡す強制整列は使用しない。現行の公式説明は `DictationTranscriber` への短い語句の認識補助であり、`SpeechTranscriber` による指定歌詞の確実な認識・整列としての根拠にはしない。

## 9. ファイル認識と時刻付き文字の取得

保存済み音源を `AVAudioFile(forReading:)` で開き、状態を `recognizing` とする。`SpeechTranscriber` は `reportingOptions: []`、`attributeOptions: [.audioTimeRange, .transcriptionConfidence]` で確定結果と時刻を要求する。

認識結果のAsyncSequenceを読みながら `SpeechAnalyzer.analyzeSequence(from:)` でファイルを解析する。ファイル読込完了は認識完了と同じではない。返された最終サンプル時刻で `finalizeAndFinish(through:)` を待ち、結果列も終端まで読む。空ファイルや中止・エラーでは `cancelAndFinishNow()` を呼ぶ。

`result.isFinal` の結果だけを使用し、`result.text.runs` ごとに文字列、`run.audioTimeRange` の開始・終了秒、認識confidenceを `RecognizedLyricToken` へ写す。時刻属性がないrun、非有限時刻、負の開始、正の長さがない区間は使用しない。confidenceの欠測は0として保持する。

Appleが返した時刻を使い、語句内部を文字数で分割して発音時刻を新しく作らない。1つのrunに複数文字がある場合、それらは同じ音源区間に属する。確定結果だけを使用するため、揮発結果の上書きを歌詞タイムラインへ反映しない。

## 10. 照合用の正規化と本文保持

照合に使う文字列だけを正規化する。入力の `sourceText`、各行の本文、保存・表示する文字列は変更しない。認識語の誤記を入力歌詞へ書き戻さない。

入力行と認識文字列に同じ正規化を適用する。Unicodeの正規合成、`widthInsensitive`・`caseInsensitive` による幅と大小文字の統一、ひらがなからカタカナへの変換を行い、`LyricParser.characterWeight` が0になる空白・句読点等を除く。幅・大小文字の処理には固定の `ja_JP` ロケールを使う。正規化した認識文字には、元の `RecognizedLyricToken` のindexと音源区間を対応付ける。正規化で文字数が変わっても音源の時刻を作り直さない。

句読点等だけの行や、正規化後に照合文字がなくなる非空行は入力から削除せず、生成全体を失敗させる。照合のために入力行を分割・結合・並べ替えない。

日本語文字を含む行では、元文字の編集距離と一致数が同点になる候補の比較を補うため、Appleの `CFStringTokenizer` と `kCFStringTokenizerAttributeLatinTranscription` を使う。`ja_JP` で行全体と認識候補全体の読みを取得し、読み文字列の編集距離を第三の評価にする。例えば「ひとつ」と「一つ」の表記差を扱う。1文字ずつ漢字を読む処理は使わない。読みだけでは最低文字一致条件を通せず、元の文字一致を優先する。いずれかの候補で読みを取得できない行は、行全体の読みの補助評価を無効にする。異なる時刻の同じ語が、文字と読みの対応で同評価のまま残る場合は曖昧判定を維持する。

## 11. 各行の候補区間

正規化した各歌詞行について、認識文字列中の連続区間との編集距離を評価し、語句の対応がある候補を作る。編集距離は、文字の置換・脱落・余分な文字を含む不一致の量として扱う。同じ編集距離なら一致文字数が多い照合を選ぶ。候補の採用条件と曖昧判定をLyricAligner内で一元管理し、変更時はalignmentVersionを上げる。

正規化した行の文字数を `N`、認識区間との一致文字数を `M` として、version 5でも文字照合の設定を次のようにする。これらは照合の設計値であり、歌唱時刻の精度保証ではない。

| 項目 | 設定 |
| --- | --- |
| 行の一致割合 `M / N` | 0.60以上 |
| 許容編集数 | `max(2, floor(N × 0.45))` 以下 |
| 認識側の連続探索窓 | `ceil(N × 1.8) + 2` 文字以内 |
| 1行の認識区間長 | 0.30秒以上 |
| 時刻・比率の数値比較誤差 | `1e-9` |

行頭や行末の文字の完全一致は必須にしない。許容範囲の認識誤字・脱落を扱うが、認識tokenの途中を候補の開始・終了として切り出さない。1つのtokenの範囲を2行に分割し、文字数で境界時刻を補う処理は行わない。

候補は認識文字列上の開始・終了位置と、その区間に対応する元の認識tokenの時刻を保持する。開始は対応する最初の認識区間の開始、終了は最後の認識区間の終了を使用する。無音や音楽境界へ移動せず、固定の最小時間や均等配分で候補を押し込まない。

同じ本文が繰り返される場合は時刻が異なる複数の候補を持てるようにし、最初に見つかった候補だけを即採用しない。候補がない行、対応文字が足りない行は、行番号を含む失敗理由を返す。

## 12. 順序を守る全体DP照合

全行の候補を、入力順序と認識文字列の順序が一致する経路として評価する。前行の終了より前へ戻る候補、認識位置や音源の時刻が前行と重なる候補は接続しない。各行を1回ずつ選ぶ全体経路を求め、局所的に最初の候補を選ぶ貪欲処理は行わない。

音源の冒頭・途中・末尾にだけ存在する認識tokenは、見送りコスト0で飛ばせる。これにより、入力歌詞にないボーカルを消化するために最初の歌詞を早めたり、他の行を引き伸ばしたりしない。歌詞行自体は飛ばさない。

全行を照合できる経路だけを成功候補とする。経路全体の編集距離の合計を最小にし、同距離なら入力側の不一致文字数 `Σ(N - M)` が少ない経路を優先する。両方同点の場合だけ、日本語の読みの編集距離を比較する。部分的に照合できた歌詞を生成済みとして返さない。最良経路と次点の経路がこの3項目で同一なら、曖昧な照合として失敗する。音楽の境界や強度だけで、同じ本文の別時刻を確定したことにしない。


## 13. 必須条件と失敗

成功結果は次のすべてを満たす。

- 全非空行の本文、行数、ordinal、入力順序を保持する。
- 各行は認識結果との対応がある候補から生成する。
- 開始・終了は有限で、`0 <= start < end <= duration`、行区間は0.30秒以上。
- 入力順の行区間が重ならない。
- 曖昧な複数の対応を、認識できたこととして扱わない。
- 音源fingerprint、本文hash、alignmentVersionが現在の要求と一致する。

端末で利用不可、言語判定不可、対応外言語、Appleモデル準備失敗、認識語なし、照合できない行、全行をつなぐ経路なし、曖昧な照合、最終境界不成立、保存データ不整合を失敗理由として区別する。

失敗時は適用済みの歌詞全文を保存・保持する。旧信号DP、曲長への均等割、過去本文のタイムライン、別曲のタイムラインへ自動で切り替えない。文字列の対応が認識できないケースをvocalやphraseだけで成功へ昇格させない。

## 14. 構造の表示枠と個別行の選択

DPで選んだ最初・最後の認識tokenの開始・終了を、そのまま `TimedLyricLine` に保持する。0.50秒のphrase補正・0.12秒のvocal補正は行わない。

`LyricMusicContext` は各フレーズについて、開始・終了、包含する大きな区間と小さな区間の番号、その枠と交差する全歌詞行のordinal、全6解析の補助情報を持つ `LyricStructureFrame` を作る。大・小区間とフレーズが未取得の場合は生成を失敗にし、架空の曲全体フレーズで補わない。

1フレーズに複数行が入る場合は、その枠の中で各行の認識時刻に従って順に切り替える。1行が複数フレーズをまたぐ場合は、交差する全枠へ関連付け、同じ行IDと認識区間を保持する。最も長く重なる1フレーズだけに限定しない。数msの端の交差を切り落とさない。元の入力行を分割・結合せず、同時に全関連行を並べる表示へ変更しない。

描画時はsnapshotの現在時刻に対応する枠の関連行から、既存の個別行選択を行う。開始前0.35秒・終了後0.40秒のフェードを保つため、隣接枠も同じ表示窓で参照する。フレーズ切替で途中の行を消さず、同じフレーズ内のシークでも現在時刻から再選択する。

全行の時刻が構造枠で覆われること、枠の非重複、3階層の包含、行参照の完全性を生成・保存・復元時に検査する。数値計算上の許容差1µsを、人間の知覚の許容誤差には置き換えない。認識結果が対応しない枠の行参照は空とする。

行IDの決定方法は第6節を維持する。同じ音源fingerprint、本文、version、認識結果、Music Understanding解析なら、ID・時刻・confidence・表示枠は同一にする。Appleの認識処理自体の再実行やモデル更新まで決定的とは説明しない。

正常な生成結果は保存して次回に再利用する。保存キー・全解析digest・表示枠の検査を満たさない場合だけ本文から再生成する。全文認識ログを新たに永続保存する仕組みは追加しない。

## 15. confidenceと診断

各行のconfidenceは正規化文字の一致割合 `M / N`、全体confidenceは各行confidenceの算術平均とする。Appleの認識confidenceはtokenへ保持するが、候補を選ぶ採点や、この保存confidenceの計算へ混ぜない。保存結果のconfidenceは文字照合の整合度として扱い、歌唱境界が正しい確率とは説明しない。通常の再生画面には数値を表示しない。

内部診断には、使用ロケール、認識token数、照合行数、認識文字数、文字照合の整合度、構造枠の数、境界補正なしという生成方式、照合できない行番号、曖昧な対応、モデル準備・認識・照合・保存の失敗理由を必要な範囲で残す。入力歌詞全文と認識全文はログへ出力しない。confidence値だけを根拠に、必須条件を破る候補を採用しない。

## 16. 描画構造と同期用データ

```text
PlayerView の ZStack
├─ MetalVisualizerView       既存
├─ PlayerLyricRegion         LyricMotionView、allowsHitTesting(false)
└─ 既存UI                    配置を保持
```

歌詞の中心はPlayerViewの横中央、上から高さの24%に固定する。2026-10-03の画像2（解析パネル表示時）の位置を基準とし、解析パネルの開閉では移動しない。表示領域の高さは `max(0, playerHeight × 0.48 − headerHeight × 2)` とし、上部ヘッダーを避ける。下部UIの高さから歌詞位置を再計算せず、解析パネルの開閉でもウィンドウの最小高さは660ptを保つ。表示領域から左右24pt、上下16ptを引いた矩形を文字描画へ渡す。行の基準フォントはsystemのmedium、32pt、行間6pt、中央揃え。Textの組版サイズを測定し、通常は32ptから14ptの範囲で縮小して収める。長い行は表示上だけ折り返す。

14ptでも高さが収まらない場合は、文字自体を省略せず、固定の表示領域内で行全体を縦方向へ送る。移動量は `-max(0, textHeight - viewportHeight) × lineProgress`。開始時は先頭、終了時は末尾を見せる。同時に全本文が見えることは保証しない。領域がない場合は表示を一時的に省き、既存UIを押し広げない。生成データと本文は保持する。

独立した文字のHStackで組版せず、SwiftUIのTextとTextRendererを使う。LyricParserが求めた各Characterの累積重みの開始・終了を `LyricProgressAttribute: TextAttribute` で各Text断片へ付け、それらを単一のTextへ連結する。組版後のrun／sliceが持つ属性を描画時に読み、強調へ渡す。`Text.Layout.CharacterIndex` から元のString.Indexを逆算しない。

複数の描画単位が同じCharacterに属する場合は同じ属性で同時に強調する。複数Characterが1つの字形に組版される場合は、SwiftUIがその描画単位へ渡した属性を使い、字形全体を一体として強調する。字形の途中を文字数に合わせて切らない。モーション用の進行とCharacterが常に1対1であるとは説明しない。本文保持と通常の字形・折返しは、日本語、結合文字、絵文字、英語の合字で実画面確認する。

`VisualFrame` に歌詞用のpayloadを1つ追加する。Metalの既存フィールドは変更しない。

```swift
struct LyricPlaybackFrame: Sendable {
    var trackID: UUID?
    var playbackGeneration: UInt64
    var audioFingerprint: String?
    var time: Double
    var duration: Double
    var isPlaying: Bool
    var isPreviewing: Bool
    var vocal: Float?             // 平滑化前の解析値
    var beat: Float
    var beatPhase: Float
    var barPhase: Float
    var phraseProgress: Float
    var sectionProgress: Float
}
```

`tick()` は、現在曲の `previewTime ?? engine.currentTime` と、その時刻を使った `TimelineSampler` の結果からpayloadを作る。既存の `TrackVisualTransition.frame(...)` 適用後に、その現在曲payloadを `frame.lyrics` へ設定してpublishする。旧曲のframeをフェード表示する時間でも、歌詞payloadは旧曲の時刻・活動量を継承しない。

payloadは再生曲・音源fingerprint・再生世代で採否を判定する。同じ曲を再選択した場合も再生世代を更新する。世代不一致またはfingerprint不一致のフレームでは歌詞を描画しない。

## 17. 更新頻度、一時停止、シーク

歌詞表示中・再生中は `TimelineView(.animation(minimumInterval: 1.0 / 60.0))` からsnapshotを読む。60fpsを目標にするが、固定60fpsやMetalとの同時描画を保証しない。アニメーションの計算には壁時計やTimelineViewのdateを使わず、payloadのtimeを使う。

一時停止中はAnimationTimelineScheduleをpausedにし、現在時刻の表示状態を保持する。歌詞なしではTimelineViewを作らない。

再生／一時停止の切替、シーク、停止、曲選択成功、自動曲切替、現在曲削除、プレビュー変更、解析完成時は、現在曲payloadを同期的に更新する。停止中の再描画には、イベント時だけ変わる `lyricFrameRevision` を使用する。再生中のtickでこのObservable値を増やさない。

`previewTime` の変更処理からもpayload更新を呼ぶ。歌詞ビューが停止していてもドラッグ先の状態を再描画できる。曲変更等の処理では先に歌詞の世代・本文・解析状態を切り替え、最後にpayloadを発行し、旧解析と新しい曲を混ぜない。

シーク後は次の描画で移動先を検索し、途中のモーション履歴を再生しない。停止は既存動作どおり0秒へ戻り、歌詞も0秒での表示状態に戻る。

## 18. V1のモーション

表示候補は `[start - 0.35, end + 0.40]` が現在時刻と重なる行。隣接行の範囲が重なる場合はクロスフェード表示する。短い行が続いて3行以上が候補になる場合は、歌唱時刻内の行を優先し、残りは計算したopacityが大きい順に選び、最大2行を描画する。同値ならordinalが小さい行を優先する。選択は毎回現在時刻だけから決定する。各行のアニメーションは固定の中央基準位置で計算し、他行の出入りによってレイアウト位置を跳ばさない。

開始前0.35秒で、opacity 0→1、scale 0.94→1、blur 10→0pt、Y +16→0pt。終了後0.40秒で、opacity 1→0、blur 0→8pt、Y 0→−16pt。補間は `smoothstep(x) = x²(3−2x)`。曲頭より前の表示時間と曲末より後の表示時間は描画しない。

歌唱中は次のように反応する。

| 入力 | 反映 |
| --- | --- |
| 平滑化前のvocal | 0〜1でclampし、発光の透明度0.15〜0.45、半径2〜6pt |
| beat／beatPhase | `1 + 0.02 × clamp(beat, 0, 1) × (1 - clamp(beatPhase, 0, 1))` のスケール |
| barPhase | X方向 `2 × sin(2π × barPhase)` ptの移動 |
| 原文の各Characterに対応する認識区間と現在時刻 | 文字ごとの白からcyanへの強調進行 |
| 行内progress | 長い行の縦送り |

vocal欠測時は発光の基準値を使用し、歌唱活動をあるように補わない。文字の基本色は白、強調色は既存UIに合わせたcyanとする。

青色は `clamp((time-character.start)/(character.end-character.start), 0, 1)` から文字ごとに計算する。対応区間より前は白、終了後はcyan、次の文字まで間があれば色の進行を待つ。開始と終了が同時刻の場合は、その時刻に強調を完了する。`lineProgress = clamp((time-start)/(end-start), 0, 1)` は長い行の縦送りにだけ使う。

選択済みの行の文字照合をたどり、原文のCharacter番号へ認識区間を対応付ける。複数文字のtokenは同じ区間を共有し、内部時刻を均等分割しない。認識で脱落した文字は次の対応区間を共有し、末尾の脱落と空白・句読点は直前区間の終了へ対応させる。原文は変更しない。

本文先頭と一致する単一文字の認識区間が、同じ行の後続tokenの最長区間とBPMの1拍の両方より長い場合だけ、待ち時間を含む先頭区間を補助確認する。その区間内の歌声活動の谷より後で最大の上昇を示す観測点を調べ、momentary音量も上昇していれば、先頭文字の色開始をその観測点にする。条件を確認できなければ元の認識区間を使用する。先頭文字の終了、後続文字、行時刻、構造枠は動かさない。固定秒数の補正、拍やフレーズへの吸着、音楽情報の重み付き採点は加えない。

認識区間内の色の濃さは視覚演出であり、すべての文字の正確な発音境界を保証するものではない。状態を積み上げるばね、ランダム値、過去のtickからの平滑化は歌詞演出へ使用しない。同じ解析・本文・再生時刻・画面サイズなら同じ表示パラメーターになる。

## 19. 歌詞編集UI

ヘッダーへ「歌詞」ボタンを1つ追加する。曲未選択時は無効にする。popoverはTextEditor、状態欄、「適用」を基本とする。

編集内容はpopover内のdraftとする。「適用」で現在曲へ確定する。適用せず閉じた変更は保存しない。空白・改行だけを適用した場合は `clearLyrics()` として保存済み歌詞を削除し、表示を消す。

状態文言は「歌詞未設定」「音源を確認中」「解析待ち」「Appleの音声認識モデルを準備中」「音声から歌詞の時刻を確認中」「歌詞と認識結果を照合中」「生成済み」「タイミングを生成できませんでした」「歌詞を保存できませんでした」を基本とし、失敗時は短い理由を添える。タイミング状態は `preparingRecognition → recognizing → generating → generated(.speechRecognition)`、各工程の失敗は `failed` とする。

歌詞入力欄は生成中も編集可能。適用の連打は直前の生成をキャンセルし、最新本文だけを対象にする。popoverを開いている間はヘッダーの自動非表示を抑止する。閉じた時点で既存の無操作4秒を数え直す。歌詞レイヤー自体はヘッダーの自動非表示に連動させない。

曲変更時はpopoverを閉じ、未適用draftを破棄する。適用済みの本文は保存対象として維持する。音楽解析の失敗では既存の解析再試行、音声認識・照合の失敗では確定済み本文を用いた生成再試行を行えるようにする。再試行のために本文を変える必要はない。

## 20. 状態と非同期処理

PlayerStoreへ、本文、タイムライン、タイミング状態、生成エラー、保存エラー、歌詞用再描画revisionと `applyLyrics(_:)`、`clearLyrics()` を追加する。

保存・hash計算は `LyricStore` actor、Appleのファイル認識は `AppleLyricTranscriber`、認識tokenと本文の照合はSendable値を入力とする純粋な `LyricAligner`、表示と現在曲への反映はMainActor上のPlayerStoreが担当する。ファイル読込・認識・DPをMainActorで行わない。認識依存は `LyricTranscribing` で注入できるようにし、遷移テストでは実モデルのダウンロードや音声認識を実行しない。

曲選択成功・自動曲切替・現在曲削除で `playbackGeneration` を更新する。適用・削除・再生成では `lyricRequestGeneration` を更新し、古いモデル準備・認識・照合Taskをキャンセルする。進行中のSpeechAnalyzerは `cancelAndFinishNow()` で終了させ、各工程でキャンセル状態を確認する。

生成結果を現在画面へ反映する条件は、キャンセルされていないこと、trackID、再生世代、要求世代、本文hash、音源fingerprint、analysisDigestが現在の要求と一致すること。曲IDだけで判定しない。

確定本文の保存要求は別管理とする。適用時の音源URL・本文・本文hash・その音源の保存要求世代を捕捉し、曲変更後もhash取得と本文保存を完了させる。現在曲と違うという理由で保存をキャンセルしない。同じ音源への新しい適用または削除によってだけ、旧保存要求を無効にする。

fingerprint確定前は標準化した元のURLごとに保存要求世代を管理する。fingerprint確定後は保存先fingerprintへ要求をまとめ、同一内容の別URLからの要求が競合した場合も適用順に付けた単調増加の要求番号が大きいものを優先する。曲IDとURLは保存結果の正しさを保証する代わりに使わず、保存先は必ず全バイトSHA256で決める。保存結果の現在画面への通知だけは再生世代で照合する。

## 21. ローカル保存と解析待ち

保存先は `~/Library/Application Support/com.hazimeno.MusicPrayer/Lyrics/<audioFingerprint>.json`。音源を変更せず、別の専用保存領域を使う。書込はatomicとする。

解析完成前でも歌詞本文を保存できるよう、既存の `MusicAnalyzer.fingerprint(_:)` の可視性を `private static` からモジュール内部の `static` へ変更する。既存の64KiB単位SHA256計算をMainActor外から再利用し、同じhash処理を別ファイルへ複製しない。加えて、全4楽器の検出範囲を変換・保存し、解析キャッシュをversion 3へ更新する。解析対象は既存の全6種類を維持する。旧キャッシュを一括削除せず、選択曲の解析とキュー内の先行解析という既存経路で取得する。

曲選択時に音源fingerprintを取得し、保存済み本文を復元する。解析が先に完成した場合はそのfingerprintを利用できる。hash取得中に適用した本文は元の音源への確定保存要求として保持し、hash取得後に先に本文を保存する。解析待ちでも `SavedLyrics.timeline = nil` で保存する。

適用直後には本文の保存をキューへ入れ、解析が利用可能ならタイミング生成も開始する。保存の失敗は生成の失敗と分け、生成結果はその実行中に表示できる。保存失敗は状態欄で明示する。hash取得不能・音源と解析のfingerprint不一致では生成を止める。

通常終了では、AppDelegateの `applicationShouldTerminate(_:)` が、進行中の保存・削除要求、または失敗済みで未保存の確定本文・未反映の削除要求を検出したら `.terminateLater` を返す。新しい歌詞要求の受付を止め、本文のためのhash取得・書込・削除要求だけを完了まで待ち、`reply(toApplicationShouldTerminate:)` を呼ぶ。すでに失敗した要求については、その終了試行で1回だけ再試行する。音楽解析・モデル準備・音声認識・DPの完了は待たない。`applicationWillTerminate` は既存の後片付けに使い、非同期保存の待機には使わない。

すべての保存処理が成功した場合は終了を許可する。保存失敗で未保存本文または未反映の削除要求が残る場合は待機を終了して終了をキャンセルし、歌詞状態欄に保存失敗を示す。終了をキャンセルしたら歌詞要求の受付を再開する。現在曲以外の失敗も、対象曲名を付けてこの状態欄で知らせる。失敗を隠したまま終了を許可したり、永続的に待機したりしない。強制終了・電源断前の保存完了は保証しない。

有効性判定には、schemaVersion、音源fingerprint、analysisVersion、alignmentVersion、sourceTextHash、analysisDigestを含める。本文hashは保存したsourceTextのUTF-8バイト列からSHA256を計算する。

analysisDigestは、全MusicAnalysis（version、fingerprint、duration、3階層、拍・小節・BPM、全4楽器のranges・activity、Pace、Key、全Loudness）を `JSONEncoder.outputFormatting = [.sortedKeys]` でエンコードしたバイト列のSHA256とする。生成と復元で同じ入力を使い、表示枠と全補助情報が現在の解析から再構成した内容と一致するか確認する。

解析到着時、保存済みタイムラインがすべてのキーと最終結果検査を満たせば使用する。それ以外は本文を保持して再生成する。データが壊れて本文を復元できなければ、保存データを読めなかった状態を表示し、黙って歌詞未設定と扱わない。

clearLyricsは、生成・保存の要求世代を更新して古い要求を無効にしてからファイルを削除する。hash取得中でも、元の音源の削除要求をキューに残し、旧本文が後から保存されないようにする。削除に失敗した場合は保存エラーを表示し、再起動で復元される可能性を隠さない。保存・削除の失敗後は状態欄に「保存を再試行」を表示し、確定済み本文または削除要求だけを再試行できるようにする。

## 22. 変更ファイルと責務

| ファイル | 内容 |
| --- | --- |
| `Sources/Lyrics/LyricModels.swift` | 歌詞、タイムライン、保存モデル、状態・エラー型 |
| `Sources/Lyrics/LyricParser.swift` | 本文保持、行と段落、Character重み |
| `Sources/Lyrics/AppleLyricTranscriber.swift` | 言語判定、Appleモデル準備、ファイル認識、時刻付きtoken、取消 |
| `Sources/Lyrics/LyricAligner.swift` | 正規化、文字照合候補、順序・非重複の全体DP、原文への文字時刻の対応、失敗、整合度 |
| `Sources/Lyrics/LyricMusicContext.swift` | 3階層の表示枠、全解析の補助確認、行との関連付け、先頭の色開始の補助確認 |
| `Sources/Lyrics/LyricStore.swift` | SHA256呼出、保存・復元・削除・要求世代 |
| `Sources/Lyrics/LyricMotionView.swift` | snapshot同期、文字時刻を使うTextRenderer、固定スタイル |
| `Sources/Lyrics/LyricEditorView.swift` | draft、状態欄、適用、保存・解析・生成の再試行 |
| `Sources/App/PlayerStore.swift` | 現在曲、要求と再生世代、認識・照合Task、解析完成の接続 |
| `Sources/Views/PlayerView.swift` | ヘッダーボタン、popover、レイヤー、非表示条件 |
| `Sources/Models/MusicModels.swift` | LyricPlaybackFrameとVisualFrameの歌詞payload |
| `Sources/Analysis/MusicAnalyzer.swift` | fingerprint既存関数の内部公開、全4楽器のranges保持 |
| `Sources/App/MusicPrayerApp.swift` | 保存完了を待つ通常終了処理の接続 |
| `Tests/LyricParserTests.swift` | 入力保持とUnicode重み |
| `Tests/LyricAlignerTests.swift` | 合成認識tokenでの未掲載ボーカル、繰り返し、曖昧、全行失敗、再現性 |
| `Tests/LyricMusicContextTests.swift` | 複数行と枠の対応、枠跨ぎ、全解析の補助、欠測と曖昧判定 |
| `Tests/LyricMotionTests.swift` | 組版・長行・クロスフェード・停止中の実描画 |
| `Tests/LyricStoreTests.swift` | 保存・失効・破損・古い要求の棄却 |
| `Tests/PlayerStoreTransitionTests.swift` | 曲切替、同曲再選択、シーク、停止の歌詞同期 |
| `FOR[hazimeno_ipoo].md` | 実装した構成、採用理由、落とし穴、検証結果 |

SwiftPMの既存Sources配下の自動検出を使う。AppleのSpeech・NaturalLanguage・AVFoundationを使用し、歌詞用の外部依存やMetalリソースを追加しない。MetalRenderer、MetalVisualizerView、Metal shaders、音声エンジン、既存のTimelineSamplerは変更対象に含めない。

## 23. 検証と完了条件

### 自動検証

1. LF／CRLF、空行、繰り返し、日本語、結合文字、絵文字、句読点だけの行で、本文と順序を保持する。
2. 歌詞にない冒頭・途中・末尾の認識tokenを見送り、入力行だけに対応する時刻を生成する。
3. 誤記・脱落・余分な文字、同文の繰り返し、複数候補を持つケースで全体の順序を守る。曖昧な候補や未照合行を成功にしない。
4. 句読点だけの非空行、認識語なし、不正時刻、曲外時刻、区間重複、全行経路なしで、本文を保持した全体失敗になる。
5. 全行について曲内、正の時間、順序、非重複、本文一致を検査する。同じ認識tokenと全Music Understanding解析からID・時刻・confidenceを含む同一値を生成する。
6. 保存の全キー、旧alignmentVersion 1〜4の失効、文字時刻の数・範囲・順序、使用する解析の有効性変化、壊れたJSON、保存失敗、削除と古いTaskの競合を検査する。
7. 曲切替フェード中と同曲再選択でも現在曲payloadを使用し、旧曲の認識・照合Taskと進捗更新を棄却する。停止中のシーク・プレビューでも再描画される。
8. 注入した認識処理で、モデル準備・認識・照合の状態、認識失敗、取消、再試行を検査する。通常終了は本文保存だけを待ち、認識完了を待たない。
9. 同一フレーズ内の複数行切替、全交差枠への関連付け、枠跨ぎの継続、全6解析の補助情報とdigest、表示枠の欠測・不整合、文字対応の曖昧判定を検査する。
10. 共有token、原文のUnicodeと欠字、先頭の長い認識区間と歌声・音量の確認、文字間の待機、停止中のシークを検査する。実際のSwiftUI描画でも、行時刻だけ進めても色開始前は白のままで、文字時刻を越えると色が変わることを確認する。

### 実曲・実画面の受入確認

既存の保存済み解析6件は信号の観測資料として扱う。歌詞本文と正解時刻を照合していないため、タイミング精度の合格資料には使用しない。

実曲の歌詞と耳で確認した各行の開始・終了を比較する。確認する楽曲条件は、イントロ・間奏を持つ通常歌唱、速い歌唱、長い音の伸ばし、同文の繰り返し、弱い歌声、インスト、歌詞にない冒頭・途中のボーカルやコーラス、認識誤記・脱落を含む場合。各条件を検証曲が実際に持つことを確認し、曲数だけで網羅と扱わない。

境界誤差、取り違えた行、認識語の誤記・脱落、照合候補の過不足、曖昧な対応、生成失敗を記録する。開始・終了の絶対誤差について、曲ごとの中央値、90パーセンタイル、最大値と比較した行数を報告する。V1では実発音への数値精度保証を設けないことを仕様として確定し、これらの誤差を測定前の保証値へ置き換えない。

機能の合否は次の完了条件で判定する。実曲のタイミング品質は測定値と取り違えの内容を併記し、「正確な自動同期」として完了報告しない。観測できなかった曲・条件は未確認とする。音声認識や本文照合が成立せず生成不能になる場合も結果として報告し、均等配置や旧信号方式への切替で検証を通さない。

実画面では、長い歌詞の折返し、クロスフェード、水面のクリック・ドラッグ、プレイヤー操作、popoverを開いたままの再生、4秒自動非表示、停止中のシーク・プレビュー、全画面、既存の各ビジュアライザーで確認する。

再生中の歌詞表示で更新頻度と負荷を測定する。一時停止後、プレビュー等の操作がない場合に歌詞の定期更新が止まることを確認する。コード上の60fps要求やビルド成功だけで実描画の合格としない。

### V1の機能完了条件

- タイムコードなしの全文を入力でき、非空行の本文と順序を保持する。
- Apple公式の認識結果と全体DP照合から全行の推定時刻を生成するか、理由を示して全体失敗する。
- 正の行時間、曲長以内、順序、非重複、決定的なID・時刻を保証する。
- 歌詞にない音源tokenを見送り、入力順序に対応する認識区間を採用する。区間内の全時間が実発音であるとは保証しない。
- シーク・停止・一時停止・リピート・曲変更・プレビューで正しい現在曲と時刻へ追従する。
- 既存の音声、Metal、水面操作、UI、約10Hzのposition更新を保持する。
- 保存と再生成のキーが働き、本文が解析待ち・生成失敗でも保存される。
- Whisper等の外部ライブラリー・自前AIモデルを追加しない。Appleモデルの準備通信と端末内認識を使用し、音源のアップロード・マイク録音を行わない。
- 自動検証と実画面確認を完了し、実曲のタイミング品質は測定結果と受入状態を別に報告する。

## 24. 改訂の根拠と現在の受入状態

旧alignmentVersion 1は、音楽のvocal活動量とphrase等の境界に歌詞行を割り当てていた。歌詞にないボーカルも歌唱支持時間と見送りコストへ含まれるため、本文の最初の行を早い時刻へ割り当てるケースを確認した。語句の対応を認識しない以上、閾値調整や全行の一律シフトだけでは途中の未掲載ボーカルを識別できない。

ユーザーは「ありがとうを歌にのせて」の最初の行が概算20秒から始まり、0〜20秒は入力歌詞にないボーカル部分であると回答した。旧保存結果の最初の行は0.77秒だった。

2026-10-02、このMacで `SpeechTranscriber.isAvailable == true`、日本語 `ja_JP` への対応を確認した。`AssetInventory` でAppleモデルを準備し、320.8秒の同曲を認識した試行では、4.26秒で628件の時刻付きrunを取得した。最初の「朝日が差し込む 窓の向こう」に対応する認識区間は20.88〜24.36秒だった。これは認識出力の観測結果であり、行照合後の最終画面や全文の境界精度の合格を示すものではない。

入力は64行、照合用の正規化文字数は638、認識側は633。単純な文字列順序比較による一致は94.9%だった。この値は認識品質の参考であり、各行の開始・終了の正確さ、全64行の正しい照合、文字の発音時刻の一致率ではない。1行目のユーザー回答は概算時刻なので、0.88秒を測定済みの正確な境界誤差として扱わない。

初回修正では、Apple公式Speechの利用、未掲載tokenの見送り、全行照合と曖昧時の失敗、Music Understandingとの近傍補正、alignmentVersion 2での再生成へ変更した。原文・描画・保存要求・操作・アプリ構造は保持した。

同曲の64行すべてを照合し、最終的な1行目は20.517851071452284〜24.36秒となった。音声認識の開始20.88秒に対し、Music Understandingの近いphrase開始とvocal立上りを使った補正である。全体では25行の25境界が補正され、最大移動は0.49625850340135秒だった。全行の最小時間・曲内・非重複・本文保持を検査した。更新したアプリが保存した64行の結果は実曲検証の出力と一致し、保存本文のSHA256は改訂前と同じだった。ユーザーの約20秒は概算なので、約0.52秒の差を正解境界からの測定誤差とは扱わない。

関連68件（本文6、照合19、音楽補正12、保存9、描画8、PlayerStore統合14）と一時的な実曲検証1件が成功した。最終版のビルド・起動・署名検査も成功した。既存の音楽解析キャッシュ8件は改訂前と同じバイト列だった。

実画面では15秒と20秒に歌詞がなく、20秒からの再生で最初の行が出ること、停止中の21秒へのシークで同じ行を表示すること、リボンとカセットで表示することを確認した。確認後は同曲の21秒・カセット・一時停止へ置き、音量と出力先を保持した。画面取得でScreenCaptureKit -3812が一時発生したが、接続を作り直して上記確認を完了した。

続いてalignmentVersion 3で、大・小区間とPaceによる第12節の補助点を追加した。関連81件（本文6、照合19、音楽補正12、音楽補助点13、保存9、描画8、PlayerStore統合14）と一時的な実曲比較1件が成功した。同じ628件の認識tokenで3項目あり／なしを比較すると、64行すべての開始・終了は同じだった。保存済みversion 2との比較も変更0行で、1行目の20.517851071452284〜24.36秒を維持した。この曲で時刻精度が上がったという結果ではない。

更新版のビルド・起動・署名検査が成功し、アプリが再生成して保存したversion 3の64行は実曲比較の出力と一致した。保存本文のSHA256と既存の音楽解析キャッシュ8件のバイト列を保持した。実画面の2秒では歌詞がなく、停止中の21秒へのシークでは1行目を表示した。確認後は同曲の2秒付近・カセット・解析パネルを開いた一時停止状態へ戻し、音量と出力先を保持した。

全文の正解時刻との境界誤差分布、他の曲・言語・認識不能条件の実音源検証、実描画の継続更新頻度と負荷、第23節の実画面条件すべての受入は未確認である。本追加の実装・関連検証と、V1全条件の受入完了を区別する。

### 2026-10-03：構造を表示枠にするversion 4の実装結果

承認された方式へ変更した。構造の3階層で表示枠を作り、Apple Speechと本文で対応する行を選ぶ。その他の全解析は各枠の補助情報と保存結果の整合確認へ使う。行の認識時刻を固定幅で動かす処理と音楽の重み付き採点は除去した。個別行の表示、フレーズをまたぐ同じ行の継続、既存の出現・消失、本文保存と再試行を保持した。

共通のMusicAnalysis保存モデルも変更したため全体テストを実行し、122件・失敗0件だった。保存済みの同曲の認識結果で実装を通す一時検証も成功し、320.8秒・64行・65表示枠・289通りの表示状態で行の欠落0、同時表示最大2行、歌唱中扱い最大1行を確認した。全64行の開始・終了は認識との本文照合で選んだ時刻のままで、音楽による時刻補正は0件だった。

更新アプリが取得・保存した実際のversion 3の音楽解析とversion 4の歌詞でも、一時検証1件が成功した。最新解析の小区間は31件（以前のキャッシュは32件）、フレーズは65件である。最新版の全曲1,221か所で構造枠による表示と個別行による表示を比較し、相違・欠落0、最大2行を確認した。2秒・20秒では空、21秒では1行目となる。本文と64行の行時刻は保存済み認識結果の検証と一致し、1行目は20.88〜24.36秒、最後の行は299.82〜307.02秒である。

音楽解析キャッシュは既存の選択曲解析とキュー内の先行解析によって4件がversion 3へ更新され、キュー外の4件は同じバイト列だった。本文、キューの選択曲・再生位置186.69815970515972秒・音量を保持した。音源、再生・描画エンジン、プレイヤー画面、Apple認識処理と外部依存は本修正で変更していない。

ビルド・起動・署名検査が成功した。MusicPrayerを明示的に前面へ出した後、3:06の歌詞表示「ありがとう 今日という日よ」と既存操作画面を取得した。続く実画面でのシーク切替は取得APIの-3812で未確認であり、上記の全曲自動検証と区別する。全文の実発音への一致やV1全条件の受入完了を、この結果から主張しない。

結果とログは `lyric-structure-implementation/validation.json`、`whole-song-test.log`、`actual-app-test.log`、`full-test.log`、`build-run.log` に保存した（今回の検証用出力フォルダ内）。一時検証ソースと作業用の控えは削除した。

### 2026-10-03：文字の青色進行を接続するversion 5の実装結果

変更前は、行の開始から終了までを文字数で配分して青色を進めていた。version 5では、選択済み認識区間を原文のCharacterへ対応付けて保存し、描画へ渡した。文字間の待機と、長い先頭区間の歌声・瞬間音量による補助確認を含む。行時刻・表示枠・本文・既存フェードと縦送りは保持した。

歌詞とPlayerStoreの関連67件、および保存済みの同じ628tokenと全Music Understanding解析を使った全曲比較1件、計68件が成功した。「ありがとうを歌にのせて」の64行の本文・開始・終了と65個の表示枠は変更前と完全に同じで、678個の原文Characterに有効な色時刻がある。長い先頭区間の色開始だけを見直した行は21行である。各文字の開始前に強調0、終了時に強調1となり、最後の行の「て」と「あ」の間でも次の文字を青くしないことを確認した。SwiftUIの実際のオフスクリーン描画でも、認識区間前は白を保ち、区間内で色が変わり、シークで白へ戻ることを確認した。

| 対象行 | 行の表示開始（保持） | 先頭文字の色開始 | 先頭文字の色完了 |
|---|---:|---:|---:|
| 雨の日も風の日も | 161.82秒 | 164.100秒 | 164.70秒 |
| 空に響け このメロディー | 201.18秒 | 202.900秒 | 203.46秒 |
| ありがとう 君に伝えたい | 283.26秒 | 285.043秒 | 285.30秒 |
| 感謝を込めて ありがとう | 299.82秒 | 301.693秒 | 302.16秒 |

ビルド・起動・署名検査が成功した。更新アプリで対象曲を選択し、保存済み本文からversion 5が生成された。実際の保存結果は全曲比較の結果と同じで、本文、全行時刻、全構造枠を保持している。音楽解析キャッシュ8件は同じバイト列、曲一覧と音量も同じである。画面確認のため選択曲を対象曲へ変更し、一時停止の20.897秒にしている。

ウィンドウのRaiseで前面へ出した画面と、停止中の先頭行の白色表示を取得した。続く4か所の画面確認はScreenCaptureKitの-3812で止まり、画面接続の再初期化後も取得できなかった。4か所の実画面・耳での確認は未確認である。全曲のデータ検証、オフスクリーン描画、実画面の確認範囲を区別し、実発音との完全一致は主張しない。

結果とログは今回の検証出力フォルダの `lyric-colour-timing/validation.json`、`related-test.log`、`build.log`、`song-v5.json`、`actual-app-saved-v5.json` に保存した。一時検証ソースと作業用の控えは削除した。

## 25. 歌詞位置固定と解析パネルの表示修正（2026-10-03）

画像2の位置を基準とし、歌詞の中心をPlayerViewの横中央・高さの24%に固定した。下部UIの測定値を歌詞位置へ使わず、解析パネルの開閉で歌詞とウィンドウの最小高さを変えない。

解析パネルは保存済みMusicAnalysisの全結果を表示する。18行は構造3階層、拍、小節、活動量、全4楽器の活動グラフと検出区間、調性区間、瞬間音量、3秒音量、ピーク位置。BPM、全曲平均音量、ピーク値と時刻は固定の下部欄へ表示する。ピークはdB、音量3種類はLUFS。保存用のversion・fingerprintと、調性ラベルから派生するhue・minorは内部識別・映像用の値として扱う。

すべての測定点を間引かず、1秒40ptの共通時間軸に描く。Apple標準のScrollViewとScrollPositionで再生・シーク位置を追う。項目名と現在値は固定し、グラフと区間をまとめて横へ移動する。停止中に手動で横へ移動した位置は再生再開・シーク・幅変更まで保持する。縦スクロールで全18行を確認する。取得していない活動量区間を線で埋めない。

関連35種類のテストが成功した。全6,416点の頂点保持と短い変化の実画像、全結果の行への引渡し、欠測、曲頭・曲末、前後シーク、実際のNSScrollViewによる再生追従と停止中の手動位置保持を確認した。歌詞のオフスクリーン描画は高さ660・850・1,000ptでパネル開閉時の画素位置が同じだった。ビルド・アプリ起動・署名検査も成功した。

前面へ出した更新アプリの同じ2:14位置で、パネル開閉の実画面を取得した。歌詞を含む同じ矩形の画像比較は相違0画素だった。18項目と現在値・BPM・全曲平均音量・ピークの表示は実アプリのアクセシビリティツリーでも確認した。追加のスクロール・再生操作に進む前に取得APIの-3812が再発し、接続再初期化後も継続した。再生中の実画面による追従と下端までの操作確認は未確認である。

今回の変更は表示ソース3件、対応テスト2件、仕様書と説明書の計7件。照合version 5の生成・色時刻・音声・Metalは変更していない。音楽解析キャッシュ8件と歌詞保存1件はバイト一致、キュー・曲位置134.2414564905815秒・音量も保持した。結果と画像は検証出力フォルダの `analysis-scroll-and-lyric-position` に保存した。

## 26. 一次資料

- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [audioTimeRange：認識文字列の音源時刻属性](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption/audiotimerange)
- [AssetInventory：Appleモデルの準備・管理](https://developer.apple.com/documentation/speech/assetinventory)
- [downloadAndInstall()：初回試行の終了と後続再試行](https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall())
- [音声認識の許可：旧SFSpeechRecognizerへの適用範囲](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
- [contextualStrings：DictationTranscriberへの短い語句の認識補助](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)
- [NLLanguageRecognizer](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer)
- [Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Music Understanding](https://developer.apple.com/documentation/musicunderstanding)
- [InstrumentActivityResult：activityは0〜1、rangesは検出時間窓](https://developer.apple.com/documentation/musicunderstanding/instrumentactivityresult)
- [Meet the Music Understanding framework：音楽構造の階層](https://developer.apple.com/videos/play/wwdc2026/253/)
- [TimelineView：スケジュールより低い更新頻度になる場合がある](https://developer.apple.com/documentation/swiftui/timelineview)
- [AnimationTimelineSchedule](https://developer.apple.com/documentation/swiftui/animationtimelineschedule)
- [TextRenderer](https://developer.apple.com/documentation/swiftui/textrenderer)
- [Text.Layout.CharacterIndex](https://developer.apple.com/documentation/swiftui/text/layout/characterindex)
- [applicationShouldTerminate(_:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:))
- [ScrollPosition：位置を指定して標準ScrollViewを動かす](https://developer.apple.com/documentation/swiftui/scrollposition)
- [LoudnessResult.peak：ピーク値の単位はdB](https://developer.apple.com/documentation/musicunderstanding/loudnessresult/peak)

以上のAPI仕様は2026-10-02の公式資料とmacOS 27 SDKで確認したもの。照合の判定・採点・表示寸法はこのV1で採用する設計値であり、Appleが歌詞同期を保証する仕様ではない。


## 27. 音量とピークの表示修正（2026-10-03）

解析結果の表示を「構造・楽器」と「音量・ピーク」へ分ける。前者は構造・拍・小節・活動量・楽器活動と検出区間・調性の15行。後者は瞬間音量と3秒音量を上下の独立したグラフにする。BPMとIntegratedは固定の下部欄に表示する。従来の18行の結果を削除する変更ではなく、音量2種類とピークの表示場所を分ける変更である。

MomentaryとShort-termの測定値は解析から得た全点を使用する。それぞれの縦の目盛りだけを現在表示中の区間へ合わせ、測定値・測定時刻は変更しない。画面外の値で線を下端へ潰さず、元の座標をグラフの矩形で切る。現在値には再生位置以前の最新の実測値と時刻を使用し、TimelineSamplerの補間値へ置き換えない。横軸は従来の1秒40ptを維持し、再生・シークに追従する。小さい画面の目盛り文字は重ねず、全測定点を間引かない。解析パネルは280〜400pt、窓の最小高さは800pt。歌詞の位置は開閉で動かさない。

Peakは最終解析結果の単一の値と時刻をそのまま使用する。「ピーク振幅 x dB」「解析結果の時刻 m:ss.s」を固定欄へ表示し、付属時刻を別の1点の行へ描く。曲末の点も切れないよう時間軸の右に8ptの余白を設ける。LUFSの極大や音源から独自に計算した振幅を解析結果として表示しない。保存済み8曲では付属時刻が曲末と同じであり、実際の発生時刻とは断定しない。

公式loudnessResultsは解析中のLoudnessResultを約100msごとに返し、各結果にpeakも含まれる。逐次値の追加収集は可能だが、区間最大か累積最大かは公開資料で確定していない。最終結果の1点から連続するピークの波形を作らない。本変更は保存済み解析の表示を直し、再解析・歌詞の再生成は行わない。

一次資料：[LoudnessResult](https://developer.apple.com/documentation/musicunderstanding/loudnessresult)、[peak](https://developer.apple.com/documentation/musicunderstanding/loudnessresult/peak)、[TimedValue.time](https://developer.apple.com/documentation/musicunderstanding/musicunderstandingsession/timedvalue/time)、[loudnessResults](https://developer.apple.com/documentation/musicunderstanding/musicunderstandingsession/loudnessresults)、[Apple公式サンプル](https://developer.apple.com/documentation/musicunderstanding/create-visuals-using-musicunderstanding-analysis-results)。

検証：グラフ・スクロールの関連テスト9件、保存済み解析を使う一時描画確認1件、歌詞位置の単独確認1件が成功。ビルドと署名検査も成功した。保存済み解析8件と歌詞1件は作業前と同一。上下別グラフの最終アプリの実画面確認は、画面取得APIが「Mac is locked」と返したため未完了。オフスクリーン描画は実画面の色・ガラス効果の確認を代替しない。

## 28. 拍・小節と活動量・楽器の表示修正（2026-10-03）

解析パネルを「構造・区間」「活動量・楽器」「音量・ピーク」の3項目へ分ける。構造・区間は9行で、構造3階層、統合した拍・小節、4楽器の検出区間、調性を表示する。拍は白い短線、小節の先頭は青い太線と小節番号で同じ行へ描く。`beats`と`bars`の元の時刻をそのまま使い、4拍ごとの推定や時刻の移動を行わない。

活動量・楽器は5つの独立したグラフとする。各80〜120ptの高さ、項目名・現在値・縦目盛りは横スクロールで動かさず、共通の横軸は1秒40pt。5種類は標準の縦スクロールで閲覧でき、上部の時刻軸は縦スクロールしても表示を保つ。再生・シーク・幅変更・曲変更・項目表示時に横軸が追従する。停止中の手動横位置は保持する。元の全測定点・全区間を使う。

活動量（pace）は回/分（events/min）で、楽曲の感じる速さを表す。元の区間ごとの値を水平線で描き、時刻が連続する区間の境界だけを縦の段差で結ぶ。欠測は結ばない。縦目盛りは表示範囲と重なる解析区間の最小・最大に合わせ、一定値でも読める幅を保つ。0始まりや最低上限200を強制しない。現在値は小数2桁と適用区間の開始〜終了を表示する。楽器4種類は活動強度0〜1の固定目盛りを保つ。現在値は補間した数値から、直前の実測サンプルとその時刻へ変更し、音量比に見える％表記を「値 / 1」へ置き換える。

音量・ピーク、プレイヤーの寸法、歌詞位置、音声解析と歌詞生成、保存モデル・解析キャッシュ・ビジュアライザーの計算は変更しない。共通の実測サンプル取得を`AnalysisTimelineRow.sample`へ置く。

一次資料：[RhythmResult](https://developer.apple.com/documentation/musicunderstanding/rhythmresult)、[InstrumentActivityResult](https://developer.apple.com/documentation/musicunderstanding/instrumentactivityresult)、[PaceResult](https://developer.apple.com/documentation/musicunderstanding/paceresult)、[WWDC26の公式説明](https://developer.apple.com/videos/play/wwdc2026/253/)。

検証：関連14件が成功（構造・音量8件、活動量・楽器5件、歌詞位置維持1件）。原値・全点保持、0〜1の強度、表示範囲に合わせる活動量の尺度、一定値・空範囲・段差・欠測、原時刻の拍と小節、標準スクロールの再生・シーク・停止・幅変更・曲変更を確認した。実アプリ「ゼロ秒の残響」では79.63339583333334秒の36.28→36.99が読める段差になること、全5グラフの縦閲覧、固定時刻軸、停止中の手動位置保持と前後シークへの追従、既存の独立した音量グラフを確認した。一定の40.71627083333333〜79.63339583333334秒へ架空の凹凸を追加しない。ビルド・署名検証が成功し、保存済み解析8件・歌詞1件は変更前と同じバイト列を保持した。
