//
//  FinlandService.swift
//  safeFLY
//
//  Finland drone geo-zones: the Traficom UAS geographical zones (established under the
//  Finnish Aviation Act; presented officially at droneinfo.fi), published as a GeoJSON
//  FeatureCollection with standard ED-269 properties. Downloaded as an offline package from
//  the gruettecloud proxy (`?country=FI`) exactly like the other ED-269 offline countries
//  (Netherlands, Austria, Luxembourg, offline Germany), and kept fresh by the same silent
//  daily background refresh. Point queries use ray-casting offline; vector rendering uses
//  MapPolygon payloads through the shared ED-269 geometry engine.
//

import Foundation

struct FinlandFeatureInfoRecord: ProviderRawRecord {
    let identifier: String?
    let name: String?
    let restriction: String?
    let reasons: [String]
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?

    nonisolated var providerID: String { FinlandProvider.providerID }
}

// One UAS zone's properties from the Traficom/Flyk GeoJSON. ED-269 vocabulary
// (`restriction`, `reason`), with vertical limits pre-computed in metres.
nonisolated struct FIZoneProperties: Decodable, Sendable {
    let identifier: String?
    let name: String?
    let restriction: String?
    let reason: [String]?
    let lowerMeters: Double?
    let upperMeters: Double?
    let active: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try? c.decodeIfPresent(String.self, forKey: .identifier)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        restriction = try? c.decodeIfPresent(String.self, forKey: .restriction)
        reason = try? c.decodeIfPresent([String].self, forKey: .reason)
        lowerMeters = try? c.decodeIfPresent(Double.self, forKey: .lowerMeters)
        upperMeters = try? c.decodeIfPresent(Double.self, forKey: .upperMeters)
        active = try? c.decodeIfPresent(Bool.self, forKey: .active)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, name, restriction, reason, lowerMeters, upperMeters, active
    }

    // Only currently-active zones restrict a flight; the feed also carries scheduled zones
    // whose window is not in force (mirrors how droneinfo.fi presents them).
    var isActive: Bool { active ?? true }

    // Whether this zone can affect a typical open-category flight (≤120 m AGL): a zone whose
    // floor is above 120 m is upper airspace and would only clutter the map.
    var affectsLowLevelFlight: Bool { (lowerMeters ?? 0) <= 120 }
}

// A zone with its geometry pre-bridged and its bounding box precomputed at parse time, so
// the per-frame viewport filter over ~720 zones stays cheap.
nonisolated struct FIZone: Sendable {
    let properties: FIZoneProperties
    let geometry: [ED269Geometry]
    let boundingBox: BoundingBox?

    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

final class FinlandProvider: ED269DownloadableProvider, @unchecked Sendable {
    nonisolated static let providerID = "finland"
    nonisolated static let datasetID = "airspace.uas-zones"

    nonisolated let id = FinlandProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("Traficom", comment: "Finland provider display name")
    }
    nonisolated var attributionName: String { "Traficom / Flyk" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    let dataset = ED269DownloadableDataset<FIZone>(
        fileName: "fin_uas_zones.json",
        remoteURL: URL(string: "https://gruettecloud.com/safefly/download-json?country=FI")!,
        parse: FinlandProvider.parse
    )

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: FinlandProvider.datasetID,
                presentation: localizedProviderPresentation(title: "UAS Geographical Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution and run queries only over real Finnish territory (incl. Åland).
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.finland }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.finland.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("UAS Geographical Zones (Droneinfo/Traficom)", comment: "Finland provider zones link title"),
                url: URL(string: "https://droneinfo.fi/en/uas-map")!
            ),
            ProviderReferenceLink(
                title: NSLocalizedString("Flyk Aviation Map", comment: "Finland provider map link title"),
                url: URL(string: "https://flyk.com/map")!
            )
        ]
    }

    nonisolated private static func parse(_ data: Data) throws -> [FIZone] {
        let collection = try JSONDecoder().decode(
            GeoJSONFeatureCollection<FIZoneProperties>.self,
            from: ed269StrippedJSONData(data)
        )
        return collection.features.compactMap { feature -> FIZone? in
            let geometry = feature.ed269Geometry
            guard !geometry.isEmpty else { return nil }
            return FIZone(properties: feature.properties, geometry: geometry, boundingBox: geometry.boundingBox)
        }
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = dataset.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [FinlandProvider.datasetID: status],
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard dataset.isDownloaded,
              selectedDatasetIDs.contains(FinlandProvider.datasetID) else { return [] }

        var payloads: [ProviderRenderPayload] = []
        for zone in await dataset.features {
            guard zone.properties.isActive, zone.properties.affectsLowLevelFlight else { continue }
            if let bbox = zone.boundingBox, !bbox.intersects(request.region) { continue }
            let verdict = FinlandZoneNormalizer.verdict(for: zone.properties.restriction)
            guard let style = ED269RenderStyle.forVerdict(verdict) else { continue }

            for ring in zone.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(id).\(zone.properties.identifier ?? "zone").\(payloads.count)",
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
        guard CountryBoundaries.finland.contains(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }
        guard dataset.isDownloaded,
              selectedDatasetIDs.contains(FinlandProvider.datasetID) else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await dataset.features
            .filter { zone in
                guard zone.properties.isActive, zone.properties.affectsLowLevelFlight else { return false }
                if let bbox = zone.boundingBox, !bbox.contains(coordinate) { return false }
                return zone.contains(coordinate)
            }
            .map { zone -> FinlandFeatureInfoRecord in
                FinlandFeatureInfoRecord(
                    identifier: zone.properties.identifier,
                    name: zone.properties.name,
                    restriction: zone.properties.restriction,
                    reasons: zone.properties.reason ?? [],
                    lowerLimit: FinlandZoneNormalizer.limit(zone.properties.lowerMeters, floor: 0.5),
                    upperLimit: FinlandZoneNormalizer.limit(zone.properties.upperMeters, floor: 0.5)
                )
            }

        return matches.isEmpty ? .noMatches : .matches(records: matches.map { $0 as any ProviderRawRecord })
    }
}

struct FinlandZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let fi = record as? FinlandFeatureInfoRecord else { return nil }
            let verdict = FinlandZoneNormalizer.verdict(for: fi.restriction)
            return ZoneFeature(
                category: FinlandZoneNormalizer.category(name: fi.name, reasons: fi.reasons),
                restrictionLevel: verdict,
                name: fi.name,
                sourceDeclaredType: fi.restriction,
                sourceDeclaredRestriction: FinlandZoneNormalizer.note(for: verdict),
                lowerLimit: fi.lowerLimit,
                upperLimit: fi.upperLimit,
                legalReference: fi.identifier,
                source: SourceProvenance(providerID: fi.providerID, sourceLayerID: FinlandProvider.providerID),
                // The advisory is our own localized text, so it must not be machine-translated.
                restrictionSourceLanguage: nil
            )
        }
    }

    // Standard ED-269 restriction enum → flight verdict (same mapping as Belgium/Austria).
    nonisolated static func verdict(for restriction: String?) -> FlightAssessmentOutcome {
        switch restriction {
        case "PROHIBITED":
            return .prohibited
        case "NO_RESTRICTION":
            return .allowed
        case "REQ_AUTHORISATION", "REQ_AUTHORIZATION", "CONDITIONAL":
            return .conditional
        default:
            return .conditional
        }
    }

    // Short localized guidance per verdict; the Finnish feed carries no per-zone advisory text.
    nonisolated static func note(for verdict: FlightAssessmentOutcome) -> String {
        switch verdict {
        case .prohibited:
            return NSLocalizedString("FI.NOTE.PROHIBITED", comment: "Finland advisory: prohibited zone")
        case .conditional:
            return NSLocalizedString("FI.NOTE.AUTHORISATION", comment: "Finland advisory: authorisation required")
        case .allowed:
            return NSLocalizedString("FI.NOTE.NO_RESTRICTION", comment: "Finland advisory: informational zone")
        }
    }

    // Category from the (Finnish) zone name plus the ED-269 reason codes.
    nonisolated static func category(name: String?, reasons: [String]) -> ZoneCategory {
        let text = (name ?? "").lowercased()
        if text.contains("vankila") {
            return .prison
        }
        if text.contains("lennokki") || text.contains("rc-") {
            return .modelFlyingField
        }
        if text.contains("sairaala") || text.contains("hospital") {
            return .hospital
        }
        if text.contains("lentoasema") || text.contains("lentokenttä") {
            return .airport
        }
        if text.contains("helikopteri") || text.contains("heliport") {
            return .aerodrome
        }
        if text.contains("voimala") || text.contains("voimalaitos") || text.contains("ydinvoima") {
            return .powerPlant
        }
        if text.contains("jalostamo") || text.contains("tehdas") || text.contains("terminaali") || text.contains("satama") {
            return .industrialInstallation
        }
        if text.contains("varuskunta") || text.contains("sotilas") || text.contains("puolustusvoim") {
            return .militaryInstallation
        }
        // The A-class air-traffic zones around airfields ("UAS-ilmatilavyöhyke …").
        if reasons.contains("AIR_TRAFFIC") || text.contains("uas-ilmatilavyöhyke") {
            return .aerodrome
        }
        return .restrictedArea
    }

    nonisolated static func limit(_ meters: Double?, floor: Double) -> AltitudeLimit? {
        guard let meters, meters >= floor, meters < 9_999 else { return nil }
        return AltitudeLimit(value: String(Int(meters)), unit: "m", reference: "AGL")
    }
}
