//
//  ProviderModels.swift
//  safeFLY
//

import Foundation
import CoreLocation

struct MapCoordinate: Equatable, Hashable, Codable, Sendable {
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

struct MapRegion: Equatable, Hashable, Codable, Sendable {
    let center: MapCoordinate
    let latitudeDelta: Double
    let longitudeDelta: Double

    // Whether this region's center falls inside a coarse country outline. See
    // `GeoMath.contains(_:outline:)` for why the center settles map attribution.
    nonisolated func centerIsInside(_ outline: [(lat: Double, lon: Double)]) -> Bool {
        GeoMath.contains(center, outline: outline)
    }
}

struct MapViewportSize: Equatable, Hashable, Codable, Sendable {
    let width: Int
    let height: Int
}

struct ProviderRenderRequest: Equatable, Hashable, Codable, Sendable {
    let region: MapRegion
    let viewportSize: MapViewportSize
}

struct ProviderPointQueryRequest: Equatable, Hashable, Codable, Sendable {
    let coordinate: MapCoordinate
    let region: MapRegion
    let viewportSize: MapViewportSize
}

struct ProviderCapabilities: Sendable {
    let supportsRendering: Bool
    let supportsQuerying: Bool
    let supportsStatusRefresh: Bool
}

struct ProviderReferenceLink: Identifiable, Sendable {
    let title: String
    let url: URL

    var id: String {
        url.absoluteString
    }
}

struct ProviderDatasetCapabilities: Sendable {
    let supportsRendering: Bool
    let supportsQuerying: Bool
}

struct ProviderDatasetPresentation: Sendable {
    let title: String
    let groupTitle: String?
}

struct ProviderDataset: Identifiable, Sendable {
    let id: String
    let presentation: ProviderDatasetPresentation
    let capabilities: ProviderDatasetCapabilities
    let isSelectedByDefault: Bool
}

// Builds a localized dataset presentation from string-table keys. Shared by every provider
// so dataset titles are localized consistently.
nonisolated func localizedProviderPresentation(title: String, groupTitle: String) -> ProviderDatasetPresentation {
    ProviderDatasetPresentation(
        title: NSLocalizedString(title, comment: "Provider dataset title"),
        groupTitle: NSLocalizedString(groupTitle, comment: "Provider dataset group title")
    )
}

enum ProviderAvailabilityStatus: String, Codable, Sendable {
    case unknown
    case available
    case degraded
    case unavailable
    case downloadRequired
}

nonisolated struct ProviderStatusSnapshot: Equatable, Codable, Sendable {
    let providerStatus: ProviderAvailabilityStatus
    let datasetStatuses: [String: ProviderAvailabilityStatus]
    // Individual source layer IDs known to be broken at the provider. Layers in this
    // set are excluded from combined requests so a single failing layer cannot blank
    // out the otherwise-working layers it is bundled with.
    let brokenLayerIDs: Set<String>
    let refreshedAt: Date?

    init(
        providerStatus: ProviderAvailabilityStatus,
        datasetStatuses: [String: ProviderAvailabilityStatus],
        brokenLayerIDs: Set<String> = [],
        refreshedAt: Date?
    ) {
        self.providerStatus = providerStatus
        self.datasetStatuses = datasetStatuses
        self.brokenLayerIDs = brokenLayerIDs
        self.refreshedAt = refreshedAt
    }

    // Decodes resiliently: snapshots persisted before `brokenLayerIDs` existed simply
    // default to an empty set rather than failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerStatus = try container.decode(ProviderAvailabilityStatus.self, forKey: .providerStatus)
        datasetStatuses = try container.decode([String: ProviderAvailabilityStatus].self, forKey: .datasetStatuses)
        brokenLayerIDs = try container.decodeIfPresent(Set<String>.self, forKey: .brokenLayerIDs) ?? []
        refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
    }

    func status(for datasetID: String) -> ProviderAvailabilityStatus {
        datasetStatuses[datasetID] ?? .unknown
    }

    func isLayerBroken(_ layerID: String) -> Bool {
        brokenLayerIDs.contains(layerID)
    }

    static func unknown(for datasets: [ProviderDataset]) -> ProviderStatusSnapshot {
        ProviderStatusSnapshot(
            providerStatus: .unknown,
            datasetStatuses: Dictionary(uniqueKeysWithValues: datasets.map { ($0.id, .unknown) }),
            brokenLayerIDs: [],
            refreshedAt: nil
        )
    }
}

protocol ProviderRawRecord: Sendable {
    var providerID: String { get }
}

enum ProviderQueryUnavailableReason: Sendable {
    case outsideCoverage
    case requestFailed(details: String?)
    case providerNoData
    case invalidResponse
}

enum ProviderQueryOutcome: Sendable {
    case matches(records: [any ProviderRawRecord])
    case noMatches
    case unavailable(reason: ProviderQueryUnavailableReason)
}

enum ProviderRenderPayloadType: Sendable {
    case wmsImage
    case polygon
}

struct WMSRenderPayload: Identifiable, Equatable, Sendable {
    let id: String
    let imageURL: URL
    let region: MapRegion
    let opacity: Double
}

struct PolygonRenderPayload: Identifiable, Equatable, Sendable {
    let id: String
    let coordinates: [MapCoordinate]
    let fillColorHex: String
    let fillOpacity: Double
    let strokeColorHex: String
    let strokeOpacity: Double
    let lineWidth: Double
}

enum ProviderRenderPayload: Identifiable, Equatable, Sendable {
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
