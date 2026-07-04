import Foundation
import CommonCrypto

/// Reads the OAuth access token the Claude **desktop app** keeps continuously fresh, so
/// ClaudeBar never has to refresh the (aggressively rate-limited) OAuth token endpoint
/// itself — the source of the old daily-429 lockups.
///
/// The desktop app (Electron) caches its tokens in
/// `~/Library/Application Support/Claude/config.json` under the keys `oauth:tokenCache` and
/// `oauth:tokenCacheV2` (both are read and merged — the desktop app has been observed moving
/// which key holds the live client-9d1c250a entry across releases), each
/// a Chromium `os_crypt` "v10" blob: base64( "v10" + AES-128-CBC ciphertext ), where
/// the key = PBKDF2-HMAC-SHA1(secret, "saltysalt", 1003, 16), the secret is the
/// `Claude Safe Storage` keychain item, and the IV is 16 bytes of 0x20. The decrypted
/// JSON is keyed `"<clientId>:<org>:<audience>:<space-separated scopes>"` → `{ token,
/// refreshToken, expiresAt, … }`. The desktop app caches *several* tokens for client
/// 9d1c250a under different scope keys; we return all of them (freshest first) so the caller
/// can try each, because the usage endpoint accepts whichever the server still honours — and
/// that is NOT always the `user:sessions:claude_code` one. An empty result lets the caller
/// fall back to the CLI keychain token — the format is undocumented and may change across desktop releases.
enum DesktopTokenReader {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let safeStorageService = "Claude Safe Storage"

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
    }

    /// Every usable access token from the desktop cache, freshest expiry first, for the caller
    /// to try in order. Empty if the desktop store is absent/unreadable or holds no currently-
    /// valid token.
    static func currentTokens() -> [String] {
        guard let cache = decryptedTokenCache() else { return [] }
        let nowMillis = Date().timeIntervalSince1970 * 1000

        let candidates = cache.compactMap { key, value -> (token: String, exp: Double)? in
            guard key.contains(clientID), key.contains("user:inference"),
                  let obj = value as? [String: Any],
                  let token = obj["token"] as? String, !token.isEmpty else { return nil }
            let exp = (obj["expiresAt"] as? NSNumber)?.doubleValue ?? (obj["expiresAt"] as? Double) ?? 0
            return (token, exp)
        }
        // Keep only tokens we believe are still valid (exp unknown = 0 is treated as usable;
        // the server is the final authority via a 401). Order by latest expiry: a later-
        // expiring token is the more likely to still be live on the server. We deliberately do
        // NOT prefer the claude_code session scope — that is exactly the token a re-login
        // revokes first, while a broader token the desktop keeps refreshing still returns 200.
        return candidates
            .filter { $0.exp == 0 || $0.exp > nowMillis }
            .sorted { $0.exp > $1.exp }
            .map { $0.token }
    }

    /// The desktop app has been observed migrating its live tokens from `oauth:tokenCache`
    /// to a newer `oauth:tokenCacheV2` key while leaving the old key holding only stale/other
    /// entries — so both must be decrypted and merged, or the client-`9d1c250a` entry can vanish
    /// from the key we're looking at entirely (not merely expire) after a desktop update.
    private static let cacheKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]

    private static func decryptedTokenCache() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = deriveKey() else { return nil }

        var merged: [String: Any] = [:]
        for cacheKey in cacheKeys {
            guard let blobB64 = root[cacheKey] as? String,
                  let blob = Data(base64Encoded: blobB64), blob.count > 3 else { continue }
            // Strip the 3-byte "v10" version tag; the remainder is AES-128-CBC ciphertext.
            let ciphertext = blob.subdata(in: 3..<blob.count)
            guard let plaintext = aes128CBCDecrypt(ciphertext, key: key),
                  let obj = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else { continue }
            merged.merge(obj) { _, new in new }
        }
        return merged.isEmpty ? nil : merged
    }

    /// AES-128 key = PBKDF2-HMAC-SHA1(safeStorageSecret, "saltysalt", 1003, 16).
    private static func deriveKey() -> Data? {
        guard let secret = safeStorageSecret(), let secretData = secret.data(using: .utf8) else { return nil }
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = secretData.withUnsafeBytes { secretRaw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                secretRaw.bindMemory(to: Int8.self).baseAddress, secretData.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &derived, derived.count
            )
        }
        return status == kCCSuccess ? Data(derived) : nil
    }

    private static func aes128CBCDecrypt(_ ciphertext: Data, key: Data) -> Data? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)   // Chromium's fixed 16-space IV
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = key.withUnsafeBytes { keyRaw in
            ciphertext.withUnsafeBytes { ctRaw in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyRaw.baseAddress, key.count,
                    iv,
                    ctRaw.baseAddress, ciphertext.count,
                    &out, out.count, &outLen
                )
            }
        }
        return status == kCCSuccess ? Data(out.prefix(outLen)) : nil
    }

    /// Read the `Claude Safe Storage` master secret via the same `security` CLI path the
    /// rest of the app uses (the running app already has read access to it).
    private static func safeStorageSecret() -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", safeStorageService, "-w"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        process.standardInput = nil
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var data = outPipe.fileHandleForReading.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
