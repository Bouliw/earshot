import SwiftUI

/// The session's summary (Summary.txt), above its transcript: folded or open, the text can be selected and copied.
struct SummaryCard: View {
    let folder: URL?
    @ViewState private var open = true

    var body: some View {
        if let text = Summary.load(folder) {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: $open) {
                    ScrollView {
                        Text(Self.render(text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 240)
                } label: {
                    Label("Summary", systemImage: "sparkles").font(.headline)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
            }
        }
    }

    /// The text without its first line (the window already shows the title and date), headings in bold.
    static func render(_ text: String) -> AttributedString {
        var out = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().drop { $0.isEmpty }
        for (i, line) in lines.enumerated() {
            var part = AttributedString(String(line) + (i < lines.count - 1 ? "\n" : ""))
            if Summary.allHeadings.contains(String(line)) { part.font = .body.bold() }
            out += part
        }
        return out
    }
}
