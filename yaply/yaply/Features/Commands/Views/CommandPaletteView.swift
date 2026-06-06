import SwiftUI

// Floating command suggestions shown when the user types "/" in MessageInputView
struct CommandPaletteView: View {
    let query: String
    let onSelect: (String) -> Void

    private var suggestions: [YaplyCommand] {
        YaplyCommand.matching(prefix: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.rawValue) { cmd in
                Button(action: { onSelect(cmd.rawValue) }) {
                    HStack(spacing: 12) {
                        Text("/\(cmd.rawValue)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.yaplyAccent)
                            .frame(width: 80, alignment: .leading)
                        Text(cmd.description)
                            .font(.caption)
                            .foregroundStyle(Color.yaplyTertiary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if cmd != suggestions.last {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))
        .shadow(color: Color.yaplyShadow, radius: 8, y: -4)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
