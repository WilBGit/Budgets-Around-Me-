import SwiftUI
import MapKit
import UIKit

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}

struct PlanView: View {
    @EnvironmentObject var planStore: PlanStore

    var body: some View {
        List {
            if planStore.planned.isEmpty {
                Text("No items in your plan yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(planStore.planned) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.name)
                                .font(.headline)
                            Spacer()
                            if let t = item.scheduledTime {
                                Text(DateFormatter.shortTime.string(from: t))
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        HStack(spacing: 12) {
                            if let price = item.priceLevel {
                                Text(String(repeating: "$", count: min(price + 1, 4)))
                                    .font(.caption)
                            }
                            Spacer()
                            Button {
                                guard item.latitude != 0 || item.longitude != 0,
                                      abs(item.latitude) <= 90, abs(item.longitude) <= 180 else { return }
                                let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)))
                                destination.name = item.name
                                destination.openInMaps(launchOptions: [
                                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
                                ])
                            } label: {
                                Label("Directions", systemImage: "arrow.triangle.turn.up.right")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .onDelete { indexSet in
                    Haptics.tap()
                    indexSet.map { planStore.planned[$0].id }.forEach(planStore.remove)
                }
            }
        }
        .navigationTitle("Your Plan")
    }
}
