import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case networkError(Error)
    case decodingError
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token invalid. Run `claude login`."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError: return "Could not parse response."
        case .httpError(let code): return "HTTP error \(code)"
        }
    }
}

struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

enum OAuthAPI {
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let refreshURL = "https://platform.claude.com/v1/oauth/token"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
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
            guard http.statusCode == 200 else { throw APIError.httpError(http.statusCode) }
            guard let result = try? JSONDecoder().decode(OAuthUsageResponse.self, from: data) else {
                throw APIError.decodingError
            }
            return result
        } catch let e as APIError { throw e
        } catch { throw APIError.networkError(error) }
    }

    static func refreshToken(_ token: String) async throws -> (accessToken: String, refreshToken: String?, expiresAt: Date?) {
        guard let url = URL(string: refreshURL) else { throw APIError.decodingError }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: token),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.decodingError }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200 else { throw APIError.httpError(http.statusCode) }
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                throw APIError.decodingError
            }
            let expiresAt = result.expiresIn.map { Date().addingTimeInterval($0) }
            return (result.accessToken, result.refreshToken, expiresAt)
        } catch let e as APIError { throw e
        } catch { throw APIError.networkError(error) }
    }
}
