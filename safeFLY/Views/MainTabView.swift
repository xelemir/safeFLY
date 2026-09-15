//
//  MainTabView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI
import Combine
import CoreLocation
import MapKit

// One row of the search list. `id` carries the rank so duplicate place names can never
// collide inside a ForEach, and the title is pre-rendered with the completer's highlight
// ranges so the part the user actually typed reads bold.
struct SearchSuggestion: Identifiable, Hashable {
    let id: String
    let title: AttributedString
    let subtitle: String
    let completion: MKLocalSearchCompletion

    static func == (lhs: SearchSuggestion, rhs: SearchSuggestion) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

class SearchManager: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [SearchSuggestion] = []
    // True between accepting a query fragment and the completer answering, so the list can
    // show a spinner instead of flashing the "no results" state on every keystroke.
    @Published private(set) var isLoading = false

    private var completer = MKLocalSearchCompleter()
    private var activeSearch: MKLocalSearch?

    // Subtitle indicators per covered country (keyed by `ProviderCountry.id`). Subtitles for
    // German results usually show the state rather than the country, so every Bundesland is
    // listed; everywhere else the country name (German + English + local) is enough.
    private static let indicatorsByCountry: [String: [String]] = [
        "DE": ["Deutschland", "Germany", "Baden-Württemberg", "Bayern", "Berlin", "Brandenburg",
               "Bremen", "Hamburg", "Hessen", "Mecklenburg-Vorpommern", "Niedersachsen",
               "Nordrhein-Westfalen", "Rheinland-Pfalz", "Saarland", "Sachsen",
               "Sachsen-Anhalt", "Schleswig-Holstein", "Thüringen"],
        "FR": ["Frankreich", "France"],
        "AT": ["Österreich", "Austria"],
        "NL": ["Niederlande", "Netherlands", "Nederland"],
        // Switzerland (+ Liechtenstein, which the Swiss provider also covers)
        "CH": ["Schweiz", "Switzerland", "Suisse", "Svizzera", "Svizra", "Liechtenstein"],
        "LU": ["Luxemburg", "Luxembourg", "Lëtzebuerg"],
        // CZ search aliases removed with its country row (licence restrictions); the provider
        // file stays in the repo — re-add when the country returns.
        "BE": ["Belgien", "Belgium", "België", "Belgique"],
        "DK": ["Dänemark", "Denmark", "Danmark"],
        "SE": ["Schweden", "Sweden", "Sverige"],
        "FI": ["Finnland", "Finland", "Suomi", "Åland"],
        "NO": ["Norwegen", "Norway", "Norge", "Noreg"]
    ]

    // Countries the search currently accepts results from. Kept in sync with the countries
    // that have at least one enabled provider, so search availability always matches the
    // countries turned on in Settings.
    private var activeIndicators: [String] = SearchManager.indicators(for: nil)

    override init() {
        super.init()
        completer.delegate = self
        completer.region = MKCoordinateRegion.supportedCountries
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // `nil` or an empty set falls back to every covered country, so search never goes
    // completely dead while the user is still setting providers up.
    private static func indicators(for countryIDs: Set<String>?) -> [String] {
        let ids: [String]
        if let countryIDs, !countryIDs.isEmpty {
            ids = ProviderCountries.all.map(\.id).filter { countryIDs.contains($0) }
        } else {
            ids = ProviderCountries.all.map(\.id)
        }
        return ids.flatMap { indicatorsByCountry[$0] ?? [] }
    }

    func updateEnabledCountries(_ countryIDs: Set<String>) {
        activeIndicators = SearchManager.indicators(for: countryIDs)
    }

    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field must also empty the results. Without this the completer simply
        // stops answering and the last query's rows stay on screen.
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        isLoading = true
        completer.queryFragment = trimmed
    }

    // Drops every result and cancels work in flight. Called when the field is cleared and
    // after a result is picked, so returning to the tab never shows a stale list.
    func clear() {
        activeSearch?.cancel()
        activeSearch = nil
        completer.cancel()
        suggestions = []
        isLoading = false
    }

    // Turns a completion into real coordinates. Any previous lookup is cancelled first, so
    // quickly tapping two rows can't have the loser's response win the race.
    @MainActor
    func resolve(_ suggestion: SearchSuggestion) async -> SearchCoordinate? {
        activeSearch?.cancel()
        let localSearch = MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion.completion))
        activeSearch = localSearch
        defer { if activeSearch === localSearch { activeSearch = nil } }

        guard let item = try? await localSearch.start().mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        return SearchCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let filtered = completer.results.filter { completion in
            activeIndicators.contains { indicator in
                completion.subtitle.contains(indicator)
            }
        }
        suggestions = filtered.prefix(14).enumerated().map { index, completion in
            SearchSuggestion(
                id: "\(index)\u{1F}\(completion.title)\u{1F}\(completion.subtitle)",
                title: SearchManager.highlighted(completion.title, ranges: completion.titleHighlightRanges),
                subtitle: completion.subtitle,
                completion: completion
            )
        }
        isLoading = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
        isLoading = false
    }

    // Bolds the substrings the completer matched against the query.
    private static func highlighted(_ text: String, ranges: [NSValue]) -> AttributedString {
        var attributed = AttributedString(text)
        for value in ranges {
            guard let range = Range(value.rangeValue, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed),
                  lower < upper else { continue }
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}

struct MainTabView: View {
    @StateObject private var droneSettings = DroneSettings()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var searchManager = SearchManager()
    @StateObject private var providersStore = ProvidersStore(registrations: BuiltInProviders.all)
    @StateObject private var offlineMapStore = OfflineMapStore()
    @State private var search: String = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        ZStack {
            TabView(selection: $droneSettings.activeTab) {
            Tab(value: 0) {
                MapView()
            } label: {
                if #available(iOS 26, *) {
                    Label("Fly", systemImage: "airplane.up.right")
                } else {
                    Label("Map", systemImage: "map")
                }
            }

            Tab(value: 1) {
                NavigationStack {
                    WeatherView()
                }
            } label: {
                Label("Weather", systemImage: "cloud.sun.fill")
            }
            
            if #available(iOS 26, *) {
                Tab(value: 3, role: .search) {
                    searchTabContent
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            } else {
                Tab(value: 3) {
                    searchTabContent
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            }
            
            if !hasCompletedOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .environmentObject(droneSettings)
        .environmentObject(providersStore)
        .environmentObject(offlineMapStore)
        // Entry point for safefly:// links (the App Store in-app event card links here).
        // Every link lands on the map, where the geozones and offline maps live; the scheme
        // is registered in Info.plist under CFBundleURLTypes.
        .onOpenURL { url in
            guard url.scheme == "safefly" else { return }
            droneSettings.activeTab = 0
        }
        // Keep place search scoped to the countries that actually have a provider turned on,
        // so every enabled country is searchable (and newly enabled ones become so instantly).
        .onAppear { searchManager.updateEnabledCountries(enabledCountryIDs) }
        .onChange(of: providersStore.enabledProviderIDs) { _, _ in
            searchManager.updateEnabledCountries(enabledCountryIDs)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await providersStore.refreshAllStatuses(force: true)
                }
                // Silently keep downloaded offline datasets (NL, AT) up to date, at most
                // once a day per provider. Fully in the background; invisible to the user.
                providersStore.refreshDownloadableDatasetsInBackground()
            }
        }
    }

    // Countries with at least one enabled provider — the set place search accepts results
    // from. A country with nothing switched on renders nothing, so it isn't searchable either.
    private var enabledCountryIDs: Set<String> {
        Set(ProviderCountries.all
            .filter { country in country.providerIDs.contains { providersStore.isProviderActive($0) } }
            .map(\.id))
    }

    private var searchTabContent: some View {
        SearchTabView(searchManager: searchManager, search: $search)
    }
}

// MARK: - Search tab

private struct SearchTabView: View {
    @ObservedObject var searchManager: SearchManager
    @Binding var search: String

    var body: some View {
        NavigationStack {
            SearchResultsView(searchManager: searchManager, search: $search)
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: Text("Search location"))
                .onChange(of: search) { _, newValue in
                    searchManager.updateQuery(newValue)
                }
        }
    }
}

// Split out from SearchTabView on purpose: `dismissSearch` only works when it is read by a
// view *inside* the searchable container. Read from the parent it silently does nothing,
// which is why the keyboard used to stay up after picking a result.
private struct SearchResultsView: View {
    @ObservedObject var searchManager: SearchManager
    @Binding var search: String

    @EnvironmentObject private var droneSettings: DroneSettings
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var resolvingID: SearchSuggestion.ID?
    @State private var showResolveError = false

    var body: some View {
        content
            .alert("Couldn't open that place", isPresented: $showResolveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try again or pick another result.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if !searchManager.suggestions.isEmpty {
            resultsList
        } else if searchManager.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.isEmpty {
            ContentUnavailableView {
                Label("Search location", systemImage: "mappin.and.ellipse")
            } description: {
                Text("Find a town, address, or landmark to move the map there.")
            }
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private var resultsList: some View {
        List(searchManager.suggestions) { suggestion in
            Button {
                select(suggestion)
            } label: {
                row(for: suggestion)
            }
            .buttonStyle(.plain)
            // One lookup at a time: the rows stay tappable-looking but inert while a
            // selection resolves, so a second tap can't race the first.
            .disabled(resolvingID != nil)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(for suggestion: SearchSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if resolvingID == suggestion.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func select(_ suggestion: SearchSuggestion) {
        guard resolvingID == nil else { return }
        resolvingID = suggestion.id
        Task {
            let coordinate = await searchManager.resolve(suggestion)
            resolvingID = nil
            guard let coordinate else {
                showResolveError = true
                return
            }
            droneSettings.searchedCoordinate = coordinate
            search = ""
            searchManager.clear()
            dismissSearch()
            droneSettings.activeTab = 0
        }
    }
}

#Preview {
    MainTabView()
}
