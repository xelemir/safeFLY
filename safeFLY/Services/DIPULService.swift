//
//  DIPULService.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import Foundation
import CoreLocation
import MapKit
import UIKit

nonisolated private func localizedProviderPresentation(title: String, groupTitle: String) -> ProviderDatasetPresentation {
    ProviderDatasetPresentation(
        title: NSLocalizedString(title, comment: "Provider dataset title"),
        groupTitle: NSLocalizedString(groupTitle, comment: "Provider dataset group title")
    )
}

struct DIPULFeatureInfoRecord: ProviderRawRecord {
    let layerName: String
    let name: String?
    let sourceDeclaredType: String?
    let sourceDeclaredRestriction: String?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let legalReference: String?

    nonisolated var providerID: String { DIPULProvider.providerID }
}

final class DIPULProvider: GeospatialProvider, @unchecked Sendable {
    nonisolated static let providerID = "dipul"

    private enum LayerStatus: Equatable {
        case working
        case broken
        case networkError
    }

    private struct DatasetDefinition {
        let dataset: ProviderDataset
        let layerIDs: [String]
    }

    nonisolated let id = DIPULProvider.providerID
    nonisolated let displayName = "DIPUL"
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated private let baseURL = "https://uas-betrieb.de/geoservices/dipul/wms"
    nonisolated private let coverageBounds = (
        minLat: 47.0,
        maxLat: 55.2,
        minLon: 5.5,
        maxLon: 15.6
    )
    nonisolated private let datasetDefinitions: [DatasetDefinition] = [
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "aviation.airports",
                presentation: localizedProviderPresentation(title: "Airports", groupTitle: "Aviation"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:flughaefen"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "aviation.aerodromes",
                presentation: localizedProviderPresentation(title: "Aerodromes", groupTitle: "Aviation"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:flugplaetze"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "aviation.control-zones",
                presentation: localizedProviderPresentation(title: "Control Zones", groupTitle: "Aviation"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:kontrollzonen"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "aviation.restricted-areas",
                presentation: localizedProviderPresentation(title: "Restricted Areas", groupTitle: "Aviation"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:flugbeschraenkungsgebiete"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "aviation.temporary-restrictions",
                presentation: localizedProviderPresentation(title: "Temporary Restrictions", groupTitle: "Aviation"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: [
                "dipul:temporaere_betriebseinschraenkungen",
                "dipul:inaktive_temporaere_betriebseinschraenkungen"
            ]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "aviation.model-flying-fields",
                presentation: localizedProviderPresentation(title: "Model Flying Fields", groupTitle: "Aviation"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:modellflugplaetze"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "infrastructure.motorways",
                presentation: localizedProviderPresentation(title: "Motorways", groupTitle: "Infrastructure"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:bundesautobahnen"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "infrastructure.highways",
                presentation: localizedProviderPresentation(title: "Highways", groupTitle: "Infrastructure"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:bundesstrassen"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "infrastructure.railways",
                presentation: localizedProviderPresentation(title: "Railways", groupTitle: "Infrastructure"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:bahnanlagen"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "infrastructure.waterways",
                presentation: localizedProviderPresentation(title: "Waterways", groupTitle: "Infrastructure"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: [
                "dipul:binnenwasserstrassen",
                "dipul:seewasserstrassen",
                "dipul:schifffahrtsanlagen"
            ]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "infrastructure.industrial-facilities",
                presentation: localizedProviderPresentation(title: "Industrial Facilities", groupTitle: "Infrastructure"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: [
                "dipul:industrieanlagen",
                "dipul:kraftwerke",
                "dipul:umspannwerke",
                "dipul:stromleitungen",
                "dipul:windkraftanlagen"
            ]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "restricted.residential-property",
                presentation: localizedProviderPresentation(title: "Residential Property", groupTitle: "Restricted Areas"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:wohngrundstuecke"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "restricted.recreational-areas",
                presentation: localizedProviderPresentation(title: "Recreational Areas", groupTitle: "Restricted Areas"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: ["dipul:freibaeder"]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "restricted.government-buildings",
                presentation: localizedProviderPresentation(title: "Government Buildings", groupTitle: "Restricted Areas"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: [
                "dipul:justizvollzugsanstalten",
                "dipul:militaerische_anlagen",
                "dipul:labore",
                "dipul:behoerden",
                "dipul:diplomatische_vertretungen",
                "dipul:internationale_organisationen",
                "dipul:polizei",
                "dipul:sicherheitsbehoerden",
                "dipul:krankenhaeuser"
            ]
        ),
        DatasetDefinition(
            dataset: ProviderDataset(
                id: "restricted.nature-reserves",
                presentation: localizedProviderPresentation(title: "Nature Reserves", groupTitle: "Restricted Areas"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            layerIDs: [
                "dipul:nationalparks",
                "dipul:naturschutzgebiete",
                "dipul:ffh-gebiete",
                "dipul:vogelschutzgebiete"
            ]
        )
    ]

    nonisolated var datasets: [ProviderDataset] {
        datasetDefinitions.map(\.dataset)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("DFS DIPUL Datasource", comment: "Provider reference link title"),
                url: URL(string: "https://uas-betrieb.dfs.de/homepage/")!
            )
        ]
    }

    nonisolated private func testLayer(_ layer: String) async -> LayerStatus {
        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetMap&" +
            "layers=\(layer)&" +
            "styles=&" +
            "crs=EPSG:4326&" +
            "bbox=50.0,8.0,50.1,8.1&" +
            "width=1&" +
            "height=1&" +
            "format=image/png&" +
            "transparent=true"

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

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let allPossibleLayers = Set(datasetDefinitions.flatMap(\.layerIDs))
        var brokenLayers = Set<String>()
        var networkErrorCount = 0
        var workingCount = 0

        await withTaskGroup(of: (String, LayerStatus).self) { group in
            for layer in allPossibleLayers {
                group.addTask {
                    let status = await self.testLayer(layer)
                    return (layer, status)
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

        if networkErrorCount > 5 || (workingCount == 0 && networkErrorCount > 0) {
            return ProviderStatusSnapshot(
                providerStatus: .unavailable,
                datasetStatuses: Dictionary(uniqueKeysWithValues: datasets.map { ($0.id, .unknown) }),
                refreshedAt: Date()
            )
        }

        let datasetStatuses = Dictionary(uniqueKeysWithValues: datasetDefinitions.map { definition in
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

    nonisolated func renderPayloads(
        for request: ProviderRenderRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> [ProviderRenderPayload] {
        let encodedLayers = encodedLayerList(for: selectedDatasetIDs, status: status, operation: .render)
        guard !encodedLayers.isEmpty else {
            return []
        }

        let minLat = request.region.center.latitude - (request.region.latitudeDelta / 2)
        let maxLat = request.region.center.latitude + (request.region.latitudeDelta / 2)
        let minLon = request.region.center.longitude - (request.region.longitudeDelta / 2)
        let maxLon = request.region.center.longitude + (request.region.longitudeDelta / 2)
        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetMap&" +
            "layers=\(encodedLayers)&" +
            "styles=&" +
            "crs=EPSG:4326&" +
            "bbox=\(minLat),\(minLon),\(maxLat),\(maxLon)&" +
            "width=\(request.viewportSize.width)&" +
            "height=\(request.viewportSize.height)&" +
            "format=image/png&" +
            "transparent=true"

        guard let imageURL = URL(string: urlString) else {
            return []
        }

        return [
            .wmsImage(
                WMSRenderPayload(
                    id: "\(id).wms-overlay",
                    imageURL: imageURL,
                    region: request.region,
                    opacity: 0.8
                )
            )
        ]
    }

    nonisolated func query(
        for request: ProviderPointQueryRequest,
        selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot
    ) async -> ProviderQueryOutcome {
        guard isWithinCoverage(request.coordinate) else {
            return .unavailable(reason: .outsideCoverage)
        }

        let encodedLayers = encodedLayerList(for: selectedDatasetIDs, status: status, operation: .query)
        guard !encodedLayers.isEmpty else {
            return .unavailable(reason: .providerNoData)
        }

        let minLat = request.region.center.latitude - (request.region.latitudeDelta / 2)
        let maxLat = request.region.center.latitude + (request.region.latitudeDelta / 2)
        let minLon = request.region.center.longitude - (request.region.longitudeDelta / 2)
        let maxLon = request.region.center.longitude + (request.region.longitudeDelta / 2)
        let x = Int((request.coordinate.longitude - minLon) / (maxLon - minLon) * Double(request.viewportSize.width))
        let y = Int((maxLat - request.coordinate.latitude) / (maxLat - minLat) * Double(request.viewportSize.height))
        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetFeatureInfo&" +
            "layers=\(encodedLayers)&" +
            "query_layers=\(encodedLayers)&" +
            "styles=&" +
            "crs=EPSG:4326&" +
            "bbox=\(minLat),\(minLon),\(maxLat),\(maxLon)&" +
            "width=\(request.viewportSize.width)&" +
            "height=\(request.viewportSize.height)&" +
            "i=\(x)&" +
            "j=\(y)&" +
            "info_format=text/plain&" +
            "feature_count=10"

        guard let url = URL(string: urlString) else {
            return .unavailable(reason: .invalidResponse)
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let responseText = String(data: data, encoding: .utf8) else {
                return .unavailable(reason: .invalidResponse)
            }

            return parseFeatureInfo(responseText)
        } catch {
            return .unavailable(reason: .requestFailed(details: error.localizedDescription))
        }
    }

    private enum OperationKind {
        case render
        case query
    }

    nonisolated private func encodedLayerList(
        for selectedDatasetIDs: Set<String>,
        status: ProviderStatusSnapshot,
        operation: OperationKind
    ) -> String {
        let layers = datasetDefinitions
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

                // Drop individual layers known to be broken so one failing layer does
                // not take down the rest of the bundled WMS request (the sibling layers
                // in this dataset and every other selected dataset keep working).
                return definition.layerIDs.filter { !status.isLayerBroken($0) }
            }

        return layers
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .joined(separator: ",")
    }

    nonisolated private func parseFeatureInfo(_ text: String) -> ProviderQueryOutcome {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedText.isEmpty {
            return .unavailable(reason: .providerNoData)
        }

        if normalizedText.localizedCaseInsensitiveContains("no features were found") {
            return .noMatches
        }

        let lines = normalizedText.components(separatedBy: .newlines)
        var records: [DIPULFeatureInfoRecord] = []
        var currentFields: [String: String] = [:]
        var currentLayer: String?

        for line in lines {
            if line.contains("Results for FeatureType") {
                if !currentFields.isEmpty, let currentLayer {
                    records.append(createRecord(from: currentFields, layer: currentLayer))
                }

                currentLayer = extractLayerName(from: line)
                currentFields = [:]
                continue
            }

            if line.contains("--------------------------------------------") {
                if !currentFields.isEmpty, let currentLayer {
                    records.append(createRecord(from: currentFields, layer: currentLayer))
                    currentFields = [:]
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(" = ") {
                let parts = trimmed.components(separatedBy: " = ")
                if parts.count == 2 {
                    currentFields[parts[0]] = parts[1]
                }
            }
        }

        if !currentFields.isEmpty, let currentLayer {
            records.append(createRecord(from: currentFields, layer: currentLayer))
        }

        if records.isEmpty {
            return .unavailable(reason: .invalidResponse)
        }

        return .matches(records: records.map { $0 as any ProviderRawRecord })
    }

    nonisolated private func extractLayerName(from line: String) -> String? {
        guard let range = line.range(of: "dipul:") else {
            return nil
        }

        let afterPrefix = line[range.upperBound...]
        guard let endRange = afterPrefix.range(of: "'") else {
            return nil
        }

        return "dipul:\(afterPrefix[..<endRange.lowerBound])"
    }

    nonisolated private func createRecord(from data: [String: String], layer: String) -> DIPULFeatureInfoRecord {
        DIPULFeatureInfoRecord(
            layerName: layer,
            name: normalizedValue(data["name"]),
            sourceDeclaredType: normalizedValue(data["type"] ?? data["type_code"]),
            sourceDeclaredRestriction: normalizedValue(data["restriction"]),
            lowerLimit: makeAltitudeLimit(
                value: data["lower_limit_altitude"],
                unit: data["lower_limit_unit"],
                reference: data["lower_limit_reference"] ?? data["lower_limit_alt_ref"]
            ),
            upperLimit: makeAltitudeLimit(
                value: data["upper_limit_altitude"],
                unit: data["upper_limit_unit"],
                reference: data["upper_limit_reference"] ?? data["upper_limit_alt_ref"]
            ),
            legalReference: normalizedValue(data["legal_ref"])
        )
    }

    nonisolated private func makeAltitudeLimit(value: String?, unit: String?, reference: String?) -> AltitudeLimit? {
        guard let value = normalizedValue(value) else {
            return nil
        }

        return AltitudeLimit(
            value: value,
            unit: normalizedValue(unit) ?? "m",
            reference: normalizedValue(reference)
        )
    }

    nonisolated private func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else {
            return nil
        }
        return trimmed
    }

    nonisolated private func isWithinCoverage(_ coordinate: MapCoordinate) -> Bool {
        coordinate.latitude >= coverageBounds.minLat &&
            coordinate.latitude <= coverageBounds.maxLat &&
            coordinate.longitude >= coverageBounds.minLon &&
            coordinate.longitude <= coverageBounds.maxLon
    }
}

extension MKCoordinateRegion {
    static var germany: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.1657, longitude: 10.4515),
            span: MKCoordinateSpan(latitudeDelta: 8.0, longitudeDelta: 8.0)
        )
    }
}
