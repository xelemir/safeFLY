//
//  NetherlandsService.swift
//  safeFLY
//
//  Netherlands drone geo-zones via official ED-269 JSON dataset.
//  Point queries use ray-casting (polygons) or geodesic checks (circles) offline.
//  Vector rendering uses MapPolygon payloads.
//

import Foundation
import CoreLocation
import MapKit

nonisolated struct NLDDroneZoneFile: Codable, Sendable {
    let title: String
    let description: String
    let features: [NLDZoneFeature]
}

nonisolated struct NLDZoneFeature: Codable, Sendable {
    let identifier: String
    let country: String
    let name: String
    let type: String
    let restriction: String
    let reason: [String]?
    let message: String?
    let geometry: [ED269Geometry]

    var boundingBox: BoundingBox? { geometry.boundingBox }
    func contains(_ coordinate: MapCoordinate) -> Bool { geometry.contains(coordinate) }
}

struct NetherlandsFeatureInfoRecord: ProviderRawRecord {
    let layerName: String?
    let localType: String?
    let sourceText: String?
    let siteName: String?
    let siteCategory: String?

    nonisolated var providerID: String { NetherlandsProvider.providerID }
}

final class NetherlandsProvider: ED269DownloadableProvider, @unchecked Sendable {
    nonisolated static let providerID = "netherlands"

    nonisolated let id = NetherlandsProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("LVNL/IenW", comment: "Netherlands provider display name")
    }
    nonisolated var attributionName: String {
        "LVNL/IenW"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    let dataset = ED269DownloadableDataset<NLDZoneFeature>(
        fileName: "nld_uas_zones.json",
        remoteURL: URL(string: "https://gruettecloud.com/safefly/download-json?country=NL")!,
        parse: NetherlandsProvider.parse
    )

    nonisolated var datasets: [ProviderDataset] {
        [
            ProviderDataset(
                id: "airspace.restricted-zones",
                presentation: localizedProviderPresentation(title: "Restricted Zones", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            ),
            ProviderDataset(
                id: "airspace.landing-sites",
                presentation: localizedProviderPresentation(title: "Landing Sites", groupTitle: "Airspace"),
                capabilities: ProviderDatasetCapabilities(supportsRendering: true, supportsQuerying: true),
                isSelectedByDefault: true
            )
        ]
    }

    // Show attribution only over the real European Netherlands: a bounding box spilled into
    // Belgium and the German Rhineland along the diagonal borders it shares with them.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.netherlands }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.netherlands.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: "Dronevluchten | LVNL",
                url: URL(string: "https://www.lvnl.nl/diensten/dronevluchten")!
            ),
            // map.godrone.nl, not godrone.nl: the bare domain now lands on the Operator Portal.
            ProviderReferenceLink(
                title: "GoDrone",
                url: URL(string: "https://map.godrone.nl/")!
            )
        ]
    }

    nonisolated private static func parse(_ data: Data) throws -> [NLDZoneFeature] {
        try JSONDecoder().decode(NLDDroneZoneFile.self, from: ed269StrippedJSONData(data)).features
    }

    nonisolated func refreshStatus() async -> ProviderStatusSnapshot {
        let status: ProviderAvailabilityStatus = dataset.isDownloaded ? .available : .downloadRequired
        return ProviderStatusSnapshot(
            providerStatus: status,
            datasetStatuses: [
                "airspace.restricted-zones": status,
                "airspace.landing-sites": status
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

        let features = await selectedFeatures(in: selectedDatasetIDs)
        var payloads: [ProviderRenderPayload] = []

        for feature in features {
            if let bbox = feature.boundingBox, !bbox.intersects(request.region) {
                continue
            }

            let style = NetherlandsProvider.style(for: feature)

            for ring in feature.geometry.renderRings() {
                payloads.append(.polygon(PolygonRenderPayload(
                    id: "\(feature.identifier).\(payloads.count)",
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
        guard dataset.isDownloaded else {
            return .unavailable(reason: .providerNoData)
        }

        let coordinate = request.coordinate
        let matches = await selectedFeatures(in: selectedDatasetIDs)
            .filter { feature in
                if let bbox = feature.boundingBox, !bbox.contains(coordinate) {
                    return false
                }
                return feature.contains(coordinate)
            }
            .map { feature -> NetherlandsFeatureInfoRecord in
                let datasetID = NetherlandsZoneNormalizer.datasetID(
                    for: NetherlandsZoneNormalizer.determineCategory(name: feature.name, message: feature.message ?? "")
                )
                return NetherlandsFeatureInfoRecord(
                    layerName: datasetID == "airspace.landing-sites" ? "landingsite" : "luchtvaartgebieden",
                    localType: feature.restriction,
                    sourceText: feature.message,
                    siteName: feature.name,
                    siteCategory: feature.type
                )
            }

        if matches.isEmpty {
            return .noMatches
        }

        return .matches(records: matches.map { $0 as any ProviderRawRecord })
    }

    // Features whose derived dataset is among the selected ones. Shared by render and query
    // so category → dataset mapping lives in exactly one place.
    @MainActor private func selectedFeatures(in selectedDatasetIDs: Set<String>) -> [NLDZoneFeature] {
        dataset.features.filter { feature in
            let category = NetherlandsZoneNormalizer.determineCategory(name: feature.name, message: feature.message ?? "")
            return selectedDatasetIDs.contains(NetherlandsZoneNormalizer.datasetID(for: category))
        }
    }

    // The Netherlands styles by low-fly vs prohibited rather than by the ED-269 verdict, so it
    // maps onto the shared palette directly instead of using `ED269RenderStyle.forVerdict`.
    nonisolated private static func style(for feature: NLDZoneFeature) -> ED269RenderStyle {
        NetherlandsZoneNormalizer.isLowFlyZone(message: feature.message ?? "") ? .conditional : .prohibited
    }
}

struct NetherlandsZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let nldRecord = record as? NetherlandsFeatureInfoRecord else {
                return nil
            }
            return normalize(nldRecord)
        }
    }

    nonisolated private func normalize(_ record: NetherlandsFeatureInfoRecord) -> ZoneFeature {
        let category = NetherlandsZoneNormalizer.determineCategory(name: record.siteName ?? "", message: record.sourceText ?? "")

        let message = record.sourceText ?? ""
        let restrictionLevel: FlightAssessmentOutcome = NetherlandsZoneNormalizer.isLowFlyZone(message: message) ? .conditional : .prohibited

        // Localize the known Dutch advisory messages here so the presentation layer receives
        // ready-to-show text. Unknown messages pass through as raw Dutch and are tagged so
        // they can still be machine-translated downstream.
        let localized = NetherlandsZoneNormalizer.localizedRestriction(for: message)

        return ZoneFeature(
            category: category,
            restrictionLevel: restrictionLevel,
            name: record.siteName,
            sourceDeclaredType: record.siteCategory,
            sourceDeclaredRestriction: localized.text,
            lowerLimit: nil,
            upperLimit: nil,
            legalReference: nil,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: record.layerName ?? "luchtvaartgebieden"),
            restrictionSourceLanguage: localized.sourceLanguage
        )
    }

    nonisolated static func isLowFlyZone(message: String) -> Bool {
        message.contains("OPEN A1/2 toegestaan") || message.contains("allowed up to a max height of 30m")
    }

    // Maps the small, enumerable set of official Dutch advisory strings to localized text.
    // A match returns localized text with a nil source language (already in the user's
    // language); anything else passes through as raw Dutch tagged "nl".
    nonisolated static func localizedRestriction(for message: String) -> (text: String?, sourceLanguage: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, nil)
        }

        if let key = noteKey(for: trimmed) {
            return (NSLocalizedString(key, comment: "Curated Netherlands provider note translation"), nil)
        }

        return (trimmed, "nl")
    }

    nonisolated private static func noteKey(for sourceText: String) -> String? {
        switch sourceText {
        case "Alle vluchten zijn hier verboden / All flights are prohibited here":
            return "NLD.NOTE.ALL_PROHIBITED"
        case "Alle vluchten zijn hier verboden op 4 mei / all flights are prohibted on the 4th of may":
            return "NLD.NOTE.MAY_4"
        case "Alle vuchten zijn hier verboden tenzij er toestemming is gegeven door de Militaire luchverkeersdienstverlener / All flights are prohibited unless permission is granted (Military air traffic control)":
            return "NLD.NOTE.MILITARY_ATC"
        case "OPEN A1/2 toegestaan tot max 30m hoogte boven de grond; A3 niet toegestaan / OPEN A1/2 are allowed up to a max height of 30m above the ground; A3 not allowed":
            return "NLD.NOTE.LOW_FLY_30M"
        case "OPEN cat. vluchten zijn hier verboden SPEC cat. vluchten vereisen een privilege op de exploitatievergunning / Flights in the OPEN cat. are not allowed in SPEC cat. a privilege on the OA is required":
            return "NLD.NOTE.CTR_NO_OPEN"
        case "Vluchten in de OPEN categorie zijn hier niet toegestaan / Flights in the OPEN category are not allowed here":
            return "NLD.NOTE.NO_OPEN"
        default:
            return nil
        }
    }

    nonisolated static func determineCategory(name: String, message: String) -> ZoneCategory {
        let text = "\(name) \(message)".lowercased()
        if text.contains("ctr") || text.contains("schiphol") || text.contains("eelde") || text.contains("rotterdam") || text.contains("eindhoven") {
            return .controlZone
        }
        if text.contains("ziekenhuis") || text.contains("traumahelikopter") || text.contains("medisch centrum") || text.contains("hospital") || text.contains("umc") {
            return .hospital
        }
        if text.contains("vliegveld") || text.contains("luchthaven") || text.contains("vliegbasis") || text.contains("luchtvaartterrein") || text.contains("airport") || text.contains("heliport") || text.contains("landingsite") || text.contains("landingsplaats") {
            return .aerodrome
        }
        if text.contains("defensie") || text.contains("defensiegebied") || text.contains("ehtra") || text.contains("ehtsa") || text.contains("ehr") || text.contains("ehd") || text.contains("militaire") || text.contains("military") {
            return .militaryInstallation
        }
        if text.contains("industriegebied") || text.contains("industrie") || text.contains("industrial") {
            return .industrialInstallation
        }
        if text.contains("beveiligd gebied") || text.contains("vitale processen") || text.contains("beveiligingsoverwegingen") {
            return .securityAuthority
        }
        if text.contains("natuur") || text.contains("natura") || text.contains("duinen") || text.contains("waddenzee") || text.contains("milieubeschermingsgebied") {
            return .natureReserve
        }
        if text.contains("laagvlieg") || text.contains("glv") {
            return .restrictedArea
        }
        return .restrictedArea
    }

    nonisolated static func datasetID(for category: ZoneCategory) -> String {
        switch category {
        case .controlZone, .aerodrome, .airport, .hospital:
            return "airspace.landing-sites"
        default:
            return "airspace.restricted-zones"
        }
    }
}
