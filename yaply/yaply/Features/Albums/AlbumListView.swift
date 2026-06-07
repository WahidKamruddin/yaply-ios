import SwiftUI

struct AlbumListView: View {
    let conversationId: UUID
    let currentUserId: UUID

    @State private var albums: [YaplyAlbum] = []
    @State private var isLoading = false
    @State private var showCreate = false
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
        .onReceive(NotificationCenter.default.publisher(for: .yaplyItemCreated)) { notif in
            guard (notif.userInfo?["type"] as? String) == "albums" else { return }
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumGallerySheet(
                album: album,
                currentUserId: currentUserId,
                repo: repo,
                onDeleted: { Task { await load() } }
            )
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
            Group {
                if let urlStr = album.coverUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default: albumPlaceholder
                        }
                    }
                } else {
                    albumPlaceholder
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.yaplyPrimary)
                Text("by \(album.creator?.name ?? "Unknown") · \(album.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))")
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

    private var albumPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yaplyBackground)
                .frame(width: 36, height: 36)
            Image(systemName: "photo.stack")
                .font(.system(size: 14))
                .foregroundStyle(Color.yaplyAccent)
        }
    }
}

// MARK: - Album Gallery Sheet

private struct AlbumGallerySheet: View {
    let album: YaplyAlbum
    let currentUserId: UUID
    let repo: AlbumRepository
    let onDeleted: () -> Void

    @State private var media: [YaplyAlbumMedia] = []
    @State private var events: [YaplyEvent] = []
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    @State private var showUnlinkConfirm = false
    @State private var showLinkPicker = false
    @Environment(\.dismiss) private var dismiss

    private let eventRepo = EventRepository()
    private var isCreator: Bool { album.createdBy == currentUserId }

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if album.eventId != nil {
                        Button {
                            showUnlinkConfirm = true
                        } label: {
                            Image(systemName: "link.badge.minus")
                        }
                        .foregroundStyle(Color.orange)
                    } else if !events.isEmpty {
                        Button {
                            showLinkPicker = true
                        } label: {
                            Image(systemName: "link")
                        }
                        .foregroundStyle(Color.yaplyAccent)
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(album.name).font(.headline)
                        Text("by \(album.creator?.name ?? "Unknown")")
                            .font(.caption2)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            if isCreator { showDeleteConfirm = true }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundStyle(isCreator ? Color.red : Color(UIColor.systemGray4))
                        .disabled(!isCreator)

                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.yaplyAccent)
                    }
                }
            }
        }
        .task {
            async let mediaFetch = repo.fetchMedia(albumId: album.id)
            async let eventFetch = eventRepo.fetchEvents(conversationId: album.conversationId)
            media = (try? await mediaFetch) ?? []
            events = (try? await eventFetch) ?? []
            isLoading = false
        }
        .alert("Delete Album", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await repo.deleteAlbum(id: album.id)
                    onDeleted()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(album.name)\" and all its photos will be permanently deleted.")
        }
        .alert("Unlink Album", isPresented: $showUnlinkConfirm) {
            Button("Unlink", role: .destructive) {
                Task {
                    try? await repo.unlinkFromEvent(albumId: album.id)
                    onDeleted()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \"\(album.name)\" from its linked event?")
        }
        .sheet(isPresented: $showLinkPicker) {
            EventLinkPickerSheet(
                title: "Link \"\(album.name)\"",
                events: events,
                onSelect: { event in
                    Task {
                        try? await repo.linkToEvent(albumId: album.id, eventId: event.id)
                        showLinkPicker = false
                        onDeleted()
                    }
                },
                onCancel: { showLinkPicker = false }
            )
        }
    }
}

// MARK: - Event Link Picker Sheet (shared by Albums + Budgets)

struct EventLinkPickerSheet: View {
    let title: String
    let events: [YaplyEvent]
    let onSelect: (YaplyEvent) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    Text("No events in this conversation")
                        .foregroundStyle(Color.yaplySecondary)
                } else {
                    ForEach(events) { event in
                        Button(action: { onSelect(event) }) {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(event.isPlanning
                                              ? Color(red: 0.929, green: 0.945, blue: 0.980)
                                              : Color(red: 0.9, green: 0.97, blue: 0.9))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: event.isPlanning ? "map" : "calendar")
                                        .font(.system(size: 12))
                                        .foregroundStyle(event.isPlanning ? Color.yaplyAccent : Color.green)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.yaplyPrimary)
                                    if let starts = event.startsAt {
                                        Text(starts.formatted(.dateTime.month(.abbreviated).day()))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.yaplySecondary)
                                    } else {
                                        Text("Planning")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.yaplySecondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
