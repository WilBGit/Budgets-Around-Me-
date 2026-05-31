//
//  OpenAIService.swift
//  Budgets Around Me!
//
//  Routes OpenAI requests through ProxyService when user is authenticated
//  (server holds API keys), falls back to direct API when not (legacy/beta).
//

import Foundation
import Security

struct BudgetSuggestion: Codable, Identifiable {
    let id = UUID()
    let title: String
    let description: String?
    let price: Double?
    let link: String?
    let category: String?
    let menuItems: [String]?
    let tips: String?
}

struct BudgetSuggestionsResponse: Codable {
    let suggestions: [BudgetSuggestion]
}

struct OpenAISuggestions: Decodable {
    let keywords: [String]
}

final class OpenAIService {
    static let shared = OpenAIService()
    private init() {
        if let stored = KeychainHelper.shared.read(service: KeychainHelper.service, account: KeychainHelper.account)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            self.apiKey = stored
            #if DEBUG
            print("🔑 OpenAI API key loaded from Keychain: \(stored.prefix(6))…")
            #endif
        } else if let plistKey = (Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !plistKey.isEmpty {
            self.apiKey = plistKey
            KeychainHelper.shared.save(plistKey, service: KeychainHelper.service, account: KeychainHelper.account)
            #if DEBUG
            print("🔑 OpenAI API key loaded from Info.plist and saved to Keychain: \(plistKey.prefix(6))…")
            #endif
        }
    }

    private var apiKey: String?

    /// Whether to use the proxy (authenticated) or direct API (legacy)
    private var useProxy: Bool { ProxyService.shared.isAuthenticated }

    /// Resolve a usable API key (throws if not available)
    /// Priority: AuthService (user-entered key) > internal apiKey > Info.plist > env var
    private func resolveAuthKey() throws -> String {
        if let authKey = AuthService.shared.openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !authKey.isEmpty {
            self.apiKey = authKey
            KeychainHelper.shared.save(authKey, service: KeychainHelper.service, account: KeychainHelper.account)
            return authKey
        }
        if let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        if let infoKey = (Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !infoKey.isEmpty {
            KeychainHelper.shared.save(infoKey, service: KeychainHelper.service, account: KeychainHelper.account)
            self.apiKey = infoKey
            return infoKey
        }
        if let legacy = (Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            KeychainHelper.shared.save(legacy, service: KeychainHelper.service, account: KeychainHelper.account)
            self.apiKey = legacy
            return legacy
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = env.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainHelper.shared.save(clean, service: KeychainHelper.service, account: KeychainHelper.account)
            self.apiKey = clean
            return clean
        }
        throw URLError(.userAuthenticationRequired)
    }

    func isApiKeyAvailable() -> Bool {
        // Proxy mode: always available if authenticated
        if useProxy { return true }
        if let authKey = AuthService.shared.openAIKey, !authKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let k = apiKey, !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String != nil { return true }
        if Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String != nil { return true }
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil { return true }
        return false
    }

    func setApiKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = clean
        KeychainHelper.shared.save(clean, service: KeychainHelper.service, account: KeychainHelper.account)
    }

    func clearApiKey() {
        self.apiKey = nil
        KeychainHelper.shared.delete(service: KeychainHelper.service, account: KeychainHelper.account)
    }

    // ─── Cache & Backoff ──────────────────────────────────────

    private var cache: [String: [String]] = [:]
    private var lastFailureAt: Date?
    private var failureCount: Int = 0
    private let maxBackoffSeconds: TimeInterval = 120

    struct Meta {
        let fromCache: Bool
        let usedFallbackParse: Bool
        let errorBackedOff: Bool
    }
    private var lastMeta: Meta = Meta(fromCache: false, usedFallbackParse: false, errorBackedOff: false)
    func getLastMeta() -> Meta { lastMeta }

    // ─── Keywords (Proxy or Direct) ────────────────────────────

    func suggestKeywords(budget: Double, latitude: Double, longitude: Double, radiusMiles: Double = 10) async throws -> [String] {
        // Exponential backoff on prior failures
        if let last = lastFailureAt {
            let backoff = min(pow(2.0, Double(failureCount)), maxBackoffSeconds)
            if Date().timeIntervalSince(last) < backoff {
                let key = cacheKey(budget: budget, latitude: latitude, longitude: longitude)
                if let cached = cache[key] {
                    lastMeta = Meta(fromCache: true, usedFallbackParse: false, errorBackedOff: true)
                    return cached
                }
                lastMeta = Meta(fromCache: false, usedFallbackParse: false, errorBackedOff: true)
                throw URLError(.cannotConnectToHost)
            }
        }

        // Cache check
        let key = cacheKey(budget: budget, latitude: latitude, longitude: longitude)
        if let cached = cache[key] {
            lastMeta = Meta(fromCache: true, usedFallbackParse: false, errorBackedOff: false)
            return cached
        }

        if useProxy {
            return try await suggestKeywordsViaProxy(budget: budget, latitude: latitude, longitude: longitude, radiusMiles: radiusMiles, cacheKey: key)
        } else {
            return try await suggestKeywordsDirect(budget: budget, latitude: latitude, longitude: longitude, radiusMiles: radiusMiles, cacheKey: key)
        }
    }

    private func suggestKeywordsViaProxy(budget: Double, latitude: Double, longitude: Double, radiusMiles: Double, cacheKey: String) async throws -> [String] {
        let system = "You suggest concise Google Places search keywords based on a user's budget and coordinates. Only output a JSON object with an array field named 'keywords' containing 3-6 short keyword strings. No prose. Focus on places within a \(Int(radiusMiles))-mile radius."
        let user = "Budget: $\(Int(budget)). Lat: \(latitude), Lng: \(longitude). Radius: \(Int(radiusMiles)) miles. Respond as {\"keywords\":[...]}"

        let response: OpenAIResponse = try await ProxyService.shared.chatCompletion(
            model: "gpt-4o-mini",
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            temperature: 0.2,
            maxTokens: 500
        )

        guard let content = response.choices?.first?.message?.content else {
            lastMeta = Meta(fromCache: false, usedFallbackParse: false, errorBackedOff: false)
            return []
        }

        if let data = content.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(OpenAISuggestions.self, from: data) {
            cache[cacheKey] = parsed.keywords
            failureCount = 0
            lastFailureAt = nil
            lastMeta = Meta(fromCache: false, usedFallbackParse: false, errorBackedOff: false)
            return parsed.keywords
        }

        // Fallback parse
        let rough = content
            .replacingOccurrences(of: "[\n\t\"{}]", with: " ", options: .regularExpression)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallback = Array(rough.prefix(5))
        cache[cacheKey] = fallback
        failureCount = 0
        lastFailureAt = nil
        lastMeta = Meta(fromCache: false, usedFallbackParse: true, errorBackedOff: false)
        return fallback
    }

    private func suggestKeywordsDirect(budget: Double, latitude: Double, longitude: Double, radiusMiles: Double, cacheKey: String) async throws -> [String] {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let authKey = try resolveAuthKey()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")

        struct Payload: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let temperature: Double
        }

        let system = "You suggest concise Google Places search keywords based on a user's budget and coordinates. Only output a JSON object with an array field named 'keywords' containing 3-6 short keyword strings. No prose. Focus on places within a \(Int(radiusMiles))-mile radius."
        let user = "Budget: $\(Int(budget)). Lat: \(latitude), Lng: \(longitude). Radius: \(Int(radiusMiles)) miles. Respond as {\"keywords\":[...]}"
        let body = Payload(model: "gpt-4o-mini", messages: [.init(role: "system", content: system), .init(role: "user", content: user)], temperature: 0.2)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await performRequest(request)

        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
        struct Root: Decodable { let choices: [Choice] }

        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let contentString = root.choices.first?.message.content else {
            lastMeta = Meta(fromCache: false, usedFallbackParse: false, errorBackedOff: false)
            return []
        }

        if let contentData = contentString.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(OpenAISuggestions.self, from: contentData) {
            cache[cacheKey] = parsed.keywords
            failureCount = 0
            lastFailureAt = nil
            lastMeta = Meta(fromCache: false, usedFallbackParse: false, errorBackedOff: false)
            return parsed.keywords
        }

        let rough = contentString
            .replacingOccurrences(of: "[\n\t\"{}]", with: " ", options: .regularExpression)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallback = Array(rough.prefix(5))
        cache[cacheKey] = fallback
        failureCount = 0
        lastFailureAt = nil
        lastMeta = Meta(fromCache: false, usedFallbackParse: true, errorBackedOff: false)
        return fallback
    }

    private func cacheKey(budget: Double, latitude: Double, longitude: Double) -> String {
        let roundedBudget = Int((budget / 5.0).rounded() * 5)
        let lat = (latitude / 0.02).rounded() * 0.02
        let lng = (longitude / 0.02).rounded() * 0.02
        return "b:\(roundedBudget)|lat:\(lat)|lng:\(lng)"
    }

    // ─── Ideas (Proxy or Direct) ────────────────────────────────

    func suggestIdeas(budget: Double, latitude: Double, longitude: Double, locality: String? = nil, radiusMiles: Double = 10) async throws -> [BudgetSuggestion] {
        if useProxy {
            return try await suggestIdeasViaProxy(budget: budget, latitude: latitude, longitude: longitude, locality: locality, radiusMiles: radiusMiles)
        } else {
            return try await suggestIdeasDirect(budget: budget, latitude: latitude, longitude: longitude, locality: locality, radiusMiles: radiusMiles)
        }
    }

    private func suggestIdeasViaProxy(budget: Double, latitude: Double, longitude: Double, locality: String? = nil, radiusMiles: Double = 10) async throws -> [BudgetSuggestion] {
        let safeLocality = (locality ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let locationPhrase = safeLocality.isEmpty ? String(format: " at %.4f,%.4f", latitude, longitude) : " near \(safeLocality)"
        let system = "You are a local budget expert. Output ONLY strict JSON: {\"suggestions\":[{\"title\":\"string\",\"description\":\"string\",\"price\":number?,\"link\":\"string?\",\"category\":\"string\",\"menuItems\":[\"string\"],\"tips\":\"string\"}]} with detailed place recommendations. Only include places that are within a \(Int(radiusMiles))-mile radius of the provided location and whose typical total price fits within the provided budget."
        let user = "For a $\(Int(budget)) budget\(locationPhrase), suggest 6-8 specific places strictly within a \(Int(radiusMiles))-mile radius of the given location. Only include places that a typical visit would fit within the budget. For each place include: title, detailed description (what makes it special, atmosphere, why visit), estimated price range, category (restaurant/attraction/activity/shopping), specific menu items or activities, and insider tips. Be specific about what to order, typical costs, and local insider knowledge. Respond only with JSON."

        let response: OpenAIResponse = try await ProxyService.shared.chatCompletion(
            model: "gpt-4o-mini",
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            temperature: 0.4,
            maxTokens: 1000
        )

        guard let content = response.choices?.first?.message?.content,
              let jsonData = content.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(BudgetSuggestionsResponse.self, from: jsonData) else {
            throw URLError(.cannotParseResponse)
        }

        failureCount = 0
        lastFailureAt = nil
        #if DEBUG
        print("🧠 Parsed \(parsed.suggestions.count) suggestions via proxy")
        #endif
        return parsed.suggestions
    }

    private func suggestIdeasDirect(budget: Double, latitude: Double, longitude: Double, locality: String? = nil, radiusMiles: Double = 10) async throws -> [BudgetSuggestion] {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let authKey = try resolveAuthKey()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")

        struct Payload: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let temperature: Double
        }

        let safeLocality = (locality ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let locationPhrase = safeLocality.isEmpty ? String(format: " at %.4f,%.4f", latitude, longitude) : " near \(safeLocality)"
        let system = "You are a local budget expert. Output ONLY strict JSON: {\"suggestions\":[{\"title\":\"string\",\"description\":\"string\",\"price\":number?,\"link\":\"string?\",\"category\":\"string\",\"menuItems\":[\"string\"],\"tips\":\"string\"}]} with detailed place recommendations. Only include places that are within a \(Int(radiusMiles))-mile radius of the provided location and whose typical total price fits within the provided budget."
        let user = "For a $\(Int(budget)) budget\(locationPhrase), suggest 6-8 specific places strictly within a \(Int(radiusMiles))-mile radius of the given location. Only include places that a typical visit would fit within the budget. For each place include: title, detailed description (what makes it special, atmosphere, why visit), estimated price range, category (restaurant/attraction/activity/shopping), specific menu items or activities, and insider tips. Be specific about what to order, typical costs, and local insider knowledge. Respond only with JSON."
        let body = Payload(model: "gpt-4o-mini", messages: [.init(role: "system", content: system), .init(role: "user", content: user)], temperature: 0.4)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await performRequest(request)

        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable { let content: String }
        struct Root: Decodable { let choices: [Choice] }
        let root = try JSONDecoder().decode(Root.self, from: data)
        if let content = root.choices.first?.message.content,
           let jsonData = content.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(BudgetSuggestionsResponse.self, from: jsonData) {
            failureCount = 0
            lastFailureAt = nil
            return parsed.suggestions
        } else {
            throw URLError(.cannotParseResponse)
        }
    }

    // ─── Networking ────────────────────────────────────────────

    private func performRequest(_ request: URLRequest, retries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        var attempt = 0
        while attempt <= retries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (200..<300).contains(http.statusCode) {
                    return (data, http)
                } else if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    lastError = URLError(.cannotConnectToHost)
                } else {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw URLError(.userAuthenticationRequired)
                    } else {
                        throw URLError(.badServerResponse)
                    }
                }
            } catch {
                lastError = error
            }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(300_000_000 * attempt))
        }
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }
}

// MARK: - Keychain Helper
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    static let service = "com.budgetsaroundme.openai"
    static let account = "api-key"

    func save(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}