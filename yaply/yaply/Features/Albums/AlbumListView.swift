import SwiftUI

struct AlbumListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @Environment(AppRouter.self) private var router

    @State private var albums: [YaplyAlbum] = []
    @State private var isLoading = false
    @State private var showCreate = false
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
                            Button(action: {
                                router.push(.albumDetail(album: album, isCurrentUserAdmin: isCurrentUserAdmin))
                            }) {
                                AlbumRowView(album: album)
                            }
                            .buttonStyle(.plain)
                            .yaplyCardStyle()
                            .yaplyCardRowContainer()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
        .yaplyPopup(isPresented: $showCreate) {
            createSheet
        }
        .yaplyConfirm(
            isPresented: Binding(get: { albumToDelete != nil }, set: { if !$0 { albumToDelete = nil } }),
            title: "Delete album",
            message: "\"\(albumToDelete?.name ?? "")\" and all its photos will be permanently deleted. This cannot be undone.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            guard let album = albumToDelete else { return }
            albumToDelete = nil
            Task {
                try? await repo.deleteAlbum(id: album.id)
                albums.removeAll { $0.id == album.id }
            }
        }
    }

    private var createSheet: some View {
        YaplySheetScaffold(
            title: "New album",
            primaryLabel: "Create",
            primaryEnabled: !newName.isBlank,
            primaryAction: {
                guard !newName.isBlank else { return }
                let name = newName
                newName = ""
                showCreate = false
                Task {
                    try? await repo.createAlbum(conversationId: conversationId, createdBy: currentUserId, name: name)
                    await load()
                }
            }
        ) {
            YaplyLabeledField(label: "Album name") {
                TextField("Trip photos, party pics…", text: $newName)
                    .yaplyInputStyle()
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

// MARK: - Album Gallery (pushed page)

struct AlbumGalleryView: View {
    let album: YaplyAlbum
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @State private var media: [YaplyAlbumMedia] = []
    @State private var events: [YaplyEvent] = []
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    @State private var showUnlinkConfirm = false
    @State private var showLinkPicker = false
    @Environment(\.dismiss) private var dismiss

    private let repo = AlbumRepository()
    private let eventRepo = EventRepository()

    private func notifyChanged() {
        NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "albums"])
    }
    private var isCreator: Bool { album.createdBy == currentUserId }
    private var canDelete: Bool { isCreator || isCurrentUserAdmin }
    private var effectiveCanDelete: Bool { canDelete && (!album.locked || isCurrentUserAdmin) }

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
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
                                    Color.yaplyCard.frame(height: 110)
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
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if album.eventId != nil {
                    Button { showUnlinkConfirm = true } label: {
                        Image(systemName: "link.badge.minus").foregroundStyle(Color.orange)
                    }
                } else if !events.isEmpty {
                    Button { showLinkPicker = true } label: {
                        Image(systemName: "link").foregroundStyle(Color.yaplyAccent)
                    }
                }
                if effectiveCanDelete {
                    Button { showDeleteConfirm = true } label: {
                        Image(systemName: "trash").foregroundStyle(Color.yaplyDanger)
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
        .yaplyConfirm(
            isPresented: $showDeleteConfirm,
            title: "Delete album",
            message: "\"\(album.name)\" and all its photos will be permanently deleted. This cannot be undone.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            Task {
                try? await repo.deleteAlbum(id: album.id)
                notifyChanged()
                dismiss()
            }
        }
        .yaplyConfirm(
            isPresented: $showUnlinkConfirm,
            title: "Unlink album",
            message: "Remove \"\(album.name)\" from its linked event?",
            icon: "link",
            confirmLabel: "Unlink"
        ) {
            Task {
                try? await repo.unlinkFromEvent(albumId: album.id)
                notifyChanged()
                dismiss()
            }
        }
        .yaplyPopup(isPresented: $showLinkPicker) {
            EventLinkPickerSheet(
                title: "Link \"\(album.name)\"",
                events: events,
                onSelect: { event in
                    Task {
                        try? await repo.linkToEvent(albumId: album.id, eventId: event.id)
                        showLinkPicker = false
                        notifyChanged()
                    }
                }
            )
        }
    }
}

// MARK: - Event Link Picker Sheet (shared by Albums + Budgets)

struct EventLinkPickerSheet: View {
    let title: String
    let events: [YaplyEvent]
    let onSelect: (YaplyEvent) -> Void

    var body: some View {
        YaplySheetScaffold(title: title) {
            VStack(spacing: 8) {
                if events.isEmpty {
                    Text("No events in this conversation")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
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
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Color.yaplyTint)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
