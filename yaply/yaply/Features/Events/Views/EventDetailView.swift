import SwiftUI
import Kingfisher

struct EventDetailView: View {
    let event: YaplyEvent
    let currentUserId: UUID

    @Environment(\.displayScale) private var displayScale

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
            VStack(alignment: .leading, spacing: 6) {
                statusBadge
                Text(event.name)
                    .font(.chatDisplay(20))
                    .foregroundStyle(Color.yaplyPrimary)
                    .lineLimit(2)
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

            AvailabilityCalendarView(
                event: event,
                currentUserId: currentUserId,
                onPickTime: isCreator ? { activeSheet = .lockTime } : nil
            )
        }
        .background(Color.yaplyBackground)
        .navigationTitle("Plan")
        .navChrome()
    }

    // MARK: - Confirmed mode

    private var confirmedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Event card (landing page `.lp-event`)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(event.name)
                            .font(.chatDisplay(22))
                            .foregroundStyle(Color.yaplyPrimary)
                        Spacer(minLength: 0)
                        statusBadge
                    }
                    if let desc = event.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.yaplyTertiary)
                            .padding(.top, 6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let starts = event.startsAt {
                            Label(
                                starts.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                                systemImage: "calendar"
                            )
                        }
                        if let loc = event.location, !loc.isEmpty {
                            Label(loc, systemImage: "mappin")
                        }
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.yaplyTertiary)
                    .labelStyle(PlanMetaLabelStyle())
                    .padding(.top, 10)

                    if isLoading {
                        ProgressView().tint(Color.yaplyAccent).padding(.top, 16)
                    } else {
                        HStack(spacing: 8) {
                            RsvpButton(label: "Going", value: "going",     count: going.count,    current: myResponse, isSaving: isSaving) { await tap("going") }
                            RsvpButton(label: "Maybe", value: "maybe",     count: maybe.count,    current: myResponse, isSaving: isSaving) { await tap("maybe") }
                            RsvpButton(label: "Can’t", value: "not_going", count: notGoing.count, current: myResponse, isSaving: isSaving) { await tap("not_going") }
                        }
                        .padding(.top, 16)

                        HStack(spacing: 12) {
                            if !going.isEmpty {
                                PlanStackedFaces(people: going.map { (id: $0.userId, name: displayName($0), avatarUrl: $0.profile?.avatarUrl) })
                            }
                            Text(goingNote)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                        .frame(minHeight: 28)
                        .padding(.top, 16)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yaplyTint, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder, lineWidth: 1))

                // Who responded
                if !isLoading && !rsvps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RESPONSES")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color.yaplySecondary)
                        ForEach(rsvps) { rsvp in
                            HStack(spacing: 10) {
                                AvatarView(url: rsvp.profile?.avatarUrl, name: displayName(rsvp), size: 30)
                                Text(displayName(rsvp))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.yaplyPrimary)
                                Spacer()
                                Text(responseLabel(rsvp.response))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(responseColor(rsvp.response))
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.yaplyTint, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder, lineWidth: 1))
                }

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
        .navChrome()
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
                                    Text(budget.totalAmount.map { BudgetMoney.format($0, currency: budget.currency) } ?? "\(budget.currency) · no cap")
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
                Text(budget.totalAmount.map { BudgetMoney.format($0, currency: budget.currency) } ?? "\(budget.currency) · no cap")
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
            KFImage(parsedUrl)
                .downsampling(size: CGSize(width: 28 * displayScale, height: 28 * displayScale))
                .backgroundDecode()
                .placeholder { albumThumbPlaceholder }
                .onFailureView { albumThumbPlaceholder }
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
        PlanBadge(text: event.isPlanning ? "Planning" : "Confirmed")
    }

    private var goingNote: String {
        if going.isEmpty { return "No one’s said they’re going yet" }
        return "\(going.count) going"
    }

    private func displayName(_ rsvp: YaplyEventRsvp) -> String {
        if rsvp.userId == currentUserId { return "You" }
        return rsvp.profile?.displayName ?? rsvp.profile?.username ?? "Member"
    }

    private func responseColor(_ response: String) -> Color {
        switch response {
        case "going":     return PlanStyle.sky
        case "maybe":     return .orange
        default:          return Color.yaplySecondary
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
    let count: Int
    let current: String
    let isSaving: Bool
    let onTap: () async -> Void

    private var isActive: Bool { current == value }

    var body: some View {
        Button {
            Task { await onTap() }
        } label: {
            Text("\(label) · \(count)")
        }
        .buttonStyle(PlanPillStyle(primary: isActive, fill: true))
        .disabled(isSaving)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// Tinted icon + text, like the landing card's meta row.
private struct PlanMetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PlanStyle.sky)
            configuration.title
        }
    }
}
