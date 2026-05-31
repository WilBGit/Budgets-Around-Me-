//
//  LocationManager.swift
//  Budgets Around Me!
//

import Foundation
internal import CoreLocation
import Combine

final class LocationManager: NSObject, ObservableObject {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func requestWhenInUse() {
        // Ensure location services are enabled before requesting authorization.
        guard CLLocationManager.locationServicesEnabled() else { return }

        // Only ever call the authorization request if the status is not determined yet.
        // Do not start updating location here; wait for the delegate callback
        // `locationManagerDidChangeAuthorization(_:)` to be invoked by the system.
        switch manager.authorizationStatus {
        case .notDetermined:
            // Requesting authorization may present UI; let the system call back via the delegate.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways, .denied, .restricted:
            // No-op here; rely on `locationManagerDidChangeAuthorization` to react to changes.
            break
        @unknown default:
            break
        }
    }

    func refresh() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            // Do not request authorization here; this should only be initiated by an explicit user action via `requestWhenInUse()`.
            break
        case .denied, .restricted:
            manager.stopUpdatingLocation()
        @unknown default:
            break
        }
    }

    // MARK: - Diagnostics
    var isLocationServicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
    var hasWhenInUseUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            DispatchQueue.main.async { [weak self] in
                self?.manager.startUpdatingLocation()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.manager.stopUpdatingLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        coordinate = loc.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Intentionally left minimal. Consider surfacing to UI as needed.
    }
}
