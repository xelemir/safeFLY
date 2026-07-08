//
//  ProtectedAreasService.swift
//  safeFLY
//
//  EU-wide nature-reserve overlay via the European Environment Agency's Natura 2000 WMS on
//  geo.discomap.eea.europa.eu. It fills a real gap: Austria, Luxembourg and the Netherlands
//  do NOT publish nature reserves in their national drone feeds (verified against the live
//  data), so this dedicated, EEA-attributed provider covers exactly those three countries —
//  Germany, Switzerland and Czechia already ship reserves and are excluded to avoid overlap.
//
//  Rendering reuses the shared WMS GetMap plumbing; point queries go through the ArcGIS REST
//  `identify` endpoint (clean JSON, no CRS pixel math), matching how the other ArcGIS-backed
//  providers here query. Being inside Natura 2000 does not uniformly ban drones — the rule is
//  national nature-protection law (permit-based, often prohibited) — so every match is a
//  `conditional` verdict with a "check before flying" note, never a green all-clear.
//

import Foundation

struct ProtectedAreaFeatureInfoRecord: ProviderRawRecord {
    let siteName: String?
    let siteType: String?

    nonisolated var providerID: String { ProtectedAreasProvider.providerID }
}

final class ProtectedAreasProvider: WMSBackedProvider, @unchecked Sendable {
    nonisolated static let providerID = "eu-protected-areas"
    nonisolated static let datasetID = "nature.protected-areas"
    // Layer "0" is the combined Habitats + Birds Directive sites (the full Natura 2000 set).
    nonisolated static let layerID = "0"

    nonisolated let id = ProtectedAreasProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("Protected Areas (Europe)", comment: "EU protected areas provider display name")
    }
    nonisolated var attributionName: String { "European Environment Agency" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated let catalog = WMSDatasetCatalog(
        baseURL: "https://bio.discomap.eea.europa.eu/arcgis/services/ProtectedSites/Natura2000Sites/MapServer/WMSServer",
        definitions: [
            .make(
                id: ProtectedAreasProvider.datasetID,
                title: "Nature Reserves",
                groupTitle: "Nature",
                layerIDs: [ProtectedAreasProvider.layerID]
            )
        ],
        // Rectangular fast-reject spanning AT + LU + NL; the exact per-country gate is `coverage`.
        coverageBounds: WMSDatasetCatalog.CoverageBounds(
            minLat: 46.3, maxLat: 53.8, minLon: 3.3, maxLon: 17.2
        ),
        coverage: CountryBoundaries.protectedAreas,
        // The EEA ArcGIS WMS, like the Czech one, is served in web-mercator for GetMap.
        crs: "EPSG:3857"
    )

    // Unused: `query` is overridden to hit the ArcGIS `identify` REST endpoint.
    nonisolated var queryInfoFormat: String { "application/json" }

    // The EEA GetMap image is EU-wide, so clip it to the served countries (AT + LU + NL) and
    // keep it faint — Natura 2000 blankets large areas, and it's a soft advisory, not a hard zone.
    nonisolated var renderOverlayOpacity: Double { 0.35 }
    nonisolated var renderClipPolygons: [[MapCoordinate]]? {
        CountryBoundaries.protectedAreas.polygons.map { ring in
            ring.map { MapCoordinate(latitude: $0[1], longitude: $0[0]) }
        }
    }

    // Only over the three countries this layer is meant to fill in for.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.protectedAreas }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.protectedAreas.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Natura 2000 network (EEA)", comment: "EEA Natura 2000 reference link title"),
                url: URL(string: "https://natura2000.eea.europa.eu/")!
            )
        ]
    }

    // Queries the EEA ArcGIS `identify` endpoint rather than WMS GetFeatureInfo: it takes the
    // tap as lon/lat directly (no CRS/pixel conversion) and returns clean JSON. Coverage and
    // layer-selection gating mirror the shared WMS query.
    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard catalog.isWithinCoverage(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        guard
            selectedDatasetIDs.contains(ProtectedAreasProvider.datasetID),
            status.status(for: ProtectedAreasProvider.datasetID) != .unavailable
        else {
            return .unavailable(reason: .providerNoData)
        }

        guard let url = identifyURL(for: request) else {
            return .unavailable(reason: .invalidResponse)
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return parseFeatureInfo(data)
        } catch {
            return .unavailable(reason: .requestFailed(details: error.localizedDescription))
        }
    }

    nonisolated private func identifyURL(for request: ProviderPointQueryRequest) -> URL? {
        let region = request.region
        let minLon = region.center.longitude - region.longitudeDelta / 2
        let maxLon = region.center.longitude + region.longitudeDelta / 2
        let minLat = region.center.latitude - region.latitudeDelta / 2
        let maxLat = region.center.latitude + region.latitudeDelta / 2

        var components = URLComponents(string: "https://bio.discomap.eea.europa.eu/arcgis/rest/services/ProtectedSites/Natura2000Sites/MapServer/identify")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "{\"x\":\(request.coordinate.longitude),\"y\":\(request.coordinate.latitude)}"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "sr", value: "4326"),
            URLQueryItem(name: "layers", value: "all:\(ProtectedAreasProvider.layerID)"),
            URLQueryItem(name: "tolerance", value: "3"),
            URLQueryItem(name: "mapExtent", value: "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            URLQueryItem(name: "imageDisplay", value: "\(request.viewportSize.width),\(request.viewportSize.height),96"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json")
        ]
        return components?.url
    }

    nonisolated func parseFeatureInfo(_ data: Data) -> ProviderQueryOutcome {
        struct IdentifyResponse: Decodable {
            struct Result: Decodable {
                let value: String?
                let attributes: [String: JSONScalar]?
            }
            let results: [Result]?
        }

        guard let response = try? JSONDecoder().decode(IdentifyResponse.self, from: data) else {
            return .unavailable(reason: .invalidResponse)
        }
        guard let results = response.results, !results.isEmpty else {
            return .noMatches
        }

        let records = results.map { result -> ProtectedAreaFeatureInfoRecord in
            let attributes = result.attributes ?? [:]
            let name = ["SITE_NAME", "SITENAME", "Site Name", "NAME", "name"]
                .compactMap { attributes[$0]?.stringValue }
                .first ?? result.value
            let type = ["SITETYPE", "SITE_TYPE", "Site Type"]
                .compactMap { attributes[$0]?.stringValue }
                .first
            return ProtectedAreaFeatureInfoRecord(siteName: name, siteType: type)
        }

        return .matches(records: records.map { $0 as any ProviderRawRecord })
    }
}

struct ProtectedAreasZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let area = record as? ProtectedAreaFeatureInfoRecord else {
                return nil
            }
            return ZoneFeature(
                category: .natureReserve,
                // Presence in Natura 2000 does not uniformly ban drones — national nature law
                // decides — so this is conditional (permit/often-prohibited), never allowed.
                restrictionLevel: .conditional,
                name: area.siteName,
                sourceDeclaredType: area.siteType,
                sourceDeclaredRestriction: NSLocalizedString("EU.NOTE.PROTECTED_AREA", comment: "EU protected-area (Natura 2000) advisory"),
                lowerLimit: nil,
                upperLimit: nil,
                legalReference: nil,
                source: SourceProvenance(providerID: area.providerID, sourceLayerID: ProtectedAreasProvider.layerID),
                restrictionSourceLanguage: nil
            )
        }
    }
}
