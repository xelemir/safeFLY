//
//  SwitzerlandService.swift
//  safeFLY
//
//  Switzerland drone geo-zones via FOCA/BAZL's official `ch.bazl.einschraenkungen-drohnen`
//  layer on the federal geoportal (geo.admin.ch). Rendering reuses the shared WMS GetMap
//  plumbing, but point queries go through the geo.admin.ch `identify` REST endpoint instead
//  of WMS GetFeatureInfo: the WMS server's GeoJSON GetFeatureInfo driver is broken, while
//  `identify` returns clean JSON with restriction/reason and the zone name, restriction and
//  message already localized in de/fr/it/en — so we surface the user's language directly.
//

import Foundation

struct SwitzerlandFeatureInfoRecord: ProviderRawRecord {
    let name: String?
    let restrictionID: String?
    let reasonID: String?
    let restrictionText: String?
    let message: String?
    let upperLimit: AltitudeLimit?
    let lowerLimit: AltitudeLimit?

    nonisolated var providerID: String { SwitzerlandProvider.providerID }
}

final class SwitzerlandProvider: WMSBackedProvider, @unchecked Sendable {
    nonisolated static let providerID = "switzerland"

    nonisolated let id = SwitzerlandProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("FOCA", comment: "Switzerland provider display name")
    }
    nonisolated var attributionName: String {
        "FOCA, swisstopo"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated static let layerID = "ch.bazl.einschraenkungen-drohnen"
    nonisolated static let datasetID = "airspace.restricted-zones"

    nonisolated let catalog = WMSDatasetCatalog(
        baseURL: "https://wms.geo.admin.ch/",
        definitions: [
            .make(
                id: SwitzerlandProvider.datasetID,
                title: "Restricted Zones",
                groupTitle: "Airspace",
                layerIDs: [SwitzerlandProvider.layerID]
            )
        ],
        coverageBounds: WMSDatasetCatalog.CoverageBounds(
            minLat: 45.8,
            maxLat: 47.85,
            minLon: 5.9,
            maxLon: 10.55
        ),
        coverage: CountryBoundaries.switzerland
    )

    // Unused: `query` is overridden to hit the `identify` REST endpoint, because the
    // geo.admin.ch WMS GetFeatureInfo JSON driver errors out server-side.
    nonisolated var queryInfoFormat: String { "application/json" }

    // Show this provider's map attribution only over actual Swiss territory. A bounding box
    // reached into France, Germany, Italy and Austria; the real outline keeps it to
    // Switzerland along the diagonal borders.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.switzerland }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.switzerland.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Geographical flight restrictions (FOCA)", comment: "Switzerland provider data source link title"),
                url: URL(string: "https://www.bazl.admin.ch/en/geographical-flight-restrictions")!
            )
        ]
    }

    // Queries the geo.admin.ch `identify` endpoint rather than the (broken) WMS
    // GetFeatureInfo. Coverage and layer-selection gating mirrors the shared WMS query.
    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard catalog.isWithinCoverage(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        guard
            selectedDatasetIDs.contains(SwitzerlandProvider.datasetID),
            status.status(for: SwitzerlandProvider.datasetID) != .unavailable,
            !status.isLayerBroken(SwitzerlandProvider.layerID)
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

        var components = URLComponents(string: "https://api3.geo.admin.ch/rest/services/api/MapServer/identify")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "\(request.coordinate.longitude),\(request.coordinate.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "layers", value: "all:\(SwitzerlandProvider.layerID)"),
            URLQueryItem(name: "mapExtent", value: "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            URLQueryItem(name: "imageDisplay", value: "\(request.viewportSize.width),\(request.viewportSize.height),96"),
            URLQueryItem(name: "tolerance", value: "5"),
            URLQueryItem(name: "sr", value: "4326"),
            URLQueryItem(name: "lang", value: SwitzerlandProvider.preferredLanguage)
        ]
        return components?.url
    }

    nonisolated func parseFeatureInfo(_ data: Data) -> ProviderQueryOutcome {
        struct IdentifyResponse: Decodable {
            struct Result: Decodable {
                let attributes: [String: JSONScalar]?
            }
            let results: [Result]?
        }

        do {
            let response = try JSONDecoder().decode(IdentifyResponse.self, from: data)
            guard let results = response.results, !results.isEmpty else {
                return .noMatches
            }

            let lang = SwitzerlandProvider.preferredLanguage
            let records = results.compactMap { result -> SwitzerlandFeatureInfoRecord? in
                guard let attributes = result.attributes else { return nil }
                func value(_ key: String) -> String? { attributes[key]?.stringValue }
                func localized(_ base: String) -> String? {
                    value("\(base)_\(lang)") ?? value("\(base)_en")
                }

                return SwitzerlandFeatureInfoRecord(
                    name: localized("zone_name"),
                    restrictionID: value("zone_restriction_id"),
                    reasonID: value("zone_reason_id"),
                    restrictionText: localized("zone_restriction"),
                    message: localized("zone_message"),
                    upperLimit: SwitzerlandProvider.altitudeLimit(
                        value: value("air_vol_upper_limit"),
                        reference: value("air_vol_upper_vref")
                    ),
                    lowerLimit: SwitzerlandProvider.altitudeLimit(
                        value: value("air_vol_lower_limit"),
                        reference: value("air_vol_lower_vref")
                    )
                )
            }

            if records.isEmpty {
                return .noMatches
            }

            return .matches(records: records.map { $0 as any ProviderRawRecord })
        } catch {
            return .unavailable(reason: .invalidResponse)
        }
    }

    // Surfaces a real ceiling only; empty/zero values mean "no limit" and are dropped so the
    // UI never shows a meaningless "up to 0 m".
    nonisolated private static func altitudeLimit(value: String?, reference: String?) -> AltitudeLimit? {
        guard let value, let metres = Double(value), metres > 0 else { return nil }
        return AltitudeLimit(value: String(Int(metres)), unit: "m", reference: reference ?? "AGL")
    }

    // The identify endpoint localizes zone name, restriction and message into de/fr/it/en;
    // pick the user's language, falling back to English.
    nonisolated static var preferredLanguage: String {
        let preferred = (Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en").lowercased()
        return ["de", "fr", "it", "en"].contains(preferred) ? preferred : "en"
    }
}

// Resilient single-value JSON decoder: identify attribute values are a mix of strings,
// numbers, nulls and string arrays (e.g. `auth_url_*`). We only ever read scalar fields,
// so arrays collapse to their first element and anything unreadable becomes nil.
enum JSONScalar: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONScalar])
    case null

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONScalar].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    nonisolated var stringValue: String? {
        switch self {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return values.first?.stringValue
        case .null:
            return nil
        }
    }
}

struct SwitzerlandZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let swissRecord = record as? SwitzerlandFeatureInfoRecord else {
                return nil
            }
            return normalize(swissRecord)
        }
    }

    nonisolated private func normalize(_ record: SwitzerlandFeatureInfoRecord) -> ZoneFeature {
        // Both the restriction phrase and the follow-up message arrive already localized in
        // the user's language, so they are joined into the displayed text and never tagged
        // for downstream machine translation.
        let lines = [record.restrictionText, record.message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let restriction = lines.isEmpty ? nil : lines.joined(separator: "\n")

        return ZoneFeature(
            category: SwitzerlandZoneNormalizer.determineCategory(reasonID: record.reasonID, name: record.name),
            restrictionLevel: SwitzerlandZoneNormalizer.verdict(for: record.restrictionID),
            name: record.name,
            sourceDeclaredType: nil,
            sourceDeclaredRestriction: restriction,
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: nil,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: SwitzerlandProvider.layerID),
            restrictionSourceLanguage: nil
        )
    }

    // Every Swiss zone is published as `REQ_AUTHORISATION` (an exemption can always be sought),
    // so the real severity lives in the suffix after the dot, which encodes who/what the ban
    // applies to:
    //   .MTOM_ALL  → "operation is prohibited" for every aircraft           → prohibited
    //   .MTOM_FROM → only aircraft over 250 g are prohibited                → conditional
    //   .CTR       → only over 250 g and only above 120 m AGL               → conditional
    // The weight/altitude-limited variants still leave a legal way to fly (a sub-250 g drone,
    // or below the ceiling), so they are conditional rather than an outright ban.
    nonisolated static func verdict(for restrictionID: String?) -> FlightAssessmentOutcome {
        guard let restrictionID else { return .conditional }
        let parts = restrictionID.split(separator: ".").map(String.init)

        switch parts.first {
        case "PROHIBITED":
            return .prohibited
        case "NO_RESTRICTION":
            return .allowed
        case "REQ_AUTHORISATION", "CONDITIONAL":
            // An absolute "all aircraft" ban is a full prohibition; anything carved out by
            // weight or altitude remains conditional.
            return parts.dropFirst().contains("MTOM_ALL") ? .prohibited : .conditional
        default:
            return .conditional
        }
    }

    // The dataset's `reason` enum (NATURE / SENSITIVE / AIR_TRAFFIC) gives the broad category;
    // zone-name keywords refine the sensitive ones into the more specific facility types the
    // app distinguishes.
    nonisolated static func determineCategory(reasonID: String?, name: String?) -> ZoneCategory {
        let text = (name ?? "").lowercased()

        switch reasonID {
        case "NATURE":
            return .natureReserve
        case "AIR_TRAFFIC":
            if text.contains("ctr") || text.contains("control") {
                return .controlZone
            }
            if text.contains("heli") {
                return .aerodrome
            }
            if text.contains("airport") || text.contains("flughafen") || text.contains("aéroport") || text.contains("aeroporto") {
                return .airport
            }
            return .controlZone
        case "SENSITIVE":
            if text.contains("gefängnis") || text.contains("prison") || text.contains("carcere") || text.contains("untersuchungs") {
                return .prison
            }
            if text.contains("kraftwerk") || text.contains("centrale") || text.contains("power") {
                return .powerPlant
            }
            if text.contains("spital") || text.contains("hôpital") || text.contains("ospedale") || text.contains("hospital") {
                return .hospital
            }
            if text.contains("polizei") || text.contains("police") || text.contains("polizia") {
                return .policeProperty
            }
            return .securityAuthority
        default:
            return .restrictedArea
        }
    }
}
