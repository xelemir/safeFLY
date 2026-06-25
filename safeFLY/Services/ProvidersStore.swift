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
        ProviderRegistration(provider: DIPULProvider(), normalizer: ZoneFeatureNormalizer())
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
    private let providerOrderStorageKey = "providers.order"
    private var renderGeneration = 0
    private var queryGeneration = 0

    init(registrations: [ProviderRegistration]) {
        let sessions = registrations.map {
            ProviderSession(provider: $0.provider, normalizer: $0.normalizer, autoRefreshStatus: false)
        }
        let orderedSessions = Self.loadOrderedSessions(from: sessions, storageKey: "providers.order")

        self.sessions = orderedSessions
        self.enabledProviderIDs = Self.loadEnabledProviderIDs(
            storageKey: "providers.enabled",
            providers: orderedSessions.map { $0.provider }
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
            enabledProviderIDs.insert(providerID)
        } else {
            enabledProviderIDs.remove(providerID)
        }
    }

    func moveProviders(fromOffsets: IndexSet, toOffset: Int) {
        let movedSessions = fromOffsets.map { sessions[$0] }
        var reorderedSessions = sessions.enumerated().compactMap { index, session in
            fromOffsets.contains(index) ? nil : session
        }
        let insertionIndex = min(toOffset, reorderedSessions.count)
        reorderedSessions.insert(contentsOf: movedSessions, at: insertionIndex)
        sessions = reorderedSessions
        persistProviderOrder()
        invalidateRenderGeneration()
        configurationRevision += 1
    }

    func refreshAllStatuses() async {
        let jobs = sessions.map { $0.makeStatusRefreshJob() }
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
        let renderOrderedSessions = Array(enabledSessions.reversed())

        for session in sessions where !enabledProviderIDs.contains(session.provider.id) {
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
            let sortedFeatures = matchedFeatures.sorted { lhs, rhs in
                if lhs.category.displayPriority != rhs.category.displayPriority {
                    return lhs.category.displayPriority < rhs.category.displayPriority
                }

                return lhs.id < rhs.id
            }
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

    private func persistProviderOrder() {
        UserDefaults.standard.set(sessions.map(\.id), forKey: providerOrderStorageKey)
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

        return Set(providers.map(\.id))
    }

    private static func loadOrderedSessions(from sessions: [ProviderSession], storageKey: String) -> [ProviderSession] {
        guard let savedOrder = UserDefaults.standard.stringArray(forKey: storageKey), !savedOrder.isEmpty else {
            return sessions
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let orderedSessions = savedOrder.compactMap { sessionsByID[$0] }
        let unorderedSessions = sessions.filter { !savedOrder.contains($0.id) }
        return orderedSessions + unorderedSessions
    }
}
