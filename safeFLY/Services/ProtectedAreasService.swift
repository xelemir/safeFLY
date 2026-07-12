//
//  ProtectedAreasService.swift
//  safeFLY
//
//  EU-wide nature-reserve overlay via the European Environment Agency's Natura 2000 WMS on
//  geo.discomap.eea.europa.eu. It fills a real gap: Austria, Luxembourg, the Netherlands and
//  Sweden do NOT publish nature reserves in their national drone feeds (verified against the
//  live data — Sweden's AIP carries only 8 of its ~30 national parks as R-areas and none of
//  its thousands of naturreservat, whose per-reserve bylaws frequently restrict drones), so
//  this EEA-attributed provider covers exactly those four countries. Germany, Switzerland,
//  Czechia and Denmark already ship reserves and are excluded to avoid overlap; Finland is
//  excluded deliberately because drone flight in Finnish nature areas is generally allowed
//  under Everyman's Right (Metsähallitus), so a blanket conditional wash would be misleading.
//
//  One instance is registered *per country* (each scoped to that country's outline) rather than
//  a single shared session, so the user can enable the nature layer in one country without it
//  switching on in the others.
//
//  Rendering reuses the shared WMS GetMap plumbing; point queries go through the ArcGIS REST
//  `identify` endpoint (clean JSON, no CRS pixel math), matching how the other ArcGIS-backed
//  providers here query. Being inside Natura 2000 does not uniformly ban drones — the rule is
//  national nature-protection law (permit-based, often prohibited) — so every match is a
//  `conditional` verdict with a "check before flying" note, never a green all-clear.
//

import Foundation

struct ProtectedAreaFeatureInfoRecord: ProviderRawRecord {
    let providerID: String
    let siteName: String?
    let siteType: String?
}

final class ProtectedAreasProvider: WMSBackedProvider, @unchecked Sendable {
    nonisolated static let datasetID = "nature.protected-areas"
    // Layer "0" is the combined Habitats + Birds Directive sites (the full Natura 2000 set).
    nonisolated static let layerID = "0"

    // Stable per-country provider ids (also the settings navigation ids).
    nonisolated static let austriaID = "eu-protected-areas-at"
    nonisolated static let luxembourgID = "eu-protected-areas-lu"
    nonisolated static let netherlandsID = "eu-protected-areas-nl"
    nonisolated static let swedenID = "eu-protected-areas-se"

    nonisolated let id: String
    nonisolated let coverage: CountryCoverage?
    nonisolated let catalog: WMSDatasetCatalog

    // Each instance is scoped to one country's outline so it toggles, renders and gates
    // independently of the same layer in the neighbouring countries.
    nonisolated init(id: String, country: CountryCoverage) {
        self.id = id
        self.coverage = country
        let box = country.boundingBox
        self.catalog = WMSDatasetCatalog(
            baseURL: "https://bio.discomap.eea.europa.eu/arcgis/services/ProtectedSites/Natura2000Sites/MapServer/WMSServer",
            definitions: [
                .make(
                    id: ProtectedAreasProvider.datasetID,
                    title: "Nature Reserves",
                    groupTitle: "Nature",
                    layerIDs: [ProtectedAreasProvider.layerID]
                )
            ],
            coverageBounds: WMSDatasetCatalog.CoverageBounds(
                minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon
            ),
            coverage: country,
            // The EEA ArcGIS WMS, like the Czech one, is served in web-mercator for GetMap.
            crs: "EPSG:3857"
        )
    }

    // The registered per-country instances.
    nonisolated static func austria() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: austriaID, country: CountryBoundaries.austria)
    }
    nonisolated static func luxembourg() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: luxembourgID, country: CountryBoundaries.luxembourg)
    }
    nonisolated static func netherlands() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: netherlandsID, country: CountryBoundaries.netherlands)
    }
    nonisolated static func sweden() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: swedenID, country: CountryBoundaries.sweden)
    }

    nonisolated var displayName: String {
        NSLocalizedString("Protected Areas (Europe)", comment: "EU protected areas provider display name")
    }
    nonisolated var attributionName: String { "EEA" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    // Unused: `query` is overridden to hit the ArcGIS `identify` REST endpoint.
    nonisolated var queryInfoFormat: String { "application/json" }

    // The EEA GetMap image spans more than this country, so clip it to the country outline and
    // keep it faint — Natura 2000 blankets large areas, and it's a soft advisory, not a hard zone.
    nonisolated var renderOverlayOpacity: Double { 0.35 }
    nonisolated var renderClipPolygons: [[MapCoordinate]]? {
        coverage?.polygons.map { ring in
            ring.map { MapCoordinate(latitude: $0[1], longitude: $0[0]) }
        }
    }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        coverage?.intersects(region) ?? false
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
            return ProtectedAreaFeatureInfoRecord(providerID: id, siteName: name, siteType: type)
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
