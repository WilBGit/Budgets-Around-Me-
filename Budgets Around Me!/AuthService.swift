//
//  AuthService.swift
//  Budgets Around Me!
//
//  Manages user authentication via Sign in with Apple and Sign in with Google.
//  On login, we retrieve the user's identity token and store it securely in Keychain.
//  The OpenAI and Google Maps/Places services use the authenticated user's session.
//

import Foundation
import AuthenticationServices
import SwiftUI
import CryptoKit
import Combine

// MARK: - Auth Provider

enum AuthProvider: String, Codable, CaseIterable {
    case apple
    case google
}

// MARK: - Auth User

struct AuthUser: Codable {
    let id: String
    let email: String?
    let displayName: String?
    let provider: AuthProvider
    /// OpenAI API key supplied by the user after login (stored in Keychain)
    var openAIKey: String?
    /// Google Places/Maps API key supplied by the user after login (stored in Keychain)
    var googlePlacesKey: String?
}

// MARK: - Auth Service

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: AuthUser?
    @Published var isAuthenticating: Bool = false
    @Published var errorMessage: String?

    private let userKey = "auth_user"
    private let openAIKeyAccount = "openai_api_key"
    private let googlePlacesKeyAccount = "google_places_api_key"
    private let keychainService = "com.budgetaround.app.auth"

    init() {
        loadUser()
    }

    // MARK: - Sign in with Apple

    func signInWithApple() {
        isAuthenticating = true
        errorMessage = nil

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = AppleAuthDelegate(authService: self)
        controller.performRequests()
    }

    // MARK: - Sign in with Google

    func signInWithGoogle() {
        errorMessage = nil

        // Google Sign-In requires the GoogleSignIn SDK (SPM dependency).
        // When integrated, this calls GIDSignIn.sharedInstance.signIn(...)
        // For now, we create a Google user and show key entry flow.

        let googleUser = AuthUser(
            id: "google_\(UUID().uuidString)",
            email: nil,
            displayName: "Google User",
            provider: .google,
            openAIKey: nil,
            googlePlacesKey: nil
        )
        completeSignIn(user: googleUser)
    }

    // MARK: - Sign Out

    func signOut() {
        isAuthenticated = false
        currentUser = nil
        AuthKeychainHelper.delete(account: userKey, service: keychainService)
        AuthKeychainHelper.delete(account: openAIKeyAccount, service: keychainService)
        AuthKeychainHelper.delete(account: googlePlacesKeyAccount, service: keychainService)
        Haptics.warning()
    }

    // MARK: - Save API Keys (legacy — proxy mode doesn't need these)

    func saveOpenAIKey(_ key: String) {
        AuthKeychainHelper.save(key, account: openAIKeyAccount, service: keychainService)
        currentUser?.openAIKey = key
        saveCurrentUser()
    }

    func saveGooglePlacesKey(_ key: String) {
        AuthKeychainHelper.save(key, account: googlePlacesKeyAccount, service: keychainService)
        currentUser?.googlePlacesKey = key
        saveCurrentUser()
    }

    // MARK: - Get API Keys (legacy direct mode fallback)

    var openAIKey: String? {
        if let current = currentUser?.openAIKey, !current.isEmpty { return current }
        return AuthKeychainHelper.load(account: openAIKeyAccount, service: keychainService)
    }

    var googlePlacesKey: String? {
        if let current = currentUser?.googlePlacesKey, !current.isEmpty { return current }
        return AuthKeychainHelper.load(account: googlePlacesKeyAccount, service: keychainService)
    }

    // MARK: - Has Required Keys

    var hasOpenAIKey: Bool {
        // In proxy mode, the proxy handles keys — always available if authenticated
        if ProxyService.shared.isAuthenticated { return true }
        if let key = openAIKey, !key.isEmpty { return true }
        return false
    }

    var hasGooglePlacesKey: Bool {
        // In proxy mode, the proxy handles keys — always available if authenticated
        if ProxyService.shared.isAuthenticated { return true }
        if let key = googlePlacesKey, !key.isEmpty { return true }
        return false
    }

    var hasAllKeys: Bool {
        // In proxy mode, authentication IS the key — no manual key entry needed
        if ProxyService.shared.isAuthenticated { return true }
        return hasOpenAIKey && hasGooglePlacesKey
    }

    // MARK: - Internal

    func completeSignIn(user: AuthUser) {
        var updatedUser = user
        updatedUser.openAIKey = AuthKeychainHelper.load(account: openAIKeyAccount, service: keychainService)
        updatedUser.googlePlacesKey = AuthKeychainHelper.load(account: googlePlacesKeyAccount, service: keychainService)

        currentUser = updatedUser
        isAuthenticated = true
        isAuthenticating = false
        saveCurrentUser()
        Haptics.success()
    }

    func failSignIn(_ error: String) {
        errorMessage = error
        isAuthenticating = false
        Haptics.error()
    }

    private func saveCurrentUser() {
        guard let user = currentUser else { return }
        if let data = try? JSONEncoder().encode(user) {
            AuthKeychainHelper.save(data.base64EncodedString(), account: userKey, service: keychainService)
        }
    }

    private func loadUser() {
        guard let encoded = AuthKeychainHelper.load(account: userKey, service: keychainService),
              let data = Data(base64Encoded: encoded),
              let user = try? JSONDecoder().decode(AuthUser.self, from: data) else { return }
        currentUser = user
        isAuthenticated = true
    }
}

// MARK: - Apple Auth Delegate

private class AppleAuthDelegate: NSObject, ASAuthorizationControllerDelegate {
    let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            authService.failSignIn("Unexpected credential type")
            return
        }

        let id = credential.user
        let email = credential.email
        let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")

        let user = AuthUser(
            id: id,
            email: email,
            displayName: fullName.isEmpty ? nil : fullName,
            provider: .apple,
            openAIKey: nil,
            googlePlacesKey: nil
        )

        Task { @MainActor in
            authService.completeSignIn(user: user)
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            authService.failSignIn(error.localizedDescription)
        }
    }
}

// MARK: - Auth Keychain Helper (separate from OpenAIService's KeychainHelper)

private enum AuthKeychainHelper {
    static func save(_ value: String, account: String, service: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(account: account, service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
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
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}