//
//  SwedenService.swift
//  safeFLY
//
//  Sweden drone geo-zones from LFV's official Drönarkartan data, downloaded as one offline
//  package from the gruettecloud proxy (`?country=SE`) — same lifecycle as the other offline
//  countries (Netherlands, Austria, Finland), including the silent daily background refresh.
//
//  The proxy merges seven upstream LFV/Transportstyrelsen sources into a single bundle
//  (see gruettecloud-se-fi-proxy.md):
//    - `uasZones`: the Transportstyrelsen UAS geographical zones as the ED-318 JSON file
//      behind dronechart.lfv.se (hydro plants, prisons, royal palaces, …)
//    - `layers`: full-country GeoJSON dumps of the drone chart's airspace layers from LFV's
//      GeoServer — 5 km airport zones (RWY5K), 1 km heliport zones (HKP1K), AIP restricted
//      areas incl. every national park (RSTA), danger areas (DNGA) and the CTR/TIZ control
//      zones with their 50 m low-level allowance.
//
//  Everything is parsed into one flat zone list at download time (verdict, category and
//  advisory resolved up front), so rendering and point queries run fully offline through the
//  shared ED-269 geometry engine.
//

import Foundation

struct SwedenFeatureInfoRecord: ProviderRawRecord {
    let layerID: String
    let identifier: String?
    let name: String?
    let sourceType: String?
    let advisory: String?          // Source's own text (ED-318 message / AIP comment), if any.
    let advisoryLanguage: String?  // Language of that text ("en"/"sv"); nil when localized.
    let verdict: FlightAssessmentOutcome
    let category: ZoneCategory
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?

    nonisolated var providerID: String { SwedenProvider.providerID }
}

// One zone from the merged package, regardless of which upstream layer it came from. All
// regulatory interpretation happens at parse time so the render/query paths stay trivial.
nonisolated struct SEZone: Sendable {
    let layerID: String
    let datasetID: String
    let identifier: String?
    let name: String?
    let sourceType: String?
    let advisory: String?
    let advisoryLanguage: String?
    let verdict: FlightAssessmentOutcome
    let category: ZoneCategory
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let geometry: [ED269Geometry]
    let boundingBox: BoundingBox?

    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

// One zone of the bundle's ED-318 part. The geometry is GeoJSON-flavoured: a Point with a
// Circle extent, or a Polygon — both bridge into the shared `[ED269Geometry]` engine.
nonisolated struct SEUASZone: Decodable, Sendable {
    let identifier: String?
    let type: String?              // REQ_AUTHORIZATION / CONDITIONAL / NO_RESTRICTION
    let reason: [String]?
    let name: String?              // Best-language pick from the source's language list.
    let message: String?           // Ditto; the official English/Swedish advisory.
    let geometry: [ED269Geometry]

    private struct LangText: Decodable {
        let text: String?
        let lang: String?
    }

    private struct Geometry: Decodable {
        let type: String?
        // Point: [lon, lat]; Polygon: rings of [lon, lat].
        let pointCoordinates: [Double]?
        let polygonCoordinates: [[[Double]]]?
        let extent: Extent?
        let layer: Layer?

        struct Extent: Decodable {
            let subType: String?
            let radius: Double?
        }

        struct Layer: Decodable {
            let upper: Double?
            let lower: Double?
        }

        private enum CodingKeys: String, CodingKey { case type, coordinates, extent, layer }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            extent = try? c.decodeIfPresent(Extent.self, forKey: .extent)
            layer = try? c.decodeIfPresent(Layer.self, forKey: .layer)
            pointCoordinates = try? c.decodeIfPresent([Double].self, forKey: .coordinates)
            polygonCoordinates = try? c.decodeIfPresent([[[Double]]].self, forKey: .coordinates)
        }
    }

    private struct Properties: Decodable {
        let identifier: String?
        let type: String?
        let reason: [String]?
        let name: [LangText]?
        let message: [LangText]?
    }

    private enum CodingKeys: String, CodingKey { case geometry, properties }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let props = try c.decode(Properties.self, forKey: .properties)
        identifier = props.identifier
        type = props.type
        reason = props.reason
        name = SEUASZone.preferredText(props.name)
        message = SEUASZone.preferredText(props.message)

        let g = try c.decode(Geometry.self, forKey: .geometry)
        let vertical = (upper: g.layer?.upper, lower: g.layer?.lower)
        if g.type == "Point", let center = g.pointCoordinates, center.count >= 2,
           let radius = g.extent?.radius {
            geometry = [ED269Geometry(
                upperLimit: vertical.upper,
                lowerLimit: vertical.lower,
                uomDimensions: "M",
                upperVerticalReference: "AGL",
                lowerVerticalReference: "AGL",
                horizontalProjection: ED269HorizontalProjection(
                    type: "Circle", center: center, radius: radius, coordinates: nil
                )
            )]
        } else if g.type == "Polygon", let rings = g.polygonCoordinates, !rings.isEmpty {
            geometry = [ED269Geometry(
                upperLimit: vertical.upper,
                lowerLimit: vertical.lower,
                uomDimensions: "M",
                upperVerticalReference: "AGL",
                lowerVerticalReference: "AGL",
                horizontalProjection: ED269HorizontalProjection(
                    type: "Polygon", center: nil, radius: nil, coordinates: rings
                )
            )]
        } else {
            geometry = []
        }
    }

    // Picks the entry matching the UI language, then English, then whatever is first. The file
    // ships "en-GB" and "se-SE" variants.
    private static func preferredText(_ entries: [LangText]?) -> String? {
        guard let entries, !entries.isEmpty else { return nil }
        let preferred = (Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en").lowercased()
        let pick = entries.first { ($0.lang ?? "").lowercased().hasPrefix(preferred) }
            ?? entries.first { ($0.lang ?? "").lowercased().hasPrefix("en") }
            ?? entries.first
        return pick?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// One WFS feature's properties. The DAIM_TOPO airport layers and the mais AIP layers use
// different column names, so everything is optional and read through helpers.
nonisolated struct SEWFSProperties: Decodable, Sendable {
    let TYPEOFAREA: String?
    let NAMEOFAREA: String?
    let NAMEOFPOIN: String?
    let LOCATION: String?
    let COMMENT_2: String?
    let COM_EN: String?
    let UPPER: String?

    var displayName: String? {
        let candidates = [LOCATION, NAMEOFAREA, NAMEOFPOIN]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    // The AIP layers carry a free-text Swedish description of the area and its permission
    // rules (COMMENT_2); the heliport layer sometimes has an English one (COM_EN).
    var sourceComment: (text: String, language: String)? {
        if let en = COM_EN?.trimmingCharacters(in: .whitespacesAndNewlines), !en.isEmpty {
            return (en, "en")
        }
        if let sv = COMMENT_2?.trimmingCharacters(in: .whitespacesAndNewlines), !sv.isEmpty {
            return (sv, "sv")
        }
        return nil
    }

    // AIP vertical limits arrive as strings: "GND", "UNL" or a number in feet AMSL.
    var upperLimit: AltitudeLimit? {
        guard let raw = UPPER?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw) else { return nil }
        return AltitudeLimit(value: String(value), unit: "ft", reference: "AMSL")
    }
}

final class SwedenProvider: ED269DownloadableProvider, @unchecked Sendable {
    nonisolated static let providerID = "sweden"

    nonisolated let id = SwedenProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("LFV / Transportstyrelsen", comment: "Sweden provider display name")
    }
    nonisolated var attributionName: String { "LFV / Transportstyrelsen" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated static let uasZonesDataset = "airspace.uas-zones"
    nonisolated static let airportZonesDataset = "airspace.airport-zones"
    nonisolated static let restrictedZonesDataset = "airspace.restricted-zones"
    nonisolated static let controlZonesDataset = "airspace.control-zones"

    let dataset = ED269DownloadableDataset<SEZone>(
        fileName: "swe_uas_zones.json",
        remoteURL: URL(string: "https://gruettecloud.com/safefly/download-json?country=SE")!,
        parse: SwedenProvider.parse
    )

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: SwedenProvider.uasZonesDataset,
                presentation: localizedProviderPresentation(title: "UAS Geo Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: SwedenProvider.airportZonesDataset,
                presentation: localizedProviderPresentation(title: "Airport & Heliport Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: SwedenProvider.restrictedZonesDataset,
                presentation: localizedProviderPresentation(title: "Restricted & Danger Areas", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: SwedenProvider.controlZonesDataset,
                presentation: localizedProviderPresentation(title: "Control Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution and run queries only over real Swedish territory (incl. Gotland/Öland).
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.sweden }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.sweden.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Drönarkartan (LFV)", comment: "Sweden provider data source link title"),
                url: URL(string: "https://dronechart.lfv.se/")!
            ),
            ProviderReferenceLink(
                title: NSLocalizedString("UAS Geographical Zones (Transportstyrelsen)", comment: "Sweden provider zones link title"),
                url: URL(string: "https://www.transportstyrelsen.se/en/aviation/Aircraft/drones--unmanned-aircraft/")!
            )
        ]
    }

    // The bundle's WFS layers, keyed by their name in the package's `layers` map, with the
    // fixed national rule each one represents.
    nonisolated private struct WFSLayerRule {
        let layerID: String
        let datasetID: String
        let category: ZoneCategory
        let verdict: FlightAssessmentOutcome
    }

    nonisolated private static let wfsLayerRules: [String: WFSLayerRule] = [
        // 5 km protection zones around airport runways: no drone flight without ATS permission.
        "RWY5K": WFSLayerRule(layerID: "airport-5km", datasetID: airportZonesDataset,
                              category: .airport, verdict: .conditional),
        // 1 km zones around heliports.
        "HKP1K": WFSLayerRule(layerID: "heliport-1km", datasetID: airportZonesDataset,
                              category: .aerodrome, verdict: .conditional),
        // AIP restricted areas (ES R…): national parks, prisons, nuclear plants — prohibited
        // without a special permit from the responsible authority.
        "RSTA": WFSLayerRule(layerID: "restricted-area", datasetID: restrictedZonesDataset,
                             category: .restrictedArea, verdict: .prohibited),
        // AIP danger areas (ES D…): hazardous activity during published hours.
        "DNGA": WFSLayerRule(layerID: "danger-area", datasetID: restrictedZonesDataset,
                             category: .restrictedArea, verdict: .conditional),
        // Control zones and traffic information zones: max 50 m AGL without clearance
        // (10 kg class), otherwise ATS clearance required.
        "CTR": WFSLayerRule(layerID: "control-zone", datasetID: controlZonesDataset,
                            category: .controlZone, verdict: .conditional),
        "TIZ": WFSLayerRule(layerID: "traffic-info-zone", datasetID: controlZonesDataset,
                            category: .controlZone, verdict: .conditional)
    ]

    // The merged proxy bundle: the ED-318 file verbatim plus one GeoJSON FeatureCollection
    // per drone-chart WFS layer.
    nonisolated private struct SEBundle: Decodable {
        struct UASZonesFile: Decodable {
            let features: [SEUASZone]
        }

        let uasZones: UASZonesFile
        let layers: [String: GeoJSONFeatureCollection<SEWFSProperties>]
    }

    nonisolated private static func parse(_ data: Data) throws -> [SEZone] {
        let bundle = try JSONDecoder().decode(SEBundle.self, from: ed269StrippedJSONData(data))
        var zones: [SEZone] = []

        for zone in bundle.uasZones.features where !zone.geometry.isEmpty {
            let limits = zone.geometry.altitudeLimits()
            zones.append(SEZone(
                layerID: "uas-zone",
                datasetID: uasZonesDataset,
                identifier: zone.identifier,
                name: zone.name,
                sourceType: zone.type,
                advisory: zone.message,
                advisoryLanguage: zone.message == nil ? nil : "en",
                verdict: SwedenZoneNormalizer.uasVerdict(for: zone.type),
                category: SwedenZoneNormalizer.uasCategory(name: zone.name, reasons: zone.reason),
                lowerLimit: limits.lower,
                upperLimit: limits.upper,
                geometry: zone.geometry,
                boundingBox: zone.geometry.boundingBox
            ))
        }

        for (layerName, collection) in bundle.layers {
            guard let rule = wfsLayerRules[layerName] else { continue }
            for feature in collection.features {
                let geometry = feature.ed269Geometry
                guard !geometry.isEmpty else { continue }
                let comment = feature.properties.sourceComment
                zones.append(SEZone(
                    layerID: rule.layerID,
                    datasetID: rule.datasetID,
                    identifier: nil,
                    name: feature.properties.displayName,
                    sourceType: feature.properties.TYPEOFAREA,
                    advisory: comment?.text,
                    advisoryLanguage: comment?.language,
                    verdict: rule.verdict,
                    category: SwedenZoneNormalizer.wfsCategory(
                        layer: rule.layerID,
                        name: feature.properties.displayName,
                        comment: feature.properties.COMMENT_2,
                        fallback: rule.category
                    ),
                    lowerLimit: nil,
                    upperLimit: feature.properties.upperLimit,
                    geometry: geometry,
                    boundingBox: geometry.boundingBox
                ))
            }
        }

        return zones
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = dataset.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [
                SwedenProvider.uasZonesDataset: status,
                SwedenProvider.airportZonesDataset: status,
                SwedenProvider.restrictedZonesDataset: status,
                SwedenProvider.controlZonesDataset: status
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

        var payloads: [ProviderRenderPayload] = []
        for zone in await dataset.features {
            guard selectedDatasetIDs.contains(zone.datasetID) else { continue }
            if let bbox = zone.boundingBox, !bbox.intersects(request.region) { continue }
            guard let style = ED269RenderStyle.forVerdict(zone.verdict) else { continue }

            for ring in zone.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(id).\(zone.layerID).\(zone.identifier ?? zone.name ?? "zone").\(payloads.count)",
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
        guard CountryBoundaries.sweden.contains(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }
        guard dataset.isDownloaded, !selectedDatasetIDs.isEmpty else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await dataset.features
            .filter { zone in
                guard selectedDatasetIDs.contains(zone.datasetID) else { return false }
                if let bbox = zone.boundingBox, !bbox.contains(coordinate) { return false }
                return zone.contains(coordinate)
            }
            .map { zone -> SwedenFeatureInfoRecord in
                SwedenFeatureInfoRecord(
                    layerID: zone.layerID,
                    identifier: zone.identifier,
                    name: zone.name,
                    sourceType: zone.sourceType,
                    advisory: zone.advisory,
                    advisoryLanguage: zone.advisoryLanguage,
                    verdict: zone.verdict,
                    category: zone.category,
                    lowerLimit: zone.lowerLimit,
                    upperLimit: zone.upperLimit
                )
            }

        return matches.isEmpty ? .noMatches : .matches(records: matches.map { $0 as any ProviderRawRecord })
    }
}

struct SwedenZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let se = record as? SwedenFeatureInfoRecord else { return nil }

            // Prefer the source's own advisory (ED-318 message / AIP comment); otherwise a
            // concise localized note derived from the layer's national rule.
            let advisory = se.advisory ?? SwedenZoneNormalizer.fallbackNote(for: se.layerID, verdict: se.verdict)
            let advisoryLanguage = se.advisory == nil ? nil : se.advisoryLanguage

            return ZoneFeature(
                category: se.category,
                restrictionLevel: se.verdict,
                name: se.name ?? se.identifier,
                sourceDeclaredType: se.sourceType,
                sourceDeclaredRestriction: advisory,
                lowerLimit: se.lowerLimit,
                upperLimit: se.upperLimit,
                legalReference: se.identifier,
                source: SourceProvenance(providerID: se.providerID, sourceLayerID: se.layerID),
                restrictionSourceLanguage: advisoryLanguage
            )
        }
    }

    // ED-318 restriction type → verdict. Sweden spells authorisation with a Z.
    nonisolated static func uasVerdict(for type: String?) -> FlightAssessmentOutcome {
        switch type {
        case "PROHIBITED":
            return .prohibited
        case "NO_RESTRICTION":
            return .allowed
        case "REQ_AUTHORIZATION", "REQ_AUTHORISATION", "CONDITIONAL":
            return .conditional
        default:
            return .conditional
        }
    }

    // Category for a Transportstyrelsen UAS zone, derived from its (English) name.
    nonisolated static func uasCategory(name: String?, reasons: [String]?) -> ZoneCategory {
        let text = (name ?? "").lowercased()
        if text.contains("hydro power") || text.contains("power plant") || text.contains("kraftverk") {
            return .powerPlant
        }
        if text.contains("prison") || text.contains("anstalt") || text.contains("häkte") {
            return .prison
        }
        if text.contains("palace") || text.contains("castle") || text.contains("slott") {
            return .securityAuthority
        }
        if text.contains("airport") || text.contains("flygplats") {
            return .airport
        }
        if (reasons ?? []).contains("AIR_TRAFFIC") {
            return .aerodrome
        }
        return .restrictedArea
    }

    // Category for a drone-chart WFS feature; the AIP restricted areas cover very different
    // things (national parks, prisons, nuclear plants), told apart by name/comment.
    nonisolated static func wfsCategory(
        layer: String, name: String?, comment: String?, fallback: ZoneCategory
    ) -> ZoneCategory {
        guard layer == "restricted-area" else { return fallback }
        let text = "\(name ?? "") \(comment ?? "")".lowercased()
        if text.contains("nationalpark") || text.contains("national park") {
            return .nationalPark
        }
        if text.contains("fågel") {
            return .birdSanctuary
        }
        if text.contains("kärnkraft") || text.contains("nuclear") {
            return .powerPlant
        }
        if text.contains("anstalt") || text.contains("häkte") || text.contains("fängelse") {
            return .prison
        }
        if text.contains("skjut") || text.contains("militär") || text.contains("försvars") {
            return .militaryInstallation
        }
        return fallback
    }

    // Short localized guidance for zones that ship no advisory text of their own.
    nonisolated static func fallbackNote(for layerID: String, verdict: FlightAssessmentOutcome) -> String {
        switch layerID {
        case "airport-5km":
            return NSLocalizedString("SE.NOTE.RWY5K", comment: "Sweden advisory: airport 5 km zone")
        case "heliport-1km":
            return NSLocalizedString("SE.NOTE.HKP1K", comment: "Sweden advisory: heliport 1 km zone")
        case "restricted-area":
            return NSLocalizedString("SE.NOTE.RSTA", comment: "Sweden advisory: restricted area")
        case "danger-area":
            return NSLocalizedString("SE.NOTE.DNGA", comment: "Sweden advisory: danger area")
        case "control-zone", "traffic-info-zone":
            return NSLocalizedString("SE.NOTE.CTR", comment: "Sweden advisory: control zone")
        default:
            return verdict == .prohibited
                ? NSLocalizedString("SE.NOTE.RSTA", comment: "Sweden advisory: restricted area")
                : NSLocalizedString("SE.NOTE.UAS", comment: "Sweden advisory: UAS geo zone")
        }
    }
}
