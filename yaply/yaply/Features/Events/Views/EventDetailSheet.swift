import SwiftUI

struct EventDetailSheet: View {
    let event: YaplyEvent
    let currentUserId: UUID

    @State private var rsvps: [YaplyEventRsvp] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    private let repo = EventRepository()

    private var myResponse: String {
        rsvps.first { $0.userId == currentUserId }?.response ?? "pending"
    }
    private var going:    [YaplyEventRsvp] { rsvps.filter { $0.response == "going" } }
    private var maybe:    [YaplyEventRsvp] { rsvps.filter { $0.response == "maybe" } }
    private var notGoing: [YaplyEventRsvp] { rsvps.filter { $0.response == "not_going" } }

    var body: some View {
        NavigationStack {
            if event.isPlanning {
                planningView
            } else {
                confirmedView
            }
        }
    }

    // MARK: - Planning mode: compact header + full availability calendar

    private var planningView: some View {
        VStack(spacing: 0) {
            // Compact header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    statusBadge
                    Text(event.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                        .lineLimit(1)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .overlay(alignment: .bottom) { Divider() }

            // Availability calendar fills remaining space
            AvailabilityCalendarView(event: event, currentUserId: currentUserId)
        }
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.yaplyAccent)
            }
        }
    }

    // MARK: - Confirmed mode: RSVP + details

    private var confirmedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        statusBadge
                        Spacer()
                    }
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
                .background(Color.white)
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
                                        .overlay(
                                            Text(responseIcon(rsvp.response))
                                                .font(.system(size: 13))
                                        )
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
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
        .background(Color.yaplyBackground)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.yaplyAccent)
            }
        }
        .task { await loadRsvps() }
    }

    // MARK: - Helpers

    private var statusBadge: some View {
        Text(event.isPlanning ? "Planning" : "Confirmed")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(event.isPlanning
                ? Color(red: 0.929, green: 0.945, blue: 0.980)
                : Color(red: 0.9, green: 0.97, blue: 0.9))
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

    private func loadRsvps() async {
        isLoading = true
        rsvps = (try? await repo.fetchRsvps(eventId: event.id)) ?? []
        isLoading = false
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
                .background(isActive ? activeColor : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? activeColor : Color.yaplyBorder)
                )
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
