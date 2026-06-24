//
//  DIPULService.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import Foundation
import CoreLocation
import Combine
import MapKit
import UIKit

private struct DIPULFeatureInfoRecord {
    let layerName: String
    let name: String?
    let sourceDeclaredType: String?
    let sourceDeclaredRestriction: String?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let legalReference: String?
}

final class DIPULService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var zoneQueryResult: ZoneQueryResult?

    @Published var failedLayers: Set<String> = []
    private var isVerifying = false

    private let providerID = "dipul"
    private let baseURL = "https://uas-betrieb.de/geoservices/dipul/wms"

    // DIPUL geozone data is Germany-specific. Treat queries clearly outside
    // Germany as unavailable instead of incorrectly concluding the location is clear.
    private let coverageBounds = (
        minLat: 47.0,
        maxLat: 55.2,
        minLon: 5.5,
        maxLon: 15.6
    )

    private let allPossibleLayers = [
        "dipul:flugplaetze",
        "dipul:flughaefen",
        "dipul:kontrollzonen",
        "dipul:flugbeschraenkungsgebiete",
        "dipul:temporaere_betriebseinschraenkungen",
        "dipul:inaktive_temporaere_betriebseinschraenkungen",
        "dipul:modellflugplaetze",
        "dipul:bundesautobahnen",
        "dipul:bundesstrassen",
        "dipul:bahnanlagen",
        "dipul:binnenwasserstrassen",
        "dipul:seewasserstrassen",
        "dipul:schifffahrtsanlagen",
        "dipul:industrieanlagen",
        "dipul:kraftwerke",
        "dipul:umspannwerke",
        "dipul:stromleitungen",
        "dipul:windkraftanlagen",
        "dipul:wohngrundstuecke",
        "dipul:freibaeder",
        "dipul:justizvollzugsanstalten",
        "dipul:militaerische_anlagen",
        "dipul:labore",
        "dipul:behoerden",
        "dipul:diplomatische_vertretungen",
        "dipul:internationale_organisationen",
        "dipul:polizei",
        "dipul:sicherheitsbehoerden",
        "dipul:krankenhaeuser",
        "dipul:nationalparks",
        "dipul:naturschutzgebiete",
        "dipul:ffh-gebiete",
        "dipul:vogelschutzgebiete"
    ]

    init() {
        if let savedFailed = UserDefaults.standard.stringArray(forKey: "failedLayers") {
            failedLayers = Set(savedFailed)
        }

        Task {
            await verifyLayersIfNeeded()
        }
    }

    func clearZoneQueryResult() {
        zoneQueryResult = nil
    }

    private func verifyLayersIfNeeded() async {
        let lastCheck = UserDefaults.standard.double(forKey: "lastLayerCheckTime")
        let now = Date().timeIntervalSince1970

        if lastCheck == 0 || (now - lastCheck) > 12 * 3600 {
            await performLayerVerification()
        }
    }

    func performLayerVerification() async {
        guard !isVerifying else { return }
        isVerifying = true

        var newlyFailed = Set<String>()
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
                    newlyFailed.insert(layer)
                case .networkError:
                    networkErrorCount += 1
                }
            }
        }

        if networkErrorCount > 5 || (workingCount == 0 && networkErrorCount > 0) {
            await MainActor.run {
                self.isVerifying = false
            }
            return
        }

        let sortedFailed = Array(newlyFailed).sorted()

        await MainActor.run {
            self.failedLayers = newlyFailed
            UserDefaults.standard.set(sortedFailed, forKey: "failedLayers")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastLayerCheckTime")
            self.isVerifying = false
            NotificationCenter.default.post(name: NSNotification.Name("DIPULLayersVerified"), object: nil)
        }
    }

    private enum LayerStatus: Equatable {
        case working
        case broken
        case networkError
    }

    private func testLayer(_ layer: String) async -> LayerStatus {
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

    func getWMSURL(for region: MKCoordinateRegion, size: CGSize, settings: DroneSettings) -> URL? {
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2)
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2)
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2)
        let maxLon = region.center.longitude + (region.span.longitudeDelta / 2)

        let layers = getAllLayers(settings: settings)
        if layers.isEmpty {
            return nil
        }

        let width = Int(size.width)
        let height = Int(size.height)
        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetMap&" +
            "layers=\(layers)&" +
            "styles=&" +
            "crs=EPSG:4326&" +
            "bbox=\(minLat),\(minLon),\(maxLat),\(maxLon)&" +
            "width=\(width)&" +
            "height=\(height)&" +
            "format=image/png&" +
            "transparent=true"

        return URL(string: urlString)
    }

    private func getAllLayers(settings: DroneSettings) -> String {
        var layers: [String] = []

        func appendLayer(_ name: String) {
            if !failedLayers.contains(name) {
                layers.append(name)
            }
        }

        if settings.showAerodromes {
            appendLayer("dipul:flugplaetze")
        }
        if settings.showAirports {
            appendLayer("dipul:flughaefen")
        }
        if settings.showControlZones {
            appendLayer("dipul:kontrollzonen")
        }
        if settings.showRestrictedAreas {
            appendLayer("dipul:flugbeschraenkungsgebiete")
        }
        if settings.showTemporaryRestrictions {
            appendLayer("dipul:temporaere_betriebseinschraenkungen")
            appendLayer("dipul:inaktive_temporaere_betriebseinschraenkungen")
        }
        if settings.showModelFlyingFields {
            appendLayer("dipul:modellflugplaetze")
        }

        if settings.showMotorways {
            appendLayer("dipul:bundesautobahnen")
        }
        if settings.showHighways {
            appendLayer("dipul:bundesstrassen")
        }
        if settings.showRailways {
            appendLayer("dipul:bahnanlagen")
        }
        if settings.showWaterways {
            appendLayer("dipul:binnenwasserstrassen")
            appendLayer("dipul:seewasserstrassen")
            appendLayer("dipul:schifffahrtsanlagen")
        }
        if settings.showIndustrial {
            appendLayer("dipul:industrieanlagen")
            appendLayer("dipul:kraftwerke")
            appendLayer("dipul:umspannwerke")
            appendLayer("dipul:stromleitungen")
            appendLayer("dipul:windkraftanlagen")
        }

        if settings.showResidential {
            appendLayer("dipul:wohngrundstuecke")
        }
        if settings.showRecreational {
            appendLayer("dipul:freibaeder")
        }
        if settings.showGovernment {
            appendLayer("dipul:justizvollzugsanstalten")
            appendLayer("dipul:militaerische_anlagen")
            appendLayer("dipul:labore")
            appendLayer("dipul:behoerden")
            appendLayer("dipul:diplomatische_vertretungen")
            appendLayer("dipul:internationale_organisationen")
            appendLayer("dipul:polizei")
            appendLayer("dipul:sicherheitsbehoerden")
            appendLayer("dipul:krankenhaeuser")
        }
        if settings.showNatureReserves {
            appendLayer("dipul:nationalparks")
            appendLayer("dipul:naturschutzgebiete")
            appendLayer("dipul:ffh-gebiete")
            appendLayer("dipul:vogelschutzgebiete")
        }

        return layers
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .joined(separator: ",")
    }

    func getFeatureInfo(
        at coordinate: CLLocationCoordinate2D,
        region: MKCoordinateRegion,
        viewSize: CGSize,
        settings: DroneSettings
    ) {
        isLoading = true
        errorMessage = nil
        zoneQueryResult = nil

        if !isWithinCoverage(coordinate) {
            isLoading = false
            zoneQueryResult = .unavailable(reason: .outsideCoverage)
            return
        }

        let layers = getAllLayers(settings: settings)
        if layers.isEmpty {
            isLoading = false
            zoneQueryResult = .nonAssessment(reason: .noEnabledLayers)
            return
        }

        let minLat = region.center.latitude - (region.span.latitudeDelta / 2)
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2)
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2)
        let maxLon = region.center.longitude + (region.span.longitudeDelta / 2)

        let width = Int(viewSize.width)
        let height = Int(viewSize.height)
        let x = Int((coordinate.longitude - minLon) / (maxLon - minLon) * Double(width))
        let y = Int((maxLat - coordinate.latitude) / (maxLat - minLat) * Double(height))

        let urlString = "\(baseURL)?" +
            "service=WMS&" +
            "version=1.3.0&" +
            "request=GetFeatureInfo&" +
            "layers=\(layers)&" +
            "query_layers=\(layers)&" +
            "styles=&" +
            "crs=EPSG:4326&" +
            "bbox=\(minLat),\(minLon),\(maxLat),\(maxLon)&" +
            "width=\(width)&" +
            "height=\(height)&" +
            "i=\(x)&" +
            "j=\(y)&" +
            "info_format=text/plain&" +
            "feature_count=10"

        guard let url = URL(string: urlString) else {
            isLoading = false
            zoneQueryResult = .unavailable(reason: .invalidResponse)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false

                if let error {
                    self.zoneQueryResult = .unavailable(reason: .requestFailed(details: error.localizedDescription))
                    return
                }

                guard let data, let responseText = String(data: data, encoding: .utf8) else {
                    self.zoneQueryResult = .unavailable(reason: .invalidResponse)
                    return
                }

                self.zoneQueryResult = self.parseFeatureInfo(responseText)
            }
        }.resume()
    }

    private func parseFeatureInfo(_ text: String) -> ZoneQueryResult {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedText.isEmpty {
            return .unavailable(reason: .providerNoData)
        }

        if normalizedText.localizedCaseInsensitiveContains("no features were found") {
            return .clear(reason: .noMatchingRestrictions)
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

        let features = records
            .map(normalize)
            .sorted { lhs, rhs in
                if lhs.category.displayPriority != rhs.category.displayPriority {
                    return lhs.category.displayPriority < rhs.category.displayPriority
                }

                return lhs.id < rhs.id
            }

        let assessment = ZoneAssessmentEvaluator.evaluate(features: features)
        return .matches(features: features, assessment: assessment)
    }

    private func extractLayerName(from line: String) -> String? {
        guard let range = line.range(of: "dipul:") else {
            return nil
        }

        let afterPrefix = line[range.upperBound...]
        guard let endRange = afterPrefix.range(of: "'") else {
            return nil
        }

        return "dipul:\(afterPrefix[..<endRange.lowerBound])"
    }

    private func createRecord(from data: [String: String], layer: String) -> DIPULFeatureInfoRecord {
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

    private func makeAltitudeLimit(value: String?, unit: String?, reference: String?) -> AltitudeLimit? {
        guard let value = normalizedValue(value) else {
            return nil
        }

        return AltitudeLimit(
            value: value,
            unit: normalizedValue(unit) ?? "m",
            reference: normalizedValue(reference)
        )
    }

    private func normalize(_ record: DIPULFeatureInfoRecord) -> ZoneFeature {
        ZoneFeature(
            category: mapCategory(from: record.layerName),
            name: record.name,
            sourceDeclaredType: record.sourceDeclaredType,
            sourceDeclaredRestriction: record.sourceDeclaredRestriction,
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: record.legalReference,
            source: SourceProvenance(providerID: providerID, sourceLayerID: record.layerName)
        )
    }

    private func mapCategory(from layerName: String) -> ZoneCategory {
        if layerName.contains("flughaefen") { return .airport }
        if layerName.contains("kontrollzonen") { return .controlZone }
        if layerName.contains("flugplaetze") { return .aerodrome }
        if layerName.contains("temporaere_betriebseinschraenkungen") && !layerName.contains("inaktive") {
            return .temporaryRestrictionActive
        }
        if layerName.contains("flugbeschraenkungsgebiete") { return .restrictedArea }
        if layerName.contains("militaerische_anlagen") { return .militaryInstallation }
        if layerName.contains("justizvollzugsanstalten") { return .prison }
        if layerName.contains("labore") { return .bsl4Facility }
        if layerName.contains("kraftwerke") { return .powerPlant }
        if layerName.contains("umspannwerke") { return .substation }
        if layerName.contains("sicherheitsbehoerden") { return .securityAuthority }
        if layerName.contains("polizei") { return .policeProperty }
        if layerName.contains("diplomatische_vertretungen") { return .diplomaticMission }
        if layerName.contains("internationale_organisationen") { return .internationalOrganization }
        if layerName.contains("behoerden") { return .authority }
        if layerName.contains("industrieanlagen") { return .industrialInstallation }
        if layerName.contains("stromleitungen") { return .powerLine }
        if layerName.contains("windkraftanlagen") { return .windFarm }
        if layerName.contains("bundesautobahnen") { return .motorway }
        if layerName.contains("bundesstrassen") { return .highway }
        if layerName.contains("bahnanlagen") { return .railway }
        if layerName.contains("seewasserstrassen") { return .maritimeWaterway }
        if layerName.contains("binnenwasserstrassen") { return .inlandWaterway }
        if layerName.contains("schifffahrtsanlagen") { return .shippingInstallation }
        if layerName.contains("nationalparks") { return .nationalPark }
        if layerName.contains("naturschutzgebiete") { return .natureReserve }
        if layerName.contains("ffh-gebiete") { return .habitatDirectiveSite }
        if layerName.contains("vogelschutzgebiete") { return .birdSanctuary }
        if layerName.contains("krankenhaeuser") { return .hospital }
        if layerName.contains("freibaeder") { return .recreationalArea }
        if layerName.contains("wohngrundstuecke") { return .residentialProperty }
        if layerName.contains("modellflugplaetze") { return .modelFlyingField }
        if layerName.contains("inaktive_temporaere_betriebseinschraenkungen") { return .temporaryRestrictionInactive }
        return .restrictedArea
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else {
            return nil
        }
        return trimmed
    }

    private func isWithinCoverage(_ coordinate: CLLocationCoordinate2D) -> Bool {
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
