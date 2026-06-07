import SwiftUI

struct AlbumListView: View {
    let conversationId: UUID
    let currentUserId: UUID

    @State private var albums: [YaplyAlbum] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var albumToDelete: YaplyAlbum?
    @State private var selectedAlbum: YaplyAlbum?
    @State private var newName = ""

    private let repo = AlbumRepository()

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if albums.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.yaplySecondary)
                        Text("No albums yet")
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(albums) { album in
                            Button(action: { selectedAlbum = album }) {
                                AlbumRowView(album: album)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if album.createdBy == currentUserId {
                                    Button(role: .destructive) {
                                        albumToDelete = album
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showCreate = true }) {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumGallerySheet(album: album, repo: repo)
        }
        .alert("Delete Album", isPresented: Binding(
            get: { albumToDelete != nil },
            set: { if !$0 { albumToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let a = albumToDelete else { return }
                albumToDelete = nil
                Task {
                    try? await repo.deleteAlbum(id: a.id)
                    albums.removeAll { $0.id == a.id }
                }
            }
            Button("Cancel", role: .cancel) { albumToDelete = nil }
        } message: {
            Text("\"\(albumToDelete?.name ?? "")\" and all its photos will be permanently deleted.")
        }
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                TextField("Album name", text: $newName)
            }
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !newName.isBlank else { return }
                        Task {
                            try? await repo.createAlbum(conversationId: conversationId, createdBy: currentUserId, name: newName)
                            newName = ""
                            showCreate = false
                            await load()
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        albums = (try? await repo.fetchAlbums(conversationId: conversationId)) ?? []
        isLoading = false
    }
}

private struct AlbumRowView: View {
    let album: YaplyAlbum

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.yaplyBackground)
                    .frame(width: 36, height: 36)
                Image(systemName: "photo.stack")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yaplyAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.yaplyPrimary)
                Text(album.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Color.yaplySecondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Album Gallery Sheet

private struct AlbumGallerySheet: View {
    let album: YaplyAlbum
    let repo: AlbumRepository

    @State private var media: [YaplyAlbumMedia] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(Color.yaplyAccent)
                } else if media.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.yaplySecondary)
                        Text("No photos yet")
                            .foregroundStyle(Color.yaplySecondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(media) { item in
                                AsyncImage(url: URL(string: item.mediaUrl)) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                                            .clipped()
                                    default:
                                        Color.yaplyBackground
                                            .frame(height: 110)
                                    }
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .navigationTitle(album.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .task {
            media = (try? await repo.fetchMedia(albumId: album.id)) ?? []
            isLoading = false
        }
    }
}
