import SwiftUI

struct TaskListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @State private var tasks: [YaplyTask] = []
    @State private var isLoading = false
    @State private var newTaskTitle = ""
    @State private var showAdd = false
    @State private var taskToDelete: YaplyTask?
    @State private var taskToEditDueDate: YaplyTask?
    @State private var editDueDate = Date()

    private let repo = TaskRepository()

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if tasks.isEmpty {
                    Spacer()
                    EmptyStateView(icon: "checkmark.circle", title: "No tasks yet")
                    Spacer()
                } else {
                    List {
                        ForEach(tasks) { task in
                            TaskRowView(
                                task: task,
                                isCurrentUserAdmin: isCurrentUserAdmin,
                                onStatusChange: { newStatus in
                                    guard !task.locked || isCurrentUserAdmin else { return }
                                    Task { try? await repo.updateStatus(taskId: task.id, status: newStatus) }
                                }
                            )
                            .yaplyCardStyle()
                            .yaplyCardRowContainer()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                let canDelete = task.createdBy == currentUserId || isCurrentUserAdmin
                                let effectiveCanDelete = canDelete && (!task.locked || isCurrentUserAdmin)
                                Button(role: effectiveCanDelete ? .destructive : .none) {
                                    if effectiveCanDelete { taskToDelete = task }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(effectiveCanDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if isCurrentUserAdmin {
                                    Button {
                                        Task { try? await repo.setLocked(id: task.id, locked: !task.locked)
                                            await load()
                                        }
                                    } label: {
                                        Label(task.locked ? "Unlock" : "Lock",
                                              systemImage: task.locked ? "lock.open" : "lock")
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
        .navigationTitle("Tasks")
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
            guard (notif.userInfo?["type"] as? String) == "tasks" else { return }
            Task { await load() }
        }
        .sheet(isPresented: $showAdd) {
            addTaskSheet
        }
        .sheet(item: $taskToEditDueDate) { task in
            NavigationStack {
                Form {
                    DatePicker("Due date", selection: $editDueDate, displayedComponents: [.date, .hourAndMinute])
                }
                .navigationTitle("Edit Due Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { taskToEditDueDate = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                try? await repo.updateDueDate(taskId: task.id, dueAt: editDueDate)
                                taskToEditDueDate = nil
                                await load()
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Delete Task", isPresented: Binding(
            get: { taskToDelete != nil },
            set: { if !$0 { taskToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let t = taskToDelete else { return }
                taskToDelete = nil
                Task {
                    try? await repo.deleteTask(id: t.id)
                    tasks.removeAll { $0.id == t.id }
                }
            }
            Button("Cancel", role: .cancel) { taskToDelete = nil }
        } message: {
            Text("\"\(taskToDelete?.title ?? "")\" will be permanently deleted. This cannot be undone.")
        }
    }

    private var addTaskSheet: some View {
        NavigationStack {
            Form {
                TextField("Task title", text: $newTaskTitle)
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard !newTaskTitle.isBlank else { return }
                        Task {
                            try? await repo.createTask(conversationId: conversationId, createdBy: currentUserId, title: newTaskTitle)
                            newTaskTitle = ""
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
        tasks = (try? await repo.fetchTasks(conversationId: conversationId)) ?? []
        isLoading = false
    }
}

private struct TaskRowView: View {
    let task: YaplyTask
    let isCurrentUserAdmin: Bool
    let onStatusChange: (String) -> Void

    @State private var showEditDueDate = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                let next = task.status == "done" ? "todo" : "done"
                onStatusChange(next)
            }) {
                Image(systemName: task.status == "done" ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(task.status == "done" ? Color.yaplyAccent : Color.yaplySecondary)
            }
            .buttonStyle(.plain)
            .disabled(task.locked && !isCurrentUserAdmin)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if task.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    Text(task.title)
                        .font(.system(size: 15))
                        .strikethrough(task.status == "done")
                        .foregroundStyle(task.status == "done" ? Color.yaplySecondary : Color.yaplyPrimary)
                }
                HStack(spacing: 4) {
                    Text(task.priority.capitalized + " priority")
                        .foregroundStyle(priorityColor)
                    Text("·")
                        .foregroundStyle(Color.yaplySecondary.opacity(0.5))
                    Text("by \(task.creator?.name ?? "Unknown")")
                        .foregroundStyle(Color.yaplySecondary)
                    if let due = task.dueAt {
                        Text("·")
                            .foregroundStyle(Color.yaplySecondary.opacity(0.5))
                        Text(due.formatted(.dateTime.month(.abbreviated).day()))
                            .foregroundStyle(due < Date() ? .red : Color.yaplySecondary)
                        if isCurrentUserAdmin {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.yaplySecondary)
                                .onTapGesture { showEditDueDate = true }
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showEditDueDate) {
            dueDateSheet
        }
    }

    private var dueDateSheet: some View {
        EditDueDateSheet(task: task, onSave: { _ in showEditDueDate = false })
    }

    private var priorityColor: Color {
        switch task.priority {
        case "high":   return .red
        case "medium": return .orange
        default:       return Color.yaplySecondary
        }
    }
}

private struct EditDueDateSheet: View {
    let task: YaplyTask
    let onSave: (Date) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss
    private let repo = TaskRepository()

    init(task: YaplyTask, onSave: @escaping (Date) -> Void) {
        self.task = task
        self.onSave = onSave
        _date = State(initialValue: task.dueAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Due date", selection: $date, displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle("Edit Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await repo.updateDueDate(taskId: task.id, dueAt: date)
                            onSave(date)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
