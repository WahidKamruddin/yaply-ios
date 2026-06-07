import SwiftUI

struct TaskListView: View {
    let conversationId: UUID
    let currentUserId: UUID

    @State private var tasks: [YaplyTask] = []
    @State private var isLoading = false
    @State private var newTaskTitle = ""
    @State private var showAdd = false
    @State private var taskToDelete: YaplyTask?

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
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.yaplySecondary)
                        Text("No tasks yet")
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(tasks) { task in
                            TaskRowView(task: task) { newStatus in
                                Task { try? await repo.updateStatus(taskId: task.id, status: newStatus) }
                            }
                            .listRowBackground(Color.white)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    taskToDelete = task
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
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
            Text("\"\(taskToDelete?.title ?? "")\" will be permanently deleted.")
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
    let onStatusChange: (String) -> Void

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

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 15))
                    .strikethrough(task.status == "done")
                    .foregroundStyle(task.status == "done" ? Color.yaplySecondary : Color.yaplyPrimary)
                Text(task.priority.capitalized + " priority")
                    .font(.caption)
                    .foregroundStyle(priorityColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var priorityColor: Color {
        switch task.priority {
        case "high":   return .red
        case "medium": return .orange
        default:       return Color.yaplySecondary
        }
    }
}
