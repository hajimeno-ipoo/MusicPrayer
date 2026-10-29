# Apple Musicの歌詞ボタン

2026-10-29にApple Music公式Webの配信ファイルを確認して作成した、黒色のテンプレートPDFです。SVGの輪郭は変更していません。

- ページ: https://music.apple.com/jp/new
- JavaScript: https://music.apple.com/assets/index~cc245af156.js
- CSS: https://music.apple.com/assets/index~83a3c7ea96.css
- `Lyrics.pdf`: `UHe`の非選択時の`FE`（輪郭の吹き出し）。
- `LyricsSelected.pdf`: `UHe`の選択時の`UE`（塗りつぶし吹き出し）を、`Mu`と同じ反転マスクで描画。

両方28×28pt。`MHe`のマスクは22×22、`DLe`の中央配置はx=3/y=3、CSSの角丸は8です。選択時は全面を塗り、吹き出し部分を抜くため、引用符部分が残ります。四角い背景に輪郭アイコンを重ねる処理や、塗りつぶし吹き出し単体での置き換えではありません。

元のSVGを既存の`rsvg-convert --dpi-x 72 --dpi-y 72 -f pdf`でPDFへ変換しました。選択時はSVGの画像マスクがPDF内で低解像度になるため、同じ外形と吹き出しのパスを`evenodd`で塗る等価なベクターにしています。再生中にネットワークから取得せず、同梱PDFをテンプレート画像として表示します。
