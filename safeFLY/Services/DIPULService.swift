//
//  DIPULService.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import Foundation
import CoreLocation
import MapKit

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

final class DIPULProvider: WMSBackedProvider, @unchecked Sendable {
    nonisolated static let providerID = "dipul"

    nonisolated let id = DIPULProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("DIPUL (Germany)", comment: "DIPUL provider display name")
    }
    nonisolated var attributionName: String {
        let year = Calendar.current.component(.year, from: Date())
        return "DFS, BKG \(year)"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated let catalog = WMSDatasetCatalog(
        baseURL: "https://uas-betrieb.de/geoservices/dipul/wms",
        definitions: [
            .make(id: "aviation.airports", title: "Airports", groupTitle: "Aviation", layerIDs: ["dipul:flughaefen"]),
            .make(id: "aviation.aerodromes", title: "Aerodromes", groupTitle: "Aviation", layerIDs: ["dipul:flugplaetze"]),
            .make(id: "aviation.control-zones", title: "Control Zones", groupTitle: "Aviation", layerIDs: ["dipul:kontrollzonen"]),
            .make(id: "aviation.restricted-areas", title: "Restricted Areas", groupTitle: "Aviation", layerIDs: ["dipul:flugbeschraenkungsgebiete"]),
            .make(
                id: "aviation.temporary-restrictions",
                title: "Temporary Restrictions",
                groupTitle: "Aviation",
                layerIDs: ["dipul:temporaere_betriebseinschraenkungen", "dipul:inaktive_temporaere_betriebseinschraenkungen"]
            ),
            .make(id: "aviation.model-flying-fields", title: "Model Flying Fields", groupTitle: "Aviation", layerIDs: ["dipul:modellflugplaetze"]),
            .make(id: "infrastructure.motorways", title: "Motorways", groupTitle: "Infrastructure", layerIDs: ["dipul:bundesautobahnen"]),
            .make(id: "infrastructure.highways", title: "Highways", groupTitle: "Infrastructure", layerIDs: ["dipul:bundesstrassen"]),
            .make(id: "infrastructure.railways", title: "Railways", groupTitle: "Infrastructure", layerIDs: ["dipul:bahnanlagen"]),
            .make(
                id: "infrastructure.waterways",
                title: "Waterways",
                groupTitle: "Infrastructure",
                layerIDs: ["dipul:binnenwasserstrassen", "dipul:seewasserstrassen", "dipul:schifffahrtsanlagen"]
            ),
            .make(
                id: "infrastructure.industrial-facilities",
                title: "Industrial Facilities",
                groupTitle: "Infrastructure",
                layerIDs: ["dipul:industrieanlagen", "dipul:kraftwerke", "dipul:umspannwerke", "dipul:stromleitungen", "dipul:windkraftanlagen"]
            ),
            .make(id: "restricted.residential-property", title: "Residential Property", groupTitle: "Restricted Areas", layerIDs: ["dipul:wohngrundstuecke"]),
            .make(id: "restricted.recreational-areas", title: "Recreational Areas", groupTitle: "Restricted Areas", layerIDs: ["dipul:freibaeder"]),
            .make(
                id: "restricted.government-buildings",
                title: "Government Buildings",
                groupTitle: "Restricted Areas",
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
            .make(
                id: "restricted.nature-reserves",
                title: "Nature Reserves",
                groupTitle: "Restricted Areas",
                layerIDs: ["dipul:nationalparks", "dipul:naturschutzgebiete", "dipul:ffh-gebiete", "dipul:vogelschutzgebiete"]
            )
        ],
        coverageBounds: WMSDatasetCatalog.CoverageBounds(minLat: 47.0, maxLat: 55.2, minLon: 5.5, maxLon: 15.6),
        coverage: CountryBoundaries.germany
    )

    nonisolated var queryInfoFormat: String { "text/plain" }

    // Show DFS attribution only when the map actually shows German territory — DIPUL's data
    // is German, so it must not be credited over France or the Netherlands.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.germany }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.germany.contains(region.center)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("DFS DIPUL Datasource", comment: "Provider reference link title"),
                url: URL(string: "https://uas-betrieb.dfs.de/homepage/")!
            )
        ]
    }

    nonisolated func parseFeatureInfo(_ data: Data) -> ProviderQueryOutcome {
        guard let responseText = String(data: data, encoding: .utf8) else {
            return .unavailable(reason: .invalidResponse)
        }

        return parseFeatureInfoText(responseText)
    }

    nonisolated private func parseFeatureInfoText(_ text: String) -> ProviderQueryOutcome {
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
}

extension MKCoordinateRegion {
    static var germany: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.1657, longitude: 10.4515),
            span: MKCoordinateSpan(latitudeDelta: 8.0, longitudeDelta: 8.0)
        )
    }

    // Biases location search across every country safeFLY ships providers for:
    // Germany, France, Austria and the Netherlands.
    static var supportedCountries: MKCoordinateRegion {
        // Centre/​span biases search completions toward the covered countries. Widened east so
        // Czechia's eastern edge (~18.9° E) is comfortably inside the bias window.
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.5, longitude: 8.0),
            span: MKCoordinateSpan(latitudeDelta: 17.0, longitudeDelta: 28.0)
        )
    }
}
