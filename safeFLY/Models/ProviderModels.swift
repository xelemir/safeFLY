//
//  ProviderModels.swift
//  safeFLY
//

import Foundation
import CoreLocation

struct MapCoordinate: Equatable, Hashable, Codable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clLocationCoordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MapRegion: Equatable, Hashable, Codable {
    let center: MapCoordinate
    let latitudeDelta: Double
    let longitudeDelta: Double
}

struct MapViewportSize: Equatable, Hashable, Codable {
    let width: Int
    let height: Int
}

struct ProviderRenderRequest: Equatable, Hashable, Codable {
    let region: MapRegion
    let viewportSize: MapViewportSize
}

struct ProviderPointQueryRequest: Equatable, Hashable, Codable {
    let coordinate: MapCoordinate
    let region: MapRegion
    let viewportSize: MapViewportSize
}

struct ProviderCapabilities {
    let supportsRendering: Bool
    let supportsQuerying: Bool
    let supportsStatusRefresh: Bool
}

struct ProviderReferenceLink: Identifiable {
    let title: String
    let url: URL

    var id: String {
        url.absoluteString
    }
}

struct ProviderDatasetCapabilities {
    let supportsRendering: Bool
    let supportsQuerying: Bool
}

struct ProviderDatasetPresentation {
    let title: String
    let groupTitle: String?
}

struct ProviderDataset: Identifiable {
    let id: String
    let presentation: ProviderDatasetPresentation
    let capabilities: ProviderDatasetCapabilities
    let isSelectedByDefault: Bool
}

enum ProviderAvailabilityStatus: String, Codable {
    case unknown
    case available
    case degraded
    case unavailable
}

struct ProviderStatusSnapshot: Equatable, Codable {
    let providerStatus: ProviderAvailabilityStatus
    let datasetStatuses: [String: ProviderAvailabilityStatus]
    let refreshedAt: Date?

    func status(for datasetID: String) -> ProviderAvailabilityStatus {
        datasetStatuses[datasetID] ?? .unknown
    }

    static func unknown(for datasets: [ProviderDataset]) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            providerStatus: .unknown,
            datasetStatuses: Dictionary(uniqueKeysWithValues: datasets.map { ($0.id, .unknown) }),
            refreshedAt: nil
        )
    }
}

protocol ProviderRawRecord {
    var providerID: String { get }
}

enum ProviderQueryUnavailableReason {
    case outsideCoverage
    case requestFailed(details: String?)
    case providerNoData
    case invalidResponse
}

enum ProviderQueryOutcome {
    case matches(records: [any ProviderRawRecord])
    case noMatches
    case unavailable(reason: ProviderQueryUnavailableReason)
}

enum ProviderRenderPayloadType {
    case wmsImage
    case polygon
}

struct WMSRenderPayload: Identifiable, Equatable {
    let id: String
    let imageURL: URL
    let region: MapRegion
    let opacity: Double
}

struct PolygonRenderPayload: Identifiable, Equatable {
    let id: String
    let coordinates: [MapCoordinate]
    let fillColorHex: String
    let fillOpacity: Double
    let strokeColorHex: String
    let strokeOpacity: Double
    let lineWidth: Double
}

enum ProviderRenderPayload: Identifiable, Equatable {
    case wmsImage(WMSRenderPayload)
    case polygon(PolygonRenderPayload)

    var id: String {
        switch self {
        case .wmsImage(let payload):
            return payload.id
        case .polygon(let payload):
            return payload.id
        }
    }

    var type: ProviderRenderPayloadType {
        switch self {
        case .wmsImage:
            return .wmsImage
        case .polygon:
            return .polygon
        }
    }
}
