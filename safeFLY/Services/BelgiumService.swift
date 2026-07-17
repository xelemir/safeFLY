//
//  BelgiumService.swift
//  safeFLY
//
//  Belgium drone geo-zones via skeyes' official DroneGuide platform. The BCAA-defined UAS
//  geographical zones are published as an OGC WFS layer (`unifly:uaszone`) at
//  https://map.droneguide.be/ows, served as GeoJSON with the standard ED-269 `restriction`
//  enum — the same verdict vocabulary Austria and Luxembourg use.
//
//  Unlike the ED-269 *file* providers this is queried *live* per viewport: the full country
//  layer is ~150 MB at full resolution because it also carries global TIME_ZONE reference
//  polygons, so a bulk offline download is impractical. Instead each render/query fetches only
//  the zones intersecting the current bounding box via a CQL filter that (a) restricts to the
//  viewport and (b) drops the non-zone TIME_ZONE features by keeping only the real restriction
//  classes. Geometry decodes through the shared `GeoJSONGeometry` bridge so the offline
//  point-in-polygon and render-ring engine is reused unchanged.
//
//  NOTE: WFS 1.1.0 with `srsName=EPSG:4326` uses latitude,longitude axis order in the CQL
//  BBOX predicate (while the returned GeoJSON coordinates are the usual longitude,latitude).
//

import Foundation
import os

struct BelgiumFeatureInfoRecord: ProviderRawRecord {
    let identifier: String?
    let name: String?
    let typeCode: String?
    let restriction: String?
    let advisory: String?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?

    nonisolated var providerID: String { BelgiumProvider.providerID }
}

// One WFS feature's properties. Decoded leniently: a single odd field must not drop the whole
// zone. Note `name` and `description` arrive as JSON-*encoded strings* (e.g.
// "{\"en\":\"…\",\"fr\":\"…\"}"), not nested objects, so they are stored raw and parsed on
// demand. Altitude limits are read from the raw value+unit fields, not the pre-computed
// `*_meter_agl` fields, because those carry a garbage sentinel (137160) for upper-air volumes.
nonisolated struct BEZoneProperties: Decodable, Sendable {
    let uniqueIdentifier: String?
    let externalReference: String?
    let code: String?
    let rawName: String?
    let rawDescription: String?
    let typeCode: String?
    let restriction: String?
    let activeWithinWindow: Int?
    let lowerLimitAltitude: Double?
    let lowerLimitUnit: String?
    let lowerLimitReference: String?
    let upperLimitAltitude: Double?
    let upperLimitUnit: String?
    let upperLimitReference: String?

    private enum CodingKeys: String, CodingKey {
        case uniqueIdentifier = "unique_identifier"
        case externalReference = "external_reference"
        case code
        case rawName = "name"
        case rawDescription = "description"
        case typeCode = "type_code"
        case restriction
        case activeWithinWindow = "active_within_window"
        case lowerLimitAltitude = "lower_limit_altitude"
        case lowerLimitUnit = "lower_limit_unit"
        case lowerLimitReference = "lower_limit_reference"
        case upperLimitAltitude = "upper_limit_altitude"
        case upperLimitUnit = "upper_limit_unit"
        case upperLimitReference = "upper_limit_reference"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uniqueIdentifier = try? c.decodeIfPresent(String.self, forKey: .uniqueIdentifier)
        externalReference = try? c.decodeIfPresent(String.self, forKey: .externalReference)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        rawName = try? c.decodeIfPresent(String.self, forKey: .rawName)
        rawDescription = try? c.decodeIfPresent(String.self, forKey: .rawDescription)
        typeCode = try? c.decodeIfPresent(String.self, forKey: .typeCode)
        restriction = try? c.decodeIfPresent(String.self, forKey: .restriction)
        activeWithinWindow = try? c.decodeIfPresent(Int.self, forKey: .activeWithinWindow)
        lowerLimitAltitude = try? c.decodeIfPresent(Double.self, forKey: .lowerLimitAltitude)
        lowerLimitUnit = try? c.decodeIfPresent(String.self, forKey: .lowerLimitUnit)
        lowerLimitReference = try? c.decodeIfPresent(String.self, forKey: .lowerLimitReference)
        upperLimitAltitude = try? c.decodeIfPresent(Double.self, forKey: .upperLimitAltitude)
        upperLimitUnit = try? c.decodeIfPresent(String.self, forKey: .upperLimitUnit)
        upperLimitReference = try? c.decodeIfPresent(String.self, forKey: .upperLimitReference)
    }

    // Parses a `{"en":…,"fr":…}` language map delivered as a JSON string and returns the value
    // for the UI language (falling back to English, then any). Plain (non-JSON) text passes
    // through unchanged.
    static func localized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data), !map.isEmpty else {
            return raw
        }
        let preferred = (Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en").lowercased()
        let value = map[preferred] ?? map["en"] ?? map.values.first
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The zone's real display name (e.g. "MIL CAMP DE CASTEAU"), falling back to its code.
    var displayName: String? {
        BEZoneProperties.localized(rawName) ?? code
    }

    // The zone's advisory text, when the source provides one (e.g. "CIV UAS prohibited.
    // Activated by NOTAM …"). Already localized, so it needs no machine translation.
    var advisory: String? {
        BEZoneProperties.localized(rawDescription)
    }

    // The lower limit expressed in metres (feet / flight-levels converted), for the low-level
    // relevance test below.
    var lowerLimitMeters: Double {
        BEZoneProperties.meters(lowerLimitAltitude, lowerLimitUnit)
    }

    static func meters(_ altitude: Double?, _ unit: String?) -> Double {
        guard let altitude else { return 0 }
        switch (unit ?? "").uppercased() {
        case "F":  return altitude * 0.3048          // feet
        case "FL": return altitude * 100 * 0.3048    // flight level (hundreds of feet)
        case "M":  return altitude
        default:   return 0
        }
    }

    // Whether this zone can affect a typical open-category flight (≤120 m AGL). Transient NOTAM
    // airspace notices — and upper-air volumes (CTA/TMA/…) whose floor is above 120 m — are
    // excluded: rendering them filled the whole map with overlapping washes and they do not
    // reflect a real low-level drone restriction. The DroneGuide portal filters these the same
    // way (by the pilot's operating altitude / an active-time window we cannot replicate here).
    var affectsLowLevelFlight: Bool {
        if (typeCode ?? "").uppercased() == "NOTAM" { return false }
        return lowerLimitMeters <= 120
    }
}

final class BelgiumProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "belgium"
    nonisolated static let datasetID = "airspace.restricted-zones"

    nonisolated let id = BelgiumProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("skeyes", comment: "Belgium provider display name")
    }
    nonisolated var attributionName: String { "skeyes / BCAA" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    // Only the real restriction classes; this also excludes the global TIME_ZONE reference
    // polygons the same layer carries (they have a null restriction). Transient NOTAM notices —
    // large upper-air polygons that otherwise flood the map — are dropped server-side too; the
    // remaining upper-air volumes are filtered by altitude client-side (see `affectsLowLevelFlight`).
    // `active_within_window = 0` keeps only the permanently/currently active zones, matching the
    // DroneGuide portal's default: it hides the NOTAM- and schedule-activated zones (e.g. the
    // large "EBR78 — international summits" area over Brussels) that are not in force right now.
    nonisolated private static let restrictionClause =
        "restriction IN ('PROHIBITED','REQ_AUTHORISATION','CONDITIONAL') AND type_code <> 'NOTAM' AND active_within_window = 0"
    nonisolated private static let wfsBaseURL = "https://map.droneguide.be/ows"

    // Last successful render fetch, reused if a subsequent fetch fails, so a transient network
    // error while panning does not blank every drawn zone until the next good response. Held in
    // an async-safe lock so it can be touched from the provider's nonisolated fetch path.
    private let renderCache = OSAllocatedUnfairLock<[GeoJSONFeature<BEZoneProperties>]>(initialState: [])

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: BelgiumProvider.datasetID,
                presentation: localizedProviderPresentation(title: "Restricted Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution and run queries only over real Belgian territory: it shares diagonal
    // borders with the Netherlands, Germany, Luxembourg and France that a bounding box would
    // spill into.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.belgium }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.belgium.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: "skeyes",
                url: URL(string: "https://www.skeyes.be/")!
            ),
            // The map's own <title> is also just "Skeyes", which would give two identically
            // labelled rows, so it takes the name it is branded and universally known by.
            ProviderReferenceLink(
                title: "DroneGuide",
                url: URL(string: "https://map.droneguide.be/")!
            )
        ]
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        // A cheap capabilities probe: the layer is up if GetCapabilities responds.
        let status: ProviderAvailabilityStatus
        if let url = URL(string: "\(Self.wfsBaseURL)?service=WFS&version=1.1.0&request=GetCapabilities"),
           let (_, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            status = .available
        } else {
            status = .unavailable
        }
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [BelgiumProvider.datasetID: status],
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard selectedDatasetIDs.contains(BelgiumProvider.datasetID),
              status.status(for: BelgiumProvider.datasetID) != .unavailable else { return [] }

        // On a transient fetch failure keep the last good set instead of blanking every zone.
        let features: [GeoJSONFeature<BEZoneProperties>]
        if let fetched = await fetchZones(in: request.region) {
            features = fetched
            renderCache.withLock { $0 = fetched }
        } else {
            features = renderCache.withLock { $0 }
        }

        var payloads: [ProviderRenderPayload] = []

        for feature in features where feature.properties.affectsLowLevelFlight {
            let verdict = BelgiumZoneNormalizer.verdict(for: feature.properties.restriction)
            guard let style = ED269RenderStyle.forVerdict(verdict) else { continue }

            for ring in feature.ed269Geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(id).\(feature.properties.uniqueIdentifier ?? feature.properties.code ?? "zone").\(payloads.count)",
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
        guard CountryBoundaries.belgium.contains(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }
        guard selectedDatasetIDs.contains(BelgiumProvider.datasetID),
              status.status(for: BelgiumProvider.datasetID) != .unavailable else {
            return .unavailable(reason: .providerNoData)
        }

        // Fetch the small neighbourhood around the tap, then run the exact point-in-polygon
        // test locally — WFS BBOX alone would also return zones that merely overlap the box.
        let coordinate = request.coordinate
        let pad = 0.02
        let region = MapRegion(center: coordinate, latitudeDelta: pad, longitudeDelta: pad)
        guard let fetched = await fetchZones(in: region) else {
            return .unavailable(reason: .requestFailed(details: nil))
        }
        let matches = fetched
            .filter { $0.properties.affectsLowLevelFlight && $0.ed269Geometry.contains(coordinate) }
            .map { feature -> BelgiumFeatureInfoRecord in
                let limits = BelgiumZoneNormalizer.altitudeLimits(for: feature.properties)
                return BelgiumFeatureInfoRecord(
                    identifier: feature.properties.externalReference ?? feature.properties.code,
                    name: feature.properties.displayName,
                    typeCode: feature.properties.typeCode,
                    restriction: feature.properties.restriction,
                    advisory: feature.properties.advisory,
                    lowerLimit: limits.lower,
                    upperLimit: limits.upper
                )
            }

        return matches.isEmpty ? .noMatches : .matches(records: matches.map { $0 as any ProviderRawRecord })
    }

    // Fetches the zones intersecting `region` as GeoJSON, or nil if the request/decode failed
    // (so callers can distinguish "no zones here" from "couldn't reach the service"). The CQL
    // BBOX is in latitude,longitude order (WFS 1.1.0 + EPSG:4326 axis order); the returned
    // coordinates are longitude,latitude.
    nonisolated private func fetchZones(in region: MapRegion) async -> [GeoJSONFeature<BEZoneProperties>]? {
        let minLat = region.center.latitude - region.latitudeDelta / 2
        let maxLat = region.center.latitude + region.latitudeDelta / 2
        let minLon = region.center.longitude - region.longitudeDelta / 2
        let maxLon = region.center.longitude + region.longitudeDelta / 2

        let cql = "BBOX(geom,\(minLat),\(minLon),\(maxLat),\(maxLon)) AND \(Self.restrictionClause)"
        var components = URLComponents(string: Self.wfsBaseURL)
        components?.queryItems = [
            URLQueryItem(name: "service", value: "WFS"),
            URLQueryItem(name: "version", value: "1.1.0"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "typeName", value: "unifly:uaszone"),
            URLQueryItem(name: "outputFormat", value: "application/json"),
            URLQueryItem(name: "srsName", value: "EPSG:4326"),
            URLQueryItem(name: "cql_filter", value: cql)
        ]

        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let collection = try? JSONDecoder().decode(GeoJSONFeatureCollection<BEZoneProperties>.self, from: data) else {
            return nil
        }
        return collection.features
    }
}

struct BelgiumZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let be = record as? BelgiumFeatureInfoRecord else { return nil }
            let verdict = BelgiumZoneNormalizer.verdict(for: be.restriction)
            // Prefer the source's own advisory text; otherwise a concise, localized note derived
            // from the restriction so every zone carries some guidance.
            let advisory = be.advisory ?? BelgiumZoneNormalizer.fallbackNote(for: verdict)
            return ZoneFeature(
                category: BelgiumZoneNormalizer.determineCategory(typeCode: be.typeCode),
                restrictionLevel: verdict,
                name: be.name,
                sourceDeclaredType: be.typeCode,
                sourceDeclaredRestriction: advisory,
                lowerLimit: be.lowerLimit,
                upperLimit: be.upperLimit,
                legalReference: nil,
                source: SourceProvenance(providerID: be.providerID, sourceLayerID: BelgiumProvider.providerID),
                // The advisory is already in the user's language (source multi-language map or
                // our own localized fallback), so it must not be machine-translated.
                restrictionSourceLanguage: nil
            )
        }
    }

    // Short, localized guidance used when a zone ships no advisory text of its own.
    nonisolated static func fallbackNote(for verdict: FlightAssessmentOutcome) -> String {
        switch verdict {
        case .prohibited:
            return NSLocalizedString("BE.NOTE.PROHIBITED", comment: "Belgium fallback advisory: prohibited")
        case .conditional:
            return NSLocalizedString("BE.NOTE.AUTHORISATION", comment: "Belgium fallback advisory: authorisation required")
        case .allowed:
            return NSLocalizedString("BE.NOTE.ALLOWED", comment: "Belgium fallback advisory: no specific restriction")
        }
    }

    // Standard ED-269 restriction enum → flight verdict (same mapping as Austria/Luxembourg).
    nonisolated static func verdict(for restriction: String?) -> FlightAssessmentOutcome {
        switch restriction {
        case "PROHIBITED":
            return .prohibited
        case "NO_RESTRICTION":
            return .allowed
        case "REQ_AUTHORISATION", "CONDITIONAL":
            return .conditional
        default:
            return .conditional
        }
    }

    // Altitude limits from the raw value+unit fields. A lower limit of 0 means "from the
    // surface" and is not shown; an upper limit is surfaced when it is a real, non-sentinel
    // ceiling. Units are normalised to the aviation abbreviations the UI expects.
    nonisolated static func altitudeLimits(for props: BEZoneProperties) -> (upper: AltitudeLimit?, lower: AltitudeLimit?) {
        let lower = limit(props.lowerLimitAltitude, props.lowerLimitUnit, props.lowerLimitReference, minMeters: 0.5)
        let upper = limit(props.upperLimitAltitude, props.upperLimitUnit, props.upperLimitReference, minMeters: 0.5)
        return (upper, lower)
    }

    nonisolated private static func limit(_ altitude: Double?, _ unit: String?, _ reference: String?, minMeters: Double) -> AltitudeLimit? {
        guard let altitude else { return nil }
        let meters = BEZoneProperties.meters(altitude, unit)
        // Skip the surface (0) and the "no ceiling" sentinel upper-air values.
        guard meters >= minMeters, meters < 100_000 else { return nil }

        let normalizedUnit: String
        switch (unit ?? "").uppercased() {
        case "F":  normalizedUnit = "ft"
        case "FL": normalizedUnit = "FL"
        case "M":  normalizedUnit = "m"
        default:   normalizedUnit = unit ?? ""
        }
        return AltitudeLimit(value: String(Int(altitude)), unit: normalizedUnit, reference: reference)
    }

    // skeyes `type_code` → zone category. Prefixes: CIV_/MIL_ for civil/military facilities.
    nonisolated static func determineCategory(typeCode: String?) -> ZoneCategory {
        let code = (typeCode ?? "").uppercased()

        if code.contains("NOTAM") || code.contains("NO-FLY") || code.contains("GEOFENCE") {
            return .temporaryRestrictionActive
        }
        if code.contains("HELISTRIP") || code == "HTA" {
            return .aerodrome
        }
        if code.contains("MODEL_TERRAIN") {
            return .modelFlyingField
        }
        if code.contains("PRISON") {
            return .prison
        }
        if code.contains("PORT") || code.contains("TEST_FACILITY") {
            return .industrialInstallation
        }
        if code.contains("FANC") {
            // FANC = Federal Agency for Nuclear Control sites.
            return .powerPlant
        }
        if code.contains("ROYAL") {
            return .securityAuthority
        }
        if code.hasPrefix("MIL") {
            return .militaryInstallation
        }
        if code.contains("CTR") || code.contains("CTA") || code.contains("TMA") ||
            code.contains("RMZ") || code.contains("CONTROL_ZONE") || code.contains("CROSSBORDER") {
            return .controlZone
        }
        if code.contains("AF_UNCONTROLLED") {
            return .aerodrome
        }
        // LFA (low-flying areas), R (restricted), and anything else stay generic.
        return .restrictedArea
    }
}
