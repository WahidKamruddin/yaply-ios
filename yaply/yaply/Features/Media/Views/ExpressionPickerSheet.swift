import SwiftUI

/// The sheet opened by the emoji / expression button inside the composer text
/// field. GIFs works today (reuses `GifPickerView`); custom Stickers and custom
/// Voice notes are reusable saved clips, built later — shown here as
/// "coming soon" so the surface is discoverable.
struct ExpressionPickerSheet: View {
    var onGifSelected: (GiphyGif) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable { case gifs = "GIFs", stickers = "Stickers", voice = "Voice notes" }
    @State private var tab: Tab = .gifs

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button {
                            tab = t
                        } label: {
                            Text(t.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(tab == t ? Color.yaplyAccent : Color.yaplySecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .overlay(
                                    Rectangle()
                                        .fill(tab == t ? Color.yaplyAccent : Color.clear)
                                        .frame(height: 2),
                                    alignment: .bottom
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(Rectangle().fill(Color.yaplyBorder).frame(height: 1), alignment: .bottom)

                switch tab {
                case .gifs:
                    GifPickerView { gif in
                        onGifSelected(gif)
                        dismiss()
                    }
                case .stickers:
                    comingSoon(
                        icon: "face.smiling",
                        title: "Custom stickers are coming",
                        subtitle: "Save your own stickers and drop them into any chat. This is still being built."
                    )
                case .voice:
                    comingSoon(
                        icon: "waveform",
                        title: "Custom voice notes are coming",
                        subtitle: "Record short reusable voice clips to send with a tap. This is still being built."
                    )
                }
            }
            .background(Color.yaplyBackground)
            .navigationTitle("Add to message")
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

    private func comingSoon(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Color.yaplySecondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.yaplyPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.yaplySecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
