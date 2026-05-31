//
//  Budgets_Around_Me_App.swift
//  Budgets Around Me!
//
//  App entry point — routes to LoginView or ContentView based on auth state.
//  In proxy mode: authenticated = has JWT from server = full access.
//  In legacy mode: authenticated + both API keys = full access.
//

import SwiftUI

@main
struct Budgets_Around_Me_App: App {
    @StateObject private var auth = AuthService.shared
    @StateObject private var locationManager = LocationManager()
    @StateObject private var planStore: PlanStore

    init() {
        let lm = LocationManager()
        _locationManager = StateObject(wrappedValue: lm)
        _planStore = StateObject(wrappedValue: PlanStore(locationManager: lm))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated && auth.hasAllKeys {
                    ContentView()
                        .environmentObject(planStore)
                        .environmentObject(locationManager)
                        .environmentObject(auth)
                } else {
                    LoginView()
                        .environmentObject(auth)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: auth.isAuthenticated)
            .animation(.easeInOut(duration: 0.3), value: auth.hasAllKeys)
        }
    }
}