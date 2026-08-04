import Foundation
import Supabase
import Auth
import Storage

@Observable
final class AccountSettingsViewModel {
    private(set) var profile: Profile?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var saveError: String?
    var saved = false

    private(set) var hasEmailAuth = false

    private(set) var isChangingPassword = false
    var passwordError: String?
    var passwordSaved = false

    private(set) var isDeleting = false
    var deleteError: String?

    private(set) var usernameAvailability: UsernameAvailability = .idle
    private var usernameCheckTask: Task<Void, Never>?

    /// Debounced pre-save availability check — mirrors the web app's
    /// useUsernameAvailability hook. Called from the view's `.onChange` on the
    /// username field; `excluding: userId` lets re-saving your own unchanged
    /// username read as available instead of taken.
    func checkUsernameAvailability(_ raw: String, userId: UUID) {
        usernameCheckTask?.cancel()
        let candidate = UsernameAvailabilityChecker.normalize(raw)

        guard !candidate.isEmpty else {
            usernameAvailability = .idle
            return
        }
        guard UsernameAvailabilityChecker.isFormatValid(candidate) else {
            usernameAvailability = .invalid
            return
        }

        usernameAvailability = .checking
        usernameCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let available = try await UsernameAvailabilityChecker.isAvailable(candidate, excluding: userId)
                guard !Task.isCancelled else { return }
                usernameAvailability = available ? .available : .taken
            } catch {
                guard !Task.isCancelled else { return }
                usernameAvailability = .idle
            }
        }
    }

    func load(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
        } catch {
            // non-fatal — screen shows fallback state
        }

        if let user = try? await supabase.auth.user() {
            hasEmailAuth = (user.identities ?? []).contains { $0.provider == "email" }
        }
    }

    func updateAvatar(imageData: Data, mimeType: String, userId: UUID) async -> String? {
        let ext = mimeType.contains("png") ? "png" : "jpg"
        let path = "\(userId.uuidString)/avatar.\(ext)"
        do {
            try await supabase.storage
                .from("avatars")
                .upload(path, data: imageData, options: .init(contentType: mimeType, upsert: true))
            let url = try supabase.storage.from("avatars").getPublicURL(path: path)
            return "\(url.absoluteString)?t=\(Int(Date().timeIntervalSince1970))"
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    func save(
        displayName: String,
        username: String,
        bio: String,
        birthdate: Date?,
        avatarData: Data?,
        avatarMime: String,
        userId: UUID
    ) async {
        saveError = nil
        saved = false

        let normalizedUsername = UsernameAvailabilityChecker.normalize(username)

        // The debounced availability check (surfaced next to the field) is
        // the pre-save guard; re-check here in case Save is tapped before it
        // settles.
        guard usernameAvailability != .invalid else {
            saveError = "Username must be at least 3 characters, using only lowercase letters, numbers, underscores, dots, and hyphens."
            return
        }
        guard usernameAvailability == .available else {
            saveError = "That username is taken."
            return
        }

        isSaving = true
        defer { isSaving = false }

        var avatarUrl: String? = profile?.avatarUrl
        if let data = avatarData {
            avatarUrl = await updateAvatar(imageData: data, mimeType: avatarMime, userId: userId)
        }

        struct ProfileUpdate: Encodable {
            let display_name: String?
            let username: String
            let bio: String?
            let birthdate: String?
            let avatar_url: String?
            let updated_at: String
        }

        let birthdateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()

        do {
            try await supabase
                .from("profiles")
                .update(ProfileUpdate(
                    display_name: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : displayName.trimmingCharacters(in: .whitespaces),
                    username: normalizedUsername,
                    bio: bio.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bio.trimmingCharacters(in: .whitespaces),
                    birthdate: birthdate.map { birthdateFormatter.string(from: $0) },
                    avatar_url: avatarUrl,
                    updated_at: Date().iso8601
                ))
                .eq("id", value: userId.uuidString)
                .execute()

            await load(userId: userId)
            saved = true
        } catch {
            // Last-resort guard against a race where someone else claimed the
            // name between the availability check and this write — the DB's
            // unique constraint is the actual source of truth.
            let message = error.localizedDescription
            saveError = message.contains("23505") ? "That username is taken." : message
        }
    }

    func changePassword(new: String, confirm: String) async {
        passwordError = nil
        passwordSaved = false

        guard new.count >= 6 else {
            passwordError = "Password must be at least 6 characters."
            return
        }
        guard new == confirm else {
            passwordError = "Passwords do not match."
            return
        }

        isChangingPassword = true
        defer { isChangingPassword = false }
        do {
            _ = try await supabase.auth.update(user: UserAttributes(password: new))
            passwordSaved = true
        } catch {
            passwordError = error.localizedDescription
        }
    }

    func deleteAccount() async -> Bool {
        deleteError = nil
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await supabase.functions.invoke("delete-account")
            return true
        } catch {
            deleteError = error.localizedDescription
            return false
        }
    }
}
