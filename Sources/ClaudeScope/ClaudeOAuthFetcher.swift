import Foundation

// MARK: - OAuth API Response Models

struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour     = "five_hour"
        case sevenDay     = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

struct OAuthUsageWindow: Decodable {
    let utilization: Double?   // 0.0 – 1.0, the real percentage
    let resetsAt: String?      // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

// MARK: - Parsed Result Passed to the UI

struct OAuthUsageData {
    let fiveHourUtilization: Double?   // nil = window inactive / unavailable
    let weeklyUtilization: Double?
    let fiveHourResetsAt: Date?
    let weeklyResetsAt: Date?
}

// MARK: - Credential File Models

private struct CredentialsFile: Decodable {
    let claudeAiOauth: OAuthCredEntry?

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth = "claudeAiOauth"
    }
}

private struct OAuthCredEntry: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Double?    // unix ms

    enum CodingKeys: String, CodingKey {
        case accessToken  = "accessToken"
        case refreshToken = "refreshToken"
        case expiresAt    = "expiresAt"
    }
}

// MARK: - Errors

enum OAuthError: LocalizedError {
    case noCredentials
    case tokenExpired
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:          return "No Claude OAuth credentials found in ~/.claude/.credentials.json"
        case .tokenExpired:           return "OAuth token expired — please run `claude` to refresh"
        case .invalidResponse:        return "Invalid response from Claude API"
        case .httpError(let c, let m): return "HTTP \(c): \(m)"
        }
    }
}

// MARK: - Fetcher

struct ClaudeOAuthFetcher {

    private static let usageURL  = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaValue = "oauth-2025-04-20"

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Public entry point

    static func fetchUsage() async throws -> OAuthUsageData {
        guard let token = readAccessToken() else {
            throw OAuthError.noCredentials
        }
        return try await fetchUsage(accessToken: token)
    }

    static func fetchUsage(accessToken: String) async throws -> OAuthUsageData {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(betaValue,               forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        return OAuthUsageData(
            fiveHourUtilization: decoded.fiveHour?.utilization,
            weeklyUtilization:   decoded.sevenDay?.utilization,
            fiveHourResetsAt:    parseDate(decoded.fiveHour?.resetsAt),
            weeklyResetsAt:      parseDate(decoded.sevenDay?.resetsAt)
        )
    }

    // MARK: Credential Reading

    /// Reads the access token from ~/.claude/.credentials.json (written by Claude CLI).
    /// Returns nil if the file is absent, unreadable, or contains no token.
    static func readAccessToken() -> String? {
        // 1. Environment variable override (useful for testing / CI)
        if let t = ProcessInfo.processInfo.environment["ANTHROPIC_ACCESS_TOKEN"], !t.isEmpty {
            return t
        }
        // 2. Credentials file written by Claude CLI
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url  = home.appendingPathComponent(".claude/.credentials.json")

        guard
            let data  = try? Data(contentsOf: url),
            let creds = try? JSONDecoder().decode(CredentialsFile.self, from: data),
            let token = creds.claudeAiOauth?.accessToken,
            !token.isEmpty
        else { return nil }

        return token
    }

    // MARK: Helpers

    private static func parseDate(_ str: String?) -> Date? {
        guard let s = str else { return nil }
        return isoWithFraction.date(from: s) ?? isoNoFraction.date(from: s)
    }
}
