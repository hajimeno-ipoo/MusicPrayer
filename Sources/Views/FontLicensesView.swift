import SwiftUI

struct FontLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private static let document: String? = {
        guard let url = Bundle.module.url(forResource: "Furifont-LICENSES", withExtension: "txt", subdirectory: "Fonts") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
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
            Divider()
            ScrollView {
                if let document = Self.document {
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
        }
        .frame(width: 720, height: 620)
    }
}
