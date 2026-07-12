//
//  CountrySettingsView.swift
//  safeFLY
//
//  The per-country provider submenu reached from Settings, plus the summary row that
//  represents a country in the main settings list.
//

import SwiftUI

struct CountrySettingsView: View {
    @EnvironmentObject private var providersStore: ProvidersStore
    let country: ProviderCountry

    private var sessions: [ProviderSession] {
        country.providerIDs.compactMap { providersStore.providerSession(for: $0) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(sessions) { session in
                    NavigationLink {
                        ProviderDetailView(providerSession: session)
                    } label: {
                        ProviderSummaryRow(
                            providerSession: session,
                            isEnabled: providersStore.isProviderEnabled(session.provider.id)
                        )
                    }
                }
            } header: {
                Text(NSLocalizedString("Providers", comment: "Providers section title"))
            } footer: {
                Text(NSLocalizedString(
                    "Enable provider explanatory text",
                    comment: "Country submenu footer explaining that providers can overlap or add data"
                ))
            }
        }
        .navigationTitle("\(country.flag)  \(country.localizedName)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// One row in the main settings list, standing in for a whole country. The colored dot and
// caption roll up the statuses of the country's providers.
struct CountrySummaryRow: View {
    let country: ProviderCountry
    let status: CountryProviderStatus

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)

            Text(country.flag)

            VStack(alignment: .leading, spacing: 2) {
                Text(country.localizedName)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        switch status {
        case .rollup(let providerStatus):
            return providerStatus.displayTitle
        case .off:
            return NSLocalizedString("Off", comment: "Country has no enabled providers")
        }
    }

    private var dotColor: Color {
        switch status {
        case .rollup(let providerStatus):
            return providerStatus.color
        case .off:
            return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        CountrySettingsView(country: ProviderCountries.all[0])
            .environmentObject(ProvidersStore(registrations: BuiltInProviders.all))
    }
}
