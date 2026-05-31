//
//  MapPlacesView.swift
//  Budgets Around Me!
//

import SwiftUI
import MapKit
internal import CoreLocation
import CoreLocationUI
import UIKit

struct MapPlacesView: View {
    @StateObject private var locationManager = LocationManager()
    @EnvironmentObject var planStore: PlanStore
    @AppStorage("dailyBudget") private var dailyBudget: Double = 40
    @AppStorage("distanceMiles") private var distanceMiles: Double = 5
    @AppStorage("lastUsedKeyword") private var lastUsedKeyword: String = ""
    @AppStorage("lastSuggestionMeta") private var lastSuggestionMeta: String = ""
    @AppStorage("hasOpenedMapBefore") private var hasOpenedMapBefore: Bool = false
    @Binding var refreshTrigger: Bool
    @State private var places: [Place] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedPlace: Place?
    @State private var usedKeyword: String?
    @State private var hasCentered: Bool = false
    @State private var hasRefreshedOnce: Bool = false

    // Filters
    @State private var showFilters: Bool = false
    @State private var minRating: Double = 0
    @State private var userMaxPriceLevel: Int? = nil // 0-4, nil = any

    // Google Places API key — Auth service (user-entered) > Info.plist > env
    private var googleApiKey: String {
        AuthService.shared.googlePlacesKey
            ?? (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String)
            ?? ProcessInfo.processInfo.environment["GOOGLE_PLACES_API_KEY"]
            ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            if let coord = locationManager.coordinate {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    // Radius overlay based on selected distance
                    MapCircle(center: coord, radius: CLLocationDistance(radiusInMeters))
                        .stroke(.blue.opacity(0.4), lineWidth: 2)
                        .foregroundStyle(.blue.opacity(0.12))
                    // Animated pulsing indicator at user location
                    Annotation("", coordinate: coord) {
                        PulsingDot(color: .blue)
                    }
                    ForEach(places) { place in
                        let coordinate = CLLocationCoordinate2D(latitude: place.geometry.location.lat, longitude: place.geometry.location.lng)
                        Annotation(place.name, coordinate: coordinate) {
                            let isSelected = (selectedPlace?.geometry.location.lat == place.geometry.location.lat) && (selectedPlace?.geometry.location.lng == place.geometry.location.lng)
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 24, height: 24)
                                        .shadow(color: .blue.opacity(0.35), radius: 6, x: 0, y: 2)
                                        .scaleEffect(isSelected ? 1.2 : 1.0)
                                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelected)
                                    Text("$")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                }
                                if let lvl = place.priceLevel {
                                    let badgeText = priceSymbols(for: lvl)
                                    Text(badgeText)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(withinBudget(lvl) ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                        .foregroundStyle(withinBudget(lvl) ? .green : .orange)
                                        .clipShape(Capsule())
                                }
                                if let user = locationManager.coordinate {
                                    Text(distanceString(from: user, to: coordinate))
                                        .font(.caption)
                                        .padding(.horizontal, 4)
                                        .background(.ultraThinMaterial)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .onTapGesture { selectedPlace = place }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 8) {
                        Button {
                            Haptics.tap()
                            Task { await refreshPlaces() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())
                    }
                    .padding()
                }
                .mapControls {
                    MapCompass()
                    MapUserLocationButton()
                    MapScaleView()
                }
                .onAppear {
                    cameraPosition = .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
                }
                .onTapGesture { selectedPlace = nil }
            } else {
                VStack(spacing: 12) {
                    Text("We need your location to show nearby places.")
                    if locationManager.authorizationStatus == .notDetermined {
                        LocationButton(.currentLocation) {
                            Haptics.tap()
                            locationManager.requestWhenInUse()
                        }
                        .labelStyle(.titleAndIcon)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(height: 36)
                    } else {
                        Button("Enable Location") {
                            Haptics.tap()
                            if !CLLocationManager.locationServicesEnabled() {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            } else if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            } else {
                                locationManager.requestWhenInUse()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }

            Divider()
            HStack(spacing: 12) {
                Text("Budget: $\(Int(dailyBudget))")
                Divider()
                // Radius chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([1.0, 3.0, 5.0, 10.0, 15.0, 25.0], id: \.self) { miles in
                            let isSelected = miles == distanceMiles
                            Button(action: {
                                Haptics.selection()
                                distanceMiles = miles
                            }) {
                                Text("\(Int(miles)) mi")
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.12))
                                    .foregroundStyle(isSelected ? .blue : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Within \(Int(distanceMiles)) mi")
                    .foregroundStyle(.secondary)
                if let kw = usedKeyword, !kw.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyword: \(kw)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let meta = suggestionMetaText {
                            Text(meta)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button {
                    Haptics.tap()
                    showFilters = true
                } label: {
                    Label("Filters", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                if isLoading { ProgressView() }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .onAppear {
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUse()
            } else {
                locationManager.refresh()
            }
            if usedKeyword == nil && !lastUsedKeyword.isEmpty { usedKeyword = lastUsedKeyword }
        }
        .onChange(of: locationManager.authorizationStatus) {
            if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
                locationManager.refresh()
            }
        }
        .onChange(of: locationManager.coordinate?.latitude) { newValue, oldValue in
            if !hasCentered, let coord = locationManager.coordinate {
                cameraPosition = .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
                hasCentered = true
            }
            if !hasRefreshedOnce {
                hasRefreshedOnce = true
                Task { await refreshPlaces() }
            }
        }
        .navigationTitle("Map")
        .sheet(isPresented: $showFilters) {
            NavigationStack {
                Form {
                    Section("Minimum Rating") {
                        HStack {
                            Slider(value: $minRating, in: 0...5, step: 0.5)
                            Text(String(format: "%.1f", minRating))
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Section("Max Price Level") {
                        Picker("Price", selection: Binding(
                            get: { userMaxPriceLevel ?? -1 },
                            set: { userMaxPriceLevel = ($0 == -1 ? nil : $0) }
                        )) {
                            Text("Any").tag(-1)
                            Text("$").tag(0)
                            Text("$$").tag(1)
                            Text("$$$").tag(2)
                            Text("$$$$").tag(3)
                            Text("$$$$$").tag(4)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .navigationTitle("Filters")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Reset") {
                            Haptics.tap()
                            minRating = 0
                            userMaxPriceLevel = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Haptics.tap()
                            showFilters = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .safeAreaInset(edge: .top) {
            if let selected = selectedPlace, let user = locationManager.coordinate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selected.name)
                            .font(.title3)
                            .lineLimit(1)
                        Spacer()
                        Button("Dismiss") {
                            Haptics.tap()
                            selectedPlace = nil
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack(spacing: 12) {
                        if let rating = selected.rating {
                            Text(String(format: "★ %.1f", rating))
                        }
                        if let price = selected.priceLevel {
                            Text(priceSymbols(for: price))
                                .monospaced()
                        }
                        Text(distanceString(from: user, to: CLLocationCoordinate2D(latitude: selected.geometry.location.lat, longitude: selected.geometry.location.lng)))
                            .foregroundStyle(.secondary)
                        if withinBudget(selected.priceLevel) {
                            Text("Within budget")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    // Pricing and rating breakdown
                    VStack(alignment: .leading, spacing: 6) {
                        if let price = selected.priceLevel {
                            Text("Pricing: \(priceSymbols(for: price))  (0=$ to 4=$$$$$)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Pricing: N/A")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let rating = selected.rating {
                            Text(String(format: "Rating: %.1f / 5.0", rating))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 8) {
                        Button {
                            Haptics.tap()
                            if let p = selectedPlace { planStore.add(place: p) }
                        } label: {
                            Text("Add to Plan")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let p = selectedPlace {
                            Button {
                                Haptics.tap()
                                openInDirections(name: p.name, lat: p.geometry.location.lat, lng: p.geometry.location.lng)
                            } label: {
                                Label("Directions", systemImage: "arrow.triangle.turn.up.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding([.horizontal, .top])
            }
        }
    }

    private func refreshPlaces() async {
        if isLoading { return }
        guard let coord = locationManager.coordinate else { return }
        isLoading = true
        defer { isLoading = false }

        // Map budget to Google price_level (0-4). Heuristic: $ -> 0, $$$$ -> 4
        // Simple mapping using thresholds
        let budgetMaxPriceLevel: Int
        switch dailyBudget {
        case ..<20: budgetMaxPriceLevel = 0
        case 20..<40: budgetMaxPriceLevel = 1
        case 40..<80: budgetMaxPriceLevel = 2
        case 80..<150: budgetMaxPriceLevel = 3
        default: budgetMaxPriceLevel = 4
        }
        // Effective max price level is the stricter of user choice and budget
        let effectiveMaxPrice = min(userMaxPriceLevel ?? 4, budgetMaxPriceLevel)

        do {
            let radiusMeters = radiusInMeters
            // Ask OpenAI for suggested keywords based on budget and coordinates
            var keyword: String? = nil
            do {
                let suggestions = try await OpenAIService.shared.suggestKeywords(budget: dailyBudget, latitude: coord.latitude, longitude: coord.longitude, radiusMiles: distanceMiles)
                keyword = suggestions.first
            } catch {
                // If OpenAI fails, proceed without keyword
                keyword = nil
            }
            let results = try await PlacesService.shared.nearbyPlaces(
                apiKey: googleApiKey,
                coordinate: coord,
                radiusMeters: radiusMeters,
                keyword: keyword,
                priceMax: effectiveMaxPrice
            )

            // Additional filtering: if place has priceLevel, ensure <= mapped price
            let filtered = results.filter { p in
                let priceOk: Bool = {
                    if let pLevel = p.priceLevel { return pLevel <= effectiveMaxPrice }
                    return true
                }()
                let ratingOk: Bool = {
                    if let r = p.rating { return r >= minRating }
                    return minRating == 0
                }()
                return priceOk && ratingOk
            }
            await MainActor.run {
                self.places = filtered
                self.usedKeyword = keyword
                self.lastUsedKeyword = keyword ?? ""
                self.lastSuggestionMeta = suggestionMetaStringFromService() ?? ""
                self.errorMessage = filtered.isEmpty ? "No results found for current filters." : nil
                Haptics.success()
            }
        } catch {
            // In production, surface error to user
            await MainActor.run {
                self.places = []
                self.usedKeyword = nil
                self.errorMessage = "Couldn’t load places. Check API key, billing, and location permission."
                Haptics.error()
            }
        }
    }

    private var suggestionMetaText: String? {
        if let live = suggestionMetaStringFromService() { return live }
        return lastSuggestionMeta.isEmpty ? nil : lastSuggestionMeta
    }

    private func suggestionMetaStringFromService() -> String? {
        let meta = OpenAIService.shared.getLastMeta()
        if meta.errorBackedOff { return "OpenAI busy; using default search" }
        if meta.fromCache { return "Cached suggestions" }
        if meta.usedFallbackParse { return "AI response parsed heuristically" }
        return nil
    }

    private var radiusInMeters: Int {
        Int(distanceMiles * 1609.34)
    }

    private func distanceString(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> String {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let meters = a.distance(from: b)
        let miles = meters / 1609.34
        if miles < 1 {
            let feet = meters * 3.28084
            return "\(Int(feet)) ft"
        } else {
            return String(format: "%.1f mi", miles)
        }
    }

    private func priceSymbols(for level: Int) -> String {
        guard level >= 0 else { return "" }
        let count = min(level + 1, 4)
        return String(repeating: "$", count: count)
    }

    private func withinBudget(_ priceLevel: Int?) -> Bool {
        // Map budget to max price level used in query
        let maxLevel: Int
        switch dailyBudget {
        case ..<20: maxLevel = 0
        case 20..<40: maxLevel = 1
        case 40..<80: maxLevel = 2
        case 80..<150: maxLevel = 3
        default: maxLevel = 4
        }
        guard let level = priceLevel else { return true }
        return level <= maxLevel
    }

    private func openInDirections(name: String, lat: Double, lng: Double) {
        // Guard against invalid coordinates (0,0 = null island from failed parsing)
        guard lat != 0 || lng != 0, abs(lat) <= 90, abs(lng) <= 180 else {
            errorMessage = "Invalid location coordinates."
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        destination.name = name
        // Apple Maps directions — single source of truth
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var animate: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 60, height: 60)
                .scaleEffect(animate ? 1.6 : 0.8)
                .opacity(animate ? 0.0 : 1.0)
                .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: animate)
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .shadow(color: color.opacity(0.6), radius: 6)
        }
        .onAppear { animate = true }
    }
}

#Preview {
    MapPlacesView(refreshTrigger: .constant(false))
        .environmentObject(PlanStore(locationManager: LocationManager()))
}
