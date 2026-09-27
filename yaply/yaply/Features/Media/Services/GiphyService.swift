import CoreGraphics
import Foundation

// Mirrors src/features/media/api/gifs.ts — direct Giphy REST API, no SDK
struct GiphyGif: Identifiable, Decodable {
    let id: String
    /// The `downsized` rendition (≤2MB), matching web. This used to be
    /// `original`, which can be many MB with full-size frames — heavy to
    /// download and animate for every recipient.
    let url: String
    let previewUrl: String
    /// Pixel size of `url`'s rendition, when Giphy reports it — sent as the
    /// `#ar=` hint so the bubble reserves its final height before loading.
    let pixelSize: CGSize

    enum CodingKeys: String, CodingKey {
        case id
        case images
    }

    enum ImageKeys: String, CodingKey {
        case original
        case downsized
        case fixedWidth = "fixed_width"
    }

    enum UrlKeys: String, CodingKey {
        case url
        case mp4
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let images = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .images)
        let original = try images.nestedContainer(keyedBy: UrlKeys.self, forKey: .original)
        let downsized = try? images.nestedContainer(keyedBy: UrlKeys.self, forKey: .downsized)
        let chosen: KeyedDecodingContainer<UrlKeys>
        if let downsized, (try? downsized.decode(String.self, forKey: .url)) != nil {
            chosen = downsized
        } else {
            chosen = original
        }
        url = try chosen.decode(String.self, forKey: .url)
        // Giphy sends dimensions as strings.
        let width = (try? chosen.decode(String.self, forKey: .width)).flatMap(Double.init) ?? 0
        let height = (try? chosen.decode(String.self, forKey: .height)).flatMap(Double.init) ?? 0
        pixelSize = CGSize(width: width, height: height)
        let preview = try images.nestedContainer(keyedBy: UrlKeys.self, forKey: .fixedWidth)
        previewUrl = (try? preview.decode(String.self, forKey: .url)) ?? url
    }
}

final class GiphyService {
    private let apiKey: String

    /// Placeholder values shipped in `Config.xcconfig.example` — treated as unset,
    /// mirroring the web app's `hasGiphyKey`.
    private static let placeholders: Set<String> = ["your-giphy-key", "your-giphy-api-key", ""]

    /// True only when a real key is configured — drives the picker's config hint.
    var hasKey: Bool { !Self.placeholders.contains(apiKey) }

    init() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GIPHY_API_KEY") as? String
            ?? ProcessInfo.processInfo.environment["GIPHY_API_KEY"]
            ?? ""
        apiKey = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(query: String, offset: Int = 0) async throws -> [GiphyGif] {
        guard !query.isBlank, hasKey else { return [] }

        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/search")!
        components.queryItems = [
            .init(name: "api_key", value: apiKey),
            .init(name: "q", value: query),
            .init(name: "limit", value: "20"),
            .init(name: "offset", value: "\(offset)"),
            .init(name: "rating", value: "g"),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try JSONDecoder().decode(GiphyResponse.self, from: data)
        return response.data
    }

    func trending() async throws -> [GiphyGif] {
        guard hasKey else { return [] }

        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/trending")!
        components.queryItems = [
            .init(name: "api_key", value: apiKey),
            .init(name: "limit", value: "20"),
            .init(name: "rating", value: "g"),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try JSONDecoder().decode(GiphyResponse.self, from: data)
        return response.data
    }

    private struct GiphyResponse: Decodable {
        let data: [GiphyGif]
    }
}
