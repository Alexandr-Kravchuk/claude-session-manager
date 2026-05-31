import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case tokenExpired
    case networkError(Error)
    case decodingError
    case httpError(Int)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token invalid. Run `claude login`."
        case .tokenExpired: return "Token expired — open Claude Code to refresh"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError: return "Could not parse response."
        case .httpError(let code): return "HTTP error \(code)"
        case .rateLimited: return "Rate limited by API."
        }
    }
}

enum OAuthAPI {
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let betaHeader = "oauth-2025-04-20"

    static func fetchUsage(accessToken: String) async throws -> OAuthUsageResponse {
        guard let url = URL(string: usageURL) else { throw APIError.decodingError }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.152", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.decodingError }
            if http.statusCode == 401 { throw APIError.unauthorized }
            if http.statusCode == 429 { throw APIError.rateLimited }
            guard http.statusCode == 200 else { throw APIError.httpError(http.statusCode) }
            guard let result = try? JSONDecoder().decode(OAuthUsageResponse.self, from: data) else {
                throw APIError.decodingError
            }
            return result
        } catch let e as APIError { throw e
        } catch { throw APIError.networkError(error) }
    }
}
