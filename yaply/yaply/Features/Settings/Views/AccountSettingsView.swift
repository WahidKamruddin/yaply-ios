import SwiftUI
import PhotosUI

struct AccountSettingsView: View {
    let userId: UUID
    let userEmail: String

    @State private var vm = AccountSettingsViewModel()
    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var birthdate: Date?
    @State private var showBirthdatePicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var avatarMime = "image/jpeg"
    @State private var avatarPreview: UIImage?

    @State private var newPassword = ""
    @State private var confirmPassword = ""

    @State private var deleteConfirmText = ""
    @State private var showDeleteDialog = false

    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @Environment(AuthService.self) private var authService
    @Environment(AppRouter.self) private var router

    private var age: Int? {
        guard let birthdate else { return nil }
        return Calendar.current.dateComponents([.year], from: birthdate, to: Date()).year
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            avatarSection
            fieldsSection

            if let error = vm.saveError {
                Text(error).font(.subheadline).foregroundStyle(Color.yaplyDanger)
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        await vm.save(
                            displayName: displayName, username: username, bio: bio,
                            birthdate: birthdate, avatarData: avatarData, avatarMime: avatarMime,
                            userId: userId
                        )
                        if vm.saveError == nil {
                            avatarData = nil
                            avatarPreview = nil
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if vm.isSaving { ProgressView().tint(.white) } else {
                            Image(systemName: "checkmark")
                            Text("Save changes")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.yaplyAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(
                    vm.isSaving
                        || vm.usernameAvailability == .checking
                        || vm.usernameAvailability == .taken
                        || vm.usernameAvailability == .invalid
                )

                if vm.saved {
                    Text("Saved").font(.subheadline).foregroundStyle(Color.yaplyMint)
                }
            }

            appearanceSection

            if vm.hasEmailAuth {
                passwordSection
            }

            dangerZone

            signOutButton
        }
        .task { await load() }
        .alert("Delete your account?", isPresented: $showDeleteDialog) {
            TextField("Type DELETE to confirm", text: $deleteConfirmText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { deleteConfirmText = "" }
            Button("Delete account", role: .destructive) {
                guard deleteConfirmText == "DELETE" else { return }
                Task {
                    if await vm.deleteAccount() {
                        try? await authService.signOut()
                    }
                    deleteConfirmText = ""
                }
            }
            .disabled(deleteConfirmText != "DELETE")
        } message: {
            Text("This permanently deletes your profile, messages, and memberships across every conversation. This cannot be undone.")
        }
        .sheet(isPresented: $showBirthdatePicker) {
            NavigationStack {
                DatePicker(
                    "Birthdate",
                    selection: Binding(get: { birthdate ?? Date() }, set: { birthdate = $0 }),
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Birthdate")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showBirthdatePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func load() async {
        await vm.load(userId: userId)
        displayName = vm.profile?.displayName ?? ""
        username = vm.profile?.username ?? ""
        bio = vm.profile?.bio ?? ""
        birthdate = vm.profile?.birthdate
    }

    private var avatarSection: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let preview = avatarPreview {
                        Image(uiImage: preview).resizable().scaledToFill()
                    } else {
                        AvatarView(url: vm.profile?.avatarUrl, name: displayName.isEmpty ? "You" : displayName, size: 64)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())

                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    ZStack {
                        Circle().fill(Color.yaplyAccent)
                        Image(systemName: "camera.fill").font(.system(size: 11)).foregroundStyle(.white)
                    }
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.yaplyBackground, lineWidth: 2))
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let original = UIImage(data: data) {
                            let resized = original.resized(maxDimension: 512)
                            let compressed = resized.jpegData(compressionQuality: 0.8) ?? data
                            avatarData = compressed
                            avatarMime = "image/jpeg"
                            avatarPreview = resized
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.isEmpty ? (vm.profile?.username ?? "You") : displayName)
                    .font(.display(15, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                Text(userEmail)
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
            }
        }
    }

    private var fieldsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                labeledField("Name") {
                    TextField("Your name", text: $displayName)
                        .settingsFieldStyle()
                }
                labeledField("Username") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            Text("@").foregroundStyle(Color.yaplySecondary)
                            TextField("username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: username) { _, newValue in
                                    vm.checkUsernameAvailability(newValue, userId: userId)
                                }
                            usernameAvailabilityIcon
                        }
                        .settingsFieldStyle()
                        if vm.usernameAvailability == .taken {
                            Text("That username is taken.")
                                .font(.caption2)
                                .foregroundStyle(Color.yaplyDanger)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                labeledField(age.map { "Birthdate · \($0) years old" } ?? "Birthdate") {
                    Button { showBirthdatePicker = true } label: {
                        HStack {
                            Text(birthdate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Select date")
                                .foregroundStyle(birthdate == nil ? Color.yaplySecondary : Color.yaplyPrimary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .settingsFieldStyle()
                }
                labeledField("Bio") {
                    TextField("Add a bio…", text: $bio)
                        .settingsFieldStyle()
                }
            }
        }
    }

    @ViewBuilder
    private var usernameAvailabilityIcon: some View {
        switch vm.usernameAvailability {
        case .checking:
            ProgressView().controlSize(.mini)
        case .available:
            Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.yaplyMint)
        case .taken:
            Image(systemName: "xmark").font(.caption).foregroundStyle(Color.yaplyDanger)
        case .idle, .invalid:
            EmptyView()
        }
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Color.yaplySecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance").font(.caption).foregroundStyle(Color.yaplySecondary)
            Picker("Appearance", selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(Color.yaplySecondary)
                Text("Change password").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
            }
            HStack(spacing: 12) {
                labeledField("New password") {
                    SecureField("", text: $newPassword).settingsFieldStyle()
                }
                labeledField("Confirm password") {
                    SecureField("", text: $confirmPassword).settingsFieldStyle()
                }
            }
            if let error = vm.passwordError {
                Text(error).font(.caption).foregroundStyle(Color.yaplyDanger)
            }
            HStack(spacing: 12) {
                Button {
                    Task {
                        await vm.changePassword(new: newPassword, confirm: confirmPassword)
                        if vm.passwordError == nil {
                            newPassword = ""
                            confirmPassword = ""
                        }
                    }
                } label: {
                    Text(vm.isChangingPassword ? "Updating…" : "Update password")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(Color.yaplyAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(vm.isChangingPassword || newPassword.isEmpty || confirmPassword.isEmpty)

                if vm.passwordSaved {
                    Text("Password updated").font(.caption).foregroundStyle(Color.yaplyMint)
                }
            }
        }
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Color.yaplyDanger)
                Text("Danger zone").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete account").font(.subheadline).fontWeight(.medium).foregroundStyle(Color.yaplyPrimary)
                    Text("Permanently deletes your profile, messages, and conversation memberships. This cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary)
                }
                Spacer()
                Button {
                    showDeleteDialog = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.yaplyDanger)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.yaplyDanger.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yaplyDanger.opacity(0.3)))
            if let error = vm.deleteError {
                Text(error).font(.caption).foregroundStyle(Color.yaplyDanger)
            }
        }
    }

    private var signOutButton: some View {
        Button {
            Task {
                try? await authService.signOut()
                router.path = .init()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Sign Out").fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(Color.yaplyDanger)
            .background(Color.yaplyDanger.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func settingsFieldStyle() -> some View {
        self
            .font(.system(size: 14))
            .foregroundStyle(Color.yaplyPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.yaplyTint)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
    }
}
