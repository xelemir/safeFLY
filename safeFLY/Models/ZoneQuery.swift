//
//  ZoneQuery.swift
//  safeFLY
//

import Foundation

enum ZoneQueryResult: Sendable {
    case clear(reason: ClearReason)
    case matches(features: [ZoneFeature], assessment: FlightAssessmentOutcome)
    case nonAssessment(reason: NonAssessmentReason)
    case unavailable(reason: UnavailableReason)
}

enum ClearReason: Sendable {
    case noMatchingRestrictions
    case offlineOnlyNoMatchingRestrictions
}

enum NonAssessmentReason: Sendable {
    case noEnabledLayers
}

enum UnavailableReason: Sendable {
    case outsideCoverage
    case requestFailed(details: String?)
    case providerNoData
    case invalidResponse
}

nonisolated enum FlightAssessmentOutcome: Sendable {
    case allowed
    case conditional
    case prohibited

    // Ordered severity so verdicts from any provider/country can be combined by taking
    // the most restrictive one, without the combiner needing to know national rules.
    nonisolated var severityRank: Int {
        switch self {
        case .allowed:
            return 0
        case .conditional:
            return 1
        case .prohibited:
            return 2
        }
    }
}

struct SourceProvenance: Sendable {
    let providerID: String
    let sourceLayerID: String
}

struct AltitudeLimit: Sendable {
    let value: String
    let unit: String
    let reference: String?

    nonisolated var stableIDComponent: String {
        [value, unit, reference ?? ""].joined(separator: "|")
    }
}

enum ZoneCategory: Sendable {
    case airport
    case controlZone
    case aerodrome
    case temporaryRestrictionActive
    case restrictedArea
    case militaryInstallation
    case prison
    case bsl4Facility
    case powerPlant
    case substation
    case securityAuthority
    case policeProperty
    case diplomaticMission
    case internationalOrganization
    case authority
    case industrialInstallation
    case powerLine
    case windFarm
    case motorway
    case highway
    case railway
    case maritimeWaterway
    case inlandWaterway
    case shippingInstallation
    case nationalPark
    case natureReserve
    case habitatDirectiveSite
    case birdSanctuary
    case hospital
    case recreationalArea
    case residentialProperty
    // A population-density classification of the terrain (e.g. the Czech nationwide HOP
    // A1/A2/A3 zones), not a specific "keep away from these houses" restriction. Kept
    // distinct from `residentialProperty` so it isn't mislabelled as a residential no-fly.
    case populatedArea
    case modelFlyingField
    case temporaryRestrictionInactive

    nonisolated var displayPriority: Int {
        switch self {
        case .airport:
            return 0
        case .controlZone:
            return 1
        case .aerodrome:
            return 2
        case .temporaryRestrictionActive:
            return 3
        case .restrictedArea:
            return 4
        case .militaryInstallation:
            return 10
        case .prison:
            return 11
        case .bsl4Facility:
            return 12
        case .powerPlant:
            return 13
        case .substation:
            return 14
        case .securityAuthority:
            return 20
        case .policeProperty:
            return 21
        case .diplomaticMission:
            return 22
        case .internationalOrganization:
            return 23
        case .authority:
            return 24
        case .industrialInstallation:
            return 30
        case .powerLine:
            return 31
        case .windFarm:
            return 32
        case .motorway:
            return 33
        case .highway:
            return 34
        case .railway:
            return 35
        case .maritimeWaterway:
            return 40
        case .inlandWaterway:
            return 41
        case .shippingInstallation:
            return 42
        case .nationalPark:
            return 50
        case .natureReserve:
            return 51
        case .habitatDirectiveSite:
            return 52
        case .birdSanctuary:
            return 53
        case .hospital:
            return 60
        case .recreationalArea:
            return 61
        case .residentialProperty:
            return 70
        case .populatedArea:
            return 71
        case .modelFlyingField:
            return 80
        case .temporaryRestrictionInactive:
            return 81
        }
    }
}

extension Array where Element == ZoneFeature {
    // Stable display order shared by per-provider results and the combined aggregate:
    // most-significant category first, then by content id for determinism.
    nonisolated func sortedByDisplayPriority() -> [ZoneFeature] {
        sorted { lhs, rhs in
            if lhs.category.displayPriority != rhs.category.displayPriority {
                return lhs.category.displayPriority < rhs.category.displayPriority
            }
            return lhs.id < rhs.id
        }
    }

    // Collapses features that are identical to the user. Providers often return several
    // overlapping polygons that share the same content-derived id, differing only by an
    // internal feature id — they would otherwise show up as repeated identical rows.
    nonisolated func deduplicatedByID() -> [ZoneFeature] {
        var seenFeatureIDs = Set<String>()
        return filter { seenFeatureIDs.insert($0.id).inserted }
    }
}

struct ZoneFeature: Identifiable, Sendable {
    let id: String
    let category: ZoneCategory
    // The flight verdict this single feature contributes, decided by the originating
    // provider's normalizer according to that country's regulations.
    let restrictionLevel: FlightAssessmentOutcome
    let name: String?
    let sourceDeclaredType: String?
    let sourceDeclaredRestriction: String?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let legalReference: String?
    let source: SourceProvenance
    // BCP-47 language of `sourceDeclaredRestriction` when it is raw text from the provider's
    // API (e.g. Dutch from PDOK). nil means the text is already in the user's language
    // (our own localized advisories) and must not be machine-translated.
    let restrictionSourceLanguage: String?
    // An extra, always-localized advisory shown beneath the main restriction text, in a
    // de-emphasized style. Used when a rule depends on something the zone geometry doesn't carry
    // (e.g. the pilot's drone class), so it can't be folded into the verdict. Always already in
    // the user's language — unlike `sourceDeclaredRestriction`, it is never machine-translated —
    // so it must not be mixed into that raw-text field, which is why it is its own field.
    let supplementaryNote: String?

    nonisolated init(
        category: ZoneCategory,
        restrictionLevel: FlightAssessmentOutcome,
        name: String?,
        sourceDeclaredType: String?,
        sourceDeclaredRestriction: String?,
        lowerLimit: AltitudeLimit?,
        upperLimit: AltitudeLimit?,
        legalReference: String?,
        source: SourceProvenance,
        restrictionSourceLanguage: String? = nil,
        supplementaryNote: String? = nil
    ) {
        self.category = category
        self.restrictionLevel = restrictionLevel
        self.name = name
        self.sourceDeclaredType = sourceDeclaredType
        self.sourceDeclaredRestriction = sourceDeclaredRestriction
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.legalReference = legalReference
        self.source = source
        self.restrictionSourceLanguage = restrictionSourceLanguage
        self.supplementaryNote = supplementaryNote
        self.id = ZoneFeature.makeID(
            category: category,
            name: name,
            sourceDeclaredType: sourceDeclaredType,
            sourceDeclaredRestriction: sourceDeclaredRestriction,
            lowerLimit: lowerLimit,
            upperLimit: upperLimit,
            legalReference: legalReference,
            source: source,
            supplementaryNote: supplementaryNote
        )
    }

    nonisolated private static func makeID(
        category: ZoneCategory,
        name: String?,
        sourceDeclaredType: String?,
        sourceDeclaredRestriction: String?,
        lowerLimit: AltitudeLimit?,
        upperLimit: AltitudeLimit?,
        legalReference: String?,
        source: SourceProvenance,
        supplementaryNote: String?
    ) -> String {
        [
            source.providerID,
            source.sourceLayerID,
            String(describing: category),
            name ?? "",
            sourceDeclaredType ?? "",
            sourceDeclaredRestriction ?? "",
            lowerLimit?.stableIDComponent ?? "",
            upperLimit?.stableIDComponent ?? "",
            legalReference ?? "",
            supplementaryNote ?? ""
        ].joined(separator: "||")
    }
}
