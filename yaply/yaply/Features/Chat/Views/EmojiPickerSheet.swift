import SwiftUI

/// A lightweight emoji grid, presented as a sheet from the reaction bar's "+"
/// button. iOS has no public emoji-picker view, so this walks the standard
/// emoji Unicode blocks and shows anything with default emoji presentation.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .background(Color.yaplyBackground)
            .navigationTitle("Choose an emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Emoji blocks worth showing, in a friendly order. Built once.
    static let emojis: [String] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F,   // emoticons
            0x1F900...0x1F9FF,   // supplemental symbols & pictographs (faces, hands, people)
            0x1F300...0x1F5FF,   // misc symbols & pictographs
            0x1F680...0x1F6FC,   // transport & map
            0x1FA70...0x1FAF8,   // symbols & pictographs extended-A
            0x2600...0x26FF,     // misc symbols
            0x2700...0x27BF,     // dingbats
        ]
        var out: [String] = []
        var seen = Set<String>()
        for range in ranges {
            for cp in range {
                guard let scalar = Unicode.Scalar(cp) else { continue }
                guard scalar.properties.isEmojiPresentation else { continue }
                let s = String(scalar)
                if seen.insert(s).inserted { out.append(s) }
            }
        }
        return out
    }()
}
