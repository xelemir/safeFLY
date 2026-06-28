//
//  ProvidersStore.swift
//  safeFLY
//

import Foundation
import Combine

struct ProviderRegistration {
    let provider: any GeospatialProvider
    let normalizer: any ZoneFeatureNormalizing
}

enum BuiltInProviders {
    static let all: [ProviderRegistration] = [
        ProviderRegistration(provider: DIPULProvider(), normalizer: DIPULZoneNormalizer()),
        ProviderRegistration(provider: FranceProvider(), normalizer: FranceZoneNormalizer()),
        ProviderRegistration(provider: SwitzerlandProvider(), normalizer: SwitzerlandZoneNormalizer()),
        ProviderRegistration(provider: AustriaProvider(), normalizer: AustriaZoneNormalizer()),
        ProviderRegistration(provider: CzechProvider(), normalizer: CzechZoneNormalizer()),
        ProviderRegistration(provider: NetherlandsProvider(), normalizer: NetherlandsZoneNormalizer()),
        ProviderRegistration(provider: LuxembourgProvider(), normalizer: LuxembourgZoneNormalizer())
    ]
}

@MainActor
final class ProvidersStore: ObservableObject {
    @Published private(set) var sessions: [ProviderSession]
    @Published private(set) var renderPayloads: [ProviderRenderPayload] = []
    @Published private(set) var zoneQueryResult: ZoneQueryResult?
    @Published private(set) var isLoading = false
    @Published private(set) var configurationRevision = 0
    @Published var enabledProviderIDs: Set<String> {
        didSet {
            invalidateRenderGeneration()
            invalidateQueryGeneration()
            persistEnabledProviderIDs()
            clearZoneQueryResult()
            configurationRevision += 1
        }
    }

    private let enabledProvidersStorageKey = "providers.enabled"
    private var renderGeneration = 0
    private var queryGeneration = 0

    init(registrations: [ProviderRegistration]) {
        let sessions = registrations.map {
            ProviderSession(provider: $0.provider, normalizer: $0.normalizer, autoRefreshStatus: false)
        }

        self.sessions = sessions
        self.enabledProviderIDs = Self.loadEnabledProviderIDs(
            storageKey: "providers.enabled",
            providers: sessions.map { $0.provider }
        )

        Task {
            await refreshAllStatuses()
        }
    }

    var enabledSessions: [ProviderSession] {
        sessions.filter { enabledProviderIDs.contains($0.provider.id) }
    }

    func isProviderEnabled(_ providerID: String) -> Bool {
        enabledProviderIDs.contains(providerID)
    }

    func providerSession(for providerID: String) -> ProviderSession? {
        sessions.first { $0.provider.id == providerID }
    }

    func setProviderEnabled(_ providerID: String, isEnabled: Bool) {
        if isEnabled {
            let wasEnabled = enabledProviderIDs.contains(providerID)
            enabledProviderIDs.insert(providerID)
            // Probe a provider the moment it is turned on so its status reflects reality
            // instead of staying stale until the next app foreground. Auto-downloading
            // providers also fetch their dataset right away, so the first enable doesn't
            // require a manual download step or wait for the next foreground.
            if !wasEnabled {
                let session = providerSession(for: providerID)
                let provider = session?.provider
                // Live (online) providers have no local data to check, so reflect "available"
                // immediately rather than leaving the status "unknown" until the real probe
                // returns. The probe below then corrects it if a layer is actually down.
                if let session, let provider, provider.downloadURL == nil {
                    session.applyOptimisticAvailableStatus()
                    configurationRevision += 1
                }
                Task {
                    if let provider, provider.autoDownloadsDataset, !provider.isDataDownloaded {
                        try? await provider.downloadData()
                        markConfigurationChanged()
                    }
                    await refreshStatus(for: providerID)
                }
            }
        } else {
            enabledProviderIDs.remove(providerID)
        }
    }

    func refreshAllStatuses(force: Bool = false) async {
        // Only probe enabled providers: a disabled provider is unused, so it must not
        // reach out to its backend or report a "last tried just now" status.
        let candidateSessions = enabledSessions
        let sessionsToRefresh = force ? candidateSessions : candidateSessions.filter { $0.needsStatusRefresh() }
        guard !sessionsToRefresh.isEmpty else {
            return
        }

        let jobs = sessionsToRefresh.map { $0.makeStatusRefreshJob() }
        let snapshotsByProviderID = await withTaskGroup(of: (String, ProviderStatusSnapshot).self, returning: [String: ProviderStatusSnapshot].self) { group in
            for job in jobs {
                group.addTask {
                    if job.supportsStatusRefresh {
                        let snapshot = await job.provider.refreshStatus()
                        return (job.providerID, snapshot)
                    }

                    return (job.providerID, job.fallbackSnapshot)
                }
            }

            var snapshots: [String: ProviderStatusSnapshot] = [:]
            for await (providerID, snapshot) in group {
                snapshots[providerID] = snapshot
            }
            return snapshots
        }

        for session in sessions {
            if let snapshot = snapshotsByProviderID[session.id] {
                session.applyStatusSnapshot(snapshot)
            }
        }

        configurationRevision += 1
    }

    // Keeps already-downloaded offline datasets (Netherlands, Austria, …) fresh without the
    // user noticing. Runs at most once per the provider's refresh interval, fully in the
    // background: each download is detached, replaces its provider's parsed data atomically
    // (so the map never flickers or blanks), and touches no published UI state. Failures are
    // silent and leave the existing local copy in place.
    func refreshDownloadableDatasetsInBackground(now: Date = Date()) {
        for session in sessions {
            let provider = session.provider

            // Only providers backed by a downloadable file. Normally the user must have a
            // local copy already; auto-downloading providers (small, frequently-updated
            // feeds) are fetched even on their first foreground.
            guard provider.downloadURL != nil,
                  provider.isDataDownloaded || provider.autoDownloadsDataset else {
                continue
            }

            // Throttle on the local dataset's own modification date, which every successful
            // download — manual "Update Now" or silent background refresh — updates atomically.
            // Keeping a single source of truth means a manual update correctly suppresses the
            // next background refresh, with no separate timestamp to drift out of sync.
            if let lastUpdated = provider.datasetLastUpdated,
               now.timeIntervalSince(lastUpdated) < provider.datasetRefreshInterval {
                continue
            }

            Task.detached(priority: .background) {
                // Silent: a failed refresh keeps the existing local dataset and is retried on
                // the next app open.
                try? await provider.downloadData()
            }
        }
    }

    func refreshStatus(for providerID: String) async {
        guard let session = providerSession(for: providerID) else {
            return
        }

        await session.refreshStatus()
        configurationRevision += 1
    }

    func refreshRenderPayloads(for request: ProviderRenderRequest) async {
        let generation = nextRenderGeneration()
        let enabledSessions = enabledSessions
        // Only render providers whose country is actually in view: no point requesting German
        // WMS tiles while looking at Paris.
        let renderOrderedSessions = Array(enabledSessions.reversed())
            .filter { $0.provider.intersects(request.region) }
        let renderingProviderIDs = Set(renderOrderedSessions.map { $0.id })

        // Clear payloads for everything not contributing this pass: disabled providers and
        // enabled-but-out-of-view ones.
        for session in sessions where !renderingProviderIDs.contains(session.id) {
            session.clearRenderPayloads()
        }

        let jobs = renderOrderedSessions.compactMap { session -> ProviderRenderJob? in
            let job = session.makeRenderJob(for: request)
            if job == nil {
                session.clearRenderPayloads()
            }
            return job
        }

        let payloadsByProviderID = await withTaskGroup(of: (String, [ProviderRenderPayload]).self, returning: [String: [ProviderRenderPayload]].self) { group in
            for job in jobs {
                group.addTask {
                    let payloads = await job.provider.renderPayloads(
                        for: job.request,
                        selectedDatasetIDs: job.selectedDatasetIDs,
                        status: job.statusSnapshot
                    )
                    return (job.providerID, payloads)
                }
            }

            var payloads: [String: [ProviderRenderPayload]] = [:]
            for await (providerID, providerPayloads) in group {
                payloads[providerID] = providerPayloads
            }
            return payloads
        }

        guard generation == renderGeneration else {
            return
        }

        for session in renderOrderedSessions {
            session.applyRenderPayloads(payloadsByProviderID[session.id] ?? [])
        }

        renderPayloads = renderOrderedSessions.flatMap { payloadsByProviderID[$0.id] ?? [] }
    }

    func queryLocation(for request: ProviderPointQueryRequest) async {
        let generation = nextQueryGeneration()
        let enabledSessions = enabledSessions

        guard !enabledSessions.isEmpty else {
            isLoading = false
            zoneQueryResult = .nonAssessment(reason: .noEnabledLayers)
            return
        }

        isLoading = true
        zoneQueryResult = nil

        for session in sessions where !enabledProviderIDs.contains(session.provider.id) {
            session.clearZoneQueryResult()
        }

        let jobs = enabledSessions.compactMap { session -> ProviderQueryJob? in
            let job = session.makeQueryJob(for: request)
            if job == nil {
                session.applyNonAssessmentNoEnabledLayers()
            }
            return job
        }

        let outcomesByProviderID = await withTaskGroup(of: (String, ProviderQueryOutcome).self, returning: [String: ProviderQueryOutcome].self) { group in
            for job in jobs {
                group.addTask {
                    let outcome = await job.provider.query(
                        for: job.request,
                        selectedDatasetIDs: job.selectedDatasetIDs,
                        status: job.statusSnapshot
                    )
                    return (job.providerID, outcome)
                }
            }

            var outcomes: [String: ProviderQueryOutcome] = [:]
            for await (providerID, outcome) in group {
                outcomes[providerID] = outcome
            }
            return outcomes
        }

        guard generation == queryGeneration else {
            return
        }

        for session in enabledSessions {
            if let outcome = outcomesByProviderID[session.id] {
                session.applyQueryOutcome(outcome)
            }
        }

        zoneQueryResult = aggregateZoneQueryResult(from: enabledSessions)
        isLoading = false
    }

    func clearZoneQueryResult() {
        invalidateQueryGeneration()
        isLoading = false
        zoneQueryResult = nil
        sessions.forEach { $0.clearZoneQueryResult() }
    }

    func clearRenderPayloads() {
        invalidateRenderGeneration()
        renderPayloads = []
        sessions.forEach { $0.clearRenderPayloads() }
    }

    func markConfigurationChanged() {
        invalidateRenderGeneration()
        clearZoneQueryResult()
        configurationRevision += 1
    }

    private func aggregateZoneQueryResult(from sessions: [ProviderSession]) -> ZoneQueryResult {
        var matchedFeatures: [ZoneFeature] = []
        var firstUnavailableReason: UnavailableReason?
        var sawClearResult = false

        for session in sessions {
            guard let result = session.zoneQueryResult else {
                continue
            }

            switch result {
            case .matches(let features, _):
                matchedFeatures.append(contentsOf: features)
            case .unavailable(let reason):
                // A provider that simply doesn't cover this location has no jurisdiction
                // here, so it must not mask another provider's valid result (e.g. DIPUL
                // outside Germany while the Netherlands provider reports a clear location).
                if case .outsideCoverage = reason {
                    continue
                }
                if firstUnavailableReason == nil {
                    firstUnavailableReason = reason
                }
            case .clear:
                sawClearResult = true
            case .nonAssessment:
                continue
            }
        }

        if !matchedFeatures.isEmpty {
            let sortedFeatures = matchedFeatures.deduplicatedByID().sortedByDisplayPriority()
            return .matches(
                features: sortedFeatures,
                assessment: ZoneAssessmentEvaluator.evaluate(features: sortedFeatures)
            )
        }

        if let firstUnavailableReason {
            return .unavailable(reason: firstUnavailableReason)
        }

        if sawClearResult {
            return .clear(reason: .noMatchingRestrictions)
        }

        return .nonAssessment(reason: .noEnabledLayers)
    }

    private func persistEnabledProviderIDs() {
        UserDefaults.standard.set(Array(enabledProviderIDs).sorted(), forKey: enabledProvidersStorageKey)
    }

    private func nextRenderGeneration() -> Int {
        renderGeneration += 1
        return renderGeneration
    }

    private func nextQueryGeneration() -> Int {
        queryGeneration += 1
        return queryGeneration
    }

    private func invalidateRenderGeneration() {
        renderGeneration += 1
    }

    private func invalidateQueryGeneration() {
        queryGeneration += 1
    }

    private static func loadEnabledProviderIDs(
        storageKey: String,
        providers: [any GeospatialProvider]
    ) -> Set<String> {
        if let savedProviderIDs = UserDefaults.standard.stringArray(forKey: storageKey) {
            return Set(savedProviderIDs)
        }

        // Only DFS DIPUL is enabled by default; every other provider is opt-in.
        return providers.map(\.id).contains(DIPULProvider.providerID)
            ? [DIPULProvider.providerID]
            : []
    }
}
