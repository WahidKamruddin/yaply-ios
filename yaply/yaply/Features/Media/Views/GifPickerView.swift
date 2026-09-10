import SwiftUI
import Kingfisher

struct GifPickerView: View {
    let onSelect: (GiphyGif) -> Void

    @State private var query = ""
    @State private var gifs: [GiphyGif] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var searchTask: Task<Void, Never>?

    private let service = GiphyService()
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.yaplySecondary)
                TextField("Search GIFs...", text: $query)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, new in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            await load(query: new)
                        }
                    }
            }
            .padding(10)
            .background(Color.yaplyBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
            .padding(12)

            if !service.hasKey {
                emptyState(
                    icon: "key",
                    title: "GIFs aren't set up",
                    subtitle: "Add a Giphy API key to GIPHY_API_KEY in Config.xcconfig, then rebuild."
                )
            } else if isLoading {
                Spacer()
                ProgressView().tint(Color.yaplyAccent)
                Spacer()
            } else if loadFailed {
                emptyState(
                    icon: "wifi.slash",
                    title: "Couldn't load GIFs",
                    subtitle: "Check your connection and that the Giphy key is valid."
                )
            } else if gifs.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: query.isEmpty ? "No trending GIFs" : "No results",
                    subtitle: query.isEmpty ? "Try searching for something." : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(gifs) { gif in
                            Button(action: { onSelect(gif) }) {
                                KFAnimatedImage(URL(string: gif.previewUrl))
                                    .configure { $0.contentMode = .scaleAspectFill }
                                    .placeholder { Color.yaplyBackground }
                                    .frame(height: 100)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .task { await load(query: "") }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
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
        .frame(maxWidth: .infinity)
    }

    private func load(query: String) async {
        guard service.hasKey else { return }
        isLoading = true
        loadFailed = false
        do {
            gifs = try await (query.isEmpty ? service.trending() : service.search(query: query))
        } catch {
            gifs = []
            loadFailed = true
        }
        isLoading = false
    }
}
