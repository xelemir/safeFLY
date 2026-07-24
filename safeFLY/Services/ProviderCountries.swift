//
//  ProviderCountries.swift
//  safeFLY
//
//  Groups providers by the country a user actually flies in. Settings shows this list of
//  countries first; each country drills into the providers responsible for it. A provider may
//  belong to several countries (the EU nature-reserve layer backfills Austria, Belgium,
//  Luxembourg, the Netherlands and Sweden), so `providerIDs` is intentionally not a partition
//  of the provider set.
//

import Foundation

struct ProviderCountry: Identifiable, Sendable {
    let id: String            // Stable ISO-3166 alpha-2 key; also the settings navigation id.
    let flag: String          // Emoji flag, shown in the country row.
    let nameKey: String       // Localization key for the country's display name.
    let providerIDs: [String] // Providers responsible for this country, in display order.

    var localizedName: String {
        NSLocalizedString(nameKey, comment: "Country name in provider settings")
    }
}

enum ProviderCountries {
    // Germany leads as the free anchor; the rest follow alphabetically by English name. The EU
    // nature-reserve layer is registered as a separate instance per country (one id each), so
    // enabling it in one country does not switch it on in the others.
    static let all: [ProviderCountry] = [
        ProviderCountry(id: "DE", flag: "🇩🇪", nameKey: "country.germany",
                        providerIDs: [DIPULProvider.providerID, DIPULOfflineProvider.providerID]),
        ProviderCountry(id: "AT", flag: "🇦🇹", nameKey: "country.austria",
                        providerIDs: [AustriaProvider.providerID, ProtectedAreasProvider.austriaID]),
        ProviderCountry(id: "BE", flag: "🇧🇪", nameKey: "country.belgium",
                        providerIDs: [BelgiumProvider.providerID, ProtectedAreasProvider.belgiumID]),
        // Czechia (CZ) is intentionally omitted — the ŘLP ČR licence forbids derived/public
        // use regardless of price (see BuiltInProviders in ProvidersStore). CzechService.swift
        // remains in the repo; re-add the country row here once an agreement is secured.
        ProviderCountry(id: "DK", flag: "🇩🇰", nameKey: "country.denmark",
                        providerIDs: [DenmarkProvider.providerID]),
        ProviderCountry(id: "FI", flag: "🇫🇮", nameKey: "country.finland",
                        providerIDs: [FinlandProvider.providerID]),
        ProviderCountry(id: "FR", flag: "🇫🇷", nameKey: "country.france",
                        providerIDs: [FranceProvider.providerID]),
        ProviderCountry(id: "LU", flag: "🇱🇺", nameKey: "country.luxembourg",
                        providerIDs: [LuxembourgProvider.providerID]),
        ProviderCountry(id: "NL", flag: "🇳🇱", nameKey: "country.netherlands",
                        providerIDs: [NetherlandsProvider.providerID, ProtectedAreasProvider.netherlandsID]),
        // Norway carries its own nature reserves (dronesoner.no), so it does not use the EU
        // protected-areas backfill layer.
        ProviderCountry(id: "NO", flag: "🇳🇴", nameKey: "country.norway",
                        providerIDs: [NorwayProvider.providerID]),
        ProviderCountry(id: "SE", flag: "🇸🇪", nameKey: "country.sweden",
                        providerIDs: [SwedenProvider.providerID, ProtectedAreasProvider.swedenID]),
        ProviderCountry(id: "CH", flag: "🇨🇭", nameKey: "country.switzerland",
                        providerIDs: [SwitzerlandProvider.providerID])
    ]
}

// Aggregate state shown on a country's row in the main settings list, condensing that
// country's individual provider statuses into one line.
enum CountryProviderStatus: Equatable {
    // At least one provider is on; the worst status among the enabled providers.
    // "All green" surfaces as `.rollup(.available)`.
    case rollup(ProviderAvailabilityStatus)
    // Providers exist but none are enabled.
    case off
}

extension ProviderAvailabilityStatus {
    // Ordering for the country roll-up: the worst (highest) status wins, so a single failing
    // provider pulls the whole country off "Available".
    var severity: Int {
        switch self {
        case .available:        return 0
        case .unknown:          return 1
        case .degraded:         return 2
        case .downloadRequired: return 3
        case .unavailable:      return 4
        }
    }
}
