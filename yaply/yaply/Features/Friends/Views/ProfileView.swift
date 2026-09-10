import SwiftUI

// The one shared profile card in the app — opened from ChatView's header
// avatar (direct conversations) and every UserRowView tap in FriendsView.
// Shows public fields only: never email or account data.
struct ProfileView: View {
    let userId: UUID
    let viewerId: UUID

    @State private var vm = ProfileCardViewModel()
    @State private var showUnfriendConfirm = false
    @State private var showBlockConfirm = false
    @State private var navigateToConversationId: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()

                if vm.isLoading && vm.profile == nil {
                    ProgressView().tint(Color.yaplyAccent)
                } else if let profile = vm.profile {
                    ScrollView {
                        VStack(spacing: 20) {
                            AvatarView(url: profile.avatarUrl, name: profile.name, size: 96)
                                .padding(.top, 16)

                            VStack(spacing: 4) {
                                Text(profile.name)
                                    .font(.display(22, weight: .semibold))
                                    .foregroundStyle(Color.yaplyPrimary)
                                Text("@\(profile.username)")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.yaplySecondary)
                                HStack(spacing: 5) {
                                    PresenceDotView(isOnline: profile.isOnline, borderColor: .yaplyBackground, size: 8)
                                    Text(profile.isOnline ? "Online" : "Offline")
                                        .font(.caption)
                                        .foregroundStyle(Color.yaplySecondary)
                                }
                            }

                            if let bio = profile.bio, !bio.isEmpty {
                                Text(bio)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.yaplyPrimary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }

                            if let mutual = vm.relationship?.mutualFriends, mutual > 0 {
                                Text("\(mutual) mutual friend\(mutual == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(Color.yaplySecondary)
                            }

                            actionArea
                                .padding(.horizontal, 24)
                                .padding(.top, 8)

                            Spacer(minLength: 20)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Text("Couldn't load this profile.")
                        .foregroundStyle(Color.yaplySecondary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
            .task { await vm.load(userId: userId, viewerId: viewerId) }
            .yaplyConfirm(
                isPresented: $showUnfriendConfirm,
                title: "Remove friend",
                message: "Remove \(vm.profile?.name ?? "this person") from your friends?",
                icon: "person.badge.minus",
                confirmLabel: "Remove"
            ) {
                Task { await vm.removeFriendship(viewerId: viewerId) }
            }
            .yaplyConfirm(
                isPresented: $showBlockConfirm,
                title: "Block user",
                message: "\(vm.profile?.name ?? "This person") won't be able to message you or see your profile.",
                icon: "hand.raised.fill",
                confirmLabel: "Block"
            ) {
                Task { await vm.block(viewerId: viewerId) }
            }
            .yaplyAlert(
                isPresented: Binding(get: { vm.actionError != nil }, set: { if !$0 { vm.actionError = nil } }),
                title: "Something went wrong",
                message: vm.actionError ?? ""
            )
            .onChange(of: navigateToConversationId) { _, id in
                guard let id else { return }
                dismiss()
                router.push(.conversation(id: id))
            }
        }
    }

    // blockedBy renders identically to `none` — never reveal a block to the
    // blocked party.
    @ViewBuilder
    private var actionArea: some View {
        switch vm.relationship?.status ?? .none {
        case .none, .blockedBy:
            FullWidthButton(title: "Add Friend", style: .primary) {
                Task { await vm.sendFriendRequest(viewerId: viewerId) }
            }
        case .pendingOut:
            FullWidthButton(title: "Requested", style: .disabled) {}
        case .pendingIn:
            VStack(spacing: 8) {
                FullWidthButton(title: "Accept Request", style: .primary) {
                    Task { await vm.acceptFriendRequest(viewerId: viewerId) }
                }
                FullWidthButton(title: "Decline", style: .secondary) {
                    Task { await vm.removeFriendship(viewerId: viewerId) }
                }
            }
        case .friends:
            VStack(spacing: 8) {
                FullWidthButton(title: "Message", style: .primary) {
                    Task { navigateToConversationId = await vm.startConversation(viewerId: viewerId) }
                }
                Menu {
                    Button(role: .destructive) { showUnfriendConfirm = true } label: {
                        Label("Remove Friend", systemImage: "person.badge.minus")
                    }
                    Button(role: .destructive) { showBlockConfirm = true } label: {
                        Label("Block", systemImage: "hand.raised")
                    }
                } label: {
                    FullWidthButton(title: "More", style: .secondary) {}
                }
            }
        case .blocked:
            FullWidthButton(title: "Unblock", style: .secondary) {
                Task { await vm.unblock(viewerId: viewerId) }
            }
        }
    }
}

private struct FullWidthButton: View {
    let title: String
    var style: Style = .primary
    let action: () -> Void

    enum Style { case primary, secondary, disabled }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(style == .disabled)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .yaplyAccent
        case .disabled: return .yaplySecondary
        }
    }

    private var background: Color {
        switch style {
        case .primary: return .yaplyAccent
        case .secondary: return .yaplyAccent.opacity(0.12)
        case .disabled: return .yaplyBorder
        }
    }
}
