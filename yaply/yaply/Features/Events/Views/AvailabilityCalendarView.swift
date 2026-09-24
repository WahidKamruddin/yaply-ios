import SwiftUI

struct AvailabilityCalendarView: View {
    let event: YaplyEvent
    let currentUserId: UUID
    /// Opens the free-form date/time picker (owned by `EventDetailView`).
    var onPickTime: (() -> Void)? = nil

    private let cellH: CGFloat   = 22
    private let timeW: CGFloat   = 30
    private let gap: CGFloat     = 3
    private let startHour        = 8
    private let slotsPerDay      = 28   // 8am–10pm, 30-min slots

    @State private var weekStart: Date
    @State private var mySlots   = Set<String>()
    @State private var allAvail  = [YaplyEventAvailability]()
    @State private var members   = [AvailMember]()
    @State private var isLoading = true
    @State private var isSaving  = false
    @State private var confirmSlot: String? = nil
    @State private var focusedMember: UUID? = nil
    @State private var cellsIn = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let repo = EventRepository()

    init(event: YaplyEvent, currentUserId: UUID, onPickTime: (() -> Void)? = nil) {
        self.event = event
        self.currentUserId = currentUserId
        self.onPickTime = onPickTime
        _weekStart = State(initialValue: Self.startOfWeek(Date()))
    }

    // MARK: - Computed

    private var isCreator: Bool { event.createdBy == currentUserId }
    private var totalMembers: Int { max(1, members.count) }

    /// Who (other than me) saved each slot. My own contribution comes from the
    /// live `mySlots` selection so the heatmap reacts before Save.
    private var othersBySlot: [String: Set<UUID>] {
        allAvail.reduce(into: [:]) { map, av in
            guard av.userId != currentUserId else { return }
            for slot in av.slots { map[slot, default: []].insert(av.userId) }
        }
    }

    private var best: (slot: String, count: Int)? {
        BestSlot.find(BestSlot.liveCounts(availability: allAvail, currentUserId: currentUserId, mySlots: mySlots))
    }

    private var weekDays: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    private func slots(for day: Date) -> [(date: Date, key: String)] {
        let cal = Calendar.current
        let base = cal.dateComponents([.year, .month, .day], from: day)
        return (0..<slotsPerDay).map { i in
            var c = base
            c.hour   = startHour + i / 2
            c.minute = (i % 2) * 30
            c.second = 0
            let d = cal.date(from: c)!
            return (date: d, key: Self.slotKey(d))
        }
    }

    private func timeLabel(_ row: Int) -> String? {
        guard row % 2 == 0 else { return nil }
        let h = startHour + row / 2
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }

    private static func slotKey(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func slotDate(_ key: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: key)
    }

    private static func startOfWeek(_ date: Date) -> Date {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: date)  // 1 = Sunday
        let sun = cal.date(byAdding: .day, value: -(wd - 1), to: date)!
        return cal.startOfDay(for: sun)
    }

    private func weekLabel() -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: weekStart)) – \(fmt.string(from: end))"
    }

    private let dayAbbr = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var confirmSlotMessage: String {
        guard let slot = confirmSlot, let d = Self.slotDate(slot) else { return "" }
        return "Set \"\(event.name)\" for \(d.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))? This moves the event from Planning to Confirmed."
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            weekNavRow

            if isLoading {
                Spacer()
                ProgressView().tint(Color.yaplyAccent)
                Spacer()
            } else {
                dayHeaderRow
                ScrollView(.vertical, showsIndicators: false) {
                    gridRows
                }
                memberChipsRow
            }

            footerRow
        }
        .background(Color.yaplyCard)
        .task { await loadData() }
        .yaplyConfirm(
            isPresented: Binding(get: { confirmSlot != nil }, set: { if !$0 { confirmSlot = nil } }),
            title: "Lock event time?",
            message: confirmSlotMessage,
            icon: "calendar.badge.checkmark",
            confirmLabel: "Confirm",
            isDestructive: false
        ) {
            guard let slot = confirmSlot else { return }
            confirmSlot = nil
            Task { await doConfirm(slot) }
        }
    }

    // MARK: - Week navigator

    private var weekNavRow: some View {
        HStack(alignment: .center) {
            PlanRoundButton(systemImage: "chevron.left", label: "Previous week") {
                weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart)!
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                Text(weekLabel())
                    .font(.display(15, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                if let best, let date = Self.slotDate(best.slot) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { weekStart = Self.startOfWeek(date) }
                    } label: {
                        PlanBadge(
                            text: "Best: \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(best.count)/\(totalMembers) free",
                            uppercase: false,
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Jumps to the best time")
                }
            }
            Spacer(minLength: 8)
            PlanRoundButton(systemImage: "chevron.right", label: "Next week") {
                weekStart = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.yaplyBorder).frame(height: 1) }
    }

    // MARK: - Day header row

    private var dayHeaderRow: some View {
        HStack(spacing: gap) {
            Spacer().frame(width: timeW)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
                let wd = Calendar.current.component(.weekday, from: day) - 1
                let dayNum = Calendar.current.component(.day, from: day)
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(dayAbbr[wd].uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.yaplySecondary)
                    Text("\(dayNum)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isToday ? .white : Color.yaplyPrimary)
                        .frame(width: 24, height: 24)
                        .background { if isToday { Circle().fill(PlanStyle.gradient) } }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Grid rows

    private var gridRows: some View {
        let others = othersBySlot
        let bestKey = best?.slot
        let days = weekDays.map { slots(for: $0) }

        return VStack(spacing: gap) {
            ForEach(0..<slotsPerDay, id: \.self) { row in
                HStack(spacing: gap) {
                    Text(timeLabel(row) ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(width: timeW, height: cellH, alignment: .trailing)
                        .padding(.trailing, 2)

                    ForEach(0..<days.count, id: \.self) { dayIdx in
                        let s = days[dayIdx][row]
                        let isMine = mySlots.contains(s.key)
                        let othersHere = others[s.key] ?? []
                        let count = othersHere.count + (isMine ? 1 : 0)
                        let isBest = s.key == bestKey
                        let dimmed: Bool = {
                            guard let m = focusedMember else { return false }
                            return m == currentUserId ? !isMine : !othersHere.contains(m)
                        }()

                        RoundedRectangle(cornerRadius: 6)
                            .fill(PlanStyle.heatFill(BestSlot.level(count: count, total: totalMembers)))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isMine ? PlanStyle.sky : Color.yaplyBorderSoft, lineWidth: isMine ? 2 : 1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: cellH)
                            .planBestGlow(isBest)
                            .opacity(dimmed ? 0.2 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if mySlots.contains(s.key) { mySlots.remove(s.key) }
                                    else { mySlots.insert(s.key) }
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.45) {
                                if isCreator && count > 0 { confirmSlot = s.key }
                            }
                            .accessibilityElement()
                            .accessibilityLabel("\(s.date.formatted(.dateTime.weekday(.wide).hour().minute())), \(count) of \(totalMembers) free\(isBest ? ", best time" : "")")
                            .accessibilityAddTraits(isMine ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.top, row > 0 && row % 2 == 0 ? 3 : 0)
                .opacity(cellsIn ? 1 : 0)
                .scaleEffect(cellsIn ? 1 : 0.92)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(row) * 0.014),
                    value: cellsIn
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .onAppear { cellsIn = true }
    }

    // MARK: - Member chips

    private var memberChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(members) { member in
                    let slotCount = allAvail.first { $0.userId == member.userId }?.slots.count ?? 0
                    let active = focusedMember == member.userId
                    let name = member.userId == currentUserId ? "You" : member.name
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            focusedMember = active ? nil : member.userId
                        }
                    } label: {
                        HStack(spacing: 6) {
                            AvatarView(url: member.avatarUrl, name: member.name, size: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.yaplyPrimary)
                                    .lineLimit(1)
                                Text("\(slotCount) slot\(slotCount == 1 ? "" : "s")")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.yaplySecondary)
                            }
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 11)
                        .padding(.vertical, 3)
                        .background(active ? Color.yaplyAccent.opacity(0.12) : Color.yaplyTint, in: Capsule())
                        .overlay(Capsule().stroke(active ? Color.yaplyAccent.opacity(0.4) : Color.yaplyBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Highlights the times \(name) is free")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.yaplyBorder).frame(height: 1) }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 10) {
            if isCreator {
                Button {
                    if let best { confirmSlot = best.slot }
                } label: {
                    Label("Lock best time", systemImage: "lock.fill")
                }
                .buttonStyle(PlanPillStyle(primary: true))
                .disabled(best == nil)

                if let onPickTime {
                    Button("Other time", action: onPickTime)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PlanStyle.sky)
                }
            } else {
                Text("tap the times you’re free — the best slot lights up")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.yaplySecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                Task { await save() }
            } label: {
                Text(isSaving ? "Saving…" : "Save")
            }
            .buttonStyle(PlanPillStyle(primary: true))
            .disabled(isSaving)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.yaplySurface)
        .overlay(alignment: .top) { Rectangle().fill(Color.yaplyBorder).frame(height: 1) }
    }

    // MARK: - Actions

    private func loadData() async {
        isLoading = true
        async let availFetch  = repo.fetchAvailability(eventId: event.id)
        async let memberFetch = repo.fetchEventMembers(conversationId: event.conversationId)

        allAvail = (try? await availFetch) ?? []
        members  = (try? await memberFetch) ?? []

        if let mine = allAvail.first(where: { $0.userId == currentUserId }) {
            mySlots = Set(mine.slots)
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        try? await repo.setAvailability(
            eventId: event.id,
            userId: currentUserId,
            slots: Array(mySlots)
        )
        allAvail = (try? await repo.fetchAvailability(eventId: event.id)) ?? allAvail
        isSaving = false
    }

    @MainActor
    private func doConfirm(_ slot: String) async {
        guard let start = Self.slotDate(slot) else { return }
        let end = start.addingTimeInterval(3600)
        try? await repo.confirmEvent(id: event.id, startsAt: start, endsAt: end)
        NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "events"])
        dismiss()
    }
}
