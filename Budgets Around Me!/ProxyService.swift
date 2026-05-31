//
//  ProxyService.swift
//  Budgets Around Me!
//
//  Communicates with the backend proxy server for OpenAI and Google Places API calls.
//  Users authenticate via Sign in with Apple/Google → get a JWT → use it for all API calls.
//  API keys are NEVER on the device — they live on the server only.
//

import Foundation

@MainActor
final class ProxyService {
    static let shared = ProxyService()

    // ─── Configuration ────────────────────────────────────────
    // Change this to your deployed server URL
    // Local dev:  http://localhost:3000
    // Production: https://budgets-proxy.onrender.com
    #if DEBUG
    private let baseURL = URL(string: "https://budgets-proxy.onrender.com")!
    #else
    private let baseURL = URL(string: "https://budgets-proxy.onrender.com")!
    #endif

    private let session = URLSession(configuration: .default)

    // ─── Auth Token ────────────────────────────────────────────

    /// JWT token from our backend (issued after Apple/Google sign-in)
    var authToken: String? {
        get { AuthKeychainHelper.load(account: "proxy_jwt", service: "com.budgetaround.app.auth") }
        set {
            if let token = newValue {
                AuthKeychainHelper.save(token, account: "proxy_jwt", service: "com.budgetaround.app.auth")
            } else {
                AuthKeychainHelper.delete(account: "proxy_jwt", service: "com.budgetaround.app.auth")
            }
        }
    }

    var isAuthenticated: Bool { authToken != nil }

    // ─── Auth Endpoints ────────────────────────────────────────

    /// Sign in with Apple — send the identity token to our server, get a JWT back
    func authenticateWithApple(identityToken: String, fullName: String?) async throws -> AuthResponse {
        let body: [String: Any] = [
            "identityToken": identityToken,
            "fullName": fullName ?? "",
        ]
        return try await post(endpoint: "/auth/apple", body: body, requiresAuth: false)
    }

    /// Sign in with Google — send the Google ID token to our server, get a JWT back
    func authenticateWithGoogle(idToken: String) async throws -> AuthResponse {
        let body: [String: Any] = ["idToken": idToken]
        return try await post(endpoint: "/auth/google", body: body, requiresAuth: false)
    }

    // ─── OpenAI Proxy ──────────────────────────────────────────

    /// Send a chat completion request through the proxy
    func chatCompletion(model: String = "gpt-4o-mini", messages: [[String: String]], temperature: Double = 0.7, maxTokens: Int = 500) async throws -> OpenAIResponse {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]
        return try await post(endpoint: "/api/openai", body: body, requiresAuth: true)
    }

    // ─── Google Places Proxy ───────────────────────────────────

    /// Search for nearby places through the proxy
    func nearbyPlaces(lat: Double, lng: Double, radius: Int = 5000, type: String = "restaurant", keyword: String? = nil) async throws -> ProxyPlacesResponse {
        var params = "lat=\(lat)&lng=\(lng)&radius=\(radius)&type=\(type)"
        if let kw = keyword, !kw.isEmpty {
            params += "&keyword=\(kw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        return try await get(endpoint: "/api/places?\(params)", requiresAuth: true)
    }

    /// Get place details through the proxy
    func placeDetails(placeId: String, fields: String = "name,formatted_address,geometry,rating,price_level,opening_hours,photos,website,formatted_phone_number") async throws -> PlacesResponse {
        let params = "fields=\(fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        return try await get(endpoint: "/api/places/\(placeId)?\(params)", requiresAuth: true)
    }

    // ─── Health Check ──────────────────────────────────────────

    func healthCheck() async throws -> HealthResponse {
        return try await get(endpoint: "/health", requiresAuth: false)
    }

    // ─── Private Helpers ───────────────────────────────────────

    private func makeRequest(endpoint: String, method: String = "GET", body: [String: Any]? = nil, requiresAuth: Bool) throws -> URLRequest {
        let url = URL(string: endpoint, relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if requiresAuth {
            guard let token = authToken else {
                throw ProxyError.notAuthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return request
    }

    private func get<T: Decodable>(endpoint: String, requiresAuth: Bool) async throws -> T {
        let request = try makeRequest(endpoint: endpoint, requiresAuth: requiresAuth)
        return try await execute(request: request)
    }

    private func post<T: Decodable>(endpoint: String, body: [String: Any], requiresAuth: Bool) async throws -> T {
        let request = try makeRequest(endpoint: endpoint, method: "POST", body: body, requiresAuth: requiresAuth)
        return try await execute(request: request)
    }

    private func execute<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            // Token expired or invalid — clear auth
            authToken = nil
            throw ProxyError.notAuthenticated
        }

        if httpResponse.statusCode >= 400 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ProxyError.serverError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProxyError.decodingError(error)
        }
    }
}

// ─── Response Types ────────────────────────────────────────────

struct AuthResponse: Codable {
    let token: String
    let user: ProxyUser
}

struct ProxyUser: Codable {
    let id: String
    let email: String?
    let displayName: String?
    let provider: String
}

struct OpenAIResponse: Codable {
    let id: String?
    let choices: [OpenAIChoice]?
    let usage: OpenAIUsage?

    struct OpenAIChoice: Codable {
        let message: OpenAIMessage?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct OpenAIMessage: Codable {
        let role: String?
        let content: String?
    }

    struct OpenAIUsage: Codable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

struct ProxyPlacesResponse: Codable {
    let results: [ProxyPlaceResult]?
    let status: String?
    let error_message: String?

    struct ProxyPlaceResult: Codable {
        let place_id: String?
        let name: String?
        let vicinity: String?
        let geometry: ProxyPlaceGeometry?
        let rating: Double?
        let price_level: Int?
        let types: [String]?
        let opening_hours: ProxyOpeningHours?
        let photos: [ProxyPlacePhoto]?
    }

    struct ProxyPlaceGeometry: Codable {
        let location: ProxyPlaceLocation?
    }

    struct ProxyPlaceLocation: Codable {
        let lat: Double?
        let lng: Double?
    }

    struct ProxyOpeningHours: Codable {
        let open_now: Bool?
    }

    struct ProxyPlacePhoto: Codable {
        let photo_reference: String?
        let height: Int?
        let width: Int?
    }
}

struct HealthResponse: Codable {
    let status: String?
    let openai: Bool?
    let google_places: Bool?
    let uptime: Double?
}

// ─── Errors ───────────────────────────────────────────────────

enum ProxyError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in to continue."
        case .invalidResponse:
            return "Invalid server response."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        }
    }
}

// ─── Keychain Helper ─────────────────────────────────────────

private enum AuthKeychainHelper {
    static func save(_ value: String, account: String, service: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(account: account, service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}