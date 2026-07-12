//
//  FranceService.swift
//  safeFLY
//

import Foundation
import CoreLocation
import MapKit

struct FranceFeatureInfoRecord: ProviderRawRecord {
    let layerName: String
    let limit: String?
    let remark: String?

    nonisolated var providerID: String { FranceProvider.providerID }
}

final class FranceProvider: WMSBackedProvider, @unchecked Sendable {
    nonisolated static let providerID = "france"

    nonisolated let id = FranceProvider.providerID
    nonisolated var displayName: String {
        NSLocalizedString("DGAC", comment: "France provider display name")
    }
    nonisolated var attributionName: String {
        "DGAC, IGN"
    }
    nonisolated let capabilities = ProviderCapabilities(
        supportsRendering: true,
        supportsQuerying: true,
        supportsStatusRefresh: true
    )

    nonisolated let catalog = WMSDatasetCatalog(
        baseURL: "https://data.geopf.fr/wms-r/wms",
        definitions: [
            .make(
                id: "airspace.restricted-zones",
                title: "Restricted Zones",
                groupTitle: "Airspace",
                layerIDs: ["TRANSPORTS.DRONES.RESTRICTIONS"]
            )
        ],
        // Coverage bounding box for metropolitan France
        coverageBounds: WMSDatasetCatalog.CoverageBounds(
            minLat: 41.0,
            maxLat: 51.5,
            minLon: -5.5,
            maxLon: 10.0
        ),
        coverage: CountryBoundaries.france
    )

    nonisolated var queryInfoFormat: String { "application/json" }

    // Show this provider's map attribution only over actual French territory (incl. Corsica).
    // A bounding box reached into Belgium, Germany, Switzerland and Italy; the real outline
    // keeps it to France along the diagonal eastern border.
    nonisolated var coverage: CountryCoverage? { CountryBoundaries.france }

    nonisolated func intersects(_ region: MapRegion) -> Bool {
        CountryBoundaries.france.intersects(region)
    }

    nonisolated var referenceLinks: [ProviderReferenceLink] {
        [
            ProviderReferenceLink(
                title: NSLocalizedString("Carte des restrictions drones (Géoportail)", comment: "France provider data source link title"),
                url: URL(string: "https://www.geoportail.gouv.fr/donnees/restrictions-uas-categorie-ouverte-et-aeromodelisme")!
            )
        ]
    }

    nonisolated func parseFeatureInfo(_ data: Data) -> ProviderQueryOutcome {
        struct FeatureCollection: Codable {
            struct Feature: Codable {
                let id: String
                let properties: [String: StringResilient]?
            }
            let features: [Feature]?
        }

        // Resiliently decode string or number values in properties
        enum StringResilient: Codable {
            case string(String)
            case number(Double)
            case null

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) {
                    self = .string(str)
                } else if let num = try? container.decode(Double.self) {
                    self = .number(num)
                } else {
                    self = .null
                }
            }

            var stringValue: String? {
                switch self {
                case .string(let s): return s
                case .number(let n): return String(n)
                case .null: return nil
                }
            }
        }

        do {
            let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
            guard let features = collection.features, !features.isEmpty else {
                return .noMatches
            }

            let records = features.map { feature -> FranceFeatureInfoRecord in
                let properties = feature.properties ?? [:]
                return FranceFeatureInfoRecord(
                    layerName: "TRANSPORTS.DRONES.RESTRICTIONS",
                    limit: properties["limite"]?.stringValue,
                    remark: properties["remarque"]?.stringValue
                )
            }

            return .matches(records: records.map { $0 as any ProviderRawRecord })
        } catch {
            return .unavailable(reason: .invalidResponse)
        }
    }
}

struct FranceZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let franceRecord = record as? FranceFeatureInfoRecord else {
                return nil
            }
            return normalize(franceRecord)
        }
    }

    // The GeoPF `TRANSPORTS.DRONES.RESTRICTIONS` layer only exposes two free-text fields:
    // `limite` (the flight rule, e.g. "Vol interdit" or "Hauteur maximale de vol de 50 m")
    // and `remarque` (an optional extra condition). Both carry a trailing "*" footnote
    // marker on every value, which we strip. We map the small, enumerable set of French
    // phrases to localized text here so the presentation layer receives ready-to-show
    // strings (restrictionSourceLanguage = nil), rather than relying on the curated
    // view-layer translator which can only key off a single whole-string match.
    nonisolated private func cleanText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("*") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    nonisolated private func normalize(_ record: FranceFeatureInfoRecord) -> ZoneFeature {
        let limitText = cleanText(record.limit ?? "")
        let remarkText = cleanText(record.remark ?? "")

        let limit = FranceZoneNormalizer.parseLimit(limitText)

        var lines: [String] = []
        if let primary = limit.restrictionText {
            lines.append(primary)
        }
        if let remark = FranceZoneNormalizer.localizedRemark(remarkText) {
            lines.append(remark)
        }
        let restriction = lines.isEmpty ? nil : lines.joined(separator: "\n")

        let upperLimit = limit.maxHeight.map {
            AltitudeLimit(value: String($0), unit: "m", reference: "AGL")
        }

        return ZoneFeature(
            category: FranceZoneNormalizer.determineCategory(remark: remarkText, limitText: limitText),
            restrictionLevel: limit.outcome,
            name: nil,
            sourceDeclaredType: nil,
            sourceDeclaredRestriction: restriction,
            lowerLimit: nil,
            upperLimit: upperLimit,
            legalReference: nil,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: record.layerName),
            // Text is already localized above, so it must not be machine-translated.
            restrictionSourceLanguage: nil
        )
    }

    struct ParsedLimit {
        let outcome: FlightAssessmentOutcome
        let maxHeight: Int?
        let restrictionText: String?
    }

    // Turns the raw `limite` phrase into a verdict, an optional max height, and localized
    // text. The layer's legend has six possible values: an outright prohibition
    // ("Vol interdit"), four reduced ceilings ("Hauteur maximale de vol de 30/50/60/100 m"),
    // and the national baseline ("Tout vol interdit au-dessus de 120 m"), which actually
    // means flight is allowed up to the standard 120 m open-category ceiling. Prohibitions
    // deliberately carry no altitude, so the UI never shows a nonsensical "up to 0 m AGL".
    nonisolated static func parseLimit(_ text: String) -> ParsedLimit {
        let lower = text.lowercased()

        if lower.isEmpty {
            return ParsedLimit(outcome: .conditional, maxHeight: nil, restrictionText: nil)
        }

        // A height ceiling — "max X m" or "prohibited above X m" — is checked before the
        // prohibition keyword, because the 120 m baseline phrase also contains "interdit".
        if let height = extractHeight(text) {
            let format = NSLocalizedString("FRA.RESTRICTION.MAX_HEIGHT", comment: "France: maximum flight height in meters AGL")
            // 120 m is the standard open-category ceiling, so it imposes no extra restriction.
            let outcome: FlightAssessmentOutcome = height >= 120 ? .allowed : .conditional
            return ParsedLimit(
                outcome: outcome,
                maxHeight: height,
                restrictionText: String(format: format, String(height))
            )
        }

        if lower.contains("interdit") || lower.contains("interdiction") || lower.contains("prohib") {
            return ParsedLimit(
                outcome: .prohibited,
                maxHeight: nil,
                restrictionText: NSLocalizedString("FRA.RESTRICTION.PROHIBITED", comment: "France: flight prohibited")
            )
        }

        // Unrecognized phrase: surface the source text rather than dropping it.
        return ParsedLimit(outcome: .conditional, maxHeight: nil, restrictionText: text)
    }

    // Maps the known `remarque` values to localized text; unknown remarks pass through.
    nonisolated static func localizedRemark(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        if lower.contains("notification préalable") && lower.contains("900") {
            return NSLocalizedString("FRA.NOTE.NOTIFICATION_900G", comment: "France: prior notification required over 900g")
        }
        if lower.contains("agglomération") && lower.contains("espace public") {
            return NSLocalizedString("FRA.NOTE.AGGLOMERATION", comment: "France: built-up area public space restriction")
        }
        return text
    }

    nonisolated static func determineCategory(remark: String, limitText: String) -> ZoneCategory {
        let text = "\(remark) \(limitText)".lowercased()
        if text.contains("agglomération") || text.contains("espace public") {
            return .residentialProperty
        }
        if text.contains("parc") || text.contains("réserve") || text.contains("biotope") || text.contains("nature") {
            return .natureReserve
        }
        if text.contains("militaire") || text.contains("défense") || text.contains("ehtra") || text.contains("ehtsa") {
            return .militaryInstallation
        }
        if text.contains("aérodrome") || text.contains("aéroport") || text.contains("hélistation") || text.contains("ctr") {
            return .controlZone
        }
        return .restrictedArea
    }

    // Extracts the first integer that precedes a "m" unit (e.g. "... de 50 m" -> 50),
    // so a stray number elsewhere in the phrase can't be mistaken for a height.
    nonisolated static func extractHeight(_ text: String) -> Int? {
        let scanner = Scanner(string: text)
        let digits = CharacterSet.decimalDigits
        while !scanner.isAtEnd {
            scanner.charactersToBeSkipped = digits.inverted
            guard let number = scanner.scanInt() else { return nil }
            scanner.charactersToBeSkipped = .whitespaces
            if let next = scanner.scanCharacter(), next == "m" || next == "M" {
                return number
            }
        }
        return nil
    }
}
