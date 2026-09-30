import Foundation

// Link previews (URL unfurling). This must match the encode/decode behavior of
// the web port at packages/shared/src/linkPreview.ts (../CLAUDE.md's "Link
// previews" section) or the two platforms disagree on whether a decrypted
// `content` string is plain text or a preview envelope.
struct LinkPreview: Codable, Hashable {
    let url: String
    let title: String?
    let description: String?
    // Our own Storage URL (the `link-preview-images` bucket) — never the
    // original third-party domain.
    let imageUrl: String?
    let siteName: String?

    enum CodingKeys: String, CodingKey {
        case url, title, description
        case imageUrl = "imageUrl"
        case siteName = "siteName"
    }
}

private struct EncodedTextMessage: Codable {
    let v: Int
    let text: String
    let linkPreview: LinkPreview?
}

/// A URL or bare-domain match found in text — see `LinkPreviewCodec.findUrls`.
struct UrlMatch {
    let range: Range<String.Index>
    /// Exactly as it appears in the source text.
    let raw: String
    /// Absolute URL to fetch/link to — `https://` prepended when `raw` had no scheme.
    let href: String
}

enum LinkPreviewCodec {
    // A conservative, common-TLD allowlist rather than a bare `\.[a-z]{2,}`
    // pattern, which false-positives constantly on ordinary sentences ("etc.",
    // "Mr. Smith", "v1.2"). Must match packages/shared/src/linkPreview.ts's list.
    private static let bareDomainTLDs = [
        "com", "org", "net", "io", "co", "dev", "app", "ai", "edu", "gov", "info",
        "biz", "me", "xyz", "us", "uk", "ca", "de", "fr", "jp", "cn", "in", "au",
        "ly", "to", "so", "gg", "tv", "link", "shop", "store", "tech", "site",
        "online", "news", "club", "live", "pro", "world", "email", "cloud",
    ]

    private static let protocolRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)
    private static let bareDomainRegex: NSRegularExpression = {
        let tlds = bareDomainTLDs.joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+(?:"# + tlds + #")\b(?:/\S*)?"#,
            options: .caseInsensitive
        )
    }()

    private static func trimTrailingPunctuation(_ s: String) -> String {
        var result = s
        while let last = result.last, ")]}>,.!?;:'\"".contains(last) {
            result.removeLast()
        }
        return result
    }

    /// Finds every `http(s)://` URL and bare "example.com"-style domain in
    /// text, in order. Used both to decide whether to offer a link preview
    /// and to linkify bubble text. Mirrors
    /// packages/shared/src/linkPreview.ts's `findUrls`.
    static func findUrls(in text: String) -> [UrlMatch] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var matches: [UrlMatch] = []

        for m in protocolRegex.matches(in: text, range: fullRange) {
            guard let range = Range(m.range, in: text) else { continue }
            let raw = trimTrailingPunctuation(String(text[range]))
            guard !raw.isEmpty else { continue }
            let end = text.index(range.lowerBound, offsetBy: raw.count)
            matches.append(UrlMatch(range: range.lowerBound..<end, raw: raw, href: raw))
        }

        for m in bareDomainRegex.matches(in: text, range: fullRange) {
            guard let range = Range(m.range, in: text) else { continue }
            let raw = trimTrailingPunctuation(String(text[range]))
            guard !raw.isEmpty else { continue }
            let end = text.index(range.lowerBound, offsetBy: raw.count)
            let candidateRange = range.lowerBound..<end
            // Skip a bare match that's really the domain portion of an
            // already-found protocol URL, or the domain half of an email
            // address ("user@example.com") — not a link.
            if matches.contains(where: { $0.range.overlaps(candidateRange) }) { continue }
            if range.lowerBound > text.startIndex, text[text.index(before: range.lowerBound)] == "@" { continue }
            matches.append(UrlMatch(range: candidateRange, raw: raw, href: "https://\(raw)"))
        }

        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // Deliberately simple and permissive, like the web port — this only
    // decides whether the compose UI offers to resolve a preview, not a
    // security boundary.
    static func extractFirstUrl(_ text: String) -> String? {
        findUrls(in: text).first?.href
    }

    /// What actually gets sealed (or, for the phase-1 fallback, stored as
    /// plain base64) for a `type='text'` message. With no preview this is
    /// just the raw text, byte-identical to the pre-link-preview wire format.
    static func encodeTextMessage(_ text: String, linkPreview: LinkPreview? = nil) -> String {
        guard let linkPreview else { return text }
        let encoded = EncodedTextMessage(v: 1, text: text, linkPreview: linkPreview)
        guard let data = try? JSONEncoder().encode(encoded), let json = String(data: data, encoding: .utf8) else {
            return text
        }
        return json
    }

    /// Inverse of `encodeTextMessage`. Guarded: only unwraps a string that
    /// decodes to the exact known shape; anything else — plain text, unrelated
    /// JSON a user happened to type, a corrupt envelope — falls back to
    /// treating the whole decrypted string as display text with no preview.
    /// Never throws.
    static func decodeTextMessage(_ raw: String) -> (text: String, linkPreview: LinkPreview?) {
        guard raw.hasPrefix("{"), let data = raw.data(using: .utf8) else { return (raw, nil) }
        guard let decoded = try? JSONDecoder().decode(EncodedTextMessage.self, from: data), decoded.v == 1 else {
            return (raw, nil)
        }
        guard let preview = decoded.linkPreview else { return (decoded.text, nil) }
        // Mirrors web's decodeTextMessage: the sender controls this JSON.
        // Only http(s) page URLs, and an image only from our own bucket — a
        // third-party host would make every recipient's client fetch it (IP and
        // read-time leak). An untrusted image is dropped; the preview remains.
        guard let pageUrl = URL(string: preview.url), ["http", "https"].contains(pageUrl.scheme?.lowercased()) else {
            return (decoded.text, nil)
        }
        let image = preview.imageUrl.flatMap { isTrustedPreviewImage($0) ? $0 : nil }
        return (decoded.text, LinkPreview(
            url: preview.url,
            title: preview.title,
            description: preview.description,
            imageUrl: image,
            siteName: preview.siteName
        ))
    }

    private static let previewImagePath = "/storage/v1/object/public/link-preview-images/"

    // The project's own origin. Fail closed: with no configured URL no image loads.
    private static let trustedImageOrigin: (scheme: String, host: String, port: Int?)? = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
                ?? ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return nil }
        return (scheme, host, url.port)
    }()

    private static func isTrustedPreviewImage(_ string: String) -> Bool {
        guard
            let origin = trustedImageOrigin,
            let url = URL(string: string),
            url.scheme?.lowercased() == origin.scheme,
            url.host?.lowercased() == origin.host,
            url.port == origin.port
        else { return false }
        return url.path.hasPrefix(previewImagePath)
    }
}
