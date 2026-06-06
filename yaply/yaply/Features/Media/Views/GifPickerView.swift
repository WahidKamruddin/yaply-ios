import SwiftUI

struct GifPickerView: View {
    let onSelect: (GiphyGif) -> Void

    @State private var query = ""
    @State private var gifs: [GiphyGif] = []
    @State private var isLoading = false
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

            if isLoading {
                Spacer()
                ProgressView().tint(Color.yaplyAccent)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(gifs) { gif in
                            Button(action: { onSelect(gif) }) {
                                AsyncImage(url: URL(string: gif.previewUrl)) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().scaledToFill()
                                    default: Color.yaplyBackground
                                    }
                                }
                                .frame(height: 100)
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

    private func load(query: String) async {
        isLoading = true
        gifs = (try? await (query.isEmpty ? service.trending() : service.search(query: query))) ?? []
        isLoading = false
    }
}
