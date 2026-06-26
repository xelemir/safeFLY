//
//  DownloadableFileStore.swift
//  safeFLY
//
//  Reusable infrastructure for providers backed by a downloadable offline dataset. It owns
//  the local file location, existence check, atomic download-with-validation, and deletion,
//  so providers keep only their dataset-specific parsing.
//

import Foundation

struct DownloadableFileStore: Sendable {
    let fileName: String
    let remoteURL: URL

    nonisolated var localURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(fileName)
    }

    nonisolated var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    // Downloads the remote payload, runs the caller's validation, writes it atomically and
    // returns the bytes. Validation lets the provider reject malformed responses before they
    // overwrite a previously good local copy.
    nonisolated func download(validate: (Data) throws -> Void) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: remoteURL)
        try validate(data)
        try data.write(to: localURL, options: .atomic)
        return data
    }

    nonisolated func read() throws -> Data {
        try Data(contentsOf: localURL)
    }

    nonisolated func delete() {
        try? FileManager.default.removeItem(at: localURL)
    }
}
