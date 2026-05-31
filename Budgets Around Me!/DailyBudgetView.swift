import SwiftUI
internal import CoreLocation

private struct DayPlanEntry: Identifiable {
    let id = UUID()
    let name: String
    let price: Double?
    let time: Date
}

private func resolveDistanceAndName(for suggestion: BudgetSuggestion, userCoordinate: CLLocationCoordinate2D) async -> (name: String, miles: Double)? {
    // Placeholder implementation: return nil so the caller falls back to the suggestion's title and 0.0 miles.
    // You can enhance this by adding coordinate data to BudgetSuggestion and computing distance via CoreLocation.
    return nil
}

private func composeDayPlan(budget: Double, locality: String?, suggestions: [BudgetSuggestion], userCoordinate: CLLocationCoordinate2D) async -> (text: String, entries: [DayPlanEntry]) {
    // Heuristic selection of morning, lunch, shopping, entertainment, and dinner activities
    let morningKeywords = ["breakfast", "coffee", "brunch", "park", "morning", "trail", "hike"]
    let lunchKeywords = ["lunch", "sandwich", "burger", "noodle", "ramen", "pho", "salad", "cafe", "deli", "tapas"]
    let shoppingKeywords = ["shopping", "mall", "market", "thrift", "boutique", "outlet"]
    let entertainmentKeywords = ["museum", "arcade", "movie", "theater", "theatre", "bowling", "mini golf", "gallery", "zoo", "aquarium", "escape room", "concert"]
    let dinnerKeywords = ["dinner", "restaurant", "food", "bar", "bbq", "sushi", "pizza", "tacos", "bistro"]

    func matches(_ suggestion: BudgetSuggestion, keywords: [String]) -> Bool {
        let title = suggestion.title.lowercased()
        let desc = suggestion.description?.lowercased() ?? ""
        let cat = suggestion.category?.lowercased() ?? ""
        return keywords.contains(where: { title.contains($0) || cat.contains($0) || desc.contains($0) })
    }

    // Prefer options with prices (and cheaper ones) to improve budget estimate
    func pick(from list: [BudgetSuggestion], keywords: [String], excluding excludedIDs: Set<AnyHashable>, remainingBudget: Double?) -> BudgetSuggestion? {
        let candidates = list.filter { !excludedIDs.contains($0.id as AnyHashable) && matches($0, keywords: keywords) }
        if candidates.isEmpty { return nil }
        let sorted = candidates.sorted { a, b in
            let aHas = a.price != nil
            let bHas = b.price != nil
            if aHas != bHas { return aHas } // prefer having price
            let ap = a.price ?? Double.greatestFiniteMagnitude
            let bp = b.price ?? Double.greatestFiniteMagnitude
            if ap != bp { return ap < bp }   // then cheaper
            return a.title < b.title         // stable fallback
        }
        if let remaining = remainingBudget {
            if let within = sorted.first(where: { ($0.price ?? remaining) <= remaining }) {
                return within
            }
        }
        return sorted.first
    }

    var picks: [BudgetSuggestion] = []
    var excluded = Set<AnyHashable>()
    var spent: Double = 0

    // Morning
    if let m = pick(from: suggestions, keywords: morningKeywords, excluding: excluded, remainingBudget: budget - spent) {
        picks.append(m)
        excluded.insert(m.id as AnyHashable)
        if let p = m.price { spent += p }
    }
    // Lunch
    if let l = pick(from: suggestions, keywords: lunchKeywords, excluding: excluded, remainingBudget: budget - spent) {
        picks.append(l)
        excluded.insert(l.id as AnyHashable)
        if let p = l.price { spent += p }
    }
    // Shopping
    if let s = pick(from: suggestions, keywords: shoppingKeywords, excluding: excluded, remainingBudget: budget - spent) {
        picks.append(s)
        excluded.insert(s.id as AnyHashable)
        if let p = s.price { spent += p }
    }
    // Entertainment
    if let e = pick(from: suggestions, keywords: entertainmentKeywords, excluding: excluded, remainingBudget: budget - spent) {
        picks.append(e)
        excluded.insert(e.id as AnyHashable)
        if let p = e.price { spent += p }
    }
    // Dinner
    if let d = pick(from: suggestions, keywords: dinnerKeywords, excluding: excluded, remainingBudget: budget - spent) {
        picks.append(d)
        excluded.insert(d.id as AnyHashable)
        if let p = d.price { spent += p }
    }

    // Fallbacks to ensure we always have five activities if possible
    for s in suggestions where picks.count < 5 && !excluded.contains(s.id as AnyHashable) {
        picks.append(s)
        excluded.insert(s.id as AnyHashable)
        if let p = s.price { spent += p }
    }

    // Resolve names and distances for each pick (keep original suggestion for price/menu)
    struct ResolvedStop {
        let name: String
        let miles: Double
        let price: Double?
        let menuItems: [String]?
    }
    var resolved: [ResolvedStop] = []
    for s in picks {
        if let info = await resolveDistanceAndName(for: s, userCoordinate: userCoordinate) {
            resolved.append(ResolvedStop(name: info.name, miles: info.miles, price: s.price, menuItems: s.menuItems))
        } else {
            resolved.append(ResolvedStop(name: s.title, miles: 0.0, price: s.price, menuItems: s.menuItems))
        }
    }

    // Estimate total cost from available prices
    let prices = resolved.compactMap { $0.price }
    let estimatedTotal = prices.reduce(0, +)
    let hasEstimate = !prices.isEmpty

    let locText = locality ?? "your area"
    let budgetInt = Int(budget)

    func milesText(_ miles: Double) -> String {
        let rounded = max(0.1, (miles * 10).rounded() / 10)
        return String(format: "it will be %.1f mi far from you", rounded)
    }
    func priceText(_ price: Double?) -> String {
        guard let price else { return "" }
        return String(format: " ~ $%d", Int(price))
    }
    func menuSuggestion(_ items: [String]?) -> String {
        guard let items, let first = items.first, !first.isEmpty else { return "" }
        return " • Try: \(first)"
    }

    // Dynamic time slots based on current time
    let calendar = Calendar.current
    let now = Date()
    let minute = calendar.component(.minute, from: now)
    let toNextHalfHour = minute == 0 ? 0 : (minute <= 30 ? (30 - minute) : (60 - minute))
    let start = now.addingTimeInterval(TimeInterval(toNextHalfHour * 60))
    let durations: [TimeInterval] = [TimeInterval(2*3600), TimeInterval(1*3600), TimeInterval(2*3600), TimeInterval(2*3600), TimeInterval(1.5*3600)]

    var times: [Date] = []
    var current = start
    for i in 0..<min(resolved.count, 5) {
        times.append(current)
        let dur = i < durations.count ? durations[i] : 3600
        current = current.addingTimeInterval(dur)
    }

    let formatter = DateFormatter()
    formatter.timeStyle = .short

    func slotLabel(_ title: String, index: Int) -> String {
        guard index < times.count else { return title }
        return "\(title) (\(formatter.string(from: times[index])))"
    }

    // Titles for the day
    let titles = ["Morning", "Lunch", "Shopping", "Entertainment", "Dinner"]

    func line(for index: Int, fallback: String) -> String {
        if resolved.indices.contains(index) {
            let r = resolved[index]
            let verb = (index == 0 ? "Start at" : index == 4 ? "Dine at" : index == 2 ? "Head to" : index == 3 ? "Enjoy" : "Visit")
            return "\(slotLabel(titles[index], index: index)): \(verb) \(r.name) (\(milesText(r.miles)))\(priceText(r.price))\(menuSuggestion(r.menuItems))."
        } else {
            return "\(slotLabel(titles[index], index: index)): \(fallback)"
        }
    }

    var lines: [String] = []
    lines.append(line(for: 0, fallback: "Start with a nearby activity."))
    lines.append(line(for: 1, fallback: "Grab lunch at a nearby spot."))
    lines.append(line(for: 2, fallback: "Visit a local shop or market."))
    lines.append(line(for: 3, fallback: "Pick an activity that sounds fun nearby."))
    lines.append(line(for: 4, fallback: "Choose a dinner option that fits your budget."))

    var entries: [DayPlanEntry] = []
    for (idx, r) in resolved.enumerated() {
        if idx < times.count {
            entries.append(DayPlanEntry(name: r.name, price: r.price, time: times[idx]))
        }
    }

    // Travel cost tip (Gas vs EV)
    let totalMiles = resolved.reduce(0.0) { $0 + $1.miles }
    // Simple assumptions: gas 25 mpg at $3.80/gal; EV 0.30 kWh/mi at $0.15/kWh
    let gasPricePerGallon = 3.80
    let mpg = 25.0
    let evKWhPerMile = 0.30
    let kWhPrice = 0.15
    let gasCost = (totalMiles / mpg) * gasPricePerGallon
    let evCost = totalMiles * evKWhPerMile * kWhPrice
    let savings = max(0, gasCost - evCost)

    var planHeader = "With your $\(budgetInt) around \(locText), here's a full-day plan:"
    var planBody = lines.joined(separator: " \n")
    if hasEstimate {
        let totalInt = Int(estimatedTotal)
        planBody += "\nEstimated total for activities: ~$\(totalInt)."
    }
    if savings > 0.0 {
        let travelTip = String(format: "Travel tip: Driving a gas car for ~%.1f mi may cost ~$%.0f; an EV would be ~$%.0f — saving ~$%.0f.", totalMiles, gasCost.rounded(), evCost.rounded(), savings.rounded())
        planBody += "\n\(travelTip)"
    }
    return (planHeader + "\n" + planBody, entries)
}

struct DailyBudgetView: View {
    @AppStorage("dailyBudget") private var dailyBudget: Double = 40
    @State private var locality: String = ""
    @StateObject private var locationManager = LocationManager()
    @State private var isGeneratingPlan: Bool = false
    @State private var planText: String? = nil
    @State private var planError: String? = nil
    @State private var animateHue: Bool = false
    @State private var displayedBudget: Int = 40
    @State private var previousBudget: Double? = nil

    @State private var interactionIntensity: CGFloat = 0
    @State private var sparkles: [Sparkle] = []
    @State private var viewportSize: CGSize = .zero
    @State private var dollarBounce: Bool = false
    @State private var confetti: [ConfettiPiece] = []

    @EnvironmentObject var planStore: PlanStore
    @State private var planEntries: [DayPlanEntry] = []
    @State private var didAddAllToPlan: Bool = false

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportSize = proxy.size }
                    .onChange(of: proxy.size) { newValue, oldValue in viewportSize = newValue }
            }

            // Animated gradient backdrop
            LinearGradient(colors: [.purple, .blue, .pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            
            // Removed FloatingParticles overlay

            // Sparkles overlay
            ZStack {
                ForEach(sparkles) { s in
                    SparkleDot(x: s.x, y: s.y, size: s.size)
                }
            }
            .allowsHitTesting(false)

            // Confetti overlay
            ZStack {
                ForEach(confetti) { c in
                    ConfettiPieceView(piece: c)
                }
            }
            .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 20) {
                    // Header Card: Budget with big number and slider
                    GlassCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Daily Budget")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("$")
                                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .scaleEffect(dollarBounce ? 1.15 : 1.0)
                                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: dollarBounce)
                                        Text("\(displayedBudget)")
                                            .font(.system(size: 56, weight: .bold, design: .rounded))
                                            .foregroundStyle(LinearGradient(colors: [.white, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .shadow(color: .cyan.opacity(0.4), radius: 10, x: 0, y: 0)
                                            .contentTransition(.numericText(value: Double(displayedBudget)))
                                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: displayedBudget)
                                    }
                                }
                                Spacer()
                                Text("Fun Mode")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().stroke(LinearGradient(colors: [.cyan.opacity(0.7), .purple.opacity(0.5)], startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                                    )
                            }
                            VStack(spacing: 10) {
                                Slider(value: $dailyBudget, in: 5...300, step: 5)
                                    .tint(.cyan)
                                HStack {
                                    Text("$5")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("$300")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("Set how much you want to spend today—this helps filter places and tailor your AI plan.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Plan Controls
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Plan")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            // Removed TextField for locality

                            HStack(spacing: 12) {
                                // Removed Button for "Find places on map"

                                Button {
                                    Haptics.tap()
                                    Task { await generateAIPlan() }
                                } label: {
                                    Label("AI Day Plan", systemImage: "sparkles")
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(NeonButtonStyle(gradient: LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)))
                            }

                            if isGeneratingPlan {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Generating your plan…")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 6)
                            }

                            if let planError {
                                Text(planError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                    }

                    // Suggested Plan Output
                    if let planText {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("Suggested Plan", systemImage: "wand.and.stars")
                                        .font(.headline)
                                    Spacer()
                                }
                                // Render plan lines with highlighted categories and times
                                VStack(alignment: .leading, spacing: 10) {
                                    let lines = planText.split(separator: "\n").map(String.init)
                                    Text("Your Day Plan")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { EmptyView() } else if line.hasPrefix("With your $") {
                                            EmptyView()
                                        } else {
                                            if let colon = line.firstIndex(of: ":") {
                                                let category = String(line[..<colon])
                                                let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text(category)
                                                        .fontWeight(.semibold)
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(rest)
                                                            .font(.callout)
                                                        if idx < planEntries.count {
                                                            Text("Time: \(DateFormatter.bamShortTime.string(from: planEntries[idx].time))")
                                                                .font(.caption)
                                                                .foregroundStyle(.secondary)
                                                            HStack(spacing: 8) {
                                                                Button {
                                                                    let e = planEntries[idx]
                                                                    openInAppleMaps(name: e.name)
                                                                } label: { Label("Apple Maps", systemImage: "map") }
                                                                .buttonStyle(.bordered)
                                                                Button {
                                                                    let e = planEntries[idx]
                                                                    openInGoogleMaps(name: e.name)
                                                                } label: { Label("Google Maps", systemImage: "globe") }
                                                                .buttonStyle(.bordered)
                                                            }
                                                        }
                                                    }
                                                }
                                            } else {
                                                Text(line)
                                                    .font(.callout)
                                            }
                                        }
                                    }
                                }
                                if !didAddAllToPlan {
                                    Button {
                                        Haptics.tap()
                                        addAllEntriesToPlan()
                                        didAddAllToPlan = true
                                    } label: {
                                        Label("Add All to Plan", systemImage: "plus.circle.fill")
                                            .fontWeight(.semibold)
                                    }
                                    .buttonStyle(NeonButtonStyle(gradient: LinearGradient(colors: [.green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
                                }
                            }
                        }
                    }

                    // Footer fun note
                    Text("Tip: Try different budgets to see how the vibe changes ✨")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                }
                .padding()
            }
        }
        .navigationTitle("Daily Budget")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // animateHue = true  // Removed per instructions
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUse()
            } else {
                locationManager.refresh()
            }

            displayedBudget = Int(dailyBudget)
            previousBudget = dailyBudget

            interactionIntensity = 0
        }
        .onChange(of: dailyBudget) { newValue, oldValue in
            // Animate numeric display
            displayedBudget = Int(newValue)

            // Haptic pulses and sparkle bursts on threshold crossings
            let thresholds: [Double] = [20, 40, 80, 150, 300]
            var crossed = false
            if let prev = previousBudget {
                for t in thresholds {
                    if (prev < t && newValue >= t) || (prev >= t && newValue < t) {
                        Haptics.tap(style: .medium)
                        crossed = true
                        break
                    }
                }
            }
            if crossed { triggerSparkles() }

            if let prev = previousBudget, abs(newValue - prev) >= 50 {
                Haptics.success()
                triggerConfetti()
            }

            // Bounce the dollar symbol
            dollarBounce = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dollarBounce = false }

            // Particle responsiveness
            interactionIntensity = 1.0
            withAnimation(.easeOut(duration: 1.0)) { interactionIntensity = 0.0 }

            previousBudget = newValue
        }
    }

    private func generateAIPlan() async {
        if isGeneratingPlan { return }
        isGeneratingPlan = true
        planError = nil
        defer { isGeneratingPlan = false }

        // Determine coordinates (optional)
        let coord = locationManager.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)

        do {
            let suggestions = try await OpenAIService.shared.suggestIdeas(
                budget: dailyBudget,
                latitude: coord.latitude,
                longitude: coord.longitude,
                locality: locality.isEmpty ? nil : locality,
                radiusMiles: 10
            )
            let result = await composeDayPlan(
                budget: dailyBudget,
                locality: locality.isEmpty ? nil : locality,
                suggestions: suggestions,
                userCoordinate: coord
            )
            await MainActor.run {
                self.planText = result.text
                self.planEntries = result.entries
            }
        } catch {
            await MainActor.run {
                self.planError = "Couldn’t load AI suggestions. Check your OpenAI API key and network."
                self.planText = nil
            }
        }
    }

    private func triggerSparkles() {
        let count = 12
        var newOnes: [Sparkle] = []
        let width = max(viewportSize.width, 1)
        let height = max(viewportSize.height * 0.35, 200)
        for _ in 0..<count {
            let x = CGFloat.random(in: width * 0.1 ... width * 0.9)
            let y = CGFloat.random(in: height * 0.15 ... height * 0.85)
            let size = CGFloat.random(in: 4...10)
            newOnes.append(Sparkle(x: x, y: y, size: size))
        }
        sparkles = newOnes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.3)) { sparkles.removeAll() }
        }
    }
    
    private func triggerConfetti() {
        let count = 24
        var pieces: [ConfettiPiece] = []
        let width = max(viewportSize.width, 1)
        let height = max(viewportSize.height, 1)
        let originY = height * 0.18
        for _ in 0..<count {
            let startX = CGFloat.random(in: width * 0.2 ... width * 0.8)
            let endX = startX + CGFloat.random(in: -120...120)
            let endY = originY + CGFloat.random(in: 220...420)
            let size = CGFloat.random(in: 6...12)
            let color = [Color.cyan, Color.purple, Color.pink, Color.blue, Color.mint, Color.orange, Color.yellow].randomElement()!
            let rotation = Double.random(in: -180...180)
            pieces.append(ConfettiPiece(xStart: startX, yStart: originY, xEnd: endX, yEnd: endY, size: size, color: color, rotation: rotation))
        }
        confetti = pieces
        // Clear after animation ends
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { confetti.removeAll() }
    }

    private func addAllEntriesToPlan() {
        guard let coord = locationManager.coordinate else { return }
        for entry in planEntries {
            let level: Int? = {
                guard let p = entry.price else { return nil }
                switch p {
                case ..<20: return 0
                case 20..<40: return 1
                case 40..<80: return 2
                case 80..<150: return 3
                default: return 4
                }
            }()
            planStore.addCustom(name: entry.name, latitude: coord.latitude, longitude: coord.longitude, priceLevel: level, scheduledTime: entry.time)
        }
        Haptics.success()
    }

    private func openInAppleMaps(name: String) {
        guard let coord = locationManager.coordinate else { return }
        let urlString = "http://maps.apple.com/?ll=\(coord.latitude),\(coord.longitude)&q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
    }

    private func openInGoogleMaps(name: String) {
        guard let coord = locationManager.coordinate else { return }
        if let url = URL(string: "comgooglemaps://?q=\(coord.latitude),\(coord.longitude)(\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))&center=\(coord.latitude),\(coord.longitude)&zoom=14"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let web = URL(string: "https://www.google.com/maps/search/?api=1&query=\(coord.latitude),\(coord.longitude)") {
            UIApplication.shared.open(web)
        }
    }
}

private struct GlassCard<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        content()
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.25), .cyan.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 6)
    }
}

private struct NeonButtonStyle: ButtonStyle {
    var gradient: LinearGradient
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(gradient)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .foregroundStyle(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .cyan.opacity(0.4), radius: 12, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct FloatingParticles: View {
    var intensity: CGFloat
    @State private var startDate = Date()
    private let particles: [Particle] = (0..<40).map { _ in Particle.random() }

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSince(startDate)
            Canvas { context, size in
                context.addFilter(.blur(radius: 6))
                let trailCount = Int(max(2, min(8, intensity * 10)))
                let trailStep = 0.06
                for p in particles {
                    // Main dot
                    let pt = p.position(at: time, in: size, speedMultiplier: 1.0 + 0.7 * Double(intensity))
                    let radius = p.radius
                    let rect = CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)
                    let path = Path(ellipseIn: rect)
                    context.fill(path, with: .radialGradient(Gradient(stops: [
                        .init(color: p.color.opacity(0.85), location: 0.0),
                        .init(color: p.color.opacity(0.0), location: 1.0)
                    ]), center: pt, startRadius: 0, endRadius: radius))

                    // Trail dots
                    if trailCount > 0 {
                        for i in 1...trailCount {
                            let backTime = time - Double(i) * trailStep
                            let backPt = p.position(at: backTime, in: size, speedMultiplier: 1.0)
                            let trailAlpha = max(0, (1.0 - Double(i) / Double(trailCount))) * Double(intensity)
                            let tr = radius * CGFloat(1.0 - (Double(i) / Double(trailCount)) * 0.6)
                            let backRect = CGRect(x: backPt.x - tr, y: backPt.y - tr, width: tr * 2, height: tr * 2)
                            let backPath = Path(ellipseIn: backRect)
                            context.fill(backPath, with: .radialGradient(Gradient(stops: [
                                .init(color: p.color.opacity(trailAlpha * 0.7), location: 0.0),
                                .init(color: p.color.opacity(0.0), location: 1.0)
                            ]), center: backPt, startRadius: 0, endRadius: tr))
                        }
                    }
                }
            }
        }
    }
}

private struct Sparkle: Identifiable { let id = UUID(); let x: CGFloat; let y: CGFloat; let size: CGFloat }

private struct SparkleDot: View {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    @State private var fadeOut = false
    @State private var spin: Double = 0

    var body: some View {
        StarShape(points: 5, innerRatio: 0.45)
            .fill(LinearGradient(colors: [Color.yellow, Color.white], startPoint: .top, endPoint: .bottom))
            .frame(width: size * 1.6, height: size * 1.6)
            .position(x: x, y: y)
            .rotationEffect(.degrees(spin))
            .scaleEffect(fadeOut ? 1.6 : 0.6)
            .opacity(fadeOut ? 0.0 : 1.0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { fadeOut = true }
                withAnimation(.linear(duration: 0.9)) { spin = Double.random(in: 180...540) }
            }
    }
}

private struct StarShape: Shape {
    let points: Int
    let innerRatio: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let angle = .pi / Double(points)
        var currentAngle = -Double.pi / 2
        var firstPoint = true
        for i in 0..<(points * 2) {
            let radius = (i % 2 == 0) ? outer : inner
            let x = center.x + CGFloat(cos(currentAngle)) * radius
            let y = center.y + CGFloat(sin(currentAngle)) * radius
            if firstPoint {
                path.move(to: CGPoint(x: x, y: y))
                firstPoint = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            currentAngle += angle
        }
        path.closeSubpath()
        return path
    }
}

private struct Particle: Identifiable {
    let id = UUID()
    let seedX: Double
    let seedY: Double
    let speed: Double
    let radius: CGFloat
    let color: Color

    static func random() -> Particle {
        Particle(
            seedX: Double.random(in: 0...1),
            seedY: Double.random(in: 0...1),
            speed: Double.random(in: 0.02...0.08),
            radius: CGFloat.random(in: 8...22),
            color: [Color.cyan, Color.purple, Color.pink, Color.blue].randomElement()!.opacity(0.9)
        )
    }

    func position(at time: TimeInterval, in size: CGSize, speedMultiplier: Double = 1.0) -> CGPoint {
        let w = size.width
        let h = size.height
        let s = speed * speedMultiplier
        let x = (sin((seedX * 2 * .pi) + time * s) * 0.5 + 0.5) * w
        let y = (cos((seedY * 2 * .pi) + time * s * 0.9) * 0.5 + 0.5) * h
        return CGPoint(x: x, y: y)
    }
}

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let xStart: CGFloat
    let yStart: CGFloat
    let xEnd: CGFloat
    let yEnd: CGFloat
    let size: CGFloat
    let color: Color
    let rotation: Double
}

private struct ConfettiPieceView: View {
    let piece: ConfettiPiece
    @State private var anim = false

    var body: some View {
        RoundedRectangle(cornerRadius: piece.size / 3)
            .fill(piece.color)
            .frame(width: piece.size, height: piece.size * 1.6)
            .rotationEffect(.degrees(anim ? piece.rotation : 0))
            .position(x: piece.xStart, y: piece.yStart)
            .offset(x: anim ? (piece.xEnd - piece.xStart) : 0, y: anim ? (piece.yEnd - piece.yStart) : 0)
            .opacity(anim ? 1 : 0.8)
            .onAppear {
                withAnimation(.interpolatingSpring(stiffness: 70, damping: 12)) { anim = true }
            }
    }
}

#Preview {
    NavigationStack { DailyBudgetView() }
}

private extension DateFormatter {
    static let bamShortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
