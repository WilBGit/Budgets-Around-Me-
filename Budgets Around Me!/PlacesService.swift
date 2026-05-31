//
//  PlacesService.swift
//  Budgets Around Me!
//
//  Routes Google Places requests through ProxyService when user is authenticated
//  (server holds API keys), falls back to direct API when not (legacy/beta).
//

import Foundation
internal import CoreLocation

struct Place: Identifiable, Decodable {
    let id = UUID()
    let name: String
    let rating: Double?
    let priceLevel: Int?
    let geometry: Geometry

    struct Geometry: Decodable {
        let location: Location
    }

    struct Location: Decodable {
        let lat: Double
        let lng: Double
    }

    enum CodingKeys: String, CodingKey {
        case name
        case rating
        case priceLevel = "price_level"
        case geometry
    }
}

struct PlacesResponse: Decodable {
    let results: [Place]
    let status: String
}

final class PlacesService {
    static let shared = PlacesService()
    private init() {}

    private let session = URLSession(configuration: .default)

    /// Whether to use the proxy (authenticated) or direct API (legacy)
    private var useProxy: Bool { ProxyService.shared.isAuthenticated }

    /// Resolves API key for direct mode: AuthService (user-entered) > Info.plist > empty
    func resolveApiKey() -> String {
        if let authKey = AuthService.shared.googlePlacesKey?.trimmingCharacters(in: .whitespacesAndNewlines), !authKey.isEmpty {
            return authKey
        }
        if let infoKey = (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !infoKey.isEmpty {
            return infoKey
        }
        return ""
    }

    var isApiKeyAvailable: Bool {
        if useProxy { return true }
        return !resolveApiKey().isEmpty
    }

    func nearbyPlaces(
        apiKey: String? = nil,
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Int = 5000,
        keyword: String? = nil,
        priceMax: Int? = nil
    ) async throws -> [Place] {
        if useProxy {
            return try await nearbyPlacesViaProxy(coordinate: coordinate, radiusMeters: radiusMeters, keyword: keyword, priceMax: priceMax)
        } else {
            return try await nearbyPlacesDirect(apiKey: apiKey, coordinate: coordinate, radiusMeters: radiusMeters, keyword: keyword, priceMax: priceMax)
        }
    }

    // ─── Proxy Mode ────────────────────────────────────────────

    private func nearbyPlacesViaProxy(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Int = 5000,
        keyword: String? = nil,
        priceMax: Int? = nil
    ) async throws -> [Place] {
        // Build type based on price level
        let type = "restaurant"
        let response: ProxyPlacesResponse = try await ProxyService.shared.nearbyPlaces(
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            radius: radiusMeters,
            type: type,
            keyword: keyword
        )

        // Convert proxy response to Place objects
        return response.results?.compactMap { result -> Place? in
            guard let loc = result.geometry?.location,
                  let lat = loc.lat, let lng = loc.lng,
                  abs(lat) <= 90, abs(lng) <= 180,
                  !(lat == 0 && lng == 0) else { return nil }
            return Place(
                name: result.name ?? "Unknown",
                rating: result.rating,
                priceLevel: result.price_level,
                geometry: .init(location: .init(lat: lat, lng: lng))
            )
        } ?? []
    }

    // ─── Direct Mode (legacy) ──────────────────────────────────

    private func nearbyPlacesDirect(
        apiKey: String? = nil,
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Int = 5000,
        keyword: String? = nil,
        priceMax: Int? = nil
    ) async throws -> [Place] {
        let resolvedKey = apiKey ?? resolveApiKey()
        guard !resolvedKey.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/nearbysearch/json")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "key", value: resolvedKey),
            URLQueryItem(name: "location", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "radius", value: String(radiusMeters))
        ]

        if let keyword, !keyword.isEmpty {
            queryItems.append(URLQueryItem(name: "keyword", value: keyword))
        }

        if let priceMax {
            queryItems.append(URLQueryItem(name: "maxprice", value: String(priceMax)))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(PlacesResponse.self, from: data)
        return decoded.results
    }
}