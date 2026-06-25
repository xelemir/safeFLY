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

    @EnvironmentObject private var providerSession: ProviderSession
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
            statusSection
            datasetSection

            if !providerSession.provider.referenceLinks.isEmpty {
                referencesSection
            }
        }
        .navigationTitle(providerSession.provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusSection: some View {
        Section {
            HStack {
                Label(providerSession.statusSnapshot.providerStatus.displayTitle, systemImage: providerSession.statusSnapshot.providerStatus.symbolName)
                    .foregroundStyle(providerSession.statusSnapshot.providerStatus.color)

                Spacer()

                if let refreshedAt = providerSession.statusSnapshot.refreshedAt {
                    Text(refreshedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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

    private var datasetSection: some View {
        Section {
            ForEach(Array(datasetSections.enumerated()), id: \.offset) { index, section in
                if let title = section.title {
                    SectionHeader(title: title)
                        .padding(.top, index == 0 ? 0 : 8)
                }

                ForEach(section.datasets) { dataset in
                    ProviderDatasetToggleRow(dataset: dataset)
                }
            }
        } header: {
            Text(NSLocalizedString("Provider Datasets", comment: "Provider datasets section title"))
        } footer: {
            Text(NSLocalizedString("Dataset selection remains editable even when a dataset is temporarily unavailable.", comment: "Provider datasets section footer"))
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
            await providerSession.refreshStatus()
            await MainActor.run {
                isRefreshingStatus = false
            }
        }
    }
}

private struct ProviderDatasetToggleRow: View {
    @EnvironmentObject private var providerSession: ProviderSession

    let dataset: ProviderDataset

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { providerSession.selectedDatasetIDs.contains(dataset.id) },
                set: { providerSession.setDatasetSelected(dataset.id, isSelected: $0) }
            )
        ) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dataset.presentation.title)
                    Text(providerSession.statusSnapshot.status(for: dataset.id).displayTitle)
                        .font(.caption)
                        .foregroundStyle(providerSession.statusSnapshot.status(for: dataset.id).color)
                }

                Spacer(minLength: 12)
            }
        }
    }
}

private struct ProviderSummaryRow: View {
    let providerName: String
    let status: ProviderAvailabilityStatus

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(status.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(providerName)
                Text(status.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
        ProviderDetailView()
            .environmentObject(ProviderSession(provider: DIPULProvider(), normalizer: ZoneFeatureNormalizer()))
    }
}

extension SettingsView {
    var providerSummaryRow: some View {
        ProviderSummaryRow(
            providerName: providerSession.provider.displayName,
            status: providerSession.statusSnapshot.providerStatus
        )
    }
}
