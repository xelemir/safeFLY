//
//  OfflineMapStore.swift
//  safeFLY
//
//  Manages offline map packs (download, list, delete) using MapLibre's built-in
//  MLNOfflineStorage. Each pack stores a bounded tile-pyramid region at zoom 0–14
//  from the OpenFreeMap Liberty vector tile style.
//

import Foundation
import MapLibre
import Combine
import MapKit

// MARK: - Models

struct OfflineMapPack: Identifiable {
    let id: String
    let name: String
    let createdAt: Date
    let sizeBytes: Int64
    let state: MLNOfflinePackState
    let completedResources: UInt64
    let expectedResources: UInt64
    let mlnPack: MLNOfflinePack

    var isComplete: Bool {
        state == .complete
    }

    var progress: Double {
        guard expectedResources > 0 else { return 0 }
        return Double(completedResources) / Double(expectedResources)
    }
}

struct ActiveDownload: Equatable {
    let name: String
    var progress: Double
    var completedResources: UInt64
    var expectedResources: UInt64

    static func == (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.name == rhs.name && lhs.completedResources == rhs.completedResources
    }
}

// Stored in MLNOfflinePack.context as JSON.
private struct PackContext: Codable {
    let name: String
    let createdAt: Date
}

// MARK: - Store

@MainActor
class OfflineMapStore: ObservableObject {
    nonisolated static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    nonisolated static let defaultMinZoom: Double = 0
    nonisolated static let defaultMaxZoom: Double = 14

    @Published var packs: [OfflineMapPack] = []
    @Published var totalStorageBytes: Int64 = 0
    @Published var activeDownload: ActiveDownload?

    private var progressObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var packsObserver: NSKeyValueObservation?
    private var activePack: MLNOfflinePack?
    private var mlnPacks: [MLNOfflinePack] = []

    init() {
        // Increase maximum allowed tiles to 50k to allow standard neighborhood/city downloads up to zoom 14
        MLNOfflineStorage.shared.setMaximumAllowedMapboxTiles(50000)
        Task {
            try? await MLNOfflineStorage.shared.setMaximumAmbientCacheSize(0)
            try? await MLNOfflineStorage.shared.clearAmbientCache()
        }
        setupObservers()
        loadPacks()
    }

    deinit {
        let pObs = progressObserver
        let eObs = errorObserver
        NotificationCenter.default.removeObserver(pObs as Any)
        NotificationCenter.default.removeObserver(eObs as Any)
        packsObserver?.invalidate()
    }

    // MARK: - Load

    func loadPacks() {
        syncMlnPacks()
    }

    private func syncMlnPacks() {
        guard let mlnPacks = MLNOfflineStorage.shared.packs else {
            self.packs = []
            self.totalStorageBytes = 0
            self.mlnPacks = []
            return
        }

        self.mlnPacks = mlnPacks
        for pack in mlnPacks {
            pack.requestProgress()
        }
        rebuildPacksList()
    }

    private func rebuildPacksList() {
        packs = mlnPacks.compactMap { pack in
            guard let context = decodeContext(from: pack.context) else { return nil }
            let progress = pack.progress
            return OfflineMapPack(
                id: context.name + "-" + context.createdAt.timeIntervalSince1970.description,
                name: context.name,
                createdAt: context.createdAt,
                sizeBytes: Int64(progress.countOfBytesCompleted),
                state: pack.state,
                completedResources: progress.countOfResourcesCompleted,
                expectedResources: progress.countOfResourcesExpected,
                mlnPack: pack
            )
        }
        .sorted { $0.createdAt > $1.createdAt }

        totalStorageBytes = packs.reduce(0) { $0 + $1.sizeBytes }
    }

    func isWithinDownloadedArea(_ targetRegion: MKCoordinateRegion) -> Bool {
        let latMin = targetRegion.center.latitude - targetRegion.span.latitudeDelta / 2.0
        let latMax = targetRegion.center.latitude + targetRegion.span.latitudeDelta / 2.0
        let lonMin = targetRegion.center.longitude - targetRegion.span.longitudeDelta / 2.0
        let lonMax = targetRegion.center.longitude + targetRegion.span.longitudeDelta / 2.0
        
        for pack in mlnPacks {
            let progress = pack.progress
            let isCompleted = pack.state == .complete || (progress.countOfResourcesExpected > 0 && progress.countOfResourcesCompleted == progress.countOfResourcesExpected)
            guard isCompleted else { continue }
            guard let tileRegion = pack.region as? MLNTilePyramidOfflineRegion else { continue }
            let bounds = tileRegion.bounds
            
            // Check containment
            let containsLat = latMin >= bounds.sw.latitude && latMax <= bounds.ne.latitude
            let containsLon = lonMin >= bounds.sw.longitude && lonMax <= bounds.ne.longitude
            
            if containsLat && containsLon {
                return true
            }
        }
        return false
    }

    // MARK: - Download

    func downloadRegion(
        name: String,
        bounds: MLNCoordinateBounds,
        minZoom: Double = OfflineMapStore.defaultMinZoom,
        maxZoom: Double = OfflineMapStore.defaultMaxZoom
    ) {
        let region = MLNTilePyramidOfflineRegion(
            styleURL: Self.styleURL,
            bounds: bounds,
            fromZoomLevel: minZoom,
            toZoomLevel: maxZoom
        )

        let context = PackContext(name: name, createdAt: Date())
        guard let contextData = try? JSONEncoder().encode(context) else { return }

        activeDownload = ActiveDownload(
            name: name,
            progress: 0,
            completedResources: 0,
            expectedResources: 0
        )

        MLNOfflineStorage.shared.addPack(for: region, withContext: contextData) { [weak self] pack, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    print("OfflineMapStore: Failed to create pack: \(error.localizedDescription)")
                    self.activeDownload = nil
                    return
                }
                if let pack {
                    self.activePack = pack
                    pack.resume()
                }
            }
        }
    }

    // MARK: - Delete

    func deletePack(_ offlinePack: OfflineMapPack) {
        MLNOfflineStorage.shared.removePack(offlinePack.mlnPack) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    print("OfflineMapStore: Failed to delete pack: \(error.localizedDescription)")
                    return
                }
                self.loadPacks()
            }
        }
    }

    // MARK: - Cancel

    func cancelActiveDownload() {
        if let activePack {
            activePack.suspend()
            MLNOfflineStorage.shared.removePack(activePack) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.activePack = nil
                    self.activeDownload = nil
                    self.loadPacks()
                }
            }
        } else {
            activeDownload = nil
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        progressObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleProgressChange(notification)
            }
        }

        errorObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.MLNOfflinePackError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let pack = notification.object as? MLNOfflinePack,
                   let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError {
                    print("OfflineMapStore: Pack error: \(error.localizedDescription)")
                    if pack === self.activePack {
                        self.activeDownload = nil
                        self.activePack = nil
                    }
                    self.loadPacks()
                }
            }
        }

        packsObserver = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.syncMlnPacks()
            }
        }
    }

    private func handleProgressChange(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack else { return }
        
        if let index = mlnPacks.firstIndex(where: { $0.context == pack.context }) {
            mlnPacks[index] = pack
        }
        
        let progress = pack.progress

        if pack === activePack {
            activeDownload = ActiveDownload(
                name: decodeContext(from: pack.context)?.name ?? activeDownload?.name ?? "",
                progress: progress.countOfResourcesExpected > 0
                    ? Double(progress.countOfResourcesCompleted) / Double(progress.countOfResourcesExpected)
                    : 0,
                completedResources: progress.countOfResourcesCompleted,
                expectedResources: progress.countOfResourcesExpected
            )

            if pack.state == .complete {
                activePack = nil
                activeDownload = nil
            }
        }

        rebuildPacksList()
    }

    // MARK: - Helpers

    private func decodeContext(from data: Data) -> PackContext? {
        try? JSONDecoder().decode(PackContext.self, from: data)
    }
}
