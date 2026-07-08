//
//  WMSProvider.swift
//  safeFLY
//
//  Shared base for providers backed by an OGC WMS service. It owns the GetMap rendering
//  and GetFeatureInfo query *transport* (URL building via the catalog, coverage gating,
//  fetching), so concrete providers only declare their catalog and parse their own
//  GetFeatureInfo response (text/plain vs GeoJSON differ per service).
//

import Foundation

protocol WMSBackedProvider: GeospatialProvider {
    nonisolated var catalog: WMSDatasetCatalog { get }

    // The `info_format` requested from GetFeatureInfo (e.g. "text/plain", "application/json").
    nonisolated var queryInfoFormat: String { get }

    // Parses the raw GetFeatureInfo body into an outcome. Each service has its own schema.
    nonisolated func parseFeatureInfo(_ data: Data) -> ProviderQueryOutcome

    // Coarse country outline used only for map attribution. `nil` means the provider is not
    // geo-gated for attribution (e.g. DIPUL, which underpins the whole app).
    nonisolated var attributionOutline: [(lat: Double, lon: Double)]? { get }

    // Opacity applied to the rendered WMS overlay image.
    nonisolated var renderOverlayOpacity: Double { get }

    // Optional country outline the rendered overlay is clipped to. Only needed for layers whose
    // WMS image spans more than the countries the provider serves (e.g. the EU-wide EEA nature
    // layer); country-scoped WMS layers leave this nil and render unclipped.
    nonisolated var renderClipPolygons: [[MapCoordinate]]? { get }
}

extension WMSBackedProvider {
    nonisolated var datasets: [ProviderDataset] {
        catalog.datasets
    }

    nonisolated var attributionOutline: [(lat: Double, lon: Double)]? { nil }
    nonisolated var renderOverlayOpacity: Double { 0.8 }
    nonisolated var renderClipPolygons: [[MapCoordinate]]? { nil }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        guard let attributionOutline else {
            return true
        }
        return region.centerIsInside(attributionOutline)
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        await catalog.probeStatus()
    }

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        let encodedLayers = catalog.encodedLayerList(for: selectedDatasetIDs, status: status, operation: .render)
        guard !encodedLayers.isEmpty else {
            return []
        }

        guard let imageURL = catalog.getMapURL(
            region: request.region,
            viewportSize: request.viewportSize,
            encodedLayers: encodedLayers
        ) else {
            return []
        }

        return [
            .wmsImage(
                WMSRenderPayload(
                    id: "\(id).wms-overlay",
                    imageURL: imageURL,
                    region: request.region,
                    opacity: renderOverlayOpacity,
                    clipPolygons: renderClipPolygons
                )
            )
        ]
    }

    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard catalog.isWithinCoverage(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        let encodedLayers = catalog.encodedLayerList(for: selectedDatasetIDs, status: status, operation: .query)
        guard !encodedLayers.isEmpty else {
            return .unavailable(reason: .providerNoData)
        }

        guard let url = catalog.getFeatureInfoURL(
            coordinate: request.coordinate,
            region: request.region,
            viewportSize: request.viewportSize,
            encodedLayers: encodedLayers,
            infoFormat: queryInfoFormat
        ) else {
            return .unavailable(reason: .invalidResponse)
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return parseFeatureInfo(data)
        } catch {
            return .unavailable(reason: .requestFailed(details: error.localizedDescription))
        }
    }
}
