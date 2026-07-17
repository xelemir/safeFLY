//
//  ProtectedAreasService.swift
//  safeFLY
//
//  EU-wide nature-reserve overlay via the European Environment Agency's Natura 2000 service on
//  bio.discomap.eea.europa.eu. It fills a real gap: Austria, Belgium, the Netherlands and Sweden
//  do NOT publish nature reserves in their national drone feeds (verified against the live data:
//  Austria's Austro Control feed carries 2 NATURE zones and both are AIP restricted areas rather
//  than the reserve network, Belgium's skeyes WFS has no nature class at all among its 38 type
//  codes, the Netherlands ships exactly one (the Waddenzee), and Sweden's AIP carries 7 of its
//  ~30 national parks as R-areas and none of its ~5,700 naturreservat), so this EEA-attributed
//  provider covers exactly those four countries.
//
//  Germany, Switzerland, Czechia and Denmark already ship reserves and are excluded to avoid
//  overlap. Finland and Luxembourg are excluded on the same principle as each other: a missing
//  reserve layer is only worth backfilling where a restriction is known to exist. Finnish nature
//  areas are generally open to drones under Everyman's Right (Metsähallitus), and no Luxembourg
//  rule restricting drone overflight of réserves naturelles could be confirmed. Without one, the
//  layer would wash the country in a `conditional` verdict it cannot substantiate, which is worse
//  than showing nothing.
//
//  Belgium matters most of the set: Wallonia bans drone overflight of every designated nature
//  reserve outright (Nature Conservation Law of 12 July 1973, art. 11, as amended by the Decree
//  of 14 February 2019), and Flanders prohibits low flying over recognised reserves
//  (Natuurdecreet art. 35 §2 12°), yet skeyes publishes none of it.
//
//  One instance is registered *per country* (each scoped to that country's outline) rather than
//  a single shared session, so the user can enable the nature layer in one country without it
//  switching on in the others.
//
//  Both rendering and querying go through ArcGIS REST: `export` with a `dynamicLayers` restyle
//  for the overlay image, and `identify` for point queries (clean JSON, no CRS pixel math),
//  matching how the other ArcGIS-backed providers here query. The shared WMS plumbing is kept
//  only for the status probe. See `dynamicLayersJSON` for why the EEA's own style could not be
//  used, and `wmsLayerID` / `restLayerID` for the layer-numbering trap between the two APIs.
//
//  Being inside Natura 2000 does not uniformly ban drones (the rule is national nature-protection
//  law, permit-based and often prohibited), so every match is a `conditional` verdict carrying
//  that country's own advisory, never a green all-clear.
//

import Foundation

struct ProtectedAreaFeatureInfoRecord: ProviderRawRecord {
    let providerID: String
    let siteName: String?
    let siteType: String?
}

final class ProtectedAreasProvider: WMSBackedProvider, @unchecked Sendable {
    nonisolated static let datasetID = "nature.protected-areas"

    // The EEA publishes the same three layers through WMS and through ArcGIS REST, but numbers
    // them in the OPPOSITE order. This is a trap:
    //
    //          WMS                                 REST
    //   0      Habitats AND Birds (full set)       Habitats only
    //   1      Birds (SPA)                         Birds (SPA)
    //   2      Habitats only                       Habitats AND Birds (full set)
    //
    // One shared constant for both APIs previously drew the full set while querying only the
    // Habitats subset, so every Birds-Directive-only site painted on the map and then returned
    // nothing when tapped: 537 of 7612 sites across the five countries (21% of the Netherlands,
    // 18% of Luxembourg), including Haff Réimech. Keep the two numberings apart.
    //
    // Rendering and querying both go through REST now, so `wmsLayerID` is only used by the
    // catalog's status probe, which is the one remaining caller that speaks WMS.
    nonisolated static let wmsLayerID = "0"   // WMS numbering: Habitats and Birds Directive Sites.
    nonisolated static let restLayerID = "2"  // REST numbering: Habitats and Birds Directive Sites.

    nonisolated static let restBaseURL =
        "https://bio.discomap.eea.europa.eu/arcgis/rest/services/ProtectedSites/Natura2000Sites/MapServer"

    // Stable per-country provider ids (also the settings navigation ids).
    nonisolated static let austriaID = "eu-protected-areas-at"
    nonisolated static let belgiumID = "eu-protected-areas-be"
    nonisolated static let netherlandsID = "eu-protected-areas-nl"
    nonisolated static let swedenID = "eu-protected-areas-se"

    // Each country's Natura 2000 advisory, keyed by provider id. Presence in Natura 2000 does
    // not itself ban drones anywhere: the rule is national (or, in Belgium, regional) nature
    // law, and it differs enough per country that one shared sentence was misleading.
    nonisolated static let noteKeysByProviderID: [String: String] = [
        austriaID: "EU.NOTE.PROTECTED_AREA.AT",
        belgiumID: "EU.NOTE.PROTECTED_AREA.BE",
        netherlandsID: "EU.NOTE.PROTECTED_AREA.NL",
        swedenID: "EU.NOTE.PROTECTED_AREA.SE"
    ]

    nonisolated let id: String
    nonisolated let coverage: CountryCoverage?
    nonisolated let catalog: WMSDatasetCatalog

    // Each instance is scoped to one country's outline so it toggles, renders and gates
    // independently of the same layer in the neighbouring countries.
    nonisolated init(id: String, country: CountryCoverage) {
        self.id = id
        self.coverage = country
        let box = country.boundingBox
        self.catalog = WMSDatasetCatalog(
            baseURL: "https://bio.discomap.eea.europa.eu/arcgis/services/ProtectedSites/Natura2000Sites/MapServer/WMSServer",
            definitions: [
                .make(
                    id: ProtectedAreasProvider.datasetID,
                    title: "Nature Reserves",
                    groupTitle: "Nature",
                    layerIDs: [ProtectedAreasProvider.wmsLayerID]
                )
            ],
            coverageBounds: WMSDatasetCatalog.CoverageBounds(
                minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon
            ),
            coverage: country,
            // The EEA ArcGIS WMS, like the Czech one, is served in web-mercator for GetMap.
            crs: "EPSG:3857"
        )
    }

    // The registered per-country instances.
    nonisolated static func austria() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: austriaID, country: CountryBoundaries.austria)
    }
    nonisolated static func belgium() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: belgiumID, country: CountryBoundaries.belgium)
    }
    nonisolated static func netherlands() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: netherlandsID, country: CountryBoundaries.netherlands)
    }
    nonisolated static func sweden() -> ProtectedAreasProvider {
        ProtectedAreasProvider(id: swedenID, country: CountryBoundaries.sweden)
    }

    nonisolated var displayName: String {
        NSLocalizedString("Protected Areas (Europe)", comment: "EU protected areas provider display name")
    }
    nonisolated var attributionName: String { "EEA" }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    // Unused: `query` is overridden to hit the ArcGIS `identify` REST endpoint.
    nonisolated var queryInfoFormat: String { "application/json" }

    // Opacity lives in the symbol's own alpha (see `dynamicLayersJSON`), so the overlay is drawn
    // at full strength. This previously sat at 0.35 to "keep it faint", on the assumption there
    // was a fill to soften; there was not. The EEA's default style is a thin outline and nothing
    // else, so the dimming only made an already-invisible hairline fainter.
    nonisolated var renderOverlayOpacity: Double { 1.0 }

    // The rendered image spans the whole requested bbox, which reaches into neighbouring
    // countries, so clip it to this instance's own outline. Without this the Austrian layer would
    // paint over Bavaria.
    nonisolated var renderClipPolygons: [[MapCoordinate]]? {
        coverage?.polygons.map { ring in
            ring.map { MapCoordinate(latitude: $0[1], longitude: $0[0]) }
        }
    }

    // Renders through the ArcGIS REST `export` endpoint rather than WMS GetMap, restyling the
    // layer server-side with `dynamicLayers`. The EEA's own style is a thin purple outline with
    // no fill: nearly invisible, in a colour used nowhere else in the app, and easily mistaken
    // for Apple's woodland shading, which made the layer look broken even when it worked.
    //
    // Deliberately still an image rather than the vector `/query` endpoint: one styled image of
    // Sweden country-wide is ~1.2 s, while the same viewport as GeoJSON is 5,282 features and
    // 3.4 MB and takes ~25 s. An image also costs the same at every zoom.
    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        guard
            selectedDatasetIDs.contains(ProtectedAreasProvider.datasetID),
            status.status(for: ProtectedAreasProvider.datasetID) != .unavailable,
            let imageURL = exportURL(for: request)
        else {
            return []
        }

        return [
            .wmsImage(WMSRenderPayload(
                id: "\(id).nature-overlay",
                imageURL: imageURL,
                region: request.region,
                opacity: renderOverlayOpacity,
                clipPolygons: renderClipPolygons
            ))
        ]
    }

    // Web-mercator in and out, matching what the map overlay expects (and what the WMS path used
    // via `crs: EPSG:3857`); an EPSG:4326 image would be stretched over a mercator viewport.
    nonisolated private func exportURL(for request: ProviderRenderRequest) -> URL? {
        let region = request.region
        let minCorner = WMSDatasetCatalog.mercator(
            lon: region.center.longitude - region.longitudeDelta / 2,
            lat: region.center.latitude - region.latitudeDelta / 2
        )
        let maxCorner = WMSDatasetCatalog.mercator(
            lon: region.center.longitude + region.longitudeDelta / 2,
            lat: region.center.latitude + region.latitudeDelta / 2
        )

        let mercatorWidth = maxCorner.x - minCorner.x
        let mercatorHeight = maxCorner.y - minCorner.y
        guard mercatorWidth > 0, mercatorHeight > 0 else { return nil }

        let size = ProtectedAreasProvider.imageSize(
            forMercatorAspect: mercatorHeight / mercatorWidth,
            viewport: request.viewportSize
        )

        var components = URLComponents(string: "\(ProtectedAreasProvider.restBaseURL)/export")
        components?.queryItems = [
            URLQueryItem(name: "bbox", value: "\(minCorner.x),\(minCorner.y),\(maxCorner.x),\(maxCorner.y)"),
            URLQueryItem(name: "bboxSR", value: "3857"),
            URLQueryItem(name: "imageSR", value: "3857"),
            URLQueryItem(name: "size", value: "\(size.width),\(size.height)"),
            URLQueryItem(name: "dynamicLayers", value: ProtectedAreasProvider.dynamicLayersJSON),
            URLQueryItem(name: "format", value: "png32"),
            URLQueryItem(name: "transparent", value: "true"),
            URLQueryItem(name: "f", value: "image")
        ]
        return components?.url
    }

    // The requested image must have the same aspect ratio as the requested bbox.
    //
    // ArcGIS `export` does not simply honour a bbox: when the image's aspect ratio disagrees with
    // the bbox's, it silently *expands the extent* to fit and hands back a picture of more ground
    // than was asked for (a phone-shaped 390x700 request over a wide bbox came back stretched by
    // ~23 km vertically). The overlay is then drawn into the region we asked for, so it lands
    // offset, and because the size of the mismatch depends on latitude and zoom, the offset
    // changes as the map moves: the layer visibly drifts while panning. WMS GetMap has no such
    // behaviour (it stretches to fit), which is why this only appeared when rendering moved to
    // `export`. Matching the aspects brings the returned extent back to within a metre, and the
    // residue is just integer-pixel rounding, far below one pixel on screen.
    nonisolated private static func imageSize(
        forMercatorAspect aspect: Double,
        viewport: MapViewportSize
    ) -> (width: Int, height: Int) {
        // The service's advertised maxImageWidth/maxImageHeight.
        let maxSide = 4096.0

        var width = Double(max(viewport.width, 1))
        var height = (width * aspect).rounded()

        // Clamp by scaling, never by cropping one side: capping a single dimension would
        // reintroduce the very aspect mismatch this exists to avoid.
        if height > maxSide {
            height = maxSide
            width = (height / aspect).rounded()
        }
        if width > maxSide {
            width = maxSide
            height = (width * aspect).rounded()
        }

        return (Int(max(width, 1)), Int(max(height, 1)))
    }

    // Overrides the EEA renderer with the app's own, so the overlay stays in step with the rest
    // of the map if that palette is ever retuned. Green (not the amber of its `conditional`
    // verdict) to match the leaf these zones carry in the zone list; the outline is what keeps it
    // legible over Apple's woodland shading. See `ED269RenderStyle.natureReserve`.
    nonisolated private static var dynamicLayersJSON: String {
        let style = ED269RenderStyle.natureReserve
        let fill = esriColor(hex: style.fillColor, opacity: style.fillOpacity)
        let stroke = esriColor(hex: style.strokeColor, opacity: style.strokeOpacity)
        return "[{\"id\":\(restLayerID),"
            + "\"source\":{\"type\":\"mapLayer\",\"mapLayerId\":\(restLayerID)},"
            + "\"drawingInfo\":{\"renderer\":{\"type\":\"simple\",\"symbol\":"
            + "{\"type\":\"esriSFS\",\"style\":\"esriSFSSolid\",\"color\":\(fill),"
            + "\"outline\":{\"type\":\"esriSLS\",\"style\":\"esriSLSSolid\",\"color\":\(stroke),\"width\":1}}}}}]"
    }

    // "F59E0B" + 0.25 -> "[245,158,11,64]", the [r,g,b,a] array ArcGIS symbols expect.
    nonisolated private static func esriColor(hex: String, opacity: Double) -> String {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let red = (value >> 16) & 0xFF
        let green = (value >> 8) & 0xFF
        let blue = value & 0xFF
        let alpha = Int((opacity * 255).rounded())
        return "[\(red),\(green),\(blue),\(alpha)]"
    }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        coverage?.intersects(region) ?? false
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Natura 2000 network (EEA)", comment: "EEA Natura 2000 reference link title"),
                url: URL(string: "https://natura2000.eea.europa.eu/")!
            )
        ]
    }

    // Queries the EEA ArcGIS `identify` endpoint rather than WMS GetFeatureInfo: it takes the
    // tap as lon/lat directly (no CRS/pixel conversion) and returns clean JSON. Coverage and
    // layer-selection gating mirror the shared WMS query.
    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard catalog.isWithinCoverage(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        guard
            selectedDatasetIDs.contains(ProtectedAreasProvider.datasetID),
            status.status(for: ProtectedAreasProvider.datasetID) != .unavailable
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

        var components = URLComponents(string: "https://bio.discomap.eea.europa.eu/arcgis/rest/services/ProtectedSites/Natura2000Sites/MapServer/identify")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "{\"x\":\(request.coordinate.longitude),\"y\":\(request.coordinate.latitude)}"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "sr", value: "4326"),
            URLQueryItem(name: "layers", value: "all:\(ProtectedAreasProvider.restLayerID)"),
            URLQueryItem(name: "tolerance", value: "3"),
            URLQueryItem(name: "mapExtent", value: "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            URLQueryItem(name: "imageDisplay", value: "\(request.viewportSize.width),\(request.viewportSize.height),96"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json")
        ]
        return components?.url
    }

    nonisolated func parseFeatureInfo(_ data: Data) -> ProviderQueryOutcome {
        struct IdentifyResponse: Decodable {
            struct Result: Decodable {
                let value: String?
                let attributes: [String: JSONScalar]?
            }
            let results: [Result]?
        }

        guard let response = try? JSONDecoder().decode(IdentifyResponse.self, from: data) else {
            return .unavailable(reason: .invalidResponse)
        }
        guard let results = response.results, !results.isEmpty else {
            return .noMatches
        }

        let records = results.map { result -> ProtectedAreaFeatureInfoRecord in
            let attributes = result.attributes ?? [:]
            let name = ["SITE_NAME", "SITENAME", "Site Name", "NAME", "name"]
                .compactMap { attributes[$0]?.stringValue }
                .first ?? result.value
            let type = ["SITETYPE", "SITE_TYPE", "Site Type"]
                .compactMap { attributes[$0]?.stringValue }
                .first
            return ProtectedAreaFeatureInfoRecord(providerID: id, siteName: name, siteType: type)
        }

        return .matches(records: records.map { $0 as any ProviderRawRecord })
    }
}

struct ProtectedAreasZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let area = record as? ProtectedAreaFeatureInfoRecord else {
                return nil
            }
            // The advisory is specific to the country whose instance matched: the reserve rule
            // is national (regional in Belgium) law, not an EU one. Falls back to the generic
            // Natura 2000 note if an instance is ever registered without its own text.
            let noteKey = ProtectedAreasProvider.noteKeysByProviderID[area.providerID]
                ?? "EU.NOTE.PROTECTED_AREA"

            return ZoneFeature(
                category: .natureReserve,
                // Presence in Natura 2000 does not uniformly ban drones (national nature law
                // decides), so this is conditional (permit/often-prohibited), never allowed.
                restrictionLevel: .conditional,
                name: area.siteName,
                sourceDeclaredType: area.siteType,
                sourceDeclaredRestriction: NSLocalizedString(noteKey, comment: "Natura 2000 advisory for one country"),
                lowerLimit: nil,
                upperLimit: nil,
                legalReference: nil,
                source: SourceProvenance(providerID: area.providerID, sourceLayerID: ProtectedAreasProvider.restLayerID),
                restrictionSourceLanguage: nil
            )
        }
    }
}
