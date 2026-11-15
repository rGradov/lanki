import Foundation

protocol ImageService {
    func firstImageURL(for query: String) async -> URL?
}

/// Fetches a representative photo from the Pexels API. Requires an API key
/// (configured in Settings). Returns `nil` silently on any failure so image
/// lookup never blocks the rest of the card.
final class PexelsService: ImageService {
    private let session: URLSession
    private let apiKeyProvider: () -> String

    init(session: URLSession = .shared, apiKeyProvider: @escaping () -> String) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    func firstImageURL(for query: String) async -> URL? {
        let key = apiKeyProvider().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        var components = URLComponents(string: "https://api.pexels.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: "1"),
            URLQueryItem(name: "orientation", value: "landscape")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(key, forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await session.data(for: request),
              let response = try? JSONDecoder().decode(PexelsResponse.self, from: data),
              let photo = response.photos?.first else {
            return nil
        }
        let urlString = photo.src?.medium ?? photo.src?.large ?? photo.src?.original
        return urlString.flatMap { URL(string: $0) }
    }
}

private struct PexelsResponse: Decodable {
    let photos: [Photo]?
    struct Photo: Decodable { let src: Source? }
    struct Source: Decodable {
        let original: String?
        let large: String?
        let medium: String?
    }
}
