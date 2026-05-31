import SwiftUI
import UIKit

struct ContentView: View {
    @State private var selectedTab: Int = 0
    @State private var mapRefreshTrigger: Bool = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DailyBudgetView()
            }
            .tabItem {
                Label("Budget", systemImage: "dollarsign.circle")
            }
            .tag(0)

            NavigationStack {
                PlanView()
            }
            .tabItem {
                Label("Plan", systemImage: "calendar")
            }
            .tag(1)

            NavigationStack {
                MapPlacesView(refreshTrigger: $mapRefreshTrigger)
            }
            .tabItem {
                Label("Map", systemImage: "map")
            }
            .tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMap)) { notification in
            Haptics.selection()
            selectedTab = 2
            mapRefreshTrigger.toggle()
        }
    }
}

extension Notification.Name {
    static let navigateToMap = Notification.Name("navigateToMap")
}

#Preview {
    ContentView()
}
