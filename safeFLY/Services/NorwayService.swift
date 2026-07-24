//
//  NorwayService.swift
//  safeFLY
//
//  Norway drone geo-zones via Luftfartstilsynet's own map, dronesoner.no. Norway is not in the
//  EU, but through the EEA agreement it applies Regulation (EU) 2019/945 and 2019/947 in full
//  (effective 1 January 2021), so the open-category C-classes and A1/A2/A3 subcategories are
//  identical to the rest of the app — see RESIDENTIAL.INFO.NO for the note the pilot sees.
//
//  Unlike the proxy-backed offline countries (DE/NL/AT) this provider fetches dronesoner.no's
//  static GeoJSON layers directly: there is no per-viewport query API, so the layers are
//  downloaded once, cached in Documents, and rendered/queried fully offline through the shared
//  `ED269Geometry` engine (same as the Denmark/ED-269 providers). The ED-269 / ED-318 / KML
//  "downloads" the site offers are just client-side reformats of these same GeoJSON files, so
//  the raw GeoJSON is the authoritative source.
//
//  Attribution: the zones are Luftfartstilsynet / dronesoner.no data; the embassies layer is
//  derived from OpenStreetMap (© OpenStreetMap contributors, ODbL), reflected in the provider's
//  attribution string.
//
//  dronesoner.no itself states three things are NOT on the map (surfaced in the app disclaimer):
//  military areas and vessels, safety zones around offshore oil/gas installations, and temporary
//  incident areas (accidents / police operations). NOTAM is only refreshed partially, so pilots
//  must still check ippc.no.
//

import Foundation

// One Norwegian zone parsed from a dronesoner.no GeoJSON layer, expressed with the shared
// ED-269 geometry engine so bounding-box, point-in-polygon and render-ring logic is reused.
nonisolated struct NorwayZoneFeature: Sendable {
    let id: String
    let layerID: String
    let datasetID: String
    let category: ZoneCategory
    // Verdict can vary per feature (nature reserves carry a `droneforbud` flag), so it is stored
    // on the feature rather than derived from the layer alone.
    let verdict: FlightAssessmentOutcome
    let name: String?
    // The zone's own declared type/theme, kept for the id and the "type" row.
    let sourceType: String?
    // Free-text advisory in Norwegian (nb) straight from the feed, when the layer carries one.
    let noteNB: String?
    // A localized fallback advisory key, used when the layer has no per-feature text.
    let noteKey: String?
    let legalReference: String?
    let legalReferenceURL: URL?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let geometry: [ED269Geometry]

    var boundingBox: BoundingBox? { geometry.boundingBox }
    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

struct NorwayFeatureInfoRecord: ProviderRawRecord {
    let layerID: String
    let category: ZoneCategory
    let verdict: FlightAssessmentOutcome
    let name: String?
    let sourceType: String?
    let noteNB: String?
    let noteKey: String?
    let legalReference: String?
    let legalReferenceURL: URL?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?

    nonisolated var providerID: String { NorwayProvider.providerID }
}

// Owns the on-disk files (one per dronesoner.no layer), the combined parsed-feature cache and
// the multi-file download lifecycle. Mirrors `ED269DownloadableDataset` but fans out over the
// several static GeoJSON files the site publishes instead of a single proxy bundle.
nonisolated final class NorwayZoneStore: @unchecked Sendable {
    struct LayerSource: Sendable {
        let layerID: String
        let fileName: String
        let remoteURL: URL
        let parse: @Sendable (Data) throws -> [NorwayZoneFeature]
    }

    private let sources: [LayerSource]
    private let stores: [DownloadableFileStore]

    @MainActor private var cache: [NorwayZoneFeature] = []

    init(sources: [LayerSource]) {
        self.sources = sources
        self.stores = sources.map { DownloadableFileStore(fileName: $0.fileName, remoteURL: $0.remoteURL) }
        Task { try? await reload() }
    }

    // Non-nil so the app treats Norway as a downloadable provider; the exact value is only used
    // as a sentinel (the individual layer URLs live on each `LayerSource`).
    nonisolated var remoteURL: URL { URL(string: "https://dronesoner.no/data/")! }
    // The package is present only once every layer has been downloaded.
    nonisolated var isDownloaded: Bool { stores.allSatisfy { $0.isDownloaded } }
    // Oldest layer timestamp, so a partially-stale package is treated as due for refresh.
    nonisolated var lastUpdated: Date? { stores.compactMap { $0.modificationDate }.min() }
    // Combined on-disk size of every downloaded layer file, or nil if none are present.
    nonisolated var byteSize: Int64? {
        let sizes = stores.compactMap { $0.byteSize }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    // Combined remote size across all layers, fetched concurrently. nil unless at least one
    // layer advertised a length.
    nonisolated func remoteByteSize() async -> Int64? {
        let total = await withTaskGroup(of: Int64?.self, returning: Int64?.self) { group in
            for source in sources {
                let url = source.remoteURL
                group.addTask { await remoteContentLength(url) }
            }
            var sum: Int64 = 0
            var sawAny = false
            for await size in group {
                if let size { sum += size; sawAny = true }
            }
            return sawAny ? sum : nil
        }
        return total
    }

    @MainActor var features: [NorwayZoneFeature] { cache }

    @MainActor func reload() async throws {
        var all: [NorwayZoneFeature] = []
        for (index, store) in stores.enumerated() where store.isDownloaded {
            let data = try store.read()
            all.append(contentsOf: try sources[index].parse(data))
        }
        cache = all
    }

    // Download every layer concurrently, validating each fully parses before it may replace the
    // local copy, so a malformed or truncated response never overwrites a previously good file.
    nonisolated func download() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                let parse = sources[index].parse
                group.addTask {
                    _ = try await store.download { data in _ = try parse(data) }
                }
            }
            try await group.waitForAll()
        }
        try await reload()
    }

    nonisolated func delete() {
        stores.forEach { $0.delete() }
        Task { @MainActor in self.cache = [] }
    }
}

final class NorwayProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "norway"

    nonisolated static let prohibitedDatasetID = "airspace.prohibited"
    nonisolated static let cautionDatasetID = "airspace.caution"
    nonisolated static let controlledDatasetID = "airspace.controlled"
    // Nature reserves split to mirror dronesoner.no: reserves whose verneforskrift actually bans
    // drones (prohibited, on by default) versus protected areas with no drone ban (advisory only,
    // off by default) — so we don't paint thousands of areas amber where flying is in fact allowed.
    nonisolated static let natureBanDatasetID = "nature.drone-ban"
    nonisolated static let natureDatasetID = "nature.protected-areas"

    nonisolated let id = NorwayProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("Luftfartstilsynet", comment: "Norway provider display name")
    }
    // dronesoner.no is Luftfartstilsynet's map; the embassies layer is OpenStreetMap-derived
    // (ODbL), so OSM is credited here as the licence requires.
    nonisolated var attributionName: String { "dronesoner.no, © OpenStreetMap" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated private static let dataBase = "https://dronesoner.no/data"

    let store = NorwayZoneStore(sources: NorwayProvider.layerSources)

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: NorwayProvider.prohibitedDatasetID,
                presentation: localizedProviderPresentation(title: "Prohibited Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: NorwayProvider.cautionDatasetID,
                presentation: localizedProviderPresentation(title: "Caution Areas", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: NorwayProvider.natureBanDatasetID,
                presentation: localizedProviderPresentation(title: "Nature Reserves (Drone Ban)", groupTitle: "Nature"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            // Protected areas without a drone ban: informational, so it defaults off (matching
            // dronesoner.no) to keep the map readable.
            ProviderDataset(
                id: NorwayProvider.natureDatasetID,
                presentation: localizedProviderPresentation(title: "Nature Reserves (No Ban)", groupTitle: "Nature"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: false
            ),
            // Controlled airspace mostly concerns manned aviation, so it defaults off to keep the
            // map readable; the pilot can switch it on.
            ProviderDataset(
                id: NorwayProvider.controlledDatasetID,
                presentation: localizedProviderPresentation(title: "Controlled Airspace", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: false
            )
        ]
    }

    nonisolated var coverage: CountryCoverage? { CountryBoundaries.norway }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.norway.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: "Dronesoner.no",
                url: URL(string: "https://dronesoner.no/")!
            ),
            ProviderReferenceLink(
                title: "Luftfartstilsynet",
                url: URL(string: "https://www.luftfartstilsynet.no/droner/droneregler/droneregler/")!
            )
        ]
    }

    // MARK: - Download lifecycle

    nonisolated var downloadURL: URL? { store.remoteURL }
    nonisolated var isDataDownloaded: Bool { store.isDownloaded }
    nonisolated var datasetLastUpdated: Date? { store.lastUpdated }
    nonisolated var datasetByteSize: Int64? { store.byteSize }
    nonisolated func remoteDatasetByteSize() async -> Int64? { await store.remoteByteSize() }
    nonisolated func downloadData() async throws { try await store.download() }
    nonisolated func deleteData() { store.delete() }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = store.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [
                NorwayProvider.prohibitedDatasetID: status,
                NorwayProvider.cautionDatasetID: status,
                NorwayProvider.natureBanDatasetID: status,
                NorwayProvider.natureDatasetID: status,
                NorwayProvider.controlledDatasetID: status
            ],
            brokenLayerIDs: [],
            refreshedAt: Date()
        )
    }

    // MARK: - Render / query

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard store.isDownloaded else { return [] }

        let features = await store.features
        var payloads: [ProviderRenderPayload] = []

        for feature in features {
            guard selectedDatasetIDs.contains(feature.datasetID) else { continue }
            guard let style = ED269RenderStyle.forVerdict(feature.verdict) else { continue }

            if let bbox = feature.boundingBox, !bbox.intersects(request.region) {
                continue
            }

            for ring in feature.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(feature.id).\(payloads.count)",
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
        // Svalbard / Jan Mayen sit outside the mainland outline; a tap there has no Norwegian
        // mainland data, so report it as outside coverage rather than a false "clear".
        guard CountryBoundaries.norway.contains(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }
        guard store.isDownloaded else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await store.features.compactMap { feature -> NorwayFeatureInfoRecord? in
            guard selectedDatasetIDs.contains(feature.datasetID) else { return nil }
            if let bbox = feature.boundingBox, !bbox.contains(coordinate) { return nil }
            guard feature.contains(coordinate) else { return nil }
            return NorwayFeatureInfoRecord(
                layerID: feature.layerID,
                category: feature.category,
                verdict: feature.verdict,
                name: feature.name,
                sourceType: feature.sourceType,
                noteNB: feature.noteNB,
                noteKey: feature.noteKey,
                legalReference: feature.legalReference,
                legalReferenceURL: feature.legalReferenceURL,
                lowerLimit: feature.lowerLimit,
                upperLimit: feature.upperLimit
            )
        }

        return matches.isEmpty ? .noMatches : .matches(records: matches.map { $0 as any ProviderRawRecord })
    }

    // MARK: - Layer catalogue

    // Each dronesoner.no layer, with the dataset toggle it belongs to and how to turn its own
    // property schema into `NorwayZoneFeature`s. Verdicts follow the site's own colour legend:
    // red = prohibited (permission required), yellow = caution/conditional, blue = controlled.
    nonisolated private static var layerSources: [NorwayZoneStore.LayerSource] {
        func source<P: Decodable & Sendable>(
            _ layerID: String, file: String, _ type: P.Type,
            _ map: @escaping @Sendable (P, [ED269Geometry], Int) -> NorwayZoneFeature?
        ) -> NorwayZoneStore.LayerSource {
            NorwayZoneStore.LayerSource(
                layerID: layerID,
                fileName: "no_\(layerID).geojson",
                remoteURL: URL(string: "\(NorwayProvider.dataBase)/\(file).geojson")!,
                parse: { data in
                    let features = try JSONDecoder()
                        .decode(GeoJSONFeatureCollection<P>.self, from: ed269StrippedJSONData(data))
                        .features
                    return features.enumerated().compactMap { index, feature in
                        let geometry = feature.ed269Geometry
                        guard !geometry.isEmpty else { return nil }
                        return map(feature.properties, geometry, index)
                    }
                }
            )
        }

        @Sendable func base(
            _ layerID: String, dataset: String, category: ZoneCategory,
            verdict: FlightAssessmentOutcome, name: String?, sourceType: String? = nil,
            noteNB: String? = nil, noteKey: String? = nil,
            legalReference: String? = nil, legalReferenceURL: URL? = nil,
            lower: AltitudeLimit? = nil, upper: AltitudeLimit? = nil,
            geometry: [ED269Geometry], index: Int
        ) -> NorwayZoneFeature {
            NorwayZoneFeature(
                id: "\(NorwayProvider.providerID).\(layerID).\(index)",
                layerID: layerID, datasetID: dataset, category: category, verdict: verdict,
                name: name, sourceType: sourceType, noteNB: noteNB, noteKey: noteKey,
                legalReference: legalReference, legalReferenceURL: legalReferenceURL,
                lowerLimit: lower, upperLimit: upper, geometry: geometry
            )
        }

        let prohibited = NorwayProvider.prohibitedDatasetID
        let caution = NorwayProvider.cautionDatasetID
        let controlled = NorwayProvider.controlledDatasetID
        let natureBan = NorwayProvider.natureBanDatasetID
        let nature = NorwayProvider.natureDatasetID

        return [
            // --- Prohibited / permission required (red) ---
            source("notam", file: "forbud_notam", NONotamProps.self) { p, g, i in
                base("notam", dataset: prohibited, category: .temporaryRestrictionActive, verdict: .prohibited,
                     name: p.navn, noteNB: NorwayText.plain(p.info), geometry: g, index: i)
            },
            source("airport5km", file: "forbud_lufthavner_5km", NOAirportProps.self) { p, g, i in
                base("airport5km", dataset: prohibited, category: .airport, verdict: .prohibited,
                     name: p.navn, sourceType: p.icao, noteKey: "NO.NOTE.AIRPORT", geometry: g, index: i)
            },
            source("restriksjoner", file: "forbud_restriksjoner", NONavnInfoProps.self) { p, g, i in
                base("restriksjoner", dataset: prohibited, category: .restrictedArea, verdict: .prohibited,
                     name: p.navn, noteNB: NorwayText.plain(p.info), geometry: g, index: i)
            },
            source("fengsler", file: "forbud_fengsler", NONavnInfoProps.self) { p, g, i in
                base("fengsler", dataset: prohibited, category: .prison, verdict: .prohibited,
                     name: p.navn, noteNB: NorwayText.plain(p.info), geometry: g, index: i)
            },
            source("nsmsensor", file: "forbud_nsm_sensor", NONsmProps.self) { p, g, i in
                base("nsmsensor", dataset: prohibited, category: .securityAuthority, verdict: .prohibited,
                     name: p.navn, sourceType: p.typeforbud, noteNB: NorwayText.plain(p.typeforbud),
                     noteKey: "NO.NOTE.NSM", geometry: g, index: i)
            },
            source("ambassader", file: "forbud_ambassader", NOEmbassyProps.self) { p, g, i in
                base("ambassader", dataset: prohibited, category: .diplomaticMission, verdict: .prohibited,
                     name: p.nameEn ?? p.name, noteKey: "NO.NOTE.EMBASSY", geometry: g, index: i)
            },

            // --- Nature reserves with a drone ban (red, on by default) ---
            source("nature_forbud", file: "forbud_verneomrader", NONatureProps.self) { p, g, i in
                let legal = NorwayText.natureLegal(p.verneforskrift)
                return base("nature_forbud", dataset: natureBan, category: .natureReserve,
                            verdict: .prohibited,
                            name: p.offisieltNavn, sourceType: p.forbudType,
                            noteNB: NorwayText.plain(p.beskrivelse) ?? NSLocalizedString("NO.NOTE.NATURE_BAN", comment: "Norway nature drone-ban advisory"),
                            legalReference: legal.reference, legalReferenceURL: legal.url,
                            geometry: g, index: i)
            },
            // --- Protected areas without a drone ban (amber advisory, off by default) ---
            source("nature_obs", file: "obs_verneomrader", NONatureProps.self) { p, g, i in
                let legal = NorwayText.natureLegal(p.verneforskrift)
                return base("nature_obs", dataset: nature, category: .natureReserve,
                            verdict: .conditional,
                            name: p.offisieltNavn, sourceType: p.forbudType,
                            noteNB: NorwayText.plain(p.beskrivelse),
                            noteKey: "NO.NOTE.NATURE",
                            legalReference: legal.reference, legalReferenceURL: legal.url,
                            geometry: g, index: i)
            },

            // --- Caution (yellow) ---
            source("fareomrader", file: "obs_fareomrader", NOFareProps.self) { p, g, i in
                base("fareomrader", dataset: caution, category: .restrictedArea, verdict: .conditional,
                     name: p.navn, noteNB: NorwayText.plain(p.info),
                     lower: NorwayText.altitude(p.lowerLimit), upper: NorwayText.altitude(p.upperLimit),
                     geometry: g, index: i)
            },
            source("flyplasser", file: "obs_flyplasser", NOFlyplassProps.self) { p, g, i in
                base("flyplasser", dataset: caution, category: .aerodrome, verdict: .conditional,
                     name: p.navn, sourceType: p.icaoKode, noteKey: "NO.NOTE.AIRFIELD", geometry: g, index: i)
            },
            source("notamsoner", file: "obs_notam_soner", NONavnInfoProps.self) { p, g, i in
                base("notamsoner", dataset: caution, category: .restrictedArea, verdict: .conditional,
                     name: p.navn, noteNB: NorwayText.plain(p.info), geometry: g, index: i)
            },

            // --- Controlled airspace (blue) ---
            source("ctrtiz", file: "luftrom_ctr_tiz", NOAirspaceProps.self) { p, g, i in
                base("ctrtiz", dataset: controlled, category: .controlZone, verdict: .conditional,
                     name: p.navn, sourceType: p.type, noteKey: "NO.NOTE.CTR",
                     lower: NorwayText.altitude(p.lowerLimit), upper: NorwayText.altitude(p.upperLimit),
                     geometry: g, index: i)
            },
            source("rmztmz", file: "luftrom_rmz_tmz", NOAirspaceProps.self) { p, g, i in
                base("rmztmz", dataset: controlled, category: .controlZone, verdict: .conditional,
                     name: p.navn, sourceType: p.type, noteKey: "NO.NOTE.RMZ",
                     lower: NorwayText.altitude(p.lowerLimit), upper: NorwayText.altitude(p.upperLimit),
                     geometry: g, index: i)
            }
        ]
    }
}

// MARK: - Per-layer property models

nonisolated struct NONotamProps: Decodable, Sendable {
    let navn: String?
    let info: String?
    enum CodingKeys: String, CodingKey { case navn = "Navn", info }
}

nonisolated struct NOAirportProps: Decodable, Sendable {
    let navn: String?
    let icao: String?
    enum CodingKeys: String, CodingKey { case navn = "NAVN", icao = "ICAO" }
}

nonisolated struct NONavnInfoProps: Decodable, Sendable {
    let navn: String?
    let info: String?
}

nonisolated struct NONsmProps: Decodable, Sendable {
    let navn: String?
    let typeforbud: String?
    let refnr: String?
}

nonisolated struct NOEmbassyProps: Decodable, Sendable {
    let name: String?
    let nameEn: String?
    let country: String?
    enum CodingKeys: String, CodingKey { case name, nameEn = "name:en", country }
}

nonisolated struct NONatureProps: Decodable, Sendable {
    let offisieltNavn: String?
    let verneforskrift: String?
    let droneforbud: Bool?
    let forbudType: String?
    let beskrivelse: String?
}

nonisolated struct NOFareProps: Decodable, Sendable {
    let navn: String?
    let info: String?
    let lowerLimit: String?
    let upperLimit: String?
    enum CodingKeys: String, CodingKey {
        case navn, info
        case lowerLimit = "lower_limit"
        case upperLimit = "upper_limit"
    }
}

nonisolated struct NOFlyplassProps: Decodable, Sendable {
    let navn: String?
    let icaoKode: String?
    let type: String?
}

nonisolated struct NOAirspaceProps: Decodable, Sendable {
    let navn: String?
    let type: String?
    let luftromsklasse: String?
    let kallesignal: String?
    let lowerLimit: String?
    let upperLimit: String?
    enum CodingKeys: String, CodingKey {
        case navn, type, luftromsklasse, kallesignal
        case lowerLimit = "lower_limit"
        case upperLimit = "upper_limit"
    }
}

// MARK: - Text helpers

nonisolated enum NorwayText {
    // dronesoner.no ships its advisories as small HTML fragments (`<br>`, links, styled spans).
    // Reduce them to plain text so the zone sheet shows a clean sentence rather than markup.
    nonisolated static func plain(_ html: String?) -> String? {
        guard var text = html else { return nil }
        for tag in ["<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: [.caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // Turns a lovdata forskrift URL (e.g. https://lovdata.no/forskrift/1987-04-03-302) into a
    // legal-reference label + link. The path's last component is the regulation's date-number id.
    nonisolated static func natureLegal(_ raw: String?) -> (reference: String?, url: URL?) {
        guard let raw, let url = URL(string: raw) else { return (nil, nil) }
        let identifier = url.lastPathComponent
        let reference = identifier.isEmpty ? nil : "FOR \(identifier)"
        return (reference, url)
    }

    // Parses an altitude string such as "4000 FT AMSL" or "300 M AGL". Non-numeric values the
    // feed uses (e.g. "GND", "FL 130", "Underside kontrollert luftrom") carry no usable limit and
    // collapse to nil so they are simply omitted rather than shown as junk.
    nonisolated static func altitude(_ raw: String?) -> AltitudeLimit? {
        guard let raw = raw?.uppercased() else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,6})\s*(FT|M)\b\s*(AMSL|AGL|MSL)?"#) else {
            return nil
        }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: raw) else { return nil }
            return String(raw[range])
        }
        guard let value = group(1) else { return nil }
        let unit = group(2) == "M" ? "m" : "ft"
        return AltitudeLimit(value: value, unit: unit, reference: group(3))
    }
}

// MARK: - Normalizer

struct NorwayZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let no = record as? NorwayFeatureInfoRecord else { return nil }

            // Prefer the authority's own Norwegian wording (tagged nb so the app treats it as raw
            // source text); fall back to a localized per-layer advisory already in the user's
            // language (lang nil, never machine-translated).
            let restriction: String?
            let language: String?
            if let noteNB = no.noteNB, !noteNB.isEmpty {
                restriction = noteNB
                language = "nb"
            } else if let noteKey = no.noteKey {
                restriction = NSLocalizedString(noteKey, comment: "Norway zone advisory")
                language = nil
            } else {
                restriction = nil
                language = nil
            }

            return ZoneFeature(
                category: no.category,
                restrictionLevel: no.verdict,
                name: no.name,
                sourceDeclaredType: no.sourceType,
                sourceDeclaredRestriction: restriction,
                lowerLimit: no.lowerLimit,
                upperLimit: no.upperLimit,
                legalReference: no.legalReference,
                legalReferenceURL: no.legalReferenceURL,
                source: SourceProvenance(providerID: no.providerID, sourceLayerID: no.layerID),
                restrictionSourceLanguage: language
            )
        }
    }
}
