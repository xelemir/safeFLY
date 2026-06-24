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
    
    private let germanIndicators = [
        "Deutschland", "Germany", "Baden-Württemberg", "Bayern", "Berlin", "Brandenburg", 
        "Bremen", "Hamburg", "Hessen", "Mecklenburg-Vorpommern", "Niedersachsen", 
        "Nordrhein-Westfalen", "Rheinland-Pfalz", "Saarland", "Sachsen", 
        "Sachsen-Anhalt", "Schleswig-Holstein", "Thüringen"
    ]
    
    override init() {
        super.init()
        completer.delegate = self
        completer.region = MKCoordinateRegion.germany
        completer.resultTypes = [.address, .pointOfInterest]
    }
    
    func updateQuery(_ query: String) {
        completer.queryFragment = query
    }
    
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let filtered = completer.results.filter { completion in
            germanIndicators.contains { indicator in
                completion.subtitle.contains(indicator)
            }
        }
        completions = Array(filtered.prefix(14))
    }
    
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Completer error: \(error)")
        completions = []
    }
}

struct MainTabView: View {
    @StateObject private var droneSettings = DroneSettings()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var searchManager = SearchManager()
    @State private var search: String = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.colorScheme) private var colorScheme
    
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
            
            Tab(value: 3, role: .search) {
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
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            }
            
            if !hasCompletedOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .environmentObject(droneSettings)
    }
}

#Preview {
    MainTabView()
}
