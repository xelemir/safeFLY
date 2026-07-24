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

class SearchManager: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var completions: [MKLocalSearchCompletion] = []

    private var completer = MKLocalSearchCompleter()

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
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let filtered = completer.results.filter { completion in
            activeIndicators.contains { indicator in
                completion.subtitle.contains(indicator)
            }
        }
        completions = Array(filtered.prefix(14))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
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
    @Environment(\.dismissSearch) private var dismissSearch
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
        NavigationStack {
            VStack {
                if searchManager.completions.isEmpty && search.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Search location")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 50)
                } else if searchManager.completions.isEmpty && !search.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No locations found")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 50)
                } else {
                    List(searchManager.completions, id: \.hash) { completion in
                        Button {
                            let request = MKLocalSearch.Request(completion: completion)
                            let localSearch = MKLocalSearch(request: request)
                            localSearch.start { response, error in
                                DispatchQueue.main.async {
                                    if let item = response?.mapItems.first {
                                        let coord = SearchCoordinate(
                                            latitude: item.placemark.coordinate.latitude,
                                            longitude: item.placemark.coordinate.longitude
                                        )
                                        droneSettings.searchedCoordinate = coord
                                        search = ""
                                        dismissSearch()
                                        droneSettings.activeTab = 0
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(completion.title)
                                        .font(.headline)
                                    if !completion.subtitle.isEmpty {
                                        Text(completion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            // No background — results float directly over the map.
                            .background(Color.clear)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    .scrollContentBackground(.hidden)
                }
                Spacer()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $search)
            .onChange(of: search) { _, newValue in
                searchManager.updateQuery(newValue)
            }
        }
        .background(Color.clear)
    }
}

#Preview {
    MainTabView()
}
