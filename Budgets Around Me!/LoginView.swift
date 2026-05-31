//
//  LoginView.swift
//  Budgets Around Me!
//
//  Authentication screen — Sign in with Apple or Google.
//  After login, the app authenticates with the backend proxy server
//  and receives a JWT. API keys are NEVER on the device.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @ObservedObject var auth = AuthService.shared
    @State private var errorMessage: String?
    @State private var isAuthenticating: Bool = false

    var body: some View {
        ZStack {
            // Background
            LinearGradient(colors: [.purple, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            if isAuthenticating {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Signing in...")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                signInView
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isAuthenticating)
    }

    // MARK: - Sign In View

    private var signInView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo / Title
            VStack(spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(LinearGradient(colors: [.white, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .cyan.opacity(0.5), radius: 20)

                Text("Budgets Around Me!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text("Sign in to discover budget-friendly places near you")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 32)
            }

            // Sign In Buttons
            VStack(spacing: 16) {
                // Sign in with Apple
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Sign in with Google (placeholder until SDK integrated)
                Button {
                    handleGoogleSignIn()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.title3)
                        Text("Sign in with Google")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 6) {
                Text("🔒 Your data is private")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Text("Sign in with Apple or Google to access AI-powered budget suggestions and nearby places.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Apple Sign-In Handler

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }

            // Get the identity token from Apple
            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                errorMessage = "Could not read Apple identity token"
                return
            }

            let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")

            isAuthenticating = true
            errorMessage = nil

            Task {
                do {
                    // Send identity token to our backend proxy → get JWT
                    let response = try await ProxyService.shared.authenticateWithApple(
                        identityToken: identityToken,
                        fullName: fullName.isEmpty ? nil : fullName
                    )

                    // Store the proxy JWT
                    ProxyService.shared.authToken = response.token

                    // Update auth state
                    let user = AuthUser(
                        id: response.user.id,
                        email: response.user.email,
                        displayName: response.user.displayName,
                        provider: .apple,
                        openAIKey: nil,
                        googlePlacesKey: nil
                    )
                    auth.completeSignIn(user: user)
                } catch {
                    errorMessage = "Sign in failed: \(error.localizedDescription)"
                    isAuthenticating = false
                }
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Google Sign-In Handler (placeholder)

    private func handleGoogleSignIn() {
        // Google Sign-In SDK integration needed (SPM dependency: GoogleSignIn)
        // When integrated, this will call GIDSignIn.sharedInstance.signIn(...)
        // and send the resulting idToken to ProxyService.shared.authenticateWithGoogle()

        // For now, create a placeholder and authenticate with proxy
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                // Placeholder: in production, this gets a real Google ID token
                let user = AuthUser(
                    id: "google_\(UUID().uuidString)",
                    email: nil,
                    displayName: "Google User",
                    provider: .google,
                    openAIKey: nil,
                    googlePlacesKey: nil
                )
                auth.completeSignIn(user: user)
                // Note: No proxy JWT for Google placeholder — API calls will fall back to direct mode
            }
        }
    }
}

#Preview {
    LoginView()
}