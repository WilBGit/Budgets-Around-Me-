import Foundation
import Combine
internal import CoreLocation

struct PlannedPlace: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let priceLevel: Int?
    let scheduledTime: Date?
}

final class PlanStore: ObservableObject {
    @Published private(set) var planned: [PlannedPlace] = [] {
        didSet { savePlanned() }
    }
    @Published var isUpdatingLocation: Bool = false

    private let locationManager: LocationManager
    private var cancellables: Set<AnyCancellable> = []
    private let plannedKey = "plannedPlaces"

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
        loadPlanned()
        bindLocationManager()
    }

    private func savePlanned() {
        do {
            let data = try JSONEncoder().encode(planned)
            UserDefaults.standard.set(data, forKey: plannedKey)
        } catch {
            print("PlanStore: failed to save – \(error)")
        }
    }

    private func loadPlanned() {
        guard let data = UserDefaults.standard.data(forKey: plannedKey) else { return }
        do {
            planned = try JSONDecoder().decode([PlannedPlace].self, from: data)
        } catch {
            print("PlanStore: failed to load – \(error)")
            planned = []
        }
    }

    func add(place: Place) {
        let id = place.name + "|" + String(place.geometry.location.lat) + "," + String(place.geometry.location.lng)
        let p = PlannedPlace(id: id, name: place.name, latitude: place.geometry.location.lat, longitude: place.geometry.location.lng, priceLevel: place.priceLevel, scheduledTime: nil)
        if !planned.contains(p) {
            planned.append(p)
        }
    }

    func addCustom(name: String, latitude: Double, longitude: Double, priceLevel: Int?, scheduledTime: Date?) {
        let id = name + "|" + String(latitude) + "," + String(longitude) + (scheduledTime != nil ? "|\(scheduledTime!.timeIntervalSince1970)" : "")
        let p = PlannedPlace(id: id, name: name, latitude: latitude, longitude: longitude, priceLevel: priceLevel, scheduledTime: scheduledTime)
        if !planned.contains(p) {
            planned.append(p)
        }
    }

    func remove(id: String) {
        planned.removeAll { $0.id == id }
    }

    private func bindLocationManager() {
        // When coordinate updates, stop the spinner
        locationManager.$coordinate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isUpdatingLocation = false
            }
            .store(in: &cancellables)

        // If authorization becomes denied/restricted, stop the spinner
        locationManager.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .denied, .restricted:
                    self?.isUpdatingLocation = false
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func updateToCurrentLocation() {
        isUpdatingLocation = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUse()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.refresh()
        case .denied, .restricted:
            isUpdatingLocation = false
        @unknown default:
            isUpdatingLocation = false
        }
    }
}
