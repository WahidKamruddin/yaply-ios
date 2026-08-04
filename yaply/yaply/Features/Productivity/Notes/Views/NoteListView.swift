import SwiftUI

struct NoteListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @State private var notes: [YaplyNote] = []
    @State private var isLoading = false
    @State private var showAdd = false
    @State private var newTitle = ""
    @State private var noteToDelete: YaplyNote?
    @State private var expandedId: UUID?

    private let repo = NoteRepository()

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if notes.isEmpty {
                    Spacer()
                    EmptyStateView(icon: "note.text", title: "No notes yet")
                    Spacer()
                } else {
                    List {
                        ForEach(notes) { note in
                            NoteRowView(
                                note: note,
                                isExpanded: expandedId == note.id,
                                isCurrentUserAdmin: isCurrentUserAdmin,
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = expandedId == note.id ? nil : note.id
                                    }
                                }
                            )
                            .yaplyCardStyle()
                            .yaplyCardRowContainer()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                let canDelete = note.userId == currentUserId || isCurrentUserAdmin
                                let effectiveCanDelete = canDelete && (!note.locked || isCurrentUserAdmin)
                                Button(role: effectiveCanDelete ? .destructive : .none) {
                                    if effectiveCanDelete { noteToDelete = note }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(effectiveCanDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if isCurrentUserAdmin {
                                    Button {
                                        Task {
                                            try? await repo.setLocked(id: note.id, locked: !note.locked)
                                            await load()
                                        }
                                    } label: {
                                        Label(note.locked ? "Unlock" : "Lock",
                                              systemImage: note.locked ? "lock.open" : "lock")
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
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showAdd = true }) {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .yaplyItemCreated)) { notif in
            guard (notif.userInfo?["type"] as? String) == "notes" else { return }
            Task { await load() }
        }
        .sheet(isPresented: $showAdd) {
            addNoteSheet
        }
        .alert("Delete Note", isPresented: Binding(
            get: { noteToDelete != nil },
            set: { if !$0 { noteToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let n = noteToDelete else { return }
                noteToDelete = nil
                Task {
                    try? await repo.deleteNote(id: n.id)
                    notes.removeAll { $0.id == n.id }
                }
            }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        } message: {
            Text("\"\(noteToDelete?.title ?? "")\" will be permanently deleted. This cannot be undone.")
        }
    }

    private var addNoteSheet: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $newTitle)
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard !newTitle.isBlank else { return }
                        Task {
                            try? await repo.createNote(conversationId: conversationId, userId: currentUserId, title: newTitle)
                            newTitle = ""
                            showAdd = false
                            await load()
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        notes = (try? await repo.fetchNotes(conversationId: conversationId)) ?? []
        isLoading = false
    }
}

private struct NoteRowView: View {
    let note: YaplyNote
    let isExpanded: Bool
    let isCurrentUserAdmin: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if note.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    Text(note.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.yaplyPrimary)
                    Spacer()
                    Text("by \(note.creator?.name ?? "Unknown")")
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary.opacity(0.7))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.yaplySecondary)
                }
                if isExpanded && !note.content.isEmpty {
                    Text(note.content)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.yaplySecondary)
                        .padding(.top, 2)
                } else if !note.content.isEmpty {
                    Text(note.content)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.yaplySecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if note.locked && !isCurrentUserAdmin {
                    Label("Locked by admin", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.opacity(0.8))
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
