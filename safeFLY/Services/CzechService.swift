//
//  CzechService.swift
//  safeFLY
//
//  Czech drone geo-zones via ANS ČR's (ŘLP) official DroneMap, backed by the open ArcGIS
//  server at aimgis.rlp.cz. Like Germany's DIPUL, the data is split into thematic layers —
//  but ŘLP publishes each theme as a *separate* ArcGIS service, so this provider fans out
//  over several `WMSDatasetCatalog`s (one per service, EPSG:3857) for the WMS GetMap render
//  and status probing. Point queries use the ArcGIS REST `identify` endpoint, because the
//  ArcGIS WMS GetFeatureInfo only returns HTML, whereas `identify` returns clean JSON.
//

import Foundation

struct CzechFeatureInfoRecord: ProviderRawRecord {
    let serviceID: String
    let name: String?
    let detail: String?
    let category: ZoneCategory
    let verdict: FlightAssessmentOutcome

    nonisolated var providerID: String { CzechProvider.providerID }
}

final class CzechProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "czech"

    nonisolated let id = CzechProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("ŘLP (Czech Republic)", comment: "Czech provider display name")
    }
    nonisolated var attributionName: String {
        "ŘLP ČR / ANS CR"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    // One ArcGIS service per theme. Each becomes a user-facing dataset and maps to a default
    // flight verdict / category for its kind of restriction.
    private struct ServiceLayer {
        let serviceName: String
        let layerIDs: [String]
        let datasetID: String
        let title: String
        let groupTitle: String
        let category: ZoneCategory
        let verdict: FlightAssessmentOutcome
        let catalog: WMSDatasetCatalog
    }

    nonisolated private static let coverageBounds = WMSDatasetCatalog.CoverageBounds(
        minLat: 48.5, maxLat: 51.1, minLon: 12.0, maxLon: 18.9
    )

    nonisolated private static func makeCatalog(serviceName: String, layerIDs: [String], dataset: ProviderDataset) -> WMSDatasetCatalog {
        WMSDatasetCatalog(
            baseURL: "https://aimgis.rlp.cz/server/services/\(serviceName)/MapServer/WMSServer",
            definitions: [WMSDatasetCatalog.DatasetDefinition(dataset: dataset, layerIDs: layerIDs)],
            coverageBounds: coverageBounds,
            coverage: CountryBoundaries.czechia,
            crs: "EPSG:3857"
        )
    }

    nonisolated private static func makeService(
        serviceName: String,
        layerIDs: [String],
        datasetID: String,
        title: String,
        groupTitle: String,
        category: ZoneCategory,
        verdict: FlightAssessmentOutcome
    ) -> ServiceLayer {
        let dataset = ProviderDataset(
            id: datasetID,
            presentation: localizedProviderPresentation(title: title, groupTitle: groupTitle),
            capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
            isSelectedByDefault: true
        )
        return ServiceLayer(
            serviceName: serviceName,
            layerIDs: layerIDs,
            datasetID: datasetID,
            title: title,
            groupTitle: groupTitle,
            category: category,
            verdict: verdict,
            catalog: makeCatalog(serviceName: serviceName, layerIDs: layerIDs, dataset: dataset)
        )
    }

    // The per-service category/verdict here are only fallbacks for the dataset toggles and
    // any unrecognised layer; the real per-feature verdict is decided by `classify(layerName:)`
    // below, which encodes the actual ŘLP rules (some services bundle sub-layers with
    // different rules, e.g. national parks vs other protected areas).
    private let services: [ServiceLayer] = [
        CzechProvider.makeService(serviceName:"zony", layerIDs: ["0"], datasetID: "aviation.airport-zones",
                    title: "Airport Zones", groupTitle: "Aviation", category: .controlZone, verdict: .conditional),
        CzechProvider.makeService(serviceName:"ODOS", layerIDs: ["0"], datasetID: "security.military",
                    title: "Military Objects", groupTitle: "Security", category: .militaryInstallation, verdict: .prohibited),
        CzechProvider.makeService(serviceName:"chranena_uzemi", layerIDs: ["0", "1", "2"], datasetID: "nature.protected-areas",
                    title: "Protected Areas", groupTitle: "Nature", category: .natureReserve, verdict: .conditional),
        CzechProvider.makeService(serviceName:"energeticka_sit", layerIDs: ["0", "1"], datasetID: "infrastructure.power",
                    title: "Power Network", groupTitle: "Infrastructure", category: .powerLine, verdict: .conditional),
        CzechProvider.makeService(serviceName:"silnicni_sit", layerIDs: ["0", "1", "2"], datasetID: "infrastructure.roads",
                    title: "Roads", groupTitle: "Infrastructure", category: .highway, verdict: .conditional),
        CzechProvider.makeService(serviceName:"Zeleznice", layerIDs: ["0", "1"], datasetID: "infrastructure.railways",
                    title: "Railways", groupTitle: "Infrastructure", category: .railway, verdict: .conditional),
        CzechProvider.makeService(serviceName:"zdroje_vody", layerIDs: ["0"], datasetID: "infrastructure.water",
                    title: "Water Sources", groupTitle: "Infrastructure", category: .restrictedArea, verdict: .conditional),
        CzechProvider.makeService(serviceName:"HOPs", layerIDs: ["0", "1", "2"], datasetID: "population.height-zones",
                    title: "Population Height Zones", groupTitle: "Population", category: .residentialProperty, verdict: .conditional)
    ]

    // Per-layer flight verdict + category from the actual ŘLP / CAA rules (OOP LKR310–320,
    // effective 1 Sep 2025). The ArcGIS `identify` response names the matched layer, which is
    // finer-grained than the service, so the rules are keyed on that layer name.
    //   Sources: letejtezodpovedne.cz "Zeměpisné zóny pro drony", ŘLP "Ochranná pásma".
    nonisolated private static func classify(
        layerName: String?,
        fallback: (category: ZoneCategory, verdict: FlightAssessmentOutcome)
    ) -> (category: ZoneCategory, verdict: FlightAssessmentOutcome) {
        switch layerName {
        // Airport inner zone (LKR): operations possible with coordination / a DroneMap flight plan.
        case "AD_inner_zones": return (.controlZone, .conditional)
        // State-defence objects (LKP): flight prohibited, exception by special approval only.
        case "Objekty_MO": return (.militaryInstallation, .prohibited)
        // National parks: drone operation prohibited outside built-up areas (permit only).
        case "NP": return (.nationalPark, .prohibited)
        // CHKO / small protected areas: authorisation required for >250 g or any camera.
        case "CHKO_Zony", "MZCHU": return (.natureReserve, .conditional)
        // Power infrastructure: operator consent / authorisation within the buffer.
        case "el_stanice_110_kV_plus": return (.substation, .conditional)
        case "el_vedeni_220_kV_plus": return (.powerLine, .conditional)
        // Roads: flight plan required; motorways/Class I/II–III need road-authority authorisation.
        case "dalnice_MV": return (.motorway, .conditional)
        case "silnice_1_tridy", "silnice_2_a_3_tridy": return (.highway, .conditional)
        // Railway buffers: flight plan required; A3 needs operator consent.
        case "Zeleznice_buffer_5m", "Zeleznice_buffer_60m": return (.railway, .conditional)
        // Drinking-water reservoirs/sources: only with the water authority's consent.
        case "nadzemni_zdroje_pitne_vody": return (.restrictedArea, .conditional)
        // Densely populated areas (A1/A2): conditions apply (flight plan, distance to people).
        case "CZ_HOP_A1A2": return (.residentialProperty, .conditional)
        // Sparsely populated (A3) and the raw population grid are informational only.
        case "EU_HOP_A3", "GHS_POP_period_2025": return (.residentialProperty, .allowed)
        default: return fallback
        }
    }

    nonisolated var datasets: [ProviderDataset] {
        services.map { $0.catalog.datasets[0] }
    }

    // Show attribution and run queries only over real Czech territory: it shares diagonal
    // borders with Germany, Poland, Slovakia and Austria that a bounding box would spill into.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.czechia }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.czechia.contains(region.center)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Drone rules (Civil Aviation Authority)", comment: "Czech drone rules link title"),
                url: URL(string: "https://www.caa.gov.cz/en/flight-operations/unmanned-aircraft/")!
            ),
            ProviderReferenceLink(
                title: NSLocalizedString("DroneMap (ŘLP ČR)", comment: "Czech provider data source link title"),
                url: URL(string: "https://dronemap.gov.cz/")!
            )
        ]
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        // Probe every service concurrently, then merge their per-dataset snapshots into one.
        let snapshots = await withTaskGroup(of: ProviderStatusSnapshot.self, returning: [ProviderStatusSnapshot].self) { group in
            for service in services {
                group.addTask { await service.catalog.probeStatus() }
            }
            var collected: [ProviderStatusSnapshot] = []
            for await snapshot in group {
                collected.append(snapshot)
            }
            return collected
        }

        var datasetStatuses: [String: ProviderAvailabilityStatus] = [:]
        var brokenLayerIDs = Set<String>()
        for snapshot in snapshots {
            datasetStatuses.merge(snapshot.datasetStatuses) { _, new in new }
            brokenLayerIDs.formUnion(snapshot.brokenLayerIDs)
        }

        let statuses = datasetStatuses.values
        let providerStatus: ProviderAvailabilityStatus
        if statuses.allSatisfy({ $0 == .available }) {
            providerStatus = .available
        } else if statuses.contains(where: { $0 == .available || $0 == .degraded }) {
            providerStatus = .degraded
        } else {
            providerStatus = .unavailable
        }

        return ProviderStatusSnapshot(
            providerStatus: providerStatus,
            datasetStatuses: datasetStatuses,
            brokenLayerIDs: brokenLayerIDs,
            refreshedAt: Date()
        )
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        var payloads: [ProviderRenderPayload] = []
        // One WMS image per service: ArcGIS exposes each theme as its own endpoint, so they
        // cannot be combined into a single GetMap the way DIPUL's layers can.
        for service in services {
            let encodedLayers = service.catalog.encodedLayerList(for: selectedDatasetIDs, status: status, operation: .render)
            guard !encodedLayers.isEmpty,
                  let imageURL = service.catalog.getMapURL(
                    region: request.region,
                    viewportSize: request.viewportSize,
                    encodedLayers: encodedLayers
                  ) else {
                continue
            }

            payloads.append(.wmsImage(WMSRenderPayload(
                id: "\(id).\(service.serviceName)",
                imageURL: imageURL,
                region: request.region,
                opacity: 0.8
            )))
        }
        return payloads
    }

    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard CountryBoundaries.czechia.contains(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        let activeServices = services.filter {
            selectedDatasetIDs.contains($0.datasetID) &&
            status.status(for: $0.datasetID) != .unavailable
        }
        guard !activeServices.isEmpty else {
            return .unavailable(reason: .providerNoData)
        }

        // Identify every active service concurrently; a single service failing must not sink
        // the others, so failures contribute no records rather than an error.
        let recordsByService = await withTaskGroup(of: [CzechFeatureInfoRecord].self, returning: [[CzechFeatureInfoRecord]].self) { group in
            for service in activeServices {
                group.addTask { await Self.identify(service: service, request: request) }
            }
            var collected: [[CzechFeatureInfoRecord]] = []
            for await records in group {
                collected.append(records)
            }
            return collected
        }

        let records = recordsByService.flatMap { $0 }
        if records.isEmpty {
            return .noMatches
        }
        return .matches(records: records.map { $0 as any ProviderRawRecord })
    }

    nonisolated private static func identify(service: ServiceLayer, request: ProviderPointQueryRequest) async -> [CzechFeatureInfoRecord] {
        let region = request.region
        let min = WMSDatasetCatalog.mercator(lon: region.center.longitude - region.longitudeDelta / 2,
                                             lat: region.center.latitude - region.latitudeDelta / 2)
        let max = WMSDatasetCatalog.mercator(lon: region.center.longitude + region.longitudeDelta / 2,
                                             lat: region.center.latitude + region.latitudeDelta / 2)
        let point = WMSDatasetCatalog.mercator(lon: request.coordinate.longitude, lat: request.coordinate.latitude)

        var components = URLComponents(string: "https://aimgis.rlp.cz/server/rest/services/\(service.serviceName)/MapServer/identify")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "{\"x\":\(point.x),\"y\":\(point.y)}"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "sr", value: "3857"),
            URLQueryItem(name: "layers", value: "all"),
            URLQueryItem(name: "tolerance", value: "3"),
            URLQueryItem(name: "mapExtent", value: "\(min.x),\(min.y),\(max.x),\(max.y)"),
            URLQueryItem(name: "imageDisplay", value: "\(request.viewportSize.width),\(request.viewportSize.height),96"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json")
        ]

        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            return []
        }

        struct IdentifyResponse: Decodable {
            struct Result: Decodable {
                let layerName: String?
                let value: String?
                let attributes: [String: JSONScalar]?
            }
            let results: [Result]?
        }

        guard let response = try? JSONDecoder().decode(IdentifyResponse.self, from: data),
              let results = response.results else {
            return []
        }

        return results.map { result in
            let attributes = result.attributes ?? [:]
            let name = ["nazev2", "nazev", "NAZEV", "Name", "name", "popis"]
                .compactMap { attributes[$0]?.stringValue }
                .first ?? result.value
            let classification = Self.classify(
                layerName: result.layerName,
                fallback: (service.category, service.verdict)
            )
            return CzechFeatureInfoRecord(
                serviceID: service.serviceName,
                name: name,
                detail: result.layerName,
                category: classification.category,
                verdict: classification.verdict
            )
        }
    }
}

struct CzechZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let czechRecord = record as? CzechFeatureInfoRecord else {
                return nil
            }
            return ZoneFeature(
                category: czechRecord.category,
                restrictionLevel: czechRecord.verdict,
                name: czechRecord.name,
                sourceDeclaredType: czechRecord.detail,
                sourceDeclaredRestriction: nil,
                lowerLimit: nil,
                upperLimit: nil,
                legalReference: nil,
                source: SourceProvenance(providerID: czechRecord.providerID, sourceLayerID: czechRecord.serviceID),
                restrictionSourceLanguage: nil
            )
        }
    }
}
