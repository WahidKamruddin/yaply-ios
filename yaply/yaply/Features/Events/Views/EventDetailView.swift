import SwiftUI

struct EventDetailView: View {
    let event: YaplyEvent
    let currentUserId: UUID

    enum SheetKind: Identifiable {
        case lockTime, linkAlbum, linkBudget
        var id: String {
            switch self { case .lockTime: return "lock"; case .linkAlbum: return "album"; case .linkBudget: return "budget" }
        }
    }

    @State private var rsvps: [YaplyEventRsvp] = []
    @State private var linkedAlbums: [YaplyAlbum] = []
    @State private var linkedBudgets: [YaplyBudget] = []
    @State private var allAlbums: [YaplyAlbum] = []
    @State private var allBudgets: [YaplyBudget] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var activeSheet: SheetKind?
    @State private var lockDate = Date().addingTimeInterval(3600)
    @State private var showLockConfirm = false
    @State private var albumToUnlink: YaplyAlbum?
    @Environment(\.dismiss) private var dismiss

    private let repo = EventRepository()
    private let albumRepo = AlbumRepository()
    private let budgetRepo = BudgetRepository()

    private var isCreator: Bool { event.createdBy == currentUserId }

    private var myResponse: String {
        rsvps.first { $0.userId == currentUserId }?.response ?? "pending"
    }
    private var going:    [YaplyEventRsvp] { rsvps.filter { $0.response == "going" } }
    private var maybe:    [YaplyEventRsvp] { rsvps.filter { $0.response == "maybe" } }
    private var notGoing: [YaplyEventRsvp] { rsvps.filter { $0.response == "not_going" } }

    var body: some View {
        Group {
            if event.isPlanning {
                planningView
            } else {
                confirmedView
            }
        }
        .yaplyPopup(item: $activeSheet) { kind in
            switch kind {
            case .lockTime:   lockTimeSheet
            case .linkAlbum:  linkAlbumSheet
            case .linkBudget: linkBudgetSheet
            }
        }
        .yaplyConfirm(
            isPresented: $showLockConfirm,
            title: "Lock event time?",
            message: "This will confirm \"\(event.name)\" for \(lockDate.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())) and move it from Planning to Confirmed.",
            icon: "lock.fill",
            confirmLabel: "Lock",
            isDestructive: false
        ) {
            Task { await doLockTime() }
        }
        .yaplyConfirm(
            isPresented: Binding(get: { albumToUnlink != nil }, set: { if !$0 { albumToUnlink = nil } }),
            title: "Unlink album",
            message: "Remove \"\(albumToUnlink?.name ?? "")\" from this event?",
            icon: "link",
            confirmLabel: "Unlink"
        ) {
            guard let album = albumToUnlink else { return }
            albumToUnlink = nil
            Task {
                try? await albumRepo.unlinkFromEvent(albumId: album.id)
                linkedAlbums.removeAll { $0.id == album.id }
            }
        }
    }

    // MARK: - Planning mode

    private var planningView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    statusBadge
                    Text(event.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if let desc = event.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.yaplySecondary)
                        .lineLimit(2)
                }
                if let loc = event.location, !loc.isEmpty {
                    Label(loc, systemImage: "mappin")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.yaplySecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yaplySurface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.yaplyBorder).frame(height: 1)
            }

            AvailabilityCalendarView(event: event, currentUserId: currentUserId)
        }
        .background(Color.yaplyBackground)
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isCreator {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Lock Time") { activeSheet = .lockTime }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
    }

    // MARK: - Confirmed mode

    private var confirmedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header card
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                    if let desc = event.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    if let starts = event.startsAt {
                        Label(
                            starts.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                            systemImage: "calendar"
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(Color.yaplySecondary)
                    }
                    if let loc = event.location, !loc.isEmpty {
                        Label(loc, systemImage: "mappin")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yaplyTint)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // RSVP section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("RSVP")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.yaplyPrimary)
                        Spacer()
                        if !rsvps.isEmpty {
                            Text(tallyText)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                    }
                    if isLoading {
                        ProgressView().tint(Color.yaplyAccent)
                    } else {
                        HStack(spacing: 10) {
                            RsvpButton(label: "Going",     value: "going",     current: myResponse, isSaving: isSaving) { await tap("going") }
                            RsvpButton(label: "Maybe",     value: "maybe",     current: myResponse, isSaving: isSaving) { await tap("maybe") }
                            RsvpButton(label: "Can't Go",  value: "not_going", current: myResponse, isSaving: isSaving) { await tap("not_going") }
                        }
                        if !rsvps.isEmpty {
                            Divider()
                            ForEach(rsvps) { rsvp in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(responseColor(rsvp.response).opacity(0.15))
                                        .frame(width: 32, height: 32)
                                        .overlay(Text(responseIcon(rsvp.response)).font(.system(size: 13)))
                                    Text(displayName(rsvp))
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.yaplyPrimary)
                                    Spacer()
                                    Text(responseLabel(rsvp.response))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(responseColor(rsvp.response))
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color.yaplyTint)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                // Linked Albums
                linkedSection(
                    title: "Albums",
                    systemImage: "photo.stack",
                    isEmpty: linkedAlbums.isEmpty,
                    onLink: { Task { await loadAllAlbums(); activeSheet = .linkAlbum } }
                ) {
                    ForEach(linkedAlbums) { album in
                        linkedAlbumRow(album)
                    }
                } emptyLabel: {
                    Text("No albums linked").font(.system(size: 13)).foregroundStyle(Color.yaplySecondary)
                }

                // Linked Budgets
                linkedSection(
                    title: "Budgets",
                    systemImage: "dollarsign.circle",
                    isEmpty: linkedBudgets.isEmpty,
                    onLink: { Task { await loadAllBudgets(); activeSheet = .linkBudget } }
                ) {
                    ForEach(linkedBudgets) { budget in
                        linkedBudgetRow(budget)
                    }
                } emptyLabel: {
                    Text("No budgets linked").font(.system(size: 13)).foregroundStyle(Color.yaplySecondary)
                }
            }
            .padding(16)
        }
        .background(Color.yaplyBackground)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadConfirmed() }
    }

    // MARK: - Lock time sheet

    @ViewBuilder
    private var lockTimeSheet: some View {
        YaplySheetScaffold(
            title: "Lock event time",
            primaryLabel: "Lock",
            primaryAction: {
                activeSheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showLockConfirm = true }
            }
        ) {
            YaplyLabeledField(label: "When is this happening?") {
                DatePicker("", selection: $lockDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Link Album picker

    @ViewBuilder
    private var linkAlbumSheet: some View {
        YaplySheetScaffold(title: "Link album") {
            VStack(spacing: 8) {
                if allAlbums.isEmpty {
                    Text("No albums in this conversation")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(allAlbums) { album in
                        let isLinked = linkedAlbums.contains { $0.id == album.id }
                        Button {
                            Task {
                                if isLinked {
                                    try? await albumRepo.unlinkFromEvent(albumId: album.id)
                                    linkedAlbums.removeAll { $0.id == album.id }
                                } else {
                                    try? await albumRepo.linkToEvent(albumId: album.id, eventId: event.id)
                                    if !linkedAlbums.contains(where: { $0.id == album.id }) {
                                        linkedAlbums.append(album)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                albumThumb(url: album.coverUrl)
                                Text(album.name)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.yaplyPrimary)
                                Spacer()
                                if isLinked {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.yaplyAccent)
                                        .font(.system(size: 13, weight: .semibold))
                                }
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

    // MARK: - Link Budget picker

    @ViewBuilder
    private var linkBudgetSheet: some View {
        YaplySheetScaffold(title: "Link budget") {
            VStack(spacing: 8) {
                if allBudgets.isEmpty {
                    Text("No budgets in this conversation")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(allBudgets) { budget in
                        let isLinked = linkedBudgets.contains { $0.id == budget.id }
                        Button {
                            Task {
                                if isLinked {
                                    try? await budgetRepo.unlinkFromEvent(budgetId: budget.id)
                                    linkedBudgets.removeAll { $0.id == budget.id }
                                } else {
                                    try? await budgetRepo.linkToEvent(budgetId: budget.id, eventId: event.id)
                                    if !linkedBudgets.contains(where: { $0.id == budget.id }) {
                                        linkedBudgets.append(budget)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.yaplyConfirmedGreen)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "dollarsign.circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.green)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(budget.name)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.yaplyPrimary)
                                    Text("\(budget.currency) \(String(format: "%.2f", budget.totalAmount))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.yaplySecondary)
                                }
                                Spacer()
                                if isLinked {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.yaplyAccent)
                                        .font(.system(size: 13, weight: .semibold))
                                }
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

    // MARK: - Row helpers

    @ViewBuilder
    private func linkedAlbumRow(_ album: YaplyAlbum) -> some View {
        HStack(spacing: 10) {
            albumThumb(url: album.coverUrl)
            Text(album.name)
                .font(.system(size: 14))
                .foregroundStyle(Color.yaplyPrimary)
            Spacer()
            Button {
                albumToUnlink = album
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.yaplySecondary.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func linkedBudgetRow(_ budget: YaplyBudget) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yaplyConfirmedGreen)
                    .frame(width: 28, height: 28)
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.green)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(budget.name)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yaplyPrimary)
                Text("\(budget.currency) \(String(format: "%.2f", budget.totalAmount))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.yaplySecondary)
            }
            Spacer()
            Button {
                Task {
                    try? await budgetRepo.unlinkFromEvent(budgetId: budget.id)
                    linkedBudgets.removeAll { $0.id == budget.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.yaplySecondary.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func linkedSection<Items: View, Empty: View>(
        title: String,
        systemImage: String,
        isEmpty: Bool,
        onLink: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Items,
        @ViewBuilder emptyLabel: @escaping () -> Empty
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                Spacer()
                Button("Link", action: onLink)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.yaplyAccent)
            }
            content()
            if isEmpty {
                emptyLabel()
            }
        }
        .padding(16)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func albumThumb(url: String?) -> some View {
        if let urlStr = url, let parsedUrl = URL(string: urlStr) {
            AsyncImage(url: parsedUrl) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                default: albumThumbPlaceholder
                }
            }
        } else {
            albumThumbPlaceholder
        }
    }

    private var albumThumbPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yaplyBackground)
                .frame(width: 28, height: 28)
            Image(systemName: "photo.stack")
                .font(.system(size: 11))
                .foregroundStyle(Color.yaplyAccent)
        }
    }

    private var statusBadge: some View {
        Text(event.isPlanning ? "Planning" : "Confirmed")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(event.isPlanning
                ? Color.yaplyBackground
                : Color.yaplyConfirmedGreen)
            .foregroundStyle(event.isPlanning ? Color.yaplyAccent : .green)
            .clipShape(Capsule())
    }

    private var tallyText: String {
        var parts: [String] = []
        if going.count    > 0 { parts.append("\(going.count) going") }
        if maybe.count    > 0 { parts.append("\(maybe.count) maybe") }
        if notGoing.count > 0 { parts.append("\(notGoing.count) can't go") }
        return parts.joined(separator: " · ")
    }

    private func displayName(_ rsvp: YaplyEventRsvp) -> String {
        if rsvp.userId == currentUserId { return "You" }
        return rsvp.profile?.displayName ?? rsvp.profile?.username ?? "Member"
    }

    private func responseColor(_ response: String) -> Color {
        switch response {
        case "going":     return .green
        case "maybe":     return .orange
        case "not_going": return .red
        default:          return Color.yaplySecondary
        }
    }

    private func responseIcon(_ response: String) -> String {
        switch response {
        case "going":     return "✓"
        case "maybe":     return "?"
        case "not_going": return "✕"
        default:          return "–"
        }
    }

    private func responseLabel(_ response: String) -> String {
        switch response {
        case "going":     return "Going"
        case "maybe":     return "Maybe"
        case "not_going": return "Can't Go"
        default:          return "No response"
        }
    }

    // MARK: - Actions

    private func tap(_ response: String) async {
        let newResponse = myResponse == response ? "pending" : response
        isSaving = true
        if let idx = rsvps.firstIndex(where: { $0.userId == currentUserId }) {
            rsvps[idx].response = newResponse
        } else {
            rsvps.append(YaplyEventRsvp(
                id: UUID(), eventId: event.id, userId: currentUserId,
                response: newResponse, updatedAt: Date(), profile: nil
            ))
        }
        try? await repo.setRsvp(eventId: event.id, userId: currentUserId, response: newResponse)
        isSaving = false
    }

    private func loadConfirmed() async {
        isLoading = true
        async let rsvpFetch   = repo.fetchRsvps(eventId: event.id)
        async let albumFetch  = repo.fetchLinkedAlbums(eventId: event.id)
        async let budgetFetch = repo.fetchLinkedBudgets(eventId: event.id)
        rsvps         = (try? await rsvpFetch)   ?? []
        linkedAlbums  = (try? await albumFetch)  ?? []
        linkedBudgets = (try? await budgetFetch) ?? []
        isLoading = false
    }

    private func loadAllAlbums() async {
        allAlbums = (try? await albumRepo.fetchAlbums(conversationId: event.conversationId)) ?? []
    }

    private func loadAllBudgets() async {
        allBudgets = (try? await budgetRepo.fetchBudgets(conversationId: event.conversationId)) ?? []
    }

    @MainActor
    private func doLockTime() async {
        let end = lockDate.addingTimeInterval(3600)
        try? await repo.confirmEvent(id: event.id, startsAt: lockDate, endsAt: end)
        NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "events"])
        dismiss()
    }
}

// MARK: - RSVP Button

private struct RsvpButton: View {
    let label: String
    let value: String
    let current: String
    let isSaving: Bool
    let onTap: () async -> Void

    private var isActive: Bool { current == value }

    var body: some View {
        Button {
            Task { await onTap() }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? .white : Color.yaplyPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isActive ? activeColor : Color.yaplySurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? activeColor : Color.yaplyBorder))
        }
        .disabled(isSaving)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private var activeColor: Color {
        switch value {
        case "going":     return .green
        case "maybe":     return .orange
        case "not_going": return .red
        default:          return Color.yaplyAccent
        }
    }
}
