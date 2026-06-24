//
//  ZoneQuery.swift
//  safeFLY
//

import Foundation

enum ZoneQueryResult {
    case clear(reason: ClearReason)
    case matches(features: [ZoneFeature], assessment: FlightAssessmentOutcome)
    case nonAssessment(reason: NonAssessmentReason)
    case unavailable(reason: UnavailableReason)
}

enum ClearReason {
    case noMatchingRestrictions
}

enum NonAssessmentReason {
    case noEnabledLayers
}

enum UnavailableReason {
    case outsideCoverage
    case requestFailed(details: String?)
    case providerNoData
    case invalidResponse
}

enum FlightAssessmentOutcome {
    case allowed
    case conditional
    case prohibited
}

struct SourceProvenance {
    let providerID: String
    let sourceLayerID: String
}

struct AltitudeLimit {
    let value: String
    let unit: String
    let reference: String?

    var stableIDComponent: String {
        [value, unit, reference ?? ""].joined(separator: "|")
    }
}

enum ZoneCategory {
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
    case modelFlyingField
    case temporaryRestrictionInactive

    var displayPriority: Int {
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
        case .modelFlyingField:
            return 80
        case .temporaryRestrictionInactive:
            return 81
        }
    }
}

struct ZoneFeature: Identifiable {
    let id: String
    let category: ZoneCategory
    let name: String?
    let sourceDeclaredType: String?
    let sourceDeclaredRestriction: String?
    let lowerLimit: AltitudeLimit?
    let upperLimit: AltitudeLimit?
    let legalReference: String?
    let source: SourceProvenance

    init(
        category: ZoneCategory,
        name: String?,
        sourceDeclaredType: String?,
        sourceDeclaredRestriction: String?,
        lowerLimit: AltitudeLimit?,
        upperLimit: AltitudeLimit?,
        legalReference: String?,
        source: SourceProvenance
    ) {
        self.category = category
        self.name = name
        self.sourceDeclaredType = sourceDeclaredType
        self.sourceDeclaredRestriction = sourceDeclaredRestriction
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.legalReference = legalReference
        self.source = source
        self.id = ZoneFeature.makeID(
            category: category,
            name: name,
            sourceDeclaredType: sourceDeclaredType,
            sourceDeclaredRestriction: sourceDeclaredRestriction,
            lowerLimit: lowerLimit,
            upperLimit: upperLimit,
            legalReference: legalReference,
            source: source
        )
    }

    private static func makeID(
        category: ZoneCategory,
        name: String?,
        sourceDeclaredType: String?,
        sourceDeclaredRestriction: String?,
        lowerLimit: AltitudeLimit?,
        upperLimit: AltitudeLimit?,
        legalReference: String?,
        source: SourceProvenance
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
            legalReference ?? ""
        ].joined(separator: "||")
    }
}
