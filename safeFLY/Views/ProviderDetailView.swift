//
//  ProviderDetailView.swift
//  safeFLY
//

import SwiftUI

struct ProviderDetailView: View {
    private struct DatasetSection: Identifiable {
        let title: String?
        var datasets: [ProviderDataset]

        var id: String {
            title ?? "ungrouped"
        }
    }

    @EnvironmentObject private var providersStore: ProvidersStore
    @ObservedObject var providerSession: ProviderSession
    @State private var isRefreshingStatus = false

    private var datasetSections: [DatasetSection] {
        var sections: [DatasetSection] = []

        for dataset in providerSession.datasetCatalog {
            if let index = sections.firstIndex(where: { $0.title == dataset.presentation.groupTitle }) {
                sections[index].datasets.append(dataset)
            } else {
                sections.append(DatasetSection(title: dataset.presentation.groupTitle, datasets: [dataset]))
            }
        }

        return sections
    }

    var body: some View {
        Form {
            enablementSection
            statusSection
            datasetSectionsView

            if !providerSession.provider.referenceLinks.isEmpty {
                referencesSection
            }
        }
        .navigationTitle(providerSession.provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: providerSession.selectedDatasetIDs) { _, _ in
            providersStore.markConfigurationChanged()
        }
    }

    private var enablementSection: some View {
        Section {
            Toggle(
                NSLocalizedString("Enable Provider", comment: "Provider enable toggle label"),
                isOn: Binding(
                    get: { providersStore.isProviderEnabled(providerSession.provider.id) },
                    set: { providersStore.setProviderEnabled(providerSession.provider.id, isEnabled: $0) }
                )
            )
        } footer: {
            Text(NSLocalizedString("Disabled providers do not participate in map rendering or location queries.", comment: "Provider enablement footer"))
        }
    }

    private var statusSection: some View {
        Section {
            Label(providerSession.statusSnapshot.providerStatus.displayTitle, systemImage: providerSession.statusSnapshot.providerStatus.symbolName)
                .foregroundStyle(providerSession.statusSnapshot.providerStatus.color)

            Button {
                refreshStatus()
            } label: {
                if isRefreshingStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("Refreshing Status...", comment: "Provider status refresh in progress"))
                    }
                } else {
                    Text(NSLocalizedString("Refresh Provider Status", comment: "Refresh provider status button"))
                }
            }
            .disabled(isRefreshingStatus)
        } header: {
            Text(NSLocalizedString("Provider Status", comment: "Provider status section title"))
        } footer: {
            if let refreshedAt = providerSession.statusSnapshot.refreshedAt {
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("Last refreshed at %@.", comment: "Provider status last refreshed footer"),
                        refreshedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                )
            } else {
                Text(NSLocalizedString("Provider status has not been refreshed yet.", comment: "Provider status not refreshed footer"))
            }
        }
    }

    @ViewBuilder
    private var datasetSectionsView: some View {
        let sections = datasetSections

        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            Section {
                ForEach(section.datasets) { dataset in
                    ProviderDatasetToggleRow(providerSession: providerSession, dataset: dataset)
                }
            } header: {
                Text(section.title ?? NSLocalizedString("Provider Datasets", comment: "Provider datasets section title"))
            } footer: {
                if index == sections.count - 1 {
                    Text(NSLocalizedString("Dataset selection remains editable even when a dataset is temporarily unavailable.", comment: "Provider datasets section footer"))
                }
            }
        }
    }

    private var referencesSection: some View {
        Section {
            ForEach(providerSession.provider.referenceLinks) { link in
                Link(link.title, destination: link.url)
            }
        } header: {
            Text(NSLocalizedString("Provider References", comment: "Provider references section title"))
        }
    }

    private func refreshStatus() {
        isRefreshingStatus = true

        Task {
            await providersStore.refreshStatus(for: providerSession.provider.id)
            await MainActor.run {
                isRefreshingStatus = false
            }
        }
    }
}

private struct ProviderDatasetToggleRow: View {
    @ObservedObject var providerSession: ProviderSession
    let dataset: ProviderDataset

    private var status: ProviderAvailabilityStatus {
        providerSession.statusSnapshot.status(for: dataset.id)
    }

    // Only surface a status caption when there is something to flag — a healthy or
    // not-yet-checked dataset just shows its name, avoiding a wall of "Available".
    private var statusCaption: String? {
        switch status {
        case .available, .unknown:
            return nil
        case .degraded, .unavailable:
            return status.displayTitle
        }
    }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { providerSession.selectedDatasetIDs.contains(dataset.id) },
                set: { providerSession.setDatasetSelected(dataset.id, isSelected: $0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.presentation.title)

                if let statusCaption {
                    Text(statusCaption)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }
            }
        }
    }
}

struct ProviderSummaryRow: View {
    @ObservedObject var providerSession: ProviderSession
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(summaryColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(providerSession.provider.displayName)
                Text(summaryTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryTitle: String {
        if isEnabled {
            return providerSession.statusSnapshot.providerStatus.displayTitle
        }

        return NSLocalizedString("Disabled", comment: "Provider disabled status")
    }

    private var summaryColor: Color {
        if isEnabled {
            return providerSession.statusSnapshot.providerStatus.color
        }

        return .secondary
    }
}

extension ProviderAvailabilityStatus {
    var displayTitle: String {
        switch self {
        case .unknown:
            return NSLocalizedString("Unknown", comment: "Provider availability unknown")
        case .available:
            return NSLocalizedString("Available", comment: "Provider availability available")
        case .degraded:
            return NSLocalizedString("Degraded", comment: "Provider availability degraded")
        case .unavailable:
            return NSLocalizedString("Unavailable", comment: "Provider availability unavailable")
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            return "questionmark.circle"
        case .available:
            return "checkmark.circle.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown:
            return .secondary
        case .available:
            return .green
        case .degraded:
            return .orange
        case .unavailable:
            return .red
        }
    }
}

#Preview {
    NavigationStack {
        ProviderDetailView(providerSession: ProviderSession(provider: DIPULProvider(), normalizer: ZoneFeatureNormalizer(), autoRefreshStatus: false))
            .environmentObject(ProvidersStore(registrations: BuiltInProviders.all))
    }
}
