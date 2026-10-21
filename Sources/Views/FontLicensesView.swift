import SwiftUI

struct FontLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFont = LyricFont.furifont

    private static let documents: [LyricFont: String] = {
        Dictionary(uniqueKeysWithValues: LyricFont.allCases.compactMap { font in
            guard let resource = font.licenseResource,
                  let url = Bundle.module.url(forResource: resource, withExtension: "txt", subdirectory: "Fonts"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (font, text)
        })
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("フォントのライセンス")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Picker("フォント", selection: $selectedFont) {
                ForEach(LyricFont.allCases.filter { $0.licenseResource != nil }) { font in
                    Text(font.title).tag(font)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            Divider()
            ScrollView {
                if let document = Self.documents[selectedFont] {
                    Text(verbatim: document)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                } else {
                    Text("同梱ライセンス文書を読み込めませんでした。")
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
            .id(selectedFont)
        }
        .frame(width: 720, height: 620)
    }
}
