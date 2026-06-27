//
//  WMSDatasetCatalog.swift
//  safeFLY
//
//  Shared WMS plumbing used by geospatial providers backed by an OGC WMS service
//  (GetMap for rendering, GetFeatureInfo for point queries). It owns the dataset/layer
//  catalog, coverage gating, broken-layer-aware layer selection, and per-layer status
//  probing. Providers stay thin: they supply the catalog config and parse their own
//  GetFeatureInfo responses (which differ per service, e.g. text/plain vs GeoJSON).
//

import Foundation
import UIKit

struct WMSDatasetCatalog: Sendable {
    struct DatasetDefinition: Sendable {
        let dataset: ProviderDataset
        let layerIDs: [String]

        // Factory for the common case: a renderable + queryable dataset whose title and
        // group come from the string table. Keeps provider catalogs declarative.
        nonisolated static func make(
            id: String,
            title: String,
            groupTitle: String,
            layerIDs: [String],
            supportsRendering: Bool = true,
            supportsQuerying: Bool = true,
            isSelectedByDefault: Bool = true
        ) -> DatasetDefinition {
            DatasetDefinition(
                dataset: ProviderDataset(
                    id: id,
                    presentation: localizedProviderPresentation(title: title, groupTitle: groupTitle),
                    capabilities: ProviderDatasetCapabilities(
                        supportsRendering: supportsRendering,
                        supportsQuerying: supportsQuerying
                    ),
                    isSelectedByDefault: isSelectedByDefault
                ),
                layerIDs: layerIDs
            )
        }
    }

    struct CoverageBounds: Sendable {
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double
    }

    enum Operation: Sendable {
        case render
        case query
    }

    let baseURL: String
    let definitions: [DatasetDefinition]
    let coverageBounds: CoverageBounds
    // Real national outline. When set, a point must fall inside the actual border (not just
    // the rectangular `coverageBounds`) for a query to fire, so taps in neighbouring
    // countries that overlap the bounding box never trigger a pointless GetFeatureInfo call.
    let coverage: CountryCoverage?
    // The CRS sent to the WMS. Defaults to EPSG:4326 (WMS 1.3.0 lat,lon axis order). Some
    // servers — e.g. the ArcGIS WMS backing the Czech provider — reject 4326 for GetMap and
    // require EPSG:3857 (web-mercator metres, x,y axis order).
    let crs: String

    nonisolated init(
        baseURL: String,
        definitions: [DatasetDefinition],
        coverageBounds: CoverageBounds,
        coverage: CountryCoverage? = nil,
        crs: String = "EPSG:4326"
    ) {
        self.baseURL = baseURL
        self.definitions = definitions
        self.coverageBounds = coverageBounds
        self.coverage = coverage
        self.crs = crs
    }

    private enum LayerStatus: Equatable {
        case working
        case broken
        case networkError
    }

    nonisolated var datasets: [ProviderDataset] {
        definitions.map(\.dataset)
    }

    nonisolated func isWithinCoverage(_ coordinate: MapCoordinate) -> Bool {
        if let coverage {
            return coverage.contains(coordinate)
        }

        return coordinate.latitude >= coverageBounds.minLat &&
            coordinate.latitude <= coverageBounds.maxLat &&
            coordinate.longitude >= coverageBounds.minLon &&
            coordinate.longitude <= coverageBounds.maxLon
    }

    // Comma-separated, percent-encoded layer list for the selected datasets, with fully
    // unavailable datasets and individually broken layers removed so one failing layer
    // never blanks the rest of the bundled request.
    nonisolated func encodedLayerList(
        for selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot,
        operation: Operation
    ) -> String {
        let layers = definitions
            .filter { selectedDatasetIDs.contains($0.dataset.id) }
            .filter {
                switch operation {
                case .render:
                    return $0.dataset.capabilities.supportsRendering
                case .query:
                    return $0.dataset.capabilities.supportsQuerying
                }
            }
            .flatMap { definition -> [String] in
                if status.status(for: definition.dataset.id) == .unavailable {
                    return []
                }

                return definition.layerIDs.filter { !status.isLayerBroken($0) }
            }

        return layers
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .joined(separator: ",")
    }

    nonisolated func getMapURL(
        region: MapRegion,
        viewportSize: MapViewportSize,
        encodedLayers: String
    ) -> URL? {
        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetMap&" +
            "layers=\(encodedLayers)&" +
            "styles=&" +
            "crs=\(crs)&" +
            "bbox=\(bboxString(for: region))&" +
            "width=\(viewportSize.width)&" +
            "height=\(viewportSize.height)&" +
            "format=image/png&" +
            "transparent=true"

        return URL(string: urlString)
    }

    // WMS 1.3.0 axis order is CRS-dependent: EPSG:4326 is lat,lon (degrees); EPSG:3857 is
    // x,y (web-mercator metres). The bbox string is formatted accordingly.
    nonisolated private func bboxString(for region: MapRegion) -> String {
        let box = boundingBox(for: region)
        if crs == "EPSG:3857" {
            let min = Self.mercator(lon: box.minLon, lat: box.minLat)
            let max = Self.mercator(lon: box.maxLon, lat: box.maxLat)
            return "\(min.x),\(min.y),\(max.x),\(max.y)"
        }
        return "\(box.minLat),\(box.minLon),\(box.maxLat),\(box.maxLon)"
    }

    nonisolated static func mercator(lon: Double, lat: Double) -> (x: Double, y: Double) {
        let x = lon * 20_037_508.34 / 180.0
        let clampedLat = Swift.max(-85.05112878, Swift.min(85.05112878, lat))
        var y = log(tan((90.0 + clampedLat) * .pi / 360.0)) / (.pi / 180.0)
        y = y * 20_037_508.34 / 180.0
        return (x, y)
    }

    nonisolated func getFeatureInfoURL(
        coordinate: MapCoordinate,
        region: MapRegion,
        viewportSize: MapViewportSize,
        encodedLayers: String,
        infoFormat: String,
        featureCount: Int = 10
    ) -> URL? {
        let box = boundingBox(for: region)
        let x = Int((coordinate.longitude - box.minLon) / (box.maxLon - box.minLon) * Double(viewportSize.width))
        let y = Int((box.maxLat - coordinate.latitude) / (box.maxLat - box.minLat) * Double(viewportSize.height))
        let encodedInfoFormat = infoFormat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? infoFormat
        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetFeatureInfo&" +
            "layers=\(encodedLayers)&" +
            "query_layers=\(encodedLayers)&" +
            "styles=&" +
            "crs=\(crs)&" +
            "bbox=\(bboxString(for: region))&" +
            "width=\(viewportSize.width)&" +
            "height=\(viewportSize.height)&" +
            "i=\(x)&" +
            "j=\(y)&" +
            "format=image/png&" +
            "info_format=\(encodedInfoFormat)&" +
            "feature_count=\(featureCount)"

        return URL(string: urlString)
    }

    // Probes every layer individually and reduces the results into a snapshot carrying both
    // dataset-level availability and the set of individually broken layer IDs.
    nonisolated func probeStatus() async -> ProviderStatusSnapshot {
        let allLayers = Set(definitions.flatMap(\.layerIDs))
        var brokenLayers = Set<String>()
        var networkErrorCount = 0
        var workingCount = 0

        await withTaskGroup(of: (String, LayerStatus).self) { group in
            for layer in allLayers {
                group.addTask {
                    (layer, await self.testLayer(layer))
                }
            }

            for await (layer, status) in group {
                switch status {
                case .working:
                    workingCount += 1
                case .broken:
                    brokenLayers.insert(layer)
                case .networkError:
                    networkErrorCount += 1
                }
            }
        }

        // Likely offline: don't flag layers as broken on transient network failures.
        if networkErrorCount > 5 || (workingCount == 0 && networkErrorCount > 0) {
            return ProviderStatusSnapshot(
                providerStatus: .unavailable,
                datasetStatuses: Dictionary(uniqueKeysWithValues: datasets.map { ($0.id, .unknown) }),
                brokenLayerIDs: [],
                refreshedAt: Date()
            )
        }

        let datasetStatuses = Dictionary(uniqueKeysWithValues: definitions.map { definition -> (String, ProviderAvailabilityStatus) in
            let availableLayerCount = definition.layerIDs.filter { !brokenLayers.contains($0) }.count
            let status: ProviderAvailabilityStatus
            if availableLayerCount == definition.layerIDs.count {
                status = .available
            } else if availableLayerCount == 0 {
                status = .unavailable
            } else {
                status = .degraded
            }
            return (definition.dataset.id, status)
        })

        let providerStatus: ProviderAvailabilityStatus
        if datasetStatuses.values.allSatisfy({ $0 == .available }) {
            providerStatus = .available
        } else if datasetStatuses.values.contains(where: { $0 == .available || $0 == .degraded }) {
            providerStatus = .degraded
        } else {
            providerStatus = .unavailable
        }

        return ProviderStatusSnapshot(
            providerStatus: providerStatus,
            datasetStatuses: datasetStatuses,
            brokenLayerIDs: brokenLayers,
            refreshedAt: Date()
        )
    }

    private nonisolated func boundingBox(for region: MapRegion) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (
            minLat: region.center.latitude - (region.latitudeDelta / 2),
            maxLat: region.center.latitude + (region.latitudeDelta / 2),
            minLon: region.center.longitude - (region.longitudeDelta / 2),
            maxLon: region.center.longitude + (region.longitudeDelta / 2)
        )
    }

    private nonisolated func testLayer(_ layer: String) async -> LayerStatus {
        let encodedLayer = layer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? layer
        let testLat = (coverageBounds.minLat + coverageBounds.maxLat) / 2
        let testLon = (coverageBounds.minLon + coverageBounds.maxLon) / 2
        let testBBox: String
        if crs == "EPSG:3857" {
            let min = Self.mercator(lon: testLon, lat: testLat)
            let max = Self.mercator(lon: testLon + 0.1, lat: testLat + 0.1)
            testBBox = "\(min.x),\(min.y),\(max.x),\(max.y)"
        } else {
            testBBox = "\(testLat),\(testLon),\(testLat + 0.1),\(testLon + 0.1)"
        }
        let urlString = "\(baseURL)?" +
            "service=WMS&version=1.3.0&request=GetMap&" +
            "layers=\(encodedLayer)&styles=&crs=\(crs)&" +
            "bbox=\(testBBox)&" +
            "width=1&height=1&format=image/png&transparent=true"

        guard let url = URL(string: urlString) else { return .broken }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .broken }

            if httpResponse.statusCode == 200 {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("image/png") && UIImage(data: data) != nil {
                    return .working
                }
                if contentType.contains("xml") || contentType.contains("text") {
                    return .broken
                }
            } else if httpResponse.statusCode >= 400 && httpResponse.statusCode < 600 {
                return .broken
            }

            return .networkError
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet,
                     NSURLErrorNetworkConnectionLost,
                     NSURLErrorTimedOut,
                     NSURLErrorCannotFindHost,
                     NSURLErrorCannotConnectToHost:
                    return .networkError
                default:
                    break
                }
            }
            return .broken
        }
    }
}
