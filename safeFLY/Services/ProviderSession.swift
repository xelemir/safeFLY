//
//  ProviderSession.swift
//  safeFLY
//

import Foundation
import Combine

protocol GeospatialProvider: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var attributionName: String { get }
    nonisolated var capabilities: ProviderCapabilities { get }
    nonisolated var datasets: [ProviderDataset] { get }
    nonisolated var referenceLinks: [ProviderReferenceLink] { get }
    
    nonisolated var downloadURL: URL? { get }
    nonisolated var isDataDownloaded: Bool { get }
    nonisolated var datasetLastUpdated: Date? { get }
    // Minimum time between silent background refreshes of a downloadable dataset. Providers
    // whose feed changes frequently (e.g. Luxembourg) can lower this to refresh every
    // foreground; the default keeps large datasets to once a day.
    nonisolated var datasetRefreshInterval: TimeInterval { get }
    // Whether the dataset should be fetched automatically on foreground even before the user
    // has explicitly downloaded it. Used for small, frequently-updated feeds.
    nonisolated var autoDownloadsDataset: Bool { get }
    nonisolated func downloadData() async throws
    nonisolated func deleteData()

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot
    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload]
    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome

    nonisolated func intersects(_ region: MapRegion) -> Bool
}

extension GeospatialProvider {
    nonisolated var attributionName: String { displayName }
    nonisolated var downloadURL: URL? { nil }
    nonisolated var isDataDownloaded: Bool { true }
    nonisolated var datasetLastUpdated: Date? { nil }
    nonisolated var datasetRefreshInterval: TimeInterval { 24 * 3600 }
    nonisolated var autoDownloadsDataset: Bool { false }
    nonisolated func downloadData() async throws {}
    nonisolated func deleteData() {}
    nonisolated func intersects(_ region: MapRegion) -> Bool { true }
}

protocol ZoneFeatureNormalizing: Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature]
}

struct ProviderStatusRefreshJob: Sendable {
    let providerID: String
    let provider: any GeospatialProvider
    let supportsStatusRefresh: Bool
    let fallbackSnapshot: ProviderStatusSnapshot
}

struct ProviderRenderJob: Sendable {
    let providerID: String
    let provider: any GeospatialProvider
    let request: ProviderRenderRequest
    let selectedDatasetIDs: Set<String>
    let statusSnapshot: ProviderStatusSnapshot
}

struct ProviderQueryJob: Sendable {
    let providerID: String
    let provider: any GeospatialProvider
    let request: ProviderPointQueryRequest
    let selectedDatasetIDs: Set<String>
    let statusSnapshot: ProviderStatusSnapshot
}

@MainActor
final class ProviderSession: ObservableObject, Identifiable {
    @Published private(set) var statusSnapshot: ProviderStatusSnapshot
    @Published private(set) var renderPayloads: [ProviderRenderPayload] = []
    @Published private(set) var zoneQueryResult: ZoneQueryResult?
    @Published private(set) var isLoading = false
    @Published var selectedDatasetIDs: Set<String> {
        didSet {
            persistSelectedDatasetIDs()
        }
    }

    let provider: any GeospatialProvider

    var id: String {
        provider.id
    }

    private let normalizer: any ZoneFeatureNormalizing
    private let selectionStorageKey: String
    private let statusStorageKey: String

    // How long a persisted status snapshot is trusted before the provider is probed
    // again. Within this window a layer flagged as broken stays hidden and we retry it
    // only in the background after the cooldown, matching the original resilience.
    static let statusRefreshCooldown: TimeInterval = 12 * 3600

    init(
        provider: any GeospatialProvider,
        normalizer: any ZoneFeatureNormalizing,
        autoRefreshStatus: Bool = true
    ) {
        let selectionStorageKey = "provider.selected-datasets.\(provider.id)"
        let statusStorageKey = "provider.status-snapshot.\(provider.id)"
        self.provider = provider
        self.normalizer = normalizer
        self.selectionStorageKey = selectionStorageKey
        self.statusStorageKey = statusStorageKey
        self.selectedDatasetIDs = Self.loadSelectedDatasetIDs(for: provider)
        self.statusSnapshot = Self.loadStatusSnapshot(for: provider, storageKey: statusStorageKey)

        if autoRefreshStatus {
            Task {
                await refreshStatus()
            }
        }
    }

    var datasetCatalog: [ProviderDataset] {
        provider.datasets
    }

    func needsStatusRefresh(now: Date = Date()) -> Bool {
        Self.shouldRefreshStatus(
            supportsStatusRefresh: provider.capabilities.supportsStatusRefresh,
            refreshedAt: statusSnapshot.refreshedAt,
            now: now,
            cooldown: Self.statusRefreshCooldown
        )
    }

    nonisolated static func shouldRefreshStatus(
        supportsStatusRefresh: Bool,
        refreshedAt: Date?,
        now: Date,
        cooldown: TimeInterval
    ) -> Bool {
        // Never probed yet: always refresh so we either learn the real status or apply
        // the available fallback for providers that don't report status.
        guard let refreshedAt else {
            return true
        }

        // Providers without status refresh keep their first snapshot forever.
        guard supportsStatusRefresh else {
            return false
        }

        return now.timeIntervalSince(refreshedAt) > cooldown
    }

    func makeStatusRefreshJob() -> ProviderStatusRefreshJob {
        ProviderStatusRefreshJob(
            providerID: provider.id,
            provider: provider,
            supportsStatusRefresh: provider.capabilities.supportsStatusRefresh,
            fallbackSnapshot: ProviderStatusSnapshot(
                providerStatus: .available,
                datasetStatuses: Dictionary(uniqueKeysWithValues: provider.datasets.map { ($0.id, .available) }),
                refreshedAt: Date()
            )
        )
    }

    func applyStatusSnapshot(_ snapshot: ProviderStatusSnapshot) {
        statusSnapshot = snapshot
        persistStatusSnapshot(snapshot)
    }

    // Optimistically marks every dataset available so the UI reflects an "available" status
    // the instant a live provider is enabled, instead of showing "unknown" until the real
    // probe finishes (which can take a moment for a provider that probes several services).
    // `refreshedAt` is left nil so this placeholder never suppresses the real probe.
    func applyOptimisticAvailableStatus() {
        applyStatusSnapshot(
            ProviderStatusSnapshot(
                providerStatus: .available,
                datasetStatuses: Dictionary(uniqueKeysWithValues: provider.datasets.map { ($0.id, .available) }),
                refreshedAt: nil
            )
        )
    }

    func makeRenderJob(for request: ProviderRenderRequest) -> ProviderRenderJob? {
        guard provider.capabilities.supportsRendering else {
            return nil
        }

        let renderableDatasetIDs = selectedDatasetIDsForRendering()
        guard !renderableDatasetIDs.isEmpty else {
            return nil
        }

        return ProviderRenderJob(
            providerID: provider.id,
            provider: provider,
            request: request,
            selectedDatasetIDs: renderableDatasetIDs,
            statusSnapshot: statusSnapshot
        )
    }

    func applyRenderPayloads(_ payloads: [ProviderRenderPayload]) {
        renderPayloads = payloads
    }

    func makeQueryJob(for request: ProviderPointQueryRequest) -> ProviderQueryJob? {
        guard provider.capabilities.supportsQuerying else {
            return nil
        }

        let queryableDatasetIDs = selectedDatasetIDsForQuerying()
        guard !queryableDatasetIDs.isEmpty else {
            return nil
        }

        return ProviderQueryJob(
            providerID: provider.id,
            provider: provider,
            request: request,
            selectedDatasetIDs: queryableDatasetIDs,
            statusSnapshot: statusSnapshot
        )
    }

    func applyQueryOutcome(_ outcome: ProviderQueryOutcome) {
        zoneQueryResult = mapQueryOutcomeToZoneQueryResult(outcome)
    }

    func applyNonAssessmentNoEnabledLayers() {
        zoneQueryResult = .nonAssessment(reason: .noEnabledLayers)
    }

    func clearZoneQueryResult() {
        zoneQueryResult = nil
    }

    func clearRenderPayloads() {
        renderPayloads = []
    }

    func setDatasetSelected(_ datasetID: String, isSelected: Bool) {
        if isSelected {
            selectedDatasetIDs.insert(datasetID)
        } else {
            selectedDatasetIDs.remove(datasetID)
        }
    }

    func refreshStatus() async {
        guard provider.capabilities.supportsStatusRefresh else {
            let availableSnapshot = ProviderStatusSnapshot(
                providerStatus: .available,
                datasetStatuses: Dictionary(uniqueKeysWithValues: provider.datasets.map { ($0.id, .available) }),
                refreshedAt: Date()
            )
            applyStatusSnapshot(availableSnapshot)
            return
        }

        let refreshedSnapshot = await provider.refreshStatus()
        applyStatusSnapshot(refreshedSnapshot)
    }

    private func selectedDatasetIDsForRendering() -> Set<String> {
        Set(
            provider.datasets
                .filter { selectedDatasetIDs.contains($0.id) && $0.capabilities.supportsRendering }
                .map(\.id)
        )
    }

    private func selectedDatasetIDsForQuerying() -> Set<String> {
        Set(
            provider.datasets
                .filter { selectedDatasetIDs.contains($0.id) && $0.capabilities.supportsQuerying }
                .map(\.id)
        )
    }

    private func mapQueryOutcomeToZoneQueryResult(_ outcome: ProviderQueryOutcome) -> ZoneQueryResult {
        switch outcome {
        case .noMatches:
            return .clear(reason: .noMatchingRestrictions)
        case .unavailable(let reason):
            return .unavailable(reason: mapUnavailableReason(reason))
        case .matches(let records):
            let features = normalizer.normalize(records: records).sortedByDisplayPriority()
            let assessment = ZoneAssessmentEvaluator.evaluate(features: features)
            return .matches(features: features, assessment: assessment)
        }
    }

    private func mapUnavailableReason(_ reason: ProviderQueryUnavailableReason) -> UnavailableReason {
        switch reason {
        case .outsideCoverage:
            return .outsideCoverage
        case .requestFailed(let details):
            return .requestFailed(details: details)
        case .providerNoData:
            return .providerNoData
        case .invalidResponse:
            return .invalidResponse
        }
    }

    private func persistSelectedDatasetIDs() {
        UserDefaults.standard.set(Array(selectedDatasetIDs).sorted(), forKey: selectionStorageKey)
    }

    private func persistStatusSnapshot(_ statusSnapshot: ProviderStatusSnapshot) {
        guard let data = try? JSONEncoder().encode(statusSnapshot) else {
            return
        }

        UserDefaults.standard.set(data, forKey: statusStorageKey)
    }

    private static func loadSelectedDatasetIDs(for provider: any GeospatialProvider) -> Set<String> {
        let storageKey = "provider.selected-datasets.\(provider.id)"
        if let savedDatasetIDs = UserDefaults.standard.stringArray(forKey: storageKey) {
            return Set(savedDatasetIDs)
        }

        return Set(provider.datasets.filter(\.isSelectedByDefault).map(\.id))
    }

    private static func loadStatusSnapshot(
        for provider: any GeospatialProvider,
        storageKey: String
    ) -> ProviderStatusSnapshot {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let snapshot = try? JSONDecoder().decode(ProviderStatusSnapshot.self, from: data)
        else {
            return .unknown(for: provider.datasets)
        }

        return snapshot
    }
}
