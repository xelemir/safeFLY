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
//
// Two rules keep the packages off the launch path. Nothing is parsed until someone actually asks
// for the features, so a downloaded-but-disabled provider — and every enabled one, until the map
// first renders — costs nothing at startup; and the parsing itself is `@concurrent`, so the
// decode of a payload that reaches tens of megabytes (DE, NO) never runs on the main actor, no
// matter which actor the caller happens to be on.
nonisolated final class ED269DownloadableDataset<Element: Sendable>: @unchecked Sendable {
    private let store: DownloadableFileStore
    private let parse: @Sendable (Data) throws -> [Element]

    @MainActor private var cache: [Element] = []
    // Whether `cache` reflects the file on disk. False after a download or delete, so the next
    // read re-parses rather than serving a cache that no longer matches the package.
    @MainActor private var isLoaded = false
    // In-flight load, so concurrent first readers (render and query can land together) await one
    // parse instead of each starting their own.
    @MainActor private var loadTask: Task<Void, Never>?

    init(fileName: String, remoteURL: URL, parse: @escaping @Sendable (Data) throws -> [Element]) {
        self.store = DownloadableFileStore(fileName: fileName, remoteURL: remoteURL)
        self.parse = parse
    }

    nonisolated var remoteURL: URL { store.remoteURL }
    nonisolated var isDownloaded: Bool { store.isDownloaded }
    nonisolated var lastUpdated: Date? { store.modificationDate }
    nonisolated var byteSize: Int64? { store.byteSize }

    // Parsed features for the render/query path, decoded on first use. Empty until the dataset
    // is downloaded, and empty if the local copy turns out to be unreadable.
    @MainActor var features: [Element] {
        get async {
            await load()
            return cache
        }
    }

    @MainActor func load() async {
        if isLoaded {
            return
        }

        if let loadTask {
            await loadTask.value
            return
        }

        let task = Task { await self.loadFromDisk() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    @MainActor private func loadFromDisk() async {
        guard store.isDownloaded else {
            // Nothing to parse. Still counts as loaded: a later download or delete resets the
            // flag, so this can't wedge an empty cache in place.
            isLoaded = true
            return
        }

        cache = (try? await parseLocalFile()) ?? []
        isLoaded = true
    }

    // The read and decode both happen off the main actor; only the finished array crosses back.
    @concurrent private func parseLocalFile() async throws -> [Element] {
        try parse(store.read())
    }

    // Validate by fully parsing before the payload may replace the local copy, so a malformed
    // response never overwrites a previously good dataset. The validating parse doubles as the
    // new cache, so a download decodes the payload once rather than twice.
    @concurrent nonisolated func download() async throws {
        var parsed: [Element] = []
        _ = try await store.download { data in parsed = try self.parse(data) }

        let features = parsed
        await MainActor.run {
            self.cache = features
            self.isLoaded = true
        }
    }

    nonisolated func delete() {
        store.delete()
        Task { @MainActor in
            self.cache = []
            self.isLoaded = false
        }
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
    nonisolated var datasetByteSize: Int64? { dataset.byteSize }
    nonisolated func downloadData() async throws { try await dataset.download() }
    nonisolated func deleteData() { dataset.delete() }
}
