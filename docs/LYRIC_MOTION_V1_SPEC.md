# MusicPrayer リリックモーショングラフィックス V1

実装仕様・技術仕様／2026-10-02

状態：仕様書完成、アプリへの実装は未着手。

## 1. 目的と適用範囲

ユーザーがタイムコードのない歌詞全文を入力すると、既存の音楽解析と歌詞各行の長さから表示時刻を推定する。生成した時刻に従い、Metalビジュアライザーの上へSwiftUIの文字モーションを表示する。

本機能は「推定した歌詞表示時刻」を生成する。音声と歌詞本文の対応を認識する機能ではない。各行の実際の歌唱時刻との一致、単語・文字の発音時刻は保証しない。入力順序、本文の保持、時刻の範囲、生成の再現性は実装で保証する。

調査の基準はコミット済み `master` の `f002968355572bb09d7705c3ae62ad528bb2d568`。対象環境は既存プロジェクトと同じmacOS 27以降。調査時の作業ツリーには未コミットのカセット表示関連変更がある。実装時は、それらの変更を保持して接続し、コミット済み版へ巻き戻さない。

## 2. V1で実装すること

- ヘッダーの「歌詞」ボタンと、歌詞編集用popover。
- 非空行をそのまま保持する歌詞パーサー。
- 既存解析からの歌唱候補抽出と、DPによる歌詞行の順序を守った時刻推定。
- 行単位・文字単位の決定的なモーションを持つ1種類の表示スタイル。
- 歌詞本文と有効な生成結果のローカル保存・復元。
- 解析待ち、生成中、通常生成、歌唱情報なしでの生成、生成失敗、保存失敗の状態表示。
- シーク、プレビュー、一時停止、停止、リピート、曲変更への追従。

## 3. V1の対象外

歌詞検索、自動取得、音声認識、Whisperなどの追加AIモデル、歌詞本文の修正、入力行の分割・結合・並べ替え、手動タイムコード編集、Metal内の文字描画、複数の演出スタイルは実装しない。歌詞処理のためのネットワーク通信は行わない。

## 4. 保持する既存動作

音声再生、音量・ミュート、出力先、曲一覧、解析パネル、ギャップレス再生、ビジュアライザー選択、Metalの描画・水面操作・カメラ・曲間フェードを保持する。

`PlayerStore.position` の通常更新は約10Hzのままにする。歌詞のためにPlayerStore全体を60Hz更新へ変更しない。既存の `VisualFrameSource.observeFrames` は単一の通知先を持つため、歌詞ビューから登録してMetal側の通知を置き換えない。

## 5. 歌詞入力と文字の定義

`sourceText` はユーザーが適用した文字列をそのまま保存する。解析用の行分解ではCRLFを1改行として扱い、LFとCRも改行として扱う。保存する本文には改行コードの変換を加えない。

空白文字だけの行は空行とする。それ以外の非空行1行を1つの `LyricLine` とする。行の先頭・末尾の空白、句読点、表記は保持する。同じ本文の行も非空行順の番号によって区別する。

連続する空行は1つの段落境界ヒントへまとめる。空行は表示行へ含めず、段落境界ヒントはsection境界または歌唱停止の近くへ行の切替を置く採点にだけ使用する。

`textWeight` はSwiftの `Character`、すなわち結合文字や絵文字のまとまりを含む見た目の文字単位で数える。空白・句読点・制御文字・書式制御だけで構成されるCharacterは0、それ以外は1とする。判定にはUnicode scalarの分類を使用するが、加算はCharacterごとに1回だけ行う。

例：`君の声` は3、`遠い夜の向こうから` は9。句読点だけの非空行も削除せず、`textWeight = 0` のまま保持する。時刻推定に使う有効重みは `max(1, textWeight)` とする。本文は変更しない。

歌詞表示での折返しはレイアウト処理であり、LyricLineの追加・分割ではない。

## 6. データモデル

```swift
enum LyricAlignmentMode: String, Codable, Sendable {
    case vocalAndPhrases
    case vocalOnly
    case phrasesOnly
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
}

struct LyricTimeline: Codable, Sendable {
    var version: Int                  // alignmentVersion
    var analysisVersion: Int
    var analysisFingerprint: String   // 既存の音源全バイトSHA256
    var analysisDigest: String        // 推定に使用した解析データのSHA256
    var sourceText: String
    var sourceTextHash: String
    var mode: LyricAlignmentMode
    var lines: [TimedLyricLine]
    var confidence: Float
}

struct SavedLyrics: Codable, Sendable {
    var schemaVersion: Int
    var audioFingerprint: String
    var sourceText: String
    var sourceTextHash: String
    var timeline: LyricTimeline?       // 解析待ち・生成失敗でも本文は保存する
}
```

`schemaVersion = 1`、`alignmentVersion = 1` を初期値とする。採点、判定値、文字数計算、境界丸めの変更はalignmentVersionを上げる。

行IDは音源fingerprint、alignmentVersion、本文hash、ordinalを、各要素のUTF-8バイト長を付けた固定順のバイト列としてSHA256にする。`UUID()`、Swiftの `Hasher`、ランダム値は使用しない。繰り返しの同文もordinalが異なるため別IDになる。

## 7. 使用する解析と役割

| 情報 | 役割 |
| --- | --- |
| `analysis.vocal` | 歌唱活動、開始・終了、候補の歌唱支持量 |
| `analysis.phrases` | 歌詞行の基本境界候補 |
| `analysis.segments` | 複数phraseをまとめる際の構造上の補助境界 |
| `analysis.sections` | 段落境界の補助、構造変更の採点 |
| `analysis.bars` | phrase内の分割候補 |
| `analysis.beats` | barだけでは足りない場合の分割候補 |
| 歌詞の有効重み | 相対的な行時間の基準 |

音楽構造は大きい順に `section → segment → phrase`。segmentをphraseより細かい分割単位として扱わない。各構造配列は独立して検査し、完全な包含関係があると仮定しない。

vocalは歌声の活動強度であり、歌詞、音節、主旋律だけの検出結果ではない。ハミング、コーラス等を本文に対応する歌唱から分離する機能はV1にはない。

## 8. 解析データの検査

LyricAlignerへ渡す作業用データだけを検査・整形する。既存のMusicAnalysisと解析キャッシュは書き換えない。

- durationが有限かつ正であることを必須とする。
- 非有限時刻・非有限値、曲外のサンプルを除外する。
- 時系列を時刻で安定ソートする。同時刻のvocal値は最大値へまとめる。
- vocalの有限値は0〜1へclampする。除外件数・clamp件数は内部診断へ残す。
- 範囲は曲内へ切り詰め、長さが正のものだけ使用する。同一範囲の重複を除く。
- beatsとbarsは曲内の有限時刻をソートし、重複を除く。
- vocalの観測範囲外を0や直前値で埋めない。観測欠落は歌唱停止と区別する。

vocalの正のサンプル間隔の中央値を `sampleInterval` とする。隣接間隔が `max(0.25秒, 4 × sampleInterval)` を超える部分は観測欠落とし、補間も小休止の連結も行わない。現行の保存済み6件は約0.05秒間隔だったが、固定間隔をAPIの保証として扱わない。

## 9. vocal判定とモード選択

V1では曲内最大値を1へ引き上げるmin-max正規化を行わない。APIが返す0〜1の活動強度を保持し、ヒステリシス判定する。原仕様の曲ごとの再正規化は、微弱な活動まで強い歌唱に見せるため、この方式へ変更する。

| 条件 | 結果 |
| --- | --- |
| 使用可能なvocalとphrasesがある | `vocalAndPhrases` |
| 使用可能なvocalがあり、phrasesがない | `vocalOnly` |
| vocalが欠測・検査後に使用不能で、phrasesがある | `phrasesOnly` |
| vocalもphrasesも使用不能 | 生成失敗 |
| 有効なvocal観測があるが、歌唱候補を検出できない | 生成失敗。phrasesOnlyへ自動降格しない |

有効なvocal観測には、異なる時刻の2点以上と、欠落をまたがない正の観測時間が必要。空配列や1点だけは使用不能とする。有効な全ゼロ系列は欠測ではなく「歌唱候補なし」とする。

`phrasesOnly` は音楽的な区切りに基づく表示推定であり、歌唱区間の判定はできない。popoverの状態欄に「生成済み・歌唱情報なし」と表示する。通常の再生画面には数値のconfidenceを表示しない。

## 10. V1の初期判定値

以下は実装の初期設定値であり、実曲で精度を確認した値ではない。実装時に散在した数値へせず、LyricAligner内の1つの設定に集約する。

| 項目 | 初期値 |
| --- | --- |
| 歌唱開始／終了 | 0.35以上／0.20未満 |
| 歌唱候補の最小長 | 0.30秒 |
| 連結可能な小休止 | 0.24秒以下 |
| 1行がまたげる歌唱停止の上限 | 1.50秒以下 |
| 行の最小表示区間 | 0.30秒 |
| vocalモードの行内歌唱支持時間率 | 50%以上 |
| 推定基準時間に対する許容比 | 0.25〜4.0倍 |
| phrase等へ境界を寄せる距離 | 0.08秒以内 |
| 時刻の出力精度 | 0.001秒 |

開始・終了閾値の等号は表のとおりとする。その他の上下限は境界値を含めて許容する。値を調整する際は実曲の行境界との比較を根拠にし、alignmentVersionを上げて再生成する。追加モデルや推定失敗を隠す均等配置は導入しない。

## 11. 歌唱候補の抽出

1. 観測欠落を境にvocal系列を分け、区間ごとに処理する。
2. 隣接サンプル間は線形補間する。開始・終了閾値を横切る位置を補間して求める。
3. 開始閾値で歌唱候補を開き、終了閾値で閉じる。系列末尾で活動中なら、最後の観測時刻で閉じる。曲末まで延長しない。
4. 間隔0.24秒以下の候補を連結する。観測欠落は連結しない。
5. 連結後の長さ0.30秒未満の候補を除く。連結で含めた停止部分は別に保持し、歌唱支持時間へ加算しない。

開始位置、終了位置、支持時間、元のvocal活動量の積分、内部停止を保持する。連結区間全体を実際に歌っている時間と見なさない。

## 12. 境界候補の生成

通常モードは歌唱候補の開始・終了とphraseの開始・終了を基本にする。vocalOnlyは歌唱候補を基本にする。phrasesOnlyは検査済みphraseの範囲を基本にする。

追加する境界の優先度は次のとおり。

1. 歌唱開始・終了、検出した内部停止の両端。
2. phraseの開始・終了。
3. segmentの開始・終了。ただし実際に候補内部にある場合だけ。
4. bar。
5. beat。

barsとbeatsは、歌唱候補内、またはphrasesOnlyの有効phrase内だけに追加する。歌唱開始・終了を最寄りの拍へ無条件に移動しない。

0秒と曲末を含む時系列の境界配列を作る。候補時刻は非負の秒数を整数ミリ秒へ四捨五入し、同じミリ秒の候補は優先度の高い種類を採用する。同優先度なら元の時刻が早いものを採用する。曲末の整数ミリ秒は切捨てとし、曲長を超えない。配列は昇順にする。

歌詞行は候補の連続範囲へ割り当てる。音楽側の1候補を複数行へ分けること、隣接する複数候補を1行へ割り当てることを許可する。入力の歌詞行を分割・結合する処理は行わない。

## 13. DPによる全体配置

`DP[i, e]` は「先頭からi行を配置済み、最後に配置した行の終了が境界e」の最小コストとする。初期状態は `DP[0, 0] = 0`。

次行の開始j、終了kは `e <= j < k`。遷移は、前行終了eから次行開始jまでの見送りコストと、j〜kへ次行を置くコストを同時に加えて `DP[i + 1, k]` を更新する。これにより、段落ヒントの採点に必要な前行終了を失わない。

見送りで飛ばすのは音楽区間だけ。歌詞行は飛ばさない。1行を複数の音楽候補へ割り当てる場合も、j〜kの1つの連続範囲として評価する。

全行配置後、`DP[lineCount, e] + C_skip(e, lastBoundary)` が最小の経路を選ぶ。曲末までの見送りも採点に含める。途中までの歌詞を成功結果として返さない。

### 基準時間

vocalモードは、候補内の歌唱支持時間の総和を `T` とする。phrasesOnlyは、有効phraseの和集合の長さをTとする。`W = Σ max(1, textWeight)`、各行の基準時間は `E_i = T × max(1, textWeight_i) / W` とする。

vocalモードの比較時間 `S` は割当範囲内の歌唱支持時間、phrasesOnlyのSは有効phraseとの交差時間とする。無音時間を歌唱時間へ加算しない。

### 配置の必須条件

- 開始と終了が有限、`0 <= start < end <= duration`。
- 区間長が0.30秒以上、Sが正。
- `0.25 <= S / E_i <= 4.0`。
- vocalモードでは歌唱支持時間率が50%以上。
- vocalモードでは1.50秒を超える内部歌唱停止をまたがない。
- 観測欠落をまたがない。
- phrasesOnlyでも1.50秒を超えるphrase間の空白をまたがない。これは歌唱停止の判定ではない。
- 他行と時間が重ならず、入力順序を守る。

条件を満たさない配置辺は作らない。短い行へ固定0.30秒を後付けして押し込むことや、曲長への強制的な均等配分は行わない。

### コスト

各候補は、次節の境界仕上げを先に行って最終境界indexへ対応させ、その境界で必須条件・支持時間・コストを計算してからDPへ渡す。後処理で時間が縮んでから有効な別経路を失うことを避ける。

行ごとに、`D = abs(log(S / E_i)) / log(4)` を長さの不一致とする。支持時間率を `R`、割当範囲内の支持部分における平均vocal活動量を `A` とする。RとAは0〜1。

境界コストBは、歌唱開始・終了=0、内部停止・phrase=0.10、segment=0.25、bar=0.50、beat=0.75として、開始・終了の平均を取る。phrasesOnlyではphrase境界を0とする。曲頭・曲末という管理上の境界だけの候補はB=1とする。同じ時刻に有効な音楽・歌唱境界がある場合は、その種類のコストを使う。

段落境界の不一致Pは、前行終了から次行開始までにsection境界または0.50秒以上の歌唱停止があれば0、それ以外は1。phrasesOnlyでは歌唱停止の代わりに0.50秒以上のphrase間の空白を使用する。段落開始でない行と最初の行はP=0。

```text
vocalモード：C_line = 2D + 2(1-R) + (1-A) + B + 0.5P
phrasesOnly：C_line = 2D + 2(1-R) + B + 0.5P
```

見送る音楽区間のコストは、Tに対する支持時間の割合をqとして `C_skip = 4 × lineCount × q`。支持時間がない区間は0。これは、歌唱区間を無条件に全部捨てる解を抑えるための採点であり、入力に含まれないコーラス等の正解判定ではない。

コスト比較は小数点以下6桁の整数値へ四捨五入して行う。同点は、行ごとの開始・終了境界index列が辞書順で小さい経路を選ぶ。候補順、計算順、同点規則を固定する。

任意の最大行長や固定の行数上限はV1で追加しない。上記の基準時間比から候補探索範囲を絞り、支持時間・活動量の累積積分と停止区間検索を利用する。

1行分の更新では、各開始jについて前行終了eからの最良コスト（見送りと段落コストを含む）を先に求め、その後に有効なj〜kの配置を評価する。e・j・kを毎回三重に総当たりしない。境界数M、行数Lに対し、時間O(LM²)、DPと復元情報のメモリO(LM)を上限とする。辞書順の同点比較は経路rankで行い、全履歴を毎回複製しない。DPはMainActor外で実行し、行単位でキャンセルを確認する。

## 14. 開始・終了の仕上げと生成失敗

vocalモードの各割当範囲を、最初と最後の歌唱支持位置へ切り詰める。範囲内を歌唱候補の途中で分割した境界は保持し、隣接行を同じ歌唱開始位置へ戻さない。

0.08秒以内のphraseまたはsegment境界へ寄せる場合も、歌唱支持部分を削らず、0.20未満の活動を越えて新しく延長せず、停止上限・順序・非重複を保てる位置だけ採用する。それ以外は元の歌唱境界を使う。phrasesOnlyでは割当境界をそのまま使う。

仕上げた候補の始点・終点を境界配列へ対応させ、同一の最終区間へ変換される候補は重複を除く。採点とDPにはこの最終区間を使う。DP後にも整数ミリ秒の結果で全行の必須条件と本文・行数・順序を再検査し、条件が破れた場合は生成全体を失敗させる。

失敗理由は、解析未取得、歌唱候補なし、配置可能な経路なし、最終境界不成立、保存データ不整合として区別する。本文は残す。以前の本文に対応するタイムラインや、別曲のタイムラインを代用しない。

## 15. confidenceと診断

confidenceは、採用した配置のコストを0〜1へ変換した内部用整合度である。

行confidenceは `1 / (1 + C_line)`、全体confidenceは `1 / (1 + (ΣC_line + ΣC_skip) / lineCount)`。phrasesOnlyはそれぞれ最大0.40へ制限する。

confidenceを正答確率として説明しない。confidence値だけを根拠に、必須条件を破る結果を成功へ昇格させない。通常の再生画面には表示しない。

内部診断にはモード、候補数、観測欠落、各コストの内訳、見送った支持時間率、生成・保存失敗理由を残す。歌詞全文をログへ出力しない。

## 16. 描画構造と同期用データ

```text
PlayerView の ZStack
├─ MetalVisualizerView       既存
├─ LyricMotionView           追加、allowsHitTesting(false)
└─ 既存UI                    配置を保持
```

歌詞の表示範囲は、上部ヘッダーと下部の既存操作・解析領域を避けた中央領域とする。PlayerViewが測定した空き領域から、左右24pt、上下16ptを引いた矩形を渡す。行の基準フォントはsystemのmedium、32pt、行間6pt、中央揃え。Textの組版サイズを測定し、通常は32ptから14ptの範囲で縮小して収める。長い行は表示上だけ折り返す。

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
| 行内progress | 組版した文字への強調進行 |

vocal欠測時は発光の基準値を使用し、歌唱活動をあるように補わない。文字の基本色は白、強調色は既存UIに合わせたcyanとする。

`lineProgress = clamp((time-start)/(end-start), 0, 1)`。有効な文字重みの累積位置から強調範囲を作る。空白・句読点は元の位置に描画し、追加時間を持たせない。文字数重みが0の行は行全体を同時に強調する。

これは視覚的な進行値であり、文字の発音タイムスタンプではない。単語・音節の時刻モデルは作らない。状態を積み上げるばね、ランダム値、過去のtickからの平滑化は歌詞演出へ使用しない。同じ解析・本文・再生時刻・画面サイズなら同じ表示パラメーターになる。

## 19. 歌詞編集UI

ヘッダーへ「歌詞」ボタンを1つ追加する。曲未選択時は無効にする。popoverはTextEditor、状態欄、「適用」を基本とする。

編集内容はpopover内のdraftとする。「適用」で現在曲へ確定する。適用せず閉じた変更は保存しない。空白・改行だけを適用した場合は `clearLyrics()` として保存済み歌詞を削除し、表示を消す。

状態文言は「歌詞未設定」「音源を確認中」「解析待ち」「タイミング生成中」「生成済み」「生成済み・歌唱情報なし」「タイミングを生成できませんでした」「歌詞を保存できませんでした」を基本とし、失敗時は短い理由を添える。

歌詞入力欄は生成中も編集可能。適用の連打は直前の生成をキャンセルし、最新本文だけを対象にする。popoverを開いている間はヘッダーの自動非表示を抑止する。閉じた時点で既存の無操作4秒を数え直す。歌詞レイヤー自体はヘッダーの自動非表示に連動させない。

曲変更時はpopoverを閉じ、未適用draftを破棄する。適用済みの本文は保存対象として維持する。生成失敗で解析の再試行が必要な場合は、状態欄から既存の `retryAnalysis()` を呼ぶ「解析をやり直す」を表示する。

## 20. 状態と非同期処理

PlayerStoreへ、本文、タイムライン、タイミング状態、生成エラー、保存エラー、歌詞用再描画revisionと `applyLyrics(_:)`、`clearLyrics()` を追加する。

保存・hash計算は `LyricStore` actor、時刻生成はSendable値を入力とする純粋な `LyricAligner`、表示と現在曲への反映はMainActor上のPlayerStoreが担当する。ファイル読込とDPをMainActorで行わない。

曲選択成功・自動曲切替・現在曲削除で `playbackGeneration` を更新する。適用・削除・再生成では `lyricRequestGeneration` を更新し、古いタイミング生成Taskをキャンセルする。

生成結果を現在画面へ反映する条件は、キャンセルされていないこと、trackID、再生世代、要求世代、本文hash、音源fingerprint、analysisDigestが現在の要求と一致すること。曲IDだけで判定しない。

確定本文の保存要求は別管理とする。適用時の音源URL・本文・本文hash・その音源の保存要求世代を捕捉し、曲変更後もhash取得と本文保存を完了させる。現在曲と違うという理由で保存をキャンセルしない。同じ音源への新しい適用または削除によってだけ、旧保存要求を無効にする。

fingerprint確定前は標準化した元のURLごとに保存要求世代を管理する。fingerprint確定後は保存先fingerprintへ要求をまとめ、同一内容の別URLからの要求が競合した場合も適用順に付けた単調増加の要求番号が大きいものを優先する。曲IDとURLは保存結果の正しさを保証する代わりに使わず、保存先は必ず全バイトSHA256で決める。保存結果の現在画面への通知だけは再生世代で照合する。

## 21. ローカル保存と解析待ち

保存先は `~/Library/Application Support/com.hazimeno.MusicPrayer/Lyrics/<audioFingerprint>.json`。音源を変更せず、別の専用保存領域を使う。書込はatomicとする。

解析完成前でも歌詞本文を保存できるよう、既存の `MusicAnalyzer.fingerprint(_:)` の可視性を `private static` からモジュール内部の `static` へ変更する。既存の64KiB単位SHA256計算をMainActor外から再利用し、同じhash処理を別ファイルへ複製しない。**MusicAnalyzerの変更はこのアクセス範囲だけとし、解析内容・変換・キャッシュ・結果判定を変えない。** 原仕様の「原則変更なし」に対する、この1点の例外を実装範囲に含める。

曲選択時に音源fingerprintを取得し、保存済み本文を復元する。解析が先に完成した場合はそのfingerprintを利用できる。hash取得中に適用した本文は元の音源への確定保存要求として保持し、hash取得後に先に本文を保存する。解析待ちでも `SavedLyrics.timeline = nil` で保存する。

適用直後には本文の保存をキューへ入れ、解析が利用可能ならタイミング生成も開始する。保存の失敗は生成の失敗と分け、生成結果はその実行中に表示できる。保存失敗は状態欄で明示する。hash取得不能・音源と解析のfingerprint不一致では生成を止める。

通常終了では、AppDelegateの `applicationShouldTerminate(_:)` が、進行中の保存・削除要求、または失敗済みで未保存の確定本文・未反映の削除要求を検出したら `.terminateLater` を返す。新しい歌詞要求の受付を止め、本文のためのhash取得・書込・削除要求だけを完了まで待ち、`reply(toApplicationShouldTerminate:)` を呼ぶ。すでに失敗した要求については、その終了試行で1回だけ再試行する。解析やDPの完了は待たない。`applicationWillTerminate` は既存の後片付けに使い、非同期保存の待機には使わない。

すべての保存処理が成功した場合は終了を許可する。保存失敗で未保存本文または未反映の削除要求が残る場合は待機を終了して終了をキャンセルし、歌詞状態欄に保存失敗を示す。終了をキャンセルしたら歌詞要求の受付を再開する。現在曲以外の失敗も、対象曲名を付けてこの状態欄で知らせる。失敗を隠したまま終了を許可したり、永続的に待機したりしない。強制終了・電源断前の保存完了は保証しない。

有効性判定には、schemaVersion、音源fingerprint、analysisVersion、alignmentVersion、sourceTextHash、analysisDigestを含める。本文hashは保存したsourceTextのUTF-8バイト列からSHA256を計算する。

analysisDigestは、検査済みのduration、vocal、phrases、segments、sections、beats、barsを固定キー・固定順の値モデルへ格納し、`JSONEncoder.outputFormatting = [.sortedKeys]` でエンコードしたバイト列のSHA256とする。非有限値をエンコードしない。同じ解析versionでも実データが変われば再生成する。

解析到着時、保存済みタイムラインがすべてのキーと最終結果検査を満たせば使用する。それ以外は本文を保持して再生成する。データが壊れて本文を復元できなければ、保存データを読めなかった状態を表示し、黙って歌詞未設定と扱わない。

clearLyricsは、生成・保存の要求世代を更新して古い要求を無効にしてからファイルを削除する。hash取得中でも、元の音源の削除要求をキューに残し、旧本文が後から保存されないようにする。削除に失敗した場合は保存エラーを表示し、再起動で復元される可能性を隠さない。保存・削除の失敗後は状態欄に「保存を再試行」を表示し、確定済み本文または削除要求だけを再試行できるようにする。

## 22. 変更ファイルと責務

| ファイル | 内容 |
| --- | --- |
| `Sources/Lyrics/LyricModels.swift` | 歌詞、タイムライン、保存モデル、状態・エラー型 |
| `Sources/Lyrics/LyricParser.swift` | 本文保持、行と段落、Character重み |
| `Sources/Lyrics/LyricAligner.swift` | データ検査、候補、DP、境界、整合度 |
| `Sources/Lyrics/LyricStore.swift` | SHA256呼出、保存・復元・削除・要求世代 |
| `Sources/Lyrics/LyricMotionView.swift` | snapshot同期、TextRenderer、固定スタイル |
| `Sources/Lyrics/LyricEditorView.swift` | draft、状態欄、適用、失敗時の解析再試行 |
| `Sources/App/PlayerStore.swift` | 現在曲、要求と再生世代、生成Task、解析完成の接続 |
| `Sources/Views/PlayerView.swift` | ヘッダーボタン、popover、レイヤー、非表示条件 |
| `Sources/Models/MusicModels.swift` | LyricPlaybackFrameとVisualFrameの歌詞payload |
| `Sources/Analysis/MusicAnalyzer.swift` | fingerprint既存関数の内部公開のみ |
| `Sources/App/MusicPrayerApp.swift` | 保存完了を待つ通常終了処理の接続 |
| `Tests/LyricParserTests.swift` | 入力保持とUnicode重み |
| `Tests/LyricAlignerTests.swift` | 合成解析でのDP・失敗・再現性 |
| `Tests/LyricStoreTests.swift` | 保存・失効・破損・古い要求の棄却 |
| `Tests/PlayerStoreTransitionTests.swift` | 曲切替、同曲再選択、シーク、停止の歌詞同期 |
| `FOR[hazimeno_ipoo].md` | 実装した構成、採用理由、落とし穴、検証結果 |

SwiftPMの既存Sources配下の自動検出を使う。歌詞用の外部依存やMetalリソースを追加しない。既存Package.swiftにある未コミット変更を保持する。MetalRenderer、MetalVisualizerView、Metal shaders、音声エンジン、既存のTimelineSamplerは変更対象に含めない。

## 23. 検証と完了条件

### 自動検証

1. LF／CRLF、空行、繰り返し、日本語、結合文字、絵文字、句読点だけの行で、本文と順序を保持する。
2. phrase数と行数の一致・不一致、内部分割、複数phraseの割当、段落ヒントを検査する。
3. vocal欠測、全ゼロ、1点、弱い活動のみ、内部欠落、曲末、候補不足で、定義されたモードまたは失敗になる。
4. 長い歌唱停止、観測欠落をまたぐ配置を禁止する。DPが貪欲選択と異なる有効な全体解を選べるケースを検査する。
5. 全行について曲内、正の時間、順序、非重複、本文一致を検査する。同入力からID・時刻・confidenceを含む同一値を生成する。
6. 保存の全キー、同version内の解析変化、壊れたJSON、保存失敗、削除と古いTaskの競合を検査する。
7. 曲切替フェード中と同曲再選択でも現曲payloadを使用し、旧曲の生成Taskを棄却する。停止中のシーク・プレビューでも再描画される。

### 実曲・実画面の受入確認

既存の保存済み解析6件は信号の観測資料として扱う。歌詞本文と正解時刻を照合していないため、タイミング精度の合格資料には使用しない。

実曲の歌詞と耳で確認した各行の開始・終了を比較する。確認する楽曲条件は、イントロ・間奏を持つ通常歌唱、速い歌唱、長い音の伸ばし、同文の繰り返し、弱い歌声、インスト、phrase数と行数の不一致、コーラス等が本文に含まれない場合。各条件を検証曲が実際に持つことを確認し、曲数だけで網羅と扱わない。

境界誤差、取り違えた行、歌唱候補の過不足、生成失敗、使用モードを記録する。開始・終了の絶対誤差について、曲ごとの中央値、90パーセンタイル、最大値と比較した行数を報告する。V1では実発音への数値精度保証を設けないことを仕様として確定し、これらの誤差を測定前の保証値へ置き換えない。

機能の合否は次の完了条件で判定する。実曲のタイミング品質は測定値と取り違えの内容を併記し、「正確な自動同期」として完了報告しない。観測できなかった曲・条件は未確認とする。通常モードで歌唱候補が正しく検出できず生成不能になる場合も結果として報告し、例外の均等配置で検証を通さない。

実画面では、長い歌詞の折返し、クロスフェード、水面のクリック・ドラッグ、プレイヤー操作、popoverを開いたままの再生、4秒自動非表示、停止中のシーク・プレビュー、全画面、既存の各ビジュアライザーで確認する。

再生中の歌詞表示で更新頻度と負荷を測定する。一時停止後、プレビュー等の操作がない場合に歌詞の定期更新が止まることを確認する。コード上の60fps要求やビルド成功だけで実描画の合格としない。

### V1の機能完了条件

- タイムコードなしの全文を入力でき、非空行の本文と順序を保持する。
- 定義した解析モードとDPから全行の推定時刻を生成するか、理由を示して全体失敗する。
- 正の行時間、曲長以内、順序、非重複、決定的なID・時刻を保証する。
- vocalモードでは検出した長い非歌唱区間へ行を配置しない。phrasesOnlyへこの保証を適用しない。
- シーク・停止・一時停止・リピート・曲変更・プレビューで正しい現在曲と時刻へ追従する。
- 既存の音声、Metal、水面操作、UI、約10Hzのposition更新を保持する。
- 保存と再生成のキーが働き、本文が解析待ち・生成失敗でも保存される。
- 外部API、音声認識、追加AIモデルを必要としない。
- 自動検証と実画面確認を完了し、実曲のタイミング品質は測定結果と受入状態を別に報告する。

## 24. 元の仕様からの確定変更

1. phraseより粗いsegmentを、phrase内分割の第一候補とする記述を修正した。
2. 曲内最大値を使う正規化をやめ、APIの0〜1活動強度と明示した失敗条件を使用する。
3. vocal欠測と、有効な全ゼロ／歌唱候補なしを分けた。
4. DPの遷移、必須条件、採点、同点規則、全体失敗を具体化した。
5. 歌詞用payloadを追加し、曲間フェードの旧曲時刻を混ぜない構造にした。
6. 更新頻度を固定60fps保証から60fps目標へ変更し、停止中の再描画を定義した。
7. 行IDを決定的なStringへ変更し、解析実データのdigestを保存キーへ追加した。
8. fingerprint既存関数の内部公開と、通常終了で本文保存を待つ接続を既存変更の範囲へ加えた。
9. 句読点だけの行、隣接行の表示重複、未適用draft、保存失敗の扱いを定義した。
10. 機能の成立と、未測定の歌詞タイミング品質を分けて完了判定する。

## 25. 一次資料

- [Music Understanding](https://developer.apple.com/documentation/musicunderstanding)
- [InstrumentActivityResult：activityは0〜1、rangesは検出時間窓](https://developer.apple.com/documentation/musicunderstanding/instrumentactivityresult)
- [Meet the Music Understanding framework：音楽構造の階層](https://developer.apple.com/videos/play/wwdc2026/253/)
- [TimelineView：スケジュールより低い更新頻度になる場合がある](https://developer.apple.com/documentation/swiftui/timelineview)
- [AnimationTimelineSchedule](https://developer.apple.com/documentation/swiftui/animationtimelineschedule)
- [TextRenderer](https://developer.apple.com/documentation/swiftui/textrenderer)
- [Text.Layout.CharacterIndex](https://developer.apple.com/documentation/swiftui/text/layout/characterindex)
- [applicationShouldTerminate(_:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:))

以上のAPI仕様は2026-10-02の調査時点のもの。判定値・採点・表示寸法はこのV1で採用する設計値であり、Appleが定めた歌詞同期仕様ではない。
