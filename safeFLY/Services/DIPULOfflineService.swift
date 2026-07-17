//
//  DIPULOfflineService.swift
//  safeFLY
//
//  Offline German geographic zones (DIPUL) as a downloadable GeoJSON package, served by the
//  gruettecloud proxy (`?country=DE`) exactly like the ED-269 offline countries. This exists
//  alongside the live DIPUL WMS provider: the WMS is always-fresh but online and rate-limited;
//  this package renders and queries the same zones fully offline. Both are free (German data
//  is the free anchor) and licensed CC BY-ND 4.0 — attribution "dipul, CC-BY-ND 4.0", and the
//  geometry is rendered/queried as-is (no derived geometries shipped), honouring the ND clause.
//
//  The proxy strips the full ~366 MB German dataset to flight-critical layers only (~36 MB),
//  keyed by an exact `type_code` (15 values). Each feature carries a Polygon geometry, DE/EN
//  generated names, a LuftVO legal reference, and (for airspace zones) an upper altitude limit.
//

import Foundation
import CoreLocation

// One German zone parsed from the offline GeoJSON. Geometry is expressed with the shared
// `ED269Geometry` engine so bounding-box, point-in-polygon and render-ring logic is reused.
nonisolated struct DIPULGeoJSONFeature: Sendable {
    let identifier: String
    let name: String?
    let typeCode: String?           // Exact DIPUL layer code, e.g. "KONTROLLZONE", "POLIZEI".
    let legalReference: String?     // LuftVO paragraph the zone rests on.
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let geometry: [ED269Geometry]

    var boundingBox: BoundingBox? { geometry.boundingBox }
    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

struct DIPULOfflineFeatureInfoRecord: ProviderRawRecord {
    let name: String?
    let typeCode: String?
    let legalReference: String?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?

    nonisolated var providerID: String { DIPULOfflineProvider.providerID }
}

final class DIPULOfflineProvider: ED269DownloadableProvider, @unchecked Sendable {
    nonisolated static let providerID = "dipul-offline"
    // The offline package is stripped server-side to flight-critical layers only, split into
    // two toggle groups here. Bulk layers (nature, transport, industry, residential) are NOT in
    // the package — the live DIPUL WMS provider carries those. See the note in ProviderDetailView.
    nonisolated static let airspaceDatasetID = "airspace.flight-critical"
    nonisolated static let facilitiesDatasetID = "facilities.sensitive"

    nonisolated let id = DIPULOfflineProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("DIPUL Offline Core", comment: "DIPUL Offline Core provider display name")
    }
    nonisolated var attributionName: String {
        "dipul, CC-BY-ND 4.0"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    let dataset = ED269DownloadableDataset<DIPULGeoJSONFeature>(
        fileName: "dipul_de_zones.geojson",
        remoteURL: URL(string: "https://gruettecloud.com/safefly/download-json?country=DE")!,
        parse: DIPULOfflineProvider.parse
    )

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: DIPULOfflineProvider.airspaceDatasetID,
                presentation: localizedProviderPresentation(title: "Airspace", groupTitle: "Geographic Zones"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: DIPULOfflineProvider.facilitiesDatasetID,
                presentation: localizedProviderPresentation(title: "Sensitive Facilities", groupTitle: "Geographic Zones"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    nonisolated var coverage: CountryCoverage? { CountryBoundaries.germany }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.germany.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("DFS DIPUL Datasource", comment: "Provider reference link title"),
                url: URL(string: "https://www.dipul.de/homepage/de/informationen/geografische-gebiete/wfs-wms/")!
            )
        ]
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = dataset.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [
                DIPULOfflineProvider.airspaceDatasetID: status,
                DIPULOfflineProvider.facilitiesDatasetID: status
            ],
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard dataset.isDownloaded else { return [] }

        let features = await dataset.features
        var payloads: [ProviderRenderPayload] = []

        for feature in features {
            guard selectedDatasetIDs.contains(DIPULOfflineZoneNormalizer.datasetID(typeCode: feature.typeCode)) else { continue }

            if let bbox = feature.boundingBox, !bbox.intersects(request.region) {
                continue
            }

            guard let style = ED269RenderStyle.forVerdict(DIPULOfflineZoneNormalizer.verdict(typeCode: feature.typeCode)) else { continue }

            for ring in feature.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(feature.identifier).\(payloads.count)",
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
        guard dataset.isDownloaded else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await dataset.features
            .compactMap { feature -> DIPULOfflineFeatureInfoRecord? in
                guard selectedDatasetIDs.contains(DIPULOfflineZoneNormalizer.datasetID(typeCode: feature.typeCode)) else { return nil }
                if let bbox = feature.boundingBox, !bbox.contains(coordinate) {
                    return nil
                }
                guard feature.contains(coordinate) else { return nil }
                return DIPULOfflineFeatureInfoRecord(
                    name: feature.name,
                    typeCode: feature.typeCode,
                    legalReference: feature.legalReference,
                    lowerLimit: feature.lowerLimit,
                    upperLimit: feature.upperLimit
                )
            }

        if matches.isEmpty {
            return .noMatches
        }

        return .matches(records: matches.map { $0 as any ProviderRawRecord })
    }

    // MARK: - Parsing

    // Whether the device is running in German, used only to pick DE vs EN generated names.
    nonisolated private static var prefersGerman: Bool {
        Locale.current.language.languageCode?.identifier == "de"
    }

    nonisolated private static func parse(_ data: Data) throws -> [DIPULGeoJSONFeature] {
        let clean = try ed269StrippedJSONData(data)
        guard
            let root = try JSONSerialization.jsonObject(with: clean) as? [String: Any],
            let features = root["features"] as? [[String: Any]]
        else {
            throw NSError(domain: "DIPULOffline", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a GeoJSON FeatureCollection"])
        }

        let preferGerman = prefersGerman

        return features.enumerated().compactMap { index, feature in
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let geometry = convertGeometry(feature["geometry"] as? [String: Any])
            guard !geometry.isEmpty else { return nil }

            let deName = properties["generated_name_DE"] as? String
            let enName = properties["generated_name_EN"] as? String
            let name = (preferGerman ? (deName ?? enName) : (enName ?? deName)) ?? firstOfNameArray(properties["name"])

            return DIPULGeoJSONFeature(
                identifier: (properties["external_reference"] as? String) ?? "dipul.\(index)",
                name: name,
                typeCode: properties["type_code"] as? String,
                legalReference: properties["legal_ref"] as? String,
                lowerLimit: altitudeLimit(
                    properties["lower_limit_altitude"], properties["lower_limit_unit"], properties["lower_limit_alt_ref"]
                ),
                upperLimit: altitudeLimit(
                    properties["upper_limit_altitude"], properties["upper_limit_unit"], properties["upper_limit_alt_ref"]
                ),
                geometry: geometry
            )
        }
    }

    // The `name` property is an array of strings in the feed; used only as a last-resort fallback
    // when the generated DE/EN names are absent.
    nonisolated private static func firstOfNameArray(_ value: Any?) -> String? {
        (value as? [Any])?.compactMap { $0 as? String }.first
    }

    // Builds an altitude limit from the feed's numeric value + unit + reference. A 0 m (or
    // missing) floor carries no useful limit, so it collapses to nil rather than "0 m AGL".
    nonisolated private static func altitudeLimit(_ value: Any?, _ unit: Any?, _ reference: Any?) -> AltitudeLimit? {
        guard let meters = (value as? NSNumber)?.doubleValue, meters > 0 else { return nil }
        return AltitudeLimit(
            value: String(Int(meters)),
            unit: (unit as? String) ?? "m",
            reference: (reference as? String) ?? "AGL"
        )
    }

    // Maps a GeoJSON geometry object into the shared ED-269 polygon representation. The DE feed
    // is all Polygon; MultiPolygon is handled too for resilience. Other types are ignored.
    nonisolated private static func convertGeometry(_ geometry: [String: Any]?) -> [ED269Geometry] {
        guard let geometry, let type = geometry["type"] as? String else { return [] }

        func polygon(_ rings: [[[Double]]]) -> ED269Geometry {
            ED269Geometry(
                upperLimit: nil, lowerLimit: nil, uomDimensions: nil,
                upperVerticalReference: nil, lowerVerticalReference: nil,
                horizontalProjection: ED269HorizontalProjection(type: "Polygon", center: nil, radius: nil, coordinates: rings)
            )
        }

        switch type {
        case "Polygon":
            guard let rings = rings(from: geometry["coordinates"]) else { return [] }
            return [polygon(rings)]
        case "MultiPolygon":
            guard let polygons = geometry["coordinates"] as? [Any] else { return [] }
            return polygons.compactMap { rings(from: $0).map(polygon) }
        default:
            return []
        }
    }

    // Parses a GeoJSON polygon coordinate array ([[[lon, lat]]]) out of loosely-typed JSON,
    // where numbers arrive as NSNumber. Returns nil if the shape isn't a valid ring array.
    nonisolated private static func rings(from any: Any?) -> [[[Double]]]? {
        guard let outer = any as? [Any] else { return nil }
        var result: [[[Double]]] = []
        for ring in outer {
            guard let ringArray = ring as? [Any] else { return nil }
            var points: [[Double]] = []
            for point in ringArray {
                guard
                    let coordinate = point as? [Any], coordinate.count >= 2,
                    let lon = (coordinate[0] as? NSNumber)?.doubleValue,
                    let lat = (coordinate[1] as? NSNumber)?.doubleValue
                else { return nil }
                points.append([lon, lat])
            }
            result.append(points)
        }
        return result.isEmpty ? nil : result
    }
}

struct DIPULOfflineZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let record = record as? DIPULOfflineFeatureInfoRecord else { return nil }
            let category = DIPULOfflineZoneNormalizer.category(typeCode: record.typeCode)
            return ZoneFeature(
                category: category,
                restrictionLevel: DIPULZoneNormalizer.restrictionLevel(for: category),
                name: record.name,
                sourceDeclaredType: record.typeCode,
                // The GeoJSON carries no free-text restriction, so use DIPUL's localized
                // per-category regulatory explanation (already in the user's language → nil lang).
                sourceDeclaredRestriction: DIPULZoneNormalizer.regulatoryText(for: category),
                lowerLimit: record.lowerLimit,
                upperLimit: record.upperLimit,
                legalReference: record.legalReference,
                source: SourceProvenance(providerID: record.providerID, sourceLayerID: record.typeCode ?? "dipul"),
                restrictionSourceLanguage: nil,
                // Same class-aware residential note as the online provider, so offline behaves
                // identically. Only .residentialProperty gets one (see DIPULZoneNormalizer.classNote).
                supplementaryNote: DIPULZoneNormalizer.classNote(
                    for: category, droneClass: DIPULZoneNormalizer.currentDroneClass()
                )
            )
        }
    }

    // Exact DIPUL `type_code` → our taxonomy. The 15 codes are the full set present in the
    // flight-critical offline package.
    nonisolated static func category(typeCode: String?) -> ZoneCategory {
        switch typeCode {
        case "FLUGHAFEN":                   return .airport
        case "KONTROLLZONE":                return .controlZone
        case "FLUGPLATZ":                   return .aerodrome
        case "HAENGEGLEITER":               return .aerodrome
        case "MODELLFLUGPLATZ":             return .modelFlyingField
        case "FLUGBESCHRAENKUNGSGEBIET":    return .restrictedArea
        case "MILITAERISCHE_ANLAGE":        return .militaryInstallation
        case "POLIZEI":                     return .policeProperty
        case "KRANKENHAUS":                 return .hospital
        case "JUSTIZVOLLZUGSANSTALT":       return .prison
        case "DIPLOMATISCHE_VERTRETUNG":    return .diplomaticMission
        case "INTERNATIONALE_ORGANISATION": return .internationalOrganization
        case "SICHERHEITSBEHOERDE":         return .securityAuthority
        case "BEHOERDE":                    return .authority
        case "BSL-4-LABOR":                 return .bsl4Facility
        default:                            return .restrictedArea
        }
    }

    // Verdict for map styling, delegating to DIPUL's shared German rules so the offline map
    // colours match the live WMS and the zone sheet: only airports (and active temporary no-fly
    // zones, absent from this package) are hard-prohibited; everything else is conditional —
    // flight is possible under conditions such as clearance or operator/authority consent.
    nonisolated static func verdict(typeCode: String?) -> FlightAssessmentOutcome {
        DIPULZoneNormalizer.restrictionLevel(for: category(typeCode: typeCode))
    }

    // Splits the flight-critical layers into the two toggle groups the offline package ships:
    // airspace zones vs. sensitive ground facilities.
    nonisolated static func datasetID(typeCode: String?) -> String {
        switch typeCode {
        case "FLUGHAFEN", "KONTROLLZONE", "FLUGPLATZ", "HAENGEGLEITER", "MODELLFLUGPLATZ", "FLUGBESCHRAENKUNGSGEBIET":
            return DIPULOfflineProvider.airspaceDatasetID
        default:
            return DIPULOfflineProvider.facilitiesDatasetID
        }
    }
}
