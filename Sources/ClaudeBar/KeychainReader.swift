import Security
import Foundation

enum KeychainError: LocalizedError {
    case notFound
    case decodingFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Claude credentials not found. Run `claude login`."
        case .decodingFailed: return "Could not decode Claude credentials."
        case .keychainError(let s): return "Keychain error \(s). Run `claude login`."
        }
    }
}

struct KeychainReader {
    private static let service = "Claude Code-credentials"

    static func readCredentials() throws -> ClaudeCredentials {
        let data = try readViaSecurityCLI()
        return try parse(data: data)
    }

    private static func readViaSecurityCLI() throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else {
            throw KeychainError.notFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        process.standardInput = nil

        do { try process.run() } catch { throw KeychainError.notFound }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { throw KeychainError.notFound }

        var data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { throw KeychainError.notFound }
        return data
    }

    private static func parse(data: Data) throws -> ClaudeCredentials {
        struct Root: Decodable {
            let claudeAiOauth: OAuth?
        }
        struct OAuth: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresAt: Double?
            let rateLimitTier: String?
        }

        guard let root = try? JSONDecoder().decode(Root.self, from: data),
              let oauth = root.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else { throw KeychainError.decodingFailed }

        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(
            accessToken: token,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            rateLimitTier: oauth.rateLimitTier
        )
    }
}
