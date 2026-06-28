//
//  DownloadableFileStore.swift
//  safeFLY
//
//  Reusable infrastructure for providers backed by a downloadable offline dataset. It owns
//  the local file location, existence check, atomic download-with-validation, and deletion,
//  so providers keep only their dataset-specific parsing.
//

import Foundation

enum DownloadableFileStoreError: LocalizedError {
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return String.localizedStringWithFormat(
                NSLocalizedString("The server returned an unexpected response (HTTP %d).", comment: "Dataset download HTTP error"),
                code
            )
        case .emptyResponse:
            return NSLocalizedString("The server returned an empty response.", comment: "Dataset download empty response error")
        }
    }
}

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

    nonisolated var modificationDate: Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        return attributes?[.modificationDate] as? Date
    }

    // Downloads the remote payload, runs the caller's validation, writes it atomically and
    // returns the bytes. The HTTP status and a non-empty body are checked first — URLSession
    // does not throw on 4xx/5xx — and validation lets the provider reject malformed responses,
    // so none of these failure modes can overwrite a previously good local copy.
    nonisolated func download(validate: (Data) throws -> Void) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadableFileStoreError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw DownloadableFileStoreError.emptyResponse }
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
