//
//  DenmarkService.swift
//  safeFLY
//
//  Denmark drone geo-zones via the Danish Civil Aviation and Railway Authority's
//  (Trafikstyrelsen) official "Dronezoner" data, published as public ArcGIS Online feature
//  layers (org `Zvx25KS6sGRl9LIx`). Like the Czech provider this fans out over several ArcGIS
//  services — one per colour-coded zone class — but these are *hosted feature services*, not
//  MapServers, so there is no WMS GetMap: rendering fetches the zone polygons as GeoJSON
//  (`f=geojson`) per viewport and point queries use the ArcGIS REST `/query` endpoint with an
//  intersecting-point spatial filter. Geometry decodes through the shared `GeoJSONGeometry`
//  bridge, reusing the same offline render-ring engine as the ED-269 providers.
//
//  Only the areal zone classes are modelled here: RØD (flight-safety-critical, prohibited),
//  BLÅ (security-critical, prohibited), ORANGE (awareness, conditional) and the green nature
//  areas (conditional). The infrastructure layers (wind turbines, roads, railways) are
//  point/line features needing buffer logic and are intentionally out of scope for now.
//

import Foundation

struct DenmarkFeatureInfoRecord: ProviderRawRecord {
    let layerID: String
    let name: String?
    // The dataset's own zone type ("HEMS 1km", "Ambassade", "Helipad 1km", or a Natura 2000
    // theme), used to derive a specific category and advisory instead of a generic per-class one.
    let typeID: String?
    // Seasonal window a nature restriction applies in, e.g. "1. februar – 31. oktober".
    let restrictionPeriod: String?
    let verdict: FlightAssessmentOutcome
    let fallbackCategory: ZoneCategory
    let legalReference: String?

    nonisolated var providerID: String { DenmarkProvider.providerID }
}

final class DenmarkProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "denmark"

    nonisolated let id = DenmarkProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("Trafikstyrelsen", comment: "Denmark provider display name")
    }
    nonisolated var attributionName: String { "Trafikstyrelsen" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    // One hosted ArcGIS feature layer per Danish zone class.
    nonisolated private struct ZoneLayer {
        let id: String                 // Stable per-layer id (used in payload ids / provenance).
        let url: String                // Full FeatureServer/{layerIndex} endpoint.
        let datasetID: String          // User-facing dataset toggle this layer belongs to.
        let category: ZoneCategory
        let verdict: FlightAssessmentOutcome
    }

    nonisolated private static let org =
        "https://services-eu1.arcgis.com/Zvx25KS6sGRl9LIx/arcgis/rest/services"
    nonisolated private static let restrictedZonesDataset = "airspace.restricted-zones"
    nonisolated private static let natureDataset = "nature.protected-areas"

    nonisolated private let layers: [ZoneLayer] = [
        // RØD — flyvesikringskritisk (flight-safety-critical): flight prohibited.
        ZoneLayer(id: "zone.red", url: "\(org)/DroneZoner_2025_ny_bekndg/FeatureServer/1",
                  datasetID: restrictedZonesDataset, category: .restrictedArea, verdict: .prohibited),
        // BLÅ — sikringskritisk (security-critical): flight prohibited (permit only).
        ZoneLayer(id: "zone.blue", url: "\(org)/DroneZoner_2025_ny_bekndg/FeatureServer/4",
                  datasetID: restrictedZonesDataset, category: .securityAuthority, verdict: .prohibited),
        // ORANGE — opmærksomhedsområde (awareness area): fly with caution / conditions.
        ZoneLayer(id: "zone.orange", url: "\(org)/DroneZoner_2025_ny_bekndg/FeatureServer/2",
                  datasetID: restrictedZonesDataset, category: .restrictedArea, verdict: .conditional),
        // GRØN — naturområder (Natura 2000 / nature): permit-based, treated as conditional.
        ZoneLayer(id: "zone.nature", url: "\(org)/NaturOmraader2024v2/FeatureServer/0",
                  datasetID: natureDataset, category: .natureReserve, verdict: .conditional)
    ]

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: DenmarkProvider.restrictedZonesDataset,
                presentation: localizedProviderPresentation(title: "Restricted Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: DenmarkProvider.natureDataset,
                presentation: localizedProviderPresentation(title: "Nature Reserves", groupTitle: "Nature"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution and run queries only over metropolitan Denmark.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.denmark }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.denmark.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Dronezoner (Trafikstyrelsen)", comment: "Denmark provider data source link title"),
                url: URL(string: "https://www.droneregler.dk/dronezoner")!
            )
        ]
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        // Probe every layer concurrently; the provider is available if any layer answers.
        let statuses = await withTaskGroup(of: (String, ProviderAvailabilityStatus).self, returning: [(String, ProviderAvailabilityStatus)].self) { group in
            for layer in layers {
                group.addTask {
                    let up = await Self.probe(layer: layer)
                    return (layer.datasetID, up ? .available : .unavailable)
                }
            }
            var collected: [(String, ProviderAvailabilityStatus)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var datasetStatuses: [String: ProviderAvailabilityStatus] = [:]
        for (datasetID, status) in statuses {
            // A dataset backed by several layers is available if any of them is.
            if datasetStatuses[datasetID] == nil || status == .available {
                datasetStatuses[datasetID] = status
            }
        }

        let values = datasetStatuses.values
        let providerStatus: ProviderAvailabilityStatus
        if values.allSatisfy({ $0 == .available }) {
            providerStatus = .available
        } else if values.contains(.available) {
            providerStatus = .degraded
        } else {
            providerStatus = .unavailable
        }

        return ProviderStatusSnapshot(
            providerStatus: providerStatus,
            datasetStatuses: datasetStatuses,
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    nonisolated private static func probe(layer: ZoneLayer) async -> Bool {
        guard let url = URL(string: "\(layer.url)?f=json"),
              let (_, response) = try? await URLSession.shared.data(from: url) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        let activeLayers = layers.filter {
            selectedDatasetIDs.contains($0.datasetID) && status.status(for: $0.datasetID) != .unavailable
        }
        guard !activeLayers.isEmpty else { return [] }

        let payloadsByLayer = await withTaskGroup(of: [ProviderRenderPayload].self, returning: [[ProviderRenderPayload]].self) { group in
            for layer in activeLayers {
                group.addTask { await Self.renderLayer(layer, region: request.region) }
            }
            var collected: [[ProviderRenderPayload]] = []
            for await payloads in group { collected.append(payloads) }
            return collected
        }
        return payloadsByLayer.flatMap { $0 }
    }

    nonisolated private static func renderLayer(_ layer: ZoneLayer, region: MapRegion) async -> [ProviderRenderPayload] {
        guard let style = ED269RenderStyle.forVerdict(layer.verdict) else { return [] }

        let minLat = region.center.latitude - region.latitudeDelta / 2
        let maxLat = region.center.latitude + region.latitudeDelta / 2
        let minLon = region.center.longitude - region.longitudeDelta / 2
        let maxLon = region.center.longitude + region.longitudeDelta / 2

        // Simplify server-side to roughly one map pixel, so a wide-zoom view of large nature
        // areas returns light geometry instead of every vertex.
        let offset = Swift.max(region.latitudeDelta, region.longitudeDelta) / 1024.0

        var components = URLComponents(string: "\(layer.url)/query")
        components?.queryItems = [
            // ArcGIS envelope is xmin,ymin,xmax,ymax i.e. minLon,minLat,maxLon,maxLat.
            URLQueryItem(name: "geometry", value: "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: ""),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "maxAllowableOffset", value: "\(offset)"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "f", value: "geojson")
        ]

        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let collection = try? JSONDecoder().decode(GeoJSONFeatureCollection<DKEmptyProperties>.self, from: data) else {
            return []
        }

        var payloads: [ProviderRenderPayload] = []
        for feature in collection.features {
            for ring in feature.ed269Geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(providerID).\(layer.id).\(payloads.count)",
                    coordinates: ring,
                    fillColorHex: style.fillColor,
                    fillOpacity: style.fillOpacity,
                    strokeColorHex: style.strokeColor,
                    strokeOpacity: style.strokeOpacity,
                    lineWidth: style.lineWidth
                )))
            }
        }
        return payloads
    }

    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard CountryBoundaries.denmark.contains(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        let activeLayers = layers.filter {
            selectedDatasetIDs.contains($0.datasetID) && status.status(for: $0.datasetID) != .unavailable
        }
        guard !activeLayers.isEmpty else {
            return .unavailable(reason: .providerNoData)
        }

        let recordsByLayer = await withTaskGroup(of: [DenmarkFeatureInfoRecord].self, returning: [[DenmarkFeatureInfoRecord]].self) { group in
            for layer in activeLayers {
                group.addTask { await Self.identify(layer: layer, coordinate: request.coordinate) }
            }
            var collected: [[DenmarkFeatureInfoRecord]] = []
            for await records in group { collected.append(records) }
            return collected
        }

        let records = recordsByLayer.flatMap { $0 }
        return records.isEmpty ? .noMatches : .matches(records: records.map { $0 as any ProviderRawRecord })
    }

    nonisolated private static func identify(layer: ZoneLayer, coordinate: MapCoordinate) async -> [DenmarkFeatureInfoRecord] {
        var components = URLComponents(string: "\(layer.url)/query")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "\(coordinate.longitude),\(coordinate.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json")
        ]

        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            return []
        }

        struct QueryResponse: Decodable {
            struct Feature: Decodable { let attributes: [String: JSONScalar]? }
            let features: [Feature]?
        }

        guard let response = try? JSONDecoder().decode(QueryResponse.self, from: data),
              let features = response.features else {
            return []
        }

        return features.map { feature in
            let attributes = feature.attributes ?? [:]
            func first(_ keys: [String]) -> String? {
                keys.compactMap { attributes[$0]?.stringValue }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
            }
            // `title` covers the coloured zones; the nature layer names its site in a single
            // (oddly named) field shared by bird and habitat areas.
            let name = first(["title", "Fuglebeskyttelsesområder_og_Hab", "Navn", "navn", "Name", "name"])
            let typeID = first(["typeId", "Temanavn"])
            let period = first(["Restriktionsperiode_"])
            let paragraf = first(["Paragraf"])
            return DenmarkFeatureInfoRecord(
                layerID: layer.id,
                name: name,
                typeID: typeID,
                restrictionPeriod: period,
                verdict: layer.verdict,
                fallbackCategory: layer.category,
                legalReference: paragraf.map { "§ \($0)" }
            )
        }
    }
}

// The render path needs geometry only; properties are ignored.
nonisolated struct DKEmptyProperties: Decodable, Sendable {}

struct DenmarkZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let dk = record as? DenmarkFeatureInfoRecord else { return nil }
            let classification = DenmarkZoneNormalizer.classify(
                layerID: dk.layerID, typeID: dk.typeID, fallback: dk.fallbackCategory
            )
            // A specific, already-localized advisory derived from the zone's own type — plus the
            // seasonal window for nature zones, which often only restrict flight part of the year.
            var note = NSLocalizedString(classification.noteKey, comment: "Denmark zone advisory")
            if let period = dk.restrictionPeriod, !period.isEmpty {
                note += " " + String(format: NSLocalizedString("DK.RESTRICTED_PERIOD", comment: "Denmark seasonal restriction period"), period)
            }
            return ZoneFeature(
                category: classification.category,
                restrictionLevel: classification.verdict ?? dk.verdict,
                name: dk.name,
                sourceDeclaredType: dk.typeID,
                sourceDeclaredRestriction: note,
                lowerLimit: nil,
                upperLimit: nil,
                legalReference: dk.legalReference,
                source: SourceProvenance(providerID: dk.providerID, sourceLayerID: dk.layerID),
                restrictionSourceLanguage: nil
            )
        }
    }

    // Maps a zone's own `typeId` / Natura 2000 theme to a specific category and a localized
    // advisory. A nil `verdict` means "keep the layer's default"; only the explicit drone-ban
    // nature zones override it (to prohibited).
    nonisolated static func classify(
        layerID: String, typeID: String?, fallback: ZoneCategory
    ) -> (category: ZoneCategory, noteKey: String, verdict: FlightAssessmentOutcome?) {
        let t = (typeID ?? "").lowercased()
        switch layerID {
        case "zone.red":
            if t.contains("hems") { return (.hospital, "DK.T.HEMS", nil) }
            if t.contains("lufthavn") { return (.airport, "DK.T.AIRPORT", nil) }
            if t.contains("vandflyve") { return (.aerodrome, "DK.T.SEAPLANE", nil) }
            return (.restrictedArea, "DK.NOTE.RED", nil)
        case "zone.blue":
            if t.contains("ambassade") { return (.diplomaticMission, "DK.T.EMBASSY", nil) }
            if t.contains("fængsel") { return (.prison, "DK.T.PRISON", nil) }
            if t.contains("politi") { return (.policeProperty, "DK.T.POLICE", nil) }
            if t.contains("militær") { return (.militaryInstallation, "DK.T.MILITARY", nil) }
            if t.contains("ret") || t.contains("domstol") || t.contains("byret") { return (.authority, "DK.T.COURT", nil) }
            if t.contains("slot") { return (.securityAuthority, "DK.T.PALACE", nil) }
            if t.contains("virksomhed") { return (.industrialInstallation, "DK.T.INDUSTRY", nil) }
            return (.securityAuthority, "DK.NOTE.BLUE", nil)
        case "zone.orange":
            if t.contains("helipad") { return (.aerodrome, "DK.T.HELIPAD", nil) }
            if t.contains("faldskærm") { return (.recreationalArea, "DK.T.PARACHUTE", nil) }
            if t.contains("svæveflyve") { return (.aerodrome, "DK.T.GLIDER", nil) }
            if t.contains("flyveplads") { return (.aerodrome, "DK.T.PRIVATE_AF", nil) }
            return (.restrictedArea, "DK.NOTE.ORANGE", nil)
        case "zone.nature":
            if t.contains("droneforbud") { return (.natureReserve, "DK.T.DRONE_BAN", .prohibited) }
            if t.contains("fugle") { return (.birdSanctuary, "DK.T.NATURA_BIRD", nil) }
            if t.contains("habitat") { return (.habitatDirectiveSite, "DK.T.NATURA_HABITAT", nil) }
            if t.contains("fredning") { return (.natureReserve, "DK.T.CONSERVATION", nil) }
            return (.natureReserve, "DK.NOTE.NATURE", nil)
        default:
            return (fallback, "DK.NOTE.RED", nil)
        }
    }
}
