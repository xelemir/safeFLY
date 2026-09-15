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
//      GeoServer: 5 km airport zones (RWY5K), 1 km heliport zones (HKP1K), AIP restricted
//      areas incl. every national park (RSTA), danger areas (DNGA), the CTR/TIZ/ATZ control
//      and traffic zones with their 50 m low-level allowance, and the two temporary sources,
//      AIP SUP (pre-published temporary areas) and NOTAM (short-notice activations).
//
//  The NOTAM layer arrives pre-filtered by the proxy: only Q-code subjects that restrict
//  airspace, and only conditions that establish something (triggers, which duplicate the SUP
//  layer, and withdrawals, which lift a restriction, are dropped). Everything below is written
//  assuming that filter, not the raw feed.
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
    // Only the temporary layers (AIP SUP, NOTAM) carry these; nil everywhere else.
    let validFrom: Date?
    let validUntil: Date?

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
    let validFrom: Date?
    let validUntil: Date?
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

// LFV types the same conceptual column differently per layer: the AIP layers publish
// LOWER/UPPER as strings ("GND", "2100"), the NOTAM layer as bare numbers (flight levels).
// This decodes either shape into the text the limit helpers below work with.
nonisolated struct SELooseText: Decodable, Sendable {
    let text: String?

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? nil : trimmed
        } else if let value = try? container.decode(Double.self) {
            text = value == value.rounded() ? String(Int(value)) : String(value)
        } else {
            text = nil
        }
    }
}

// One WFS feature's properties. The DAIM_TOPO airport layers, the mais AIP layers, the AIP
// SUP layer and the NOTAM layer all use different column names, so everything is optional
// and read through helpers.
nonisolated struct SEWFSProperties: Decodable, Sendable {
    let TYPEOFAREA: String?
    let NAMEOFAREA: String?
    let NAMEOFPOIN: String?
    let LOCATION: String?
    let COMMENT_2: String?
    let COM_EN: String?
    let COM_SE: String?
    let LOWER: SELooseText?
    let UPPER: SELooseText?
    // AIP SUP: a named temporary area ("HJORTEN") with its designator ("ESR833"), the
    // validity window and LFV's own human-readable schedule line.
    let NAME: String?
    let DESIG: String?
    let FROM: String?
    let TO: String?
    let SCHEDULE: String?
    // NOTAM: no name column at all. SERIES/NO/YEAR form the reference ("B2292/26") and ITEM_E
    // is the English free text, which for these is the only place the real boundary is written.
    let SERIES: String?
    let NO: SELooseText?
    let YEAR: SELooseText?
    let CODE23: String?
    let ITEM_E: String?
    let STARTVALIDITY: String?
    let ENDVALIDITY: String?

    var displayName: String? {
        let candidates = [LOCATION, NAMEOFAREA, NAMEOFPOIN, NAME, DESIG, notamReference]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    // A NOTAM is referenced by series, number and two-digit year, e.g. "B2292/26".
    var notamReference: String? {
        guard let series = SERIES?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty,
              let number = NO?.text, let year = YEAR?.text else { return nil }
        let paddedYear = year.count == 1 ? "0" + year : year
        return "\(series)\(number)/\(paddedYear)"
    }

    // The AIP layers carry a free-text Swedish description of the area and its permission
    // rules (COMMENT_2); SUP and the heliport layer carry an English one (COM_EN), and a
    // NOTAM's item E is always English.
    var sourceComment: (text: String, language: String)? {
        for candidate in [COM_EN, ITEM_E] {
            if let en = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !en.isEmpty {
                // An AIP SUP's FROM/TO span the whole publication (e.g. Nov 2025 to Aug 2027)
                // while SCHEDULE carries the hours it is actually active inside that span
                // ("MON - FRI 0600 - 2100"). The window alone would read as a two-year closure,
                // so the schedule is appended here, in the same English the caller translates.
                let schedule = SCHEDULE?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let schedule, !schedule.isEmpty, !en.contains(schedule) {
                    return (en + "\n" + schedule, "en")
                }
                return (en, "en")
            }
        }
        for candidate in [COMMENT_2, COM_SE] {
            if let sv = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !sv.isEmpty {
                return (sv, "sv")
            }
        }
        return nil
    }

    // AIP vertical limits come in four shapes across LFV's layers: "GND" and its synonym "SFC"
    // for the surface, a flight level ("FL95", and "FL 95" with a space in one RSTA row), a bare
    // number in feet AMSL, or "UNL" for unlimited. "UNL" is dropped because an unlimited ceiling
    // tells a drone pilot nothing actionable; everything else is surfaced as published.
    var aipLimits: (lower: AltitudeLimit?, upper: AltitudeLimit?) {
        (SEWFSProperties.aipLimit(LOWER), SEWFSProperties.aipLimit(UPPER))
    }

    nonisolated private static func aipLimit(_ raw: SELooseText?) -> AltitudeLimit? {
        guard let text = raw?.text else { return nil }
        if ["GND", "SFC"].contains(where: { text.caseInsensitiveCompare($0) == .orderedSame }) {
            return AltitudeLimit(value: "GND", unit: "", reference: nil)
        }
        if text.uppercased().hasPrefix("FL") {
            let level = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard let value = Int(level) else { return nil }
            return AltitudeLimit(value: "FL\(value)", unit: "", reference: nil)
        }
        guard let value = Int(text) else { return nil }
        return AltitudeLimit(value: String(value), unit: "ft", reference: "AMSL")
    }

    // NOTAM limits are flight levels, not feet: FL000 is ground and FL999 is the feed's
    // "no upper limit" placeholder, so neither is shown as a number.
    var flightLevelLimits: (lower: AltitudeLimit?, upper: AltitudeLimit?) {
        (SEWFSProperties.flightLevelLimit(LOWER), SEWFSProperties.flightLevelLimit(UPPER))
    }

    nonisolated private static func flightLevelLimit(_ raw: SELooseText?) -> AltitudeLimit? {
        guard let text = raw?.text, let level = Int(text) else { return nil }
        if level == 0 { return AltitudeLimit(value: "GND", unit: "", reference: nil) }
        guard level < 999 else { return nil }
        return AltitudeLimit(value: "FL\(level)", unit: "", reference: nil)
    }

    // AIP SUP publishes "2025-11-10T06:00Z", NOTAM "2026-07-10T12:43:00Z". Both are ISO-8601
    // with a Z offset; the seconds are the only difference, so both formats are tried.
    var validityWindow: (from: Date?, until: Date?) {
        (SEWFSProperties.date(FROM ?? STARTVALIDITY), SEWFSProperties.date(TO ?? ENDVALIDITY))
    }

    nonisolated private static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let parsed = ISO8601DateFormatter().date(from: raw) { return parsed }
        // ISO8601DateFormatter always demands seconds, which the SUP layer omits.
        let minutePrecision = DateFormatter()
        minutePrecision.locale = Locale(identifier: "en_US_POSIX")
        minutePrecision.timeZone = TimeZone(identifier: "UTC")
        minutePrecision.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return minutePrecision.date(from: raw)
    }
}

final class SwedenProvider: ED269DownloadableProvider, @unchecked Sendable {
    nonisolated static let providerID = "sweden"

    nonisolated let id = SwedenProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("LFV / Transportstyrelsen", comment: "Sweden provider display name")
    }
    // Drönarkartan data is licensed CC BY 4.0 (see daim.lfv.se/echarts/dronechart/API/), so
    // attribution is the only condition: no non-commercial and no no-derivatives restriction.
    nonisolated var attributionName: String { "LFV / Transportstyrelsen, CC BY 4.0" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated static let uasZonesDataset = "airspace.uas-zones"
    nonisolated static let airportZonesDataset = "airspace.airport-zones"
    nonisolated static let restrictedZonesDataset = "airspace.restricted-zones"
    nonisolated static let controlZonesDataset = "airspace.control-zones"
    nonisolated static let temporaryRestrictionsDataset = "airspace.temporary-restrictions"

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
            ),
            ProviderDataset(
                id: SwedenProvider.temporaryRestrictionsDataset,
                presentation: localizedProviderPresentation(title: "Temporary Restrictions", groupTitle: "Airspace"),
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
                title: "LFV - Luftfartsverket",
                url: URL(string: "https://www.lfv.se/")!
            ),
            ProviderReferenceLink(
                title: "Drönarkartan",
                url: URL(string: "https://dronechart.lfv.se/")!
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
                            category: .controlZone, verdict: .conditional),
        // Traffic zones around uncontrolled aerodromes that run a traffic information service:
        // same clearance requirement as a control zone.
        "ATZ": WFSLayerRule(layerID: "traffic-zone", datasetID: controlZonesDataset,
                            category: .controlZone, verdict: .conditional),
        // AIP SUP: temporary restricted and danger areas, published weeks ahead of the window
        // they apply to, so each one is only a real prohibition inside its own validity window.
        "SUP": WFSLayerRule(layerID: "temporary-restriction", datasetID: temporaryRestrictionsDataset,
                            category: .temporaryRestrictionActive, verdict: .prohibited),
        // NOTAM: short-notice activations, pre-filtered by the proxy to the airspace subjects
        // that establish something (triggers and withdrawals are dropped there).
        //
        // Deliberately conditional rather than prohibited, unlike SUP: LFV's NOTAM layer does not
        // publish the restriction's real boundary. Every geometry in it is a circle generated
        // from the Q-line radius, which ICAO defines as a generous "area of influence" and which
        // reaches 41 NM on the widest Swedish entries; the true boundary only exists as free text
        // in item E. Painting that circle red would put a hard no-fly over thousands of square
        // kilometres the restriction never covered, so it is shown as "check this" instead, and
        // SE.NOTE.NOTAM.EXTENT tells the pilot the outline is approximate.
        "NOTAM": WFSLayerRule(layerID: "notam-restriction", datasetID: temporaryRestrictionsDataset,
                              category: .temporaryRestrictionActive, verdict: .conditional)
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
                validFrom: nil,
                validUntil: nil,
                geometry: zone.geometry,
                boundingBox: zone.geometry.boundingBox
            ))
        }

        for (layerName, collection) in bundle.layers {
            guard let rule = wfsLayerRules[layerName] else { continue }
            let isNOTAM = layerName == "NOTAM"
            for feature in collection.features {
                let geometry = feature.ed269Geometry
                guard !geometry.isEmpty else { continue }
                let properties = feature.properties
                let comment = properties.sourceComment
                let window = properties.validityWindow
                let limits = isNOTAM ? properties.flightLevelLimits : properties.aipLimits

                zones.append(SEZone(
                    layerID: rule.layerID,
                    datasetID: rule.datasetID,
                    identifier: isNOTAM ? properties.notamReference : properties.DESIG,
                    name: properties.displayName,
                    sourceType: properties.TYPEOFAREA,
                    advisory: comment?.text,
                    advisoryLanguage: comment?.language,
                    // The zone is stored exactly as published. Whether a temporary one is in
                    // force right now is decided on the render/query path instead, because the
                    // parsed package is cached for the life of the process: deciding it here
                    // would freeze "not yet active" into a zone that starts an hour into the
                    // session and never re-evaluate it.
                    verdict: rule.verdict,
                    category: SwedenZoneNormalizer.wfsCategory(
                        layer: rule.layerID,
                        name: properties.displayName,
                        comment: properties.COMMENT_2,
                        fallback: rule.category
                    ),
                    lowerLimit: limits.lower,
                    upperLimit: limits.upper,
                    validFrom: window.from,
                    validUntil: window.until,
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
                SwedenProvider.controlZonesDataset: status,
                SwedenProvider.temporaryRestrictionsDataset: status
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
        // One instant for the whole pass, so a temporary zone can't be judged active for its
        // fill and inactive for its stroke.
        let now = Date()
        for zone in await dataset.features {
            guard selectedDatasetIDs.contains(zone.datasetID) else { continue }
            if let bbox = zone.boundingBox, !bbox.intersects(request.region) { continue }
            let state = SwedenZoneNormalizer.temporaryState(
                category: zone.category, verdict: zone.verdict,
                start: zone.validFrom, end: zone.validUntil, now: now
            )
            guard let style = ED269RenderStyle.forVerdict(state.verdict) else { continue }

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
        let now = Date()
        let matches = await dataset.features
            .filter { zone in
                guard selectedDatasetIDs.contains(zone.datasetID) else { return false }
                if let bbox = zone.boundingBox, !bbox.contains(coordinate) { return false }
                return zone.contains(coordinate)
            }
            .map { zone -> SwedenFeatureInfoRecord in
                let state = SwedenZoneNormalizer.temporaryState(
                    category: zone.category, verdict: zone.verdict,
                    start: zone.validFrom, end: zone.validUntil, now: now
                )
                return SwedenFeatureInfoRecord(
                    layerID: zone.layerID,
                    identifier: zone.identifier,
                    name: zone.name,
                    sourceType: zone.sourceType,
                    advisory: zone.advisory,
                    advisoryLanguage: zone.advisoryLanguage,
                    verdict: state.verdict,
                    category: state.category,
                    lowerLimit: zone.lowerLimit,
                    upperLimit: zone.upperLimit,
                    validFrom: zone.validFrom,
                    validUntil: zone.validUntil
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
                restrictionSourceLanguage: advisoryLanguage,
                // Kept out of the advisory above: that field carries the source's own Swedish or
                // English text and is machine-translated, this one is already localized.
                supplementaryNote: SwedenZoneNormalizer.supplementaryNote(
                    layerID: se.layerID, start: se.validFrom, end: se.validUntil
                )
            )
        }
    }

    // AIP SUP and NOTAM both publish areas ahead of the window they apply to, and a lapsed one
    // can linger until the next daily refresh. A temporary area is only a live prohibition while
    // `now` sits inside [start, end]; outside it the zone is known but not in force, so it drops
    // to the inactive category and a conditional verdict instead of showing a red no-fly weeks
    // early. An area with no window at all is left exactly as published: we cannot prove it is
    // dormant. Mirrors DIPULZoneNormalizer.effectiveCategory, which does the same for Germany.
    nonisolated static func temporaryState(
        category: ZoneCategory,
        verdict: FlightAssessmentOutcome,
        start: Date?,
        end: Date?,
        now: Date
    ) -> (category: ZoneCategory, verdict: FlightAssessmentOutcome) {
        guard case .temporaryRestrictionActive = category else { return (category, verdict) }
        if let start, now < start { return (.temporaryRestrictionInactive, .conditional) }
        if let end, now > end { return (.temporaryRestrictionInactive, .conditional) }
        return (.temporaryRestrictionActive, verdict)
    }

    // The always-localized lines shown beneath the source's own restriction text: how far a
    // NOTAM's drawn outline can be trusted, and when a temporary area actually applies. The
    // footprint caveat cannot ride on the fallback advisory, because a NOTAM always ships its
    // own item E text and so never falls back.
    nonisolated static func supplementaryNote(layerID: String, start: Date?, end: Date?) -> String? {
        let lines = [
            layerID == "notam-restriction"
                ? NSLocalizedString("SE.NOTE.NOTAM.EXTENT", comment: "Sweden advisory: NOTAM outline is approximate")
                : nil,
            validityNote(start: start, end: end)
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // When a temporary area applies, shown beneath the restriction text. Rendered in Swedish
    // local time to match the published AIP SUP / NOTAM regardless of the device's timezone; a
    // window that opens and closes on one day shows the end as a bare time.
    nonisolated static func validityNote(start: Date?, end: Date?) -> String? {
        guard let start, let end else { return nil }

        let stockholm = TimeZone(identifier: "Europe/Stockholm")
        let dateTime = DateFormatter()
        dateTime.dateStyle = .medium
        dateTime.timeStyle = .short
        dateTime.timeZone = stockholm

        var calendar = Calendar(identifier: .gregorian)
        if let stockholm { calendar.timeZone = stockholm }

        let endText: String
        if calendar.isDate(start, inSameDayAs: end) {
            let timeOnly = DateFormatter()
            timeOnly.dateStyle = .none
            timeOnly.timeStyle = .short
            timeOnly.timeZone = stockholm
            endText = timeOnly.string(from: end)
        } else {
            endText = dateTime.string(from: end)
        }

        return String(
            format: NSLocalizedString("SE.TEMP.WINDOW", comment: "Sweden temporary restriction validity window"),
            dateTime.string(from: start), endText
        )
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
        case "control-zone", "traffic-info-zone", "traffic-zone":
            return NSLocalizedString("SE.NOTE.CTR", comment: "Sweden advisory: control zone")
        case "temporary-restriction":
            return NSLocalizedString("SE.NOTE.TEMP", comment: "Sweden advisory: temporary restriction")
        case "notam-restriction":
            return NSLocalizedString("SE.NOTE.NOTAM", comment: "Sweden advisory: NOTAM restriction")
        default:
            return verdict == .prohibited
                ? NSLocalizedString("SE.NOTE.RSTA", comment: "Sweden advisory: restricted area")
                : NSLocalizedString("SE.NOTE.UAS", comment: "Sweden advisory: UAS geo zone")
        }
    }
}
