import Foundation
import Supabase
import Storage

// Mirrors src/features/media/api/upload.ts — uploads to Supabase Storage `media` bucket
final class MediaUploadService {

    func uploadImage(_ data: Data, mimeType: String = "image/jpeg", ext: String = "jpg", userId: UUID) async throws -> String {
        let filename = "\(userId.uuidString)/\(UUID().uuidString).\(ext)"

        try await supabase.storage
            .from("media")
            .upload(filename, data: data, options: .init(contentType: mimeType, upsert: false))

        let urlResponse = try supabase.storage
            .from("media")
            .getPublicURL(path: filename)

        return urlResponse.absoluteString
    }

    func uploadFile(_ data: Data, filename: String, mimeType: String, userId: UUID) async throws -> String {
        let path = "\(userId.uuidString)/\(UUID().uuidString)-\(filename)"

        try await supabase.storage
            .from("media")
            .upload(path, data: data, options: .init(contentType: mimeType, upsert: false))

        let urlResponse = try supabase.storage
            .from("media")
            .getPublicURL(path: path)

        return urlResponse.absoluteString
    }
}
