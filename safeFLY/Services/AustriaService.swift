//
//  AustriaService.swift
//  safeFLY
//
//  Austria drone geo-zones via Austro Control's official ED-269 dataset. Same offline
//  geometry engine as the Netherlands provider; the differences are the top-level envelope
//  (a bare array of zones), the standard ED-269 `restriction` enum, and the per-zone
//  localized messages the dataset already ships (de-AT + en), which we surface directly.
//

import Foundation

struct ATZone: Codable, Sendable {
    let zoneId: String?
    let identifier: String?
    let country: String?
    let name: String?
    let type: String?
    let restriction: String?
    let reason: [String]?
    let message: String?
    let extendedProperties: ATExtendedProperties?
    let geometry: [ED269Geometry]

    var stableID: String { zoneId ?? identifier ?? name ?? UUID().uuidString }
    var boundingBox: BoundingBox? { geometry.boundingBox }
    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

struct ATExtendedProperties: Codable, Sendable {
    let legalBasis: String?
    let legalBasisURL: String?
    let localizedMessages: [ATLocalizedMessage]?
}

struct ATLocalizedMessage: Codable, Sendable {
    let language: String?
    let message: String?
}

struct AustriaFeatureInfoRecord: ProviderRawRecord {
    let name: String?
    let zoneType: String?
    let restriction: String?
    let reason: [String]?
    let localizedMessage: String?
    let legalReference: String?
    let upperLimit: AltitudeLimit?
    let lowerLimit: AltitudeLimit?

    nonisolated var providerID: String { AustriaProvider.providerID }
}

final class AustriaProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "austria"

    nonisolated let id = AustriaProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("Austro Control (Austria)", comment: "Austria provider display name")
    }
    nonisolated var attributionName: String {
        "Austro Control"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    private let store = DownloadableFileStore(
        fileName: "aut_uas_zones.json",
        remoteURL: URL(string: "https://gruettecloud.com/safefly/download-json?country=AT")!
    )

    private static let datasetID = "airspace.restricted-zones"

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: AustriaProvider.datasetID,
                presentation: localizedProviderPresentation(title: "Restricted Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution only over real Austrian territory: it shares diagonal borders with
    // Germany, Czechia, Slovakia, Hungary, Slovenia, Italy and Switzerland that a bounding
    // box would spill into.
    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.austria.contains(region.center)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Austro Control Dronespace", comment: "Austria provider data source link title"),
                url: URL(string: "https://www.dronespace.at/geo_zonen/allgemeine_informationen")!
            )
        ]
    }

    nonisolated var downloadURL: URL? {
        store.remoteURL
    }

    nonisolated var isDataDownloaded: Bool {
        store.isDownloaded
    }

    @MainActor private var _parsedZones: [ATZone] = []

    @MainActor var parsedZones: [ATZone] {
        _parsedZones
    }

    init() {
        Task {
            try? await reloadData()
        }
    }

    @MainActor func reloadData() async throws {
        guard store.isDownloaded else { return }
        _parsedZones = try Self.parse(store.read())
    }

    nonisolated private static func parse(_ data: Data) throws -> [ATZone] {
        try JSONDecoder().decode([ATZone].self, from: ed269StrippedJSONData(data))
    }

    nonisolated func downloadData() async throws {
        _ = try await store.download { data in
            _ = try Self.parse(data)
        }
        try await reloadData()
    }

    nonisolated func deleteData() {
        store.delete()
        Task { @MainActor in
            self._parsedZones = []
        }
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = store.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [AustriaProvider.datasetID: status],
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard store.isDownloaded, selectedDatasetIDs.contains(AustriaProvider.datasetID) else { return [] }

        let zones = await parsedZones
        var payloads: [ProviderRenderPayload] = []

        for zone in zones {
            let verdict = AustriaZoneNormalizer.verdict(for: zone.restriction, name: zone.name, message: zone.message)
            // Unrestricted zones carry no flight limitation, so drawing them as coloured
            // overlays would only clutter the map; they remain available to point queries.
            guard let style = AustriaProvider.style(for: verdict) else { continue }

            if let bbox = zone.boundingBox, !bbox.intersects(request.region) {
                continue
            }

            for ring in zone.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(zone.stableID).\(payloads.count)",
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
        guard store.isDownloaded, selectedDatasetIDs.contains(AustriaProvider.datasetID) else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await parsedZones
            .filter { zone in
                if let bbox = zone.boundingBox, !bbox.contains(coordinate) {
                    return false
                }
                return zone.contains(coordinate)
            }
            .map { zone -> AustriaFeatureInfoRecord in
                let limits = AustriaProvider.altitudeLimits(for: zone)
                return AustriaFeatureInfoRecord(
                    name: zone.name,
                    zoneType: zone.type,
                    restriction: zone.restriction,
                    reason: zone.reason,
                    localizedMessage: AustriaZoneNormalizer.localizedMessage(for: zone),
                    legalReference: zone.extendedProperties?.legalBasis,
                    upperLimit: limits.upper,
                    lowerLimit: limits.lower
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

    // ED-269 uses 99999 m AGL as a sentinel for "no ceiling"; surface only real ceilings.
    nonisolated private static func altitudeLimits(for zone: ATZone) -> (upper: AltitudeLimit?, lower: AltitudeLimit?) {
        guard let geometry = zone.geometry.first else { return (nil, nil) }

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

struct AustriaZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let austriaRecord = record as? AustriaFeatureInfoRecord else {
                return nil
            }
            return normalize(austriaRecord)
        }
    }

    nonisolated private func normalize(_ record: AustriaFeatureInfoRecord) -> ZoneFeature {
        ZoneFeature(
            category: AustriaZoneNormalizer.determineCategory(reason: record.reason, name: record.name, message: record.localizedMessage),
            restrictionLevel: AustriaZoneNormalizer.verdict(for: record.restriction, name: record.name, message: record.localizedMessage),
            name: record.name,
            sourceDeclaredType: record.zoneType,
            sourceDeclaredRestriction: record.localizedMessage,
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: record.legalReference,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: AustriaProvider.providerID),
            // The dataset ships an English/German message, so it is already in one of the
            // app's languages and must not be machine-translated.
            restrictionSourceLanguage: nil
        )
    }

    // Standard ED-269 restriction enum → flight verdict, with one deliberate exception:
    // military danger areas are published as NO_RESTRICTION (unrestricted by default, but
    // hazardous and activated by NOTAM). Treating them as a caution keeps them visible with
    // their "fly at own risk / NOTAM" note instead of being silently hidden like the other
    // unrestricted zones (model-flying areas).
    nonisolated static func verdict(for restriction: String?, name: String?, message: String?) -> FlightAssessmentOutcome {
        if restriction == "NO_RESTRICTION", isMilitaryDangerArea(name: name, message: message) {
            return .conditional
        }

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

    // Austrian military danger areas use ICAO-style "LO D …" identifiers and a "Danger Area /
    // fly at own risk" advisory; both signals are checked so the match survives either UI
    // language.
    nonisolated static func isMilitaryDangerArea(name: String?, message: String?) -> Bool {
        if (name ?? "").uppercased().hasPrefix("LO D") {
            return true
        }
        let text = (message ?? "").lowercased()
        return text.contains("danger area") || text.contains("gefahrengebiet")
    }

    // Picks the message in the user's language, falling back to English, then any message.
    nonisolated static func localizedMessage(for zone: ATZone) -> String? {
        let messages = zone.extendedProperties?.localizedMessages ?? []
        let preferred = (Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en").lowercased()

        if let match = messages.first(where: { ($0.language ?? "").lowercased().hasPrefix(preferred) })?.message {
            return match
        }
        if let english = messages.first(where: { ($0.language ?? "").lowercased().hasPrefix("en") })?.message {
            return english
        }
        return messages.first?.message ?? zone.message
    }

    nonisolated static func determineCategory(reason: [String]?, name: String?, message: String?) -> ZoneCategory {
        let reasons = Set(reason ?? [])
        let text = "\(name ?? "") \(message ?? "")".lowercased()

        // Military danger areas would otherwise be mis-read as control zones via their
        // AIR_TRAFFIC reason.
        if isMilitaryDangerArea(name: name, message: message) {
            return .militaryInstallation
        }
        if reasons.contains("NATURE") || text.contains("natur") {
            return .natureReserve
        }
        if reasons.contains("SENSITIVE") {
            return .securityAuthority
        }
        if text.contains("flughafen") || text.contains("airport") {
            return .airport
        }
        if text.contains("kontrollzone") || text.contains("ctr") || text.contains("control zone") {
            return .controlZone
        }
        if text.contains("flugplatz") || text.contains("airfield") || text.contains("hubschrauber") || text.contains("heliport") {
            return .aerodrome
        }
        if reasons.contains("AIR_TRAFFIC") {
            return .controlZone
        }
        return .restrictedArea
    }
}
