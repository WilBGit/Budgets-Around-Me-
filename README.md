# Budgets Around Me!

A native SwiftUI iOS app for turning everyday spending into a simple, location-aware budget plan. The app combines personal budget planning with nearby place discovery so a user can make a spending decision in context rather than treating a budget as a static spreadsheet.

## What the app is designed to do

- Let a user create and review a daily or recurring spending plan.
- Present a clear budget-first home experience with lightweight progress feedback.
- Use location to find relevant nearby places through the server-side Places proxy.
- Use an AI assistant through the protected backend boundary instead of embedding a provider key in the app binary.
- Support sign-in flows and local plan persistence through focused SwiftUI services.
- Keep privacy and configuration concerns separate from the user interface.

## Main building blocks

- `ContentView.swift` — primary app shell and navigation.
- `PlanView.swift`, `DailyBudgetView.swift`, and `PlanStore.swift` — plan creation, daily budget presentation, and local state.
- `LocationManager.swift` — location permission and location updates.
- `MapPlacesView.swift` and `PlacesService.swift` — nearby discovery and map-oriented presentation.
- `OpenAIService.swift` and `ProxyService.swift` — authenticated server-backed AI and API requests.
- `AuthService.swift` and `LoginView.swift` — authentication flow.
- `Assets.xcassets/` and `PrivacyInfo.xcprivacy` — app presentation and privacy declarations.

## Security model

The iOS app is intentionally not the place for provider secrets. OpenAI and Google Places credentials belong on the server in `budgets-proxy`. Local Xcode configuration should be based on the provided example file and must remain untracked. Do not put API keys in Swift source, plist files, screenshots, or committed build settings.

The app should also request location only when the nearby-discovery feature needs it and should explain that use clearly to the user.

## Getting started

1. Open the Xcode project on a macOS machine with the required iOS SDK.
2. Create local configuration from `.env.xcconfig.example` using the project's private Xcode configuration workflow.
3. Start and verify the companion `budgets-proxy` service.
4. Select the app scheme and a simulator or connected device.
5. Build and run from Xcode.
6. Test authentication, budget creation, nearby discovery, and the AI request path independently.

## Companion backend

The app is intended to work with:

https://github.com/WilBGit/budgets-proxy

That service keeps provider credentials server-side and exposes authenticated application endpoints for AI and place discovery.

## Project status

This repository is the iOS application layer. Product polish, provider configuration, App Store compliance, and production deployment remain separate release tasks. The source is not a substitute for a completed privacy review or production security review.
