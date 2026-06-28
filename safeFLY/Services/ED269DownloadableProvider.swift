//
//  ED269DownloadableProvider.swift
//  safeFLY
//
//  Shared lifecycle for providers backed by a downloadable ED-269 dataset (Netherlands,
//  Austria, Luxembourg). It mirrors what `WMSBackedProvider` does for the WMS family: the
//  download / validate / parse / cache machinery lives here once, so each national provider
//  only declares its Codable envelope, parse step, and country-specific rendering & queries.
//

import Foundation

// Owns the on-disk file, the parsed-feature cache and the download lifecycle for one ED-269
// dataset. Generic over the parsed element type; the provider supplies how to turn raw bytes
// into elements. The cache is main-actor isolated (read on the render/query path); the rest
// is nonisolated, matching the providers that hold it.
nonisolated final class ED269DownloadableDataset<Element: Sendable>: @unchecked Sendable {
    private let store: DownloadableFileStore
    private let parse: (Data) throws -> [Element]

    @MainActor private var cache: [Element] = []

    init(fileName: String, remoteURL: URL, parse: @escaping (Data) throws -> [Element]) {
        self.store = DownloadableFileStore(fileName: fileName, remoteURL: remoteURL)
        self.parse = parse
        Task { try? await reload() }
    }

    nonisolated var remoteURL: URL { store.remoteURL }
    nonisolated var isDownloaded: Bool { store.isDownloaded }
    nonisolated var lastUpdated: Date? { store.modificationDate }

    // Parsed features for the render/query path. Empty until the dataset is downloaded.
    @MainActor var features: [Element] { cache }

    @MainActor func reload() async throws {
        guard store.isDownloaded else { return }
        cache = try parse(store.read())
    }

    // Validate by fully parsing before the payload may replace the local copy, so a malformed
    // response never overwrites a previously good dataset.
    nonisolated func download() async throws {
        _ = try await store.download { data in _ = try parse(data) }
        try await reload()
    }

    nonisolated func delete() {
        store.delete()
        Task { @MainActor in self.cache = [] }
    }
}

// A GeospatialProvider whose data is a downloadable ED-269 file. Conformers only declare their
// `dataset`; the download/status plumbing the protocol shares with the rest of the app comes
// from the extension below.
protocol ED269DownloadableProvider: GeospatialProvider {
    associatedtype Feature: Sendable
    nonisolated var dataset: ED269DownloadableDataset<Feature> { get }
}

extension ED269DownloadableProvider {
    nonisolated var downloadURL: URL? { dataset.remoteURL }
    nonisolated var isDataDownloaded: Bool { dataset.isDownloaded }
    nonisolated var datasetLastUpdated: Date? { dataset.lastUpdated }
    nonisolated func downloadData() async throws { try await dataset.download() }
    nonisolated func deleteData() { dataset.delete() }
}
