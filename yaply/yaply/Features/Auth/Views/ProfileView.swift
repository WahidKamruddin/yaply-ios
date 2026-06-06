import SwiftUI
import PhotosUI

struct ProfileView: View {
    let userId: UUID
    let userEmail: String
    @State private var vm = ProfileViewModel()
    @State private var isEditing = false
    @State private var editName = ""
    @State private var editBio = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var avatarMime = "image/jpeg"
    @State private var avatarPreview: UIImage?
    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Avatar + name
                        VStack(spacing: 12) {
                            ZStack(alignment: .bottomTrailing) {
                                Group {
                                    if let preview = avatarPreview {
                                        Image(uiImage: preview)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        AvatarView(
                                            url: vm.profile?.avatarUrl,
                                            name: vm.profile?.name ?? "You",
                                            size: 80
                                        )
                                    }
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())

                                if isEditing {
                                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                                        ZStack {
                                            Circle().fill(Color.yaplyAccent)
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(.white)
                                        }
                                        .frame(width: 28, height: 28)
                                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
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
                            }

                            if isEditing {
                                TextField("Display name", text: $editName)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(Color.yaplyPrimary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 8)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .padding(.horizontal, 32)
                            } else {
                                VStack(spacing: 4) {
                                    Text(vm.profile?.name ?? "—")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(Color.yaplyPrimary)

                                    if let username = vm.profile?.username {
                                        Text("@\(username)")
                                            .font(.subheadline)
                                            .foregroundStyle(Color.yaplySecondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 32)
                        .padding(.bottom, 24)

                        // Info rows
                        VStack(spacing: 0) {
                            infoRow(icon: "envelope", value: userEmail)
                            Divider().padding(.leading, 52)

                            if isEditing {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "text.alignleft")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.yaplySecondary)
                                        .frame(width: 24)
                                        .padding(.top, 1)
                                    TextField("Add a bio…", text: $editBio, axis: .vertical)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.yaplyPrimary)
                                        .lineLimit(3...6)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            } else if let bio = vm.profile?.bio, !bio.isEmpty {
                                infoRow(icon: "text.alignleft", value: bio)
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)

                        // Action buttons
                        if isEditing {
                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    cancelEditing()
                                }
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.yaplyBackground)
                                .foregroundStyle(Color.yaplySecondary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))

                                Button {
                                    Task {
                                        await vm.saveWithAvatar(
                                            displayName: editName,
                                            bio: editBio,
                                            avatarData: avatarData,
                                            avatarMime: avatarMime,
                                            userId: userId
                                        )
                                        if vm.saveError == nil { isEditing = false }
                                    }
                                } label: {
                                    Group {
                                        if vm.isSaving {
                                            ProgressView().tint(.white)
                                        } else {
                                            Text("Save")
                                                .font(.system(size: 15, weight: .semibold))
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.yaplyAccent)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .disabled(vm.isSaving)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        } else {
                            VStack(spacing: 12) {
                                Button {
                                    startEditing()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "pencil")
                                        Text("Edit Profile").fontWeight(.medium)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.yaplyBackground)
                                    .foregroundStyle(Color.yaplyAccent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    Task {
                                        try? await authService.signOut()
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "rectangle.portrait.and.arrow.right")
                                        Text("Sign Out").fontWeight(.medium)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.red.opacity(0.08))
                                    .foregroundStyle(Color.red)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Cancel") { cancelEditing() }
                            .foregroundStyle(Color.yaplySecondary)
                    } else {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.yaplyAccent)
                    }
                }
            }
        }
        .task { await vm.load(userId: userId) }
        .alert("Save failed", isPresented: Binding(
            get: { vm.saveError != nil },
            set: { if !$0 { vm.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.saveError ?? "")
        }
    }

    private func startEditing() {
        editName = vm.profile?.displayName ?? vm.profile?.username ?? ""
        editBio = vm.profile?.bio ?? ""
        avatarData = nil
        avatarPreview = nil
        photoItem = nil
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        avatarData = nil
        avatarPreview = nil
        photoItem = nil
    }

    private func infoRow(icon: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.yaplySecondary)
                .frame(width: 24)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.yaplyTertiary)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
