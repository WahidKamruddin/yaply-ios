import SwiftUI

struct CommandPaletteView: View {
    let query: String
    let onSelect: (String) -> Void

    private var suggestions: [YaplyCommand] {
        YaplyCommand.matching(prefix: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("COMMANDS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }

            ForEach(suggestions, id: \.rawValue) { cmd in
                Button(action: { onSelect(cmd.rawValue) }) {
                    HStack(spacing: 0) {
                        Text("/\(cmd.rawValue)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.yaplyAccent)
                        if let hint = cmd.argHint {
                            let pattern = hint.components(separatedBy: "  ").first ?? hint
                            Text("  \(pattern)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.yaplySecondary.opacity(0.45))
                        }
                        Spacer()
                        Text(cmd.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.yaplySecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if cmd != suggestions.last {
                    Divider().padding(.leading, 14)
                }
            }

            if suggestions.count > 1 {
                HStack {
                    Text("Tap to select")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.yaplySecondary.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Divider() }
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
