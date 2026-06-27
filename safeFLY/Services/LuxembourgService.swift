//
//  LuxembourgService.swift
//  safeFLY
//

//  Luxembourg drone geo-zones via the DAC's official ED-269 feed at
//  https://drones.geoportail.lu/zones. The payload is the same ED-269 shape the app already
//  parses: a Netherlands-style {title, description, features} envelope whose features carry
//  the standard ED-269 `restriction` enum (like Austria) and `ED269Geometry`.
//

import Foundation

nonisolated struct LUXDroneZoneFile: Codable, Sendable {
    let title: String
    let description: String?
    let features: [LUXZoneFeature]
}

nonisolated struct LUXZoneAuthority: Codable, Sendable {
    let name: String?
}

nonisolated struct LUXZoneFeature: Codable, Sendable {
    let identifier: String?
    let country: String?
    let name: String?
    let type: String?
    let restriction: String?
    let reason: [String]?
    let message: String?
    let zoneAuthority: [LUXZoneAuthority]?
    let geometry: [ED269Geometry]

    var stableID: String { identifier ?? name ?? UUID().uuidString }
    var boundingBox: BoundingBox? { geometry.boundingBox }
    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

struct LuxembourgFeatureInfoRecord: ProviderRawRecord {
    let identifier: String?
    let name: String?
    let zoneType: String?
    let restriction: String?
    let reason: [String]?
    let message: String?
    let upperLimit: AltitudeLimit?
    let lowerLimit: AltitudeLimit?
    let authorityName: String?

    nonisolated var providerID: String { LuxembourgProvider.providerID }
}

final class LuxembourgProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "luxembourg"

    nonisolated let id = LuxembourgProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("DAC (Luxembourg)", comment: "Luxembourg provider display name")
    }
    nonisolated var attributionName: String {
        "DAC Luxembourg"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    private let store = DownloadableFileStore(
        fileName: "lux_uas_zones_v2.json",
        remoteURL: URL(string: "https://drones.geoportail.lu/zones")!
    )

    nonisolated private static let datasetID = "airspace.restricted-zones"

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: LuxembourgProvider.datasetID,
                presentation: localizedProviderPresentation(title: "Restricted Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution only over Luxembourg: it shares borders with Belgium, France and
    // Germany that a bounding box would spill into.
    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.luxembourg.contains(region.center)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("UAS Geographical Zones (DAC)", comment: "Luxembourg provider data source link title"),
                url: URL(string: "https://dac.gouvernement.lu/en/drones/geozones.html")!
            )
        ]
    }

    nonisolated var downloadURL: URL? {
        store.remoteURL
    }

    nonisolated var isDataDownloaded: Bool {
        store.isDownloaded
    }

    nonisolated var datasetLastUpdated: Date? {
        store.modificationDate
    }

    @MainActor private var _parsedFeatures: [LUXZoneFeature] = []

    @MainActor var parsedFeatures: [LUXZoneFeature] {
        _parsedFeatures
    }

    init() {
        Task {
            try? await reloadData()
        }
    }

    @MainActor func reloadData() async throws {
        guard store.isDownloaded else { return }
        _parsedFeatures = try Self.parse(store.read())
    }

    nonisolated private static func parse(_ data: Data) throws -> [LUXZoneFeature] {
        try JSONDecoder().decode(LUXDroneZoneFile.self, from: ed269StrippedJSONData(data)).features
    }

    nonisolated func downloadData() async throws {
        // Validate by fully parsing before the payload may replace the local copy, so a
        // malformed response never overwrites a previously good dataset.
        _ = try await store.download { data in
            _ = try Self.parse(data)
        }
        try await reloadData()
    }

    nonisolated func deleteData() {
        store.delete()
        Task { @MainActor in
            self._parsedFeatures = []
        }
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = store.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [LuxembourgProvider.datasetID: status],
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard store.isDownloaded, selectedDatasetIDs.contains(LuxembourgProvider.datasetID) else { return [] }

        let features = await parsedFeatures
        var payloads: [ProviderRenderPayload] = []

        for feature in features {
            let verdict = LuxembourgZoneNormalizer.verdict(for: feature.restriction)
            guard let style = LuxembourgProvider.style(for: verdict) else { continue }

            if let bbox = feature.boundingBox, !bbox.intersects(request.region) {
                continue
            }

            for ring in feature.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(feature.stableID).\(payloads.count)",
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
        guard store.isDownloaded, selectedDatasetIDs.contains(LuxembourgProvider.datasetID) else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await parsedFeatures
            .filter { feature in
                if let bbox = feature.boundingBox, !bbox.contains(coordinate) {
                    return false
                }
                return feature.contains(coordinate)
            }
            .map { feature -> LuxembourgFeatureInfoRecord in
                let limits = LuxembourgProvider.altitudeLimits(for: feature)
                return LuxembourgFeatureInfoRecord(
                    identifier: feature.identifier,
                    name: feature.name,
                    zoneType: feature.type,
                    restriction: feature.restriction,
                    reason: feature.reason,
                    message: feature.message,
                    upperLimit: limits.upper,
                    lowerLimit: limits.lower,
                    authorityName: feature.zoneAuthority?.first?.name
                )
            }

        if matches.isEmpty {
            return .noMatches
        }

        return .matches(records: matches.map { $0 as any ProviderRawRecord })
    }

    private struct RenderStyle {
        let fillColor: String
        let fillOpacity: Double
        let strokeColor: String
        let strokeOpacity: Double
        let lineWidth: Double
    }

    nonisolated private static func style(for verdict: FlightAssessmentOutcome) -> RenderStyle? {
        switch verdict {
        case .prohibited:
            return RenderStyle(fillColor: "EF4444", fillOpacity: 0.25, strokeColor: "EF4444", strokeOpacity: 0.8, lineWidth: 2.0)
        case .conditional:
            return RenderStyle(fillColor: "F59E0B", fillOpacity: 0.25, strokeColor: "D97706", strokeOpacity: 0.8, lineWidth: 1.5)
        case .allowed:
            return nil
        }
    }

    // ED-269 uses 99999 m as a sentinel for "no ceiling"; surface only real limits.
    nonisolated private static func altitudeLimits(for feature: LUXZoneFeature) -> (upper: AltitudeLimit?, lower: AltitudeLimit?) {
        guard let geometry = feature.geometry.first else { return (nil, nil) }

        let upper: AltitudeLimit?
        if let value = geometry.upperLimit, value > 0, value < 99_999 {
            upper = AltitudeLimit(value: String(Int(value)), unit: "m", reference: geometry.upperVerticalReference ?? "AGL")
        } else {
            upper = nil
        }

        let lower: AltitudeLimit?
        if let value = geometry.lowerLimit, value > 0 {
            lower = AltitudeLimit(value: String(Int(value)), unit: "m", reference: geometry.lowerVerticalReference ?? "AGL")
        } else {
            lower = nil
        }

        return (upper, lower)
    }
}

struct LuxembourgZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let luxRecord = record as? LuxembourgFeatureInfoRecord else {
                return nil
            }
            return normalize(luxRecord)
        }
    }

    nonisolated private func normalize(_ record: LuxembourgFeatureInfoRecord) -> ZoneFeature {
        let category = LuxembourgZoneNormalizer.determineCategory(
            reason: record.reason,
            name: record.name,
            identifier: record.identifier,
            authorityName: record.authorityName
        )
        let restriction = LuxembourgZoneNormalizer.verdict(for: record.restriction)

        let rawMessage = record.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGenericMessage = rawMessage?.contains("g-o.lu/uas") == true
        let message = hasGenericMessage ? nil : rawMessage

        let fallbackMessageKey: String?
        if message == nil {
            fallbackMessageKey = LuxembourgZoneNormalizer.fallbackMessageKey(for: category, restriction: restriction, authorityName: record.authorityName)
        } else {
            fallbackMessageKey = nil
        }

        let displayedRestriction = fallbackMessageKey != nil ? NSLocalizedString(fallbackMessageKey!, comment: "Luxembourg fallback message") : message

        return ZoneFeature(
            category: category,
            restrictionLevel: restriction,
            // The feed's `name` is an opaque code (e.g. "EL-UAS-S12"), so the operating
            // authority is shown as the user-facing title instead and the code is relegated
            // to the detail fields below.
            name: record.authorityName ?? record.name,
            sourceDeclaredType: record.name,
            sourceDeclaredRestriction: (displayedRestriction?.isEmpty == false) ? displayedRestriction : nil,
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: nil,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: LuxembourgProvider.providerID),
            restrictionSourceLanguage: fallbackMessageKey == nil && message != nil ? "en" : nil
        )
    }

    nonisolated static func fallbackMessageKey(
        for category: ZoneCategory,
        restriction: FlightAssessmentOutcome,
        authorityName: String?
    ) -> String {
        let auth = (authorityName ?? "").lowercased()
        switch category {
        case .airport:
            return restriction == .prohibited ? "LUX.NOTE.AIRPORT_PROHIBITED" : "LUX.NOTE.AIRPORT_CONDITIONAL"
        case .controlZone:
            return "CONTROL_ZONE_CLEARANCE"
        case .aerodrome:
            return "AERODROME_CONDITIONAL"
        case .militaryInstallation:
            return "LUX.NOTE.MILITARY_REQ_AUTHORISATION"
        case .hospital:
            return "LUX.NOTE.HOSPITAL_HELIPAD"
        case .recreationalArea:
            return "LUX.NOTE.STADIUM_PROHIBITED"
        case .policeProperty:
            return "LUX.NOTE.POLICE_REQ_AUTHORISATION"
        case .securityAuthority:
            if auth.contains("police") {
                return "LUX.NOTE.POLICE_REQ_AUTHORISATION"
            } else if auth.contains("armée") {
                return "LUX.NOTE.MILITARY_REQ_AUTHORISATION"
            } else {
                return "LUX.NOTE.SENSITIVE_REQ_AUTHORISATION"
            }
        default:
            return "RESTRICTED_ZONE_CHECK"
        }
    }

    // Standard ED-269 restriction enum → flight verdict.
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

    // The feed gives zones only an opaque code as a name (e.g. "EL-UAS-S12") and a single
    // `type` of "COMMON", so a specific facility type cannot be read from them. The two
    // reliable signals are the operating authority's name and the identifier prefix; anything
    // not covered by those is surfaced as a generic restricted area rather than guessing a
    // specific kind of site (which previously mislabelled e.g. a castle as a "security
    // authority" or a stadium as a recreational area).
    nonisolated static func determineCategory(
        reason: [String]?,
        name: String?,
        identifier: String?,
        authorityName: String?
    ) -> ZoneCategory {
        let reasons = Set(reason ?? [])
        let auth = (authorityName ?? "").lowercased()
        let id = (identifier ?? "").uppercased()

        // Authority name is the most reliable signal for the sensitive zones.
        if auth.contains("hôpital") || auth.contains("hopital") || auth.contains("hospital") || auth.contains("schuman") {
            return .hospital
        }
        if auth.contains("police") {
            return .policeProperty
        }
        if auth.contains("armée") || auth.contains("armee") || auth.contains("nato") || auth.contains("otan") {
            return .militaryInstallation
        }

        // Otherwise the identifier prefix encodes the kind of zone: AIRPO = airport core
        // (A2/A3), A1 = its approach/control zone, HELIS = a helipad.
        if id.hasPrefix("AIRPO") {
            return .airport
        }
        if id.hasPrefix("A1") {
            return .controlZone
        }
        if id.hasPrefix("HELIS") {
            return .aerodrome
        }
        if reasons.contains("NATURE") {
            return .natureReserve
        }
        if reasons.contains("AIR_TRAFFIC") {
            return .controlZone
        }
        // SENSITIVE / POPULATION / TSA zones carry no facility detail, so they stay generic.
        return .restrictedArea
    }
}
