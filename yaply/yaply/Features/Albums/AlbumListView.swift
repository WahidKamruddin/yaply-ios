import SwiftUI

struct AlbumListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @State private var albums: [YaplyAlbum] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var selectedAlbum: YaplyAlbum?
    @State private var newName = ""
    @State private var albumToDelete: YaplyAlbum?

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
                    EmptyStateView(icon: "photo.on.rectangle.angled", title: "No albums yet")
                    Spacer()
                } else {
                    List {
                        ForEach(albums) { album in
                            Button(action: { selectedAlbum = album }) {
                                AlbumRowView(album: album)
                            }
                            .buttonStyle(.plain)
                            .yaplyCardStyle()
                            .yaplyCardRowContainer()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Additive to the gallery sheet's own delete entry point —
                                // gives Albums the same trailing-swipe delete affordance as
                                // every other list, using the identical creator/admin/lock
                                // gating the gallery sheet already applies.
                                let canDelete = album.createdBy == currentUserId || isCurrentUserAdmin
                                let effectiveCanDelete = canDelete && (!album.locked || isCurrentUserAdmin)
                                Button(role: effectiveCanDelete ? .destructive : .none) {
                                    if effectiveCanDelete { albumToDelete = album }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(effectiveCanDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if isCurrentUserAdmin {
                                    Button {
                                        Task {
                                            try? await repo.setLocked(id: album.id, locked: !album.locked)
                                            await load()
                                        }
                                    } label: {
                                        Label(album.locked ? "Unlock" : "Lock",
                                              systemImage: album.locked ? "lock.open" : "lock")
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
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
                isCurrentUserAdmin: isCurrentUserAdmin,
                repo: repo,
                onDeleted: { Task { await load() } }
            )
        }
        .alert(
            "Delete Album",
            isPresented: Binding(
                get: { albumToDelete != nil },
                set: { if !$0 { albumToDelete = nil } }
            ),
            presenting: albumToDelete
        ) { album in
            Button("Delete", role: .destructive) {
                albumToDelete = nil
                Task {
                    try? await repo.deleteAlbum(id: album.id)
                    albums.removeAll { $0.id == album.id }
                }
            }
            Button("Cancel", role: .cancel) { albumToDelete = nil }
        } message: { album in
            Text("\"\(album.name)\" and all its photos will be permanently deleted. This cannot be undone.")
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
                HStack(spacing: 4) {
                    if album.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    Text(album.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.yaplyPrimary)
                }
                Text("by \(album.creator?.name ?? "Unknown") · \(album.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Color.yaplySecondary)
        }
        .padding(.vertical, 4)
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
    var isCurrentUserAdmin: Bool = false
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
    private var canDelete: Bool { isCreator || isCurrentUserAdmin }
    private var effectiveCanDelete: Bool { canDelete && (!album.locked || isCurrentUserAdmin) }

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(Color.yaplyAccent)
                } else if media.isEmpty {
                    EmptyStateView(icon: "photo", title: "No photos yet")
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
                            if effectiveCanDelete { showDeleteConfirm = true }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundStyle(effectiveCanDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))
                        .disabled(!effectiveCanDelete)

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
            Text("\"\(album.name)\" and all its photos will be permanently deleted. This cannot be undone.")
        }
        .alert("Unlink Album", isPresented: $showUnlinkConfirm) {
            Button("Unlink", role: .destructive) {
                Task {
                    try? await repo.unlinkFromEvent(albumId: album.id)
                    onDeleted()
                    dismiss()
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
                                        .fill(event.isPlanning ? Color.yaplyBackground : Color.yaplyConfirmedGreen)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: event.isPlanning ? "map" : "calendar")
                                        .font(.system(size: 12))
                                        .foregroundStyle(event.isPlanning ? Color.yaplyAccent : Color.yaplyMint)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.yaplyPrimary)
                                    if let starts = event.startsAt {
                                        Text(starts.formatted(.dateTime.month(.abbreviated).day()))
                                            .font(.caption)
                                            .foregroundStyle(Color.yaplySecondary)
                                    } else {
                                        Text("Planning")
                                            .font(.caption)
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
