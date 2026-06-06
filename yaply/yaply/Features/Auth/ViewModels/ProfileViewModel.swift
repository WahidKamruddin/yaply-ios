import Foundation
import Supabase
import Storage

@Observable
final class ProfileViewModel {
    private(set) var profile: Profile?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var saveError: String?

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
            // non-fatal — bottom bar shows fallback initials
        }
    }

    func save(displayName: String, bio: String, userId: UUID) async {
        isSaving = true
        defer { isSaving = false }
        do {
            struct ProfileUpdate: Encodable {
                let display_name: String?
                let bio: String?
                let updated_at: String
            }
            try await supabase
                .from("profiles")
                .update(ProfileUpdate(
                    display_name: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : displayName.trimmingCharacters(in: .whitespaces),
                    bio: bio.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bio.trimmingCharacters(in: .whitespaces),
                    updated_at: Date().iso8601
                ))
                .eq("id", value: userId.uuidString)
                .execute()

            await load(userId: userId)
        } catch {
            saveError = error.localizedDescription
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
            // Cache bust so the UI picks up the new image
            return "\(url.absoluteString)?t=\(Int(Date().timeIntervalSince1970))"
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    func saveWithAvatar(displayName: String, bio: String, avatarData: Data?, avatarMime: String, userId: UUID) async {
        isSaving = true
        defer { isSaving = false }

        var avatarUrl: String? = profile?.avatarUrl

        if let data = avatarData {
            avatarUrl = await updateAvatar(imageData: data, mimeType: avatarMime, userId: userId)
        }

        do {
            struct ProfileUpdate: Encodable {
                let display_name: String?
                let bio: String?
                let avatar_url: String?
                let updated_at: String
            }
            try await supabase
                .from("profiles")
                .update(ProfileUpdate(
                    display_name: displayName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : displayName.trimmingCharacters(in: .whitespaces),
                    bio: bio.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bio.trimmingCharacters(in: .whitespaces),
                    avatar_url: avatarUrl,
                    updated_at: Date().iso8601
                ))
                .eq("id", value: userId.uuidString)
                .execute()

            await load(userId: userId)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
