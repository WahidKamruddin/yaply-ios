import SwiftUI

struct AvailabilityCalendarView: View {
    let event: YaplyEvent
    let currentUserId: UUID

    private let cellH: CGFloat   = 20
    private let timeW: CGFloat   = 34
    private let startHour        = 8
    private let slotsPerDay      = 28   // 8am–10pm, 30-min slots

    @State private var weekStart: Date
    @State private var mySlots   = Set<String>()
    @State private var allAvail  = [YaplyEventAvailability]()
    @State private var members   = [AvailMember]()
    @State private var isLoading = true
    @State private var isSaving  = false
    @State private var confirmSlot: String? = nil
    @Environment(\.dismiss) private var dismiss

    private let repo = EventRepository()

    init(event: YaplyEvent, currentUserId: UUID) {
        self.event = event
        self.currentUserId = currentUserId
        _weekStart = State(initialValue: Self.startOfWeek(Date()))
    }

    // MARK: - Computed

    private var isCreator: Bool { event.createdBy == currentUserId }
    private var totalMembers: Int { max(1, members.count) }

    private var availMap: [String: Int] {
        allAvail.reduce(into: [:]) { map, av in
            for slot in av.slots { map[slot, default: 0] += 1 }
        }
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

    private func heatColor(_ count: Int) -> Color {
        guard count > 0 else { return Color.yaplyBackground }
        let ratio = Double(count) / Double(totalMembers)
        if ratio <= 0.33 { return Color(red: 0.863, green: 0.906, blue: 0.969) }
        if ratio <= 0.66 { return Color(red: 0.576, green: 0.710, blue: 0.937) }
        return Color(red: 0.357, green: 0.553, blue: 0.937)
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

    private let dayAbbr = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private var confirmSlotMessage: String {
        guard let slot = confirmSlot else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: slot) else { return slot }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
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
        .background(Color.yaplyBackground)
        .task { await loadData() }
        .alert("Confirm this time?", isPresented: Binding(
            get: { confirmSlot != nil },
            set: { if !$0 { confirmSlot = nil } }
        )) {
            Button("Confirm") {
                guard let slot = confirmSlot else { return }
                confirmSlot = nil
                Task { await doConfirm(slot) }
            }
            Button("Cancel", role: .cancel) { confirmSlot = nil }
        } message: {
            Text(confirmSlotMessage)
        }
    }

    // MARK: - Week navigator

    private var weekNavRow: some View {
        HStack {
            Button {
                weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart)!
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.yaplyBorder))
            }
            Spacer()
            Text(weekLabel())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.yaplyPrimary)
            Spacer()
            Button {
                weekStart = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.yaplyBorder))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Day header row

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: timeW)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
                let wd = Calendar.current.component(.weekday, from: day) - 1
                let dayNum = Calendar.current.component(.day, from: day)
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 1) {
                    Text(dayAbbr[wd])
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.yaplySecondary)
                    ZStack {
                        if isToday {
                            Circle()
                                .fill(Color.yaplyAccent)
                                .frame(width: 18, height: 18)
                        }
                        Text("\(dayNum)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isToday ? .white : Color.yaplyPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .background(Color.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Grid rows

    private var gridRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<slotsPerDay, id: \.self) { row in
                HStack(spacing: 0) {
                    // Time label
                    ZStack {
                        if let label = timeLabel(row) {
                            Text(label)
                                .font(.system(size: 8))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                    }
                    .frame(width: timeW, height: cellH)

                    // 7 day cells
                    ForEach(Array(weekDays.enumerated()), id: \.offset) { dayIdx, day in
                        let s = slots(for: day)[row]
                        let count   = availMap[s.key] ?? 0
                        let isMine  = mySlots.contains(s.key)
                        let canConfirm = isCreator && count > 0 && !isMine

                        Rectangle()
                            .fill(isMine
                                  ? Color(red: 0.102, green: 0.153, blue: 0.267)
                                  : heatColor(count))
                            .frame(maxWidth: .infinity)
                            .frame(height: cellH)
                            .overlay(alignment: .trailing) {
                                if dayIdx < 6 {
                                    Rectangle()
                                        .fill(Color.yaplyBorder.opacity(0.4))
                                        .frame(width: 0.5)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.08)) {
                                    if mySlots.contains(s.key) { mySlots.remove(s.key) }
                                    else { mySlots.insert(s.key) }
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.45) {
                                if canConfirm { confirmSlot = s.key }
                            }
                    }
                }
                // Row border: full divider every hour, faint every half-hour
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(row % 2 == 1
                              ? Color.yaplyBorder.opacity(0.6)
                              : Color.yaplyBorder.opacity(0.25))
                        .frame(height: 0.5)
                }
            }
        }
        .background(Color.white)
    }

    // MARK: - Member chips

    private var memberChipsRow: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(members) { member in
                        let slotCount = allAvail.first { $0.userId == member.userId }?.slots.count ?? 0
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.yaplyAccent.opacity(0.12))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Text(member.initials)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.yaplyAccent)
                                )
                            VStack(alignment: .leading, spacing: 0) {
                                Text(member.userId == currentUserId ? "You" : member.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.yaplyPrimary)
                                    .lineLimit(1)
                                Text("\(slotCount) slot\(slotCount == 1 ? "" : "s")")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.yaplySecondary)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yaplyBorder))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(Color.yaplyBackground)
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            Text(isCreator
                 ? "Long-press a shared slot to lock the time"
                 : "Tap cells to mark your availability")
                .font(.system(size: 11))
                .foregroundStyle(Color.yaplySecondary)
            Spacer()
            Button {
                Task { await save() }
            } label: {
                Text(isSaving ? "Saving…" : "Save")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(isSaving ? Color.yaplySecondary : Color.yaplyAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(isSaving)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
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
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = f.date(from: slot) else { return }
        let end = start.addingTimeInterval(3600)
        try? await repo.confirmEvent(id: event.id, startsAt: start, endsAt: end)
        NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "events"])
        dismiss()
    }
}
