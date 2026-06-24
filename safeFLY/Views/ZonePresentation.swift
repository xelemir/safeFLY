//
//  ZonePresentation.swift
//  safeFLY
//

import SwiftUI

enum ZonePresentation {
    static func title(for feature: ZoneFeature) -> String {
        localizedTitle(for: feature.category)
    }

    static func subtitle(for feature: ZoneFeature) -> String? {
        if let name = feature.name, !name.isEmpty {
            return name
        }

        guard let sourceDeclaredType = feature.sourceDeclaredType else {
            return nil
        }

        let formattedType = formattedTypeCode(sourceDeclaredType)
        return formattedType == localizedTitle(for: feature.category) ? nil : formattedType
    }

    static func localizedTitle(for category: ZoneCategory) -> String {
        switch category {
        case .airport:
            return NSLocalizedString("LAYER.flughaefen", comment: "Airport")
        case .controlZone:
            return NSLocalizedString("LAYER.kontrollzonen", comment: "Control Zone")
        case .aerodrome:
            return NSLocalizedString("LAYER.flugplaetze", comment: "Aerodrome")
        case .temporaryRestrictionActive:
            return NSLocalizedString("LAYER.temporaere_betriebseinschraenkungen", comment: "Temporary restriction")
        case .restrictedArea:
            return NSLocalizedString("LAYER.flugbeschraenkungsgebiete", comment: "Restricted area")
        case .militaryInstallation:
            return NSLocalizedString("LAYER.militaerische_anlagen", comment: "Military installation")
        case .prison:
            return NSLocalizedString("LAYER.justizvollzugsanstalten", comment: "Prison")
        case .bsl4Facility:
            return NSLocalizedString("LAYER.labore", comment: "BSL-4 facility")
        case .powerPlant:
            return NSLocalizedString("LAYER.kraftwerke", comment: "Power plant")
        case .substation:
            return NSLocalizedString("LAYER.umspannwerke", comment: "Substation")
        case .securityAuthority:
            return NSLocalizedString("LAYER.sicherheitsbehoerden", comment: "Security authority")
        case .policeProperty:
            return NSLocalizedString("LAYER.polizei", comment: "Police property")
        case .diplomaticMission:
            return NSLocalizedString("LAYER.diplomatische_vertretungen", comment: "Diplomatic mission")
        case .internationalOrganization:
            return NSLocalizedString("LAYER.internationale_organisationen", comment: "International organization")
        case .authority:
            return NSLocalizedString("LAYER.behoerden", comment: "Authority")
        case .industrialInstallation:
            return NSLocalizedString("LAYER.industrieanlagen", comment: "Industrial installation")
        case .powerLine:
            return NSLocalizedString("LAYER.stromleitungen", comment: "Power line")
        case .windFarm:
            return NSLocalizedString("LAYER.windkraftanlagen", comment: "Wind farm")
        case .motorway:
            return NSLocalizedString("LAYER.bundesautobahnen", comment: "Motorway")
        case .highway:
            return NSLocalizedString("LAYER.bundesstrassen", comment: "Highway")
        case .railway:
            return NSLocalizedString("LAYER.bahnanlagen", comment: "Railway")
        case .maritimeWaterway:
            return NSLocalizedString("LAYER.seewasserstrassen", comment: "Maritime waterway")
        case .inlandWaterway:
            return NSLocalizedString("LAYER.binnenwasserstrassen", comment: "Inland waterway")
        case .shippingInstallation:
            return NSLocalizedString("LAYER.schifffahrtsanlagen", comment: "Shipping installation")
        case .nationalPark:
            return NSLocalizedString("LAYER.nationalparks", comment: "National park")
        case .natureReserve:
            return NSLocalizedString("LAYER.naturschutzgebiete", comment: "Nature reserve")
        case .habitatDirectiveSite:
            return NSLocalizedString("LAYER.ffh-gebiete", comment: "Habitat site")
        case .birdSanctuary:
            return NSLocalizedString("LAYER.vogelschutzgebiete", comment: "Bird sanctuary")
        case .hospital:
            return NSLocalizedString("LAYER.krankenhaeuser", comment: "Hospital")
        case .recreationalArea:
            return NSLocalizedString("LAYER.freibaeder", comment: "Recreational area")
        case .residentialProperty:
            return NSLocalizedString("LAYER.wohngrundstuecke", comment: "Residential property")
        case .modelFlyingField:
            return NSLocalizedString("LAYER.modellflugplaetze", comment: "Model flying field")
        case .temporaryRestrictionInactive:
            return NSLocalizedString("LAYER.inaktive_temporaere_betriebseinschraenkungen", comment: "Inactive temporary restriction")
        }
    }

    static func formattedTypeCode(_ typeCode: String) -> String {
        let typeMap: [String: String] = [
            "FLUGPLATZ": NSLocalizedString("TYPE.FLUGPLATZ", comment: "Aerodrome"),
            "FLUGHAFEN": NSLocalizedString("TYPE.FLUGHAFEN", comment: "Airport"),
            "KONTROLLZONE": NSLocalizedString("TYPE.KONTROLLZONE", comment: "Control zone"),
            "ED-R": NSLocalizedString("TYPE.ED-R", comment: "Restricted area"),
            "WOHNGRUNDSTÜCK": NSLocalizedString("TYPE.WOHNGRUNDSTUECK", comment: "Residential property"),
            "WOHNGRUNDSTUECK": NSLocalizedString("TYPE.WOHNGRUNDSTUECK", comment: "Residential property"),
            "FREIBAD": NSLocalizedString("TYPE.FREIBAD", comment: "Outdoor pool"),
            "INDUSTRIEANLAGE": NSLocalizedString("TYPE.INDUSTRIEANLAGE", comment: "Industrial installation"),
            "KRAFTWERK": NSLocalizedString("TYPE.KRAFTWERK", comment: "Power plant"),
            "UMSPANNWERK": NSLocalizedString("TYPE.UMSPANNWERK", comment: "Substation"),
            "STROMLEITUNG": NSLocalizedString("TYPE.STROMLEITUNG", comment: "Power line"),
            "WINDKRAFTANLAGE": NSLocalizedString("TYPE.WINDKRAFTANLAGE", comment: "Wind farm"),
            "JVA": NSLocalizedString("TYPE.JVA", comment: "Prison"),
            "MILITÄRANLAGE": NSLocalizedString("TYPE.MILITAERANLAGE", comment: "Military installation"),
            "MILITAERANLAGE": NSLocalizedString("TYPE.MILITAERANLAGE", comment: "Military installation"),
            "LABOR": NSLocalizedString("TYPE.LABOR", comment: "BSL-4 facility"),
            "BEHÖRDE": NSLocalizedString("TYPE.BEHORDE", comment: "Authority"),
            "BEHOERDE": NSLocalizedString("TYPE.BEHORDE", comment: "Authority"),
            "KRANKENHAUS": NSLocalizedString("LAYER.krankenhaeuser", comment: "Hospital"),
            "NATIONALPARK": NSLocalizedString("LAYER.nationalparks", comment: "National park"),
            "NSG": NSLocalizedString("LAYER.naturschutzgebiete", comment: "Nature reserve"),
            "FFH-GEBIET": NSLocalizedString("LAYER.ffh-gebiete", comment: "Habitat site"),
            "VOGELSCHUTZGEBIET": NSLocalizedString("LAYER.vogelschutzgebiete", comment: "Bird sanctuary")
        ]

        return typeMap[typeCode.uppercased()] ?? typeCode
    }

    static func iconName(for category: ZoneCategory) -> String {
        switch category {
        case .airport, .aerodrome:
            return "airplane"
        case .controlZone:
            return "dot.radiowaves.left.and.right"
        case .modelFlyingField:
            return "paperplane.fill"
        case .industrialInstallation:
            return "building.2.fill"
        case .powerPlant, .powerLine, .substation:
            return "bolt.fill"
        case .windFarm:
            return "wind"
        case .motorway, .highway:
            return "car.fill"
        case .railway:
            return "tram.fill"
        case .inlandWaterway, .maritimeWaterway, .shippingInstallation:
            return "ferry.fill"
        case .nationalPark, .natureReserve, .habitatDirectiveSite:
            return "leaf.fill"
        case .birdSanctuary:
            return "bird.fill"
        case .militaryInstallation, .securityAuthority:
            return "shield.fill"
        case .prison:
            return "lock.fill"
        case .policeProperty:
            return "shield.checkered"
        case .authority, .diplomaticMission, .internationalOrganization:
            return "building.columns.fill"
        case .hospital:
            return "cross.case.fill"
        case .residentialProperty:
            return "house.fill"
        case .recreationalArea:
            return "figure.pool.swim"
        case .temporaryRestrictionActive, .temporaryRestrictionInactive:
            return "clock.badge.exclamationmark"
        case .bsl4Facility:
            return "flask.fill"
        case .restrictedArea:
            return "exclamationmark.triangle.fill"
        }
    }

    static func tintColor(for category: ZoneCategory) -> Color {
        switch category {
        case .airport, .aerodrome, .controlZone, .inlandWaterway, .maritimeWaterway, .shippingInstallation:
            return .blue
        case .temporaryRestrictionActive:
            return .red
        case .temporaryRestrictionInactive, .modelFlyingField, .industrialInstallation, .recreationalArea:
            return .orange
        case .powerPlant, .powerLine, .substation, .militaryInstallation, .securityAuthority:
            return .gray
        case .windFarm, .birdSanctuary:
            return .teal
        case .motorway, .highway, .railway, .prison, .authority, .diplomaticMission, .internationalOrganization, .restrictedArea:
            return .secondary
        case .nationalPark, .natureReserve, .habitatDirectiveSite:
            return .green
        case .hospital:
            return .red
        case .residentialProperty:
            return .brown
        case .policeProperty:
            return .indigo
        case .bsl4Facility:
            return .purple
        }
    }

    static func formattedAltitude(for feature: ZoneFeature) -> String? {
        let lower = formatted(limit: feature.lowerLimit)
        let upper = formatted(limit: feature.upperLimit)

        if let lower, let upper {
            return "\(lower) - \(upper)"
        }

        if let upper {
            return String(format: NSLocalizedString("ALTITUDE_UP_TO", comment: "Altitude upper limit"), upper)
        }

        if let lower {
            return String(format: NSLocalizedString("ALTITUDE_FROM", comment: "Altitude lower limit"), lower)
        }

        return nil
    }

    static func detailSummary(for feature: ZoneFeature) -> String? {
        if let restriction = feature.sourceDeclaredRestriction, !restriction.isEmpty {
            return restriction
        }

        if let altitude = formattedAltitude(for: feature) {
            return altitude
        }

        return nil
    }

    private static func formatted(limit: AltitudeLimit?) -> String? {
        guard let limit else { return nil }
        return [limit.value, limit.unit, limit.reference ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct ZoneResultHeaderPresentation {
    let title: String
    let message: String?
    let iconName: String
    let color: Color
}

enum ZoneQueryPresentation {
    static func header(for result: ZoneQueryResult) -> ZoneResultHeaderPresentation {
        switch result {
        case .clear:
            return ZoneResultHeaderPresentation(
                title: NSLocalizedString("No Restrictions", comment: "Clear result title"),
                message: NSLocalizedString("ZONE_RESULT_CLEAR_MESSAGE", comment: "Clear result message"),
                iconName: "checkmark",
                color: .green
            )
        case .matches(_, let assessment):
            switch assessment {
            case .allowed:
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("FLIGHT_PERMITTED", comment: "Flight permitted"),
                    message: NSLocalizedString("FLIGHT_ALLOWED", comment: "Flight allowed"),
                    iconName: "checkmark",
                    color: .green
                )
            case .conditional:
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("PERMITTED_UNDER_CONDITIONS", comment: "Permitted under conditions"),
                    message: NSLocalizedString("ZONE_RESULT_CONDITIONAL_MESSAGE", comment: "Conditional result message"),
                    iconName: "exclamationmark.triangle.fill",
                    color: .orange
                )
            case .prohibited:
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("FLIGHT_PROHIBITED", comment: "Flight prohibited"),
                    message: NSLocalizedString("ZONE_RESULT_PROHIBITED_MESSAGE", comment: "Prohibited result message"),
                    iconName: "xmark",
                    color: .red
                )
            }
        case .nonAssessment(.noEnabledLayers):
            return ZoneResultHeaderPresentation(
                title: NSLocalizedString("ZONE_RESULT_NOT_ASSESSED_TITLE", comment: "Not assessed title"),
                message: NSLocalizedString("ZONE_RESULT_NO_LAYERS_MESSAGE", comment: "No layers message"),
                iconName: "slider.horizontal.3",
                color: .secondary
            )
        case .unavailable(let reason):
            switch reason {
            case .outsideCoverage:
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("ZONE_RESULT_UNAVAILABLE_TITLE", comment: "Unavailable title"),
                    message: NSLocalizedString("ZONE_RESULT_OUTSIDE_COVERAGE_MESSAGE", comment: "Outside coverage message"),
                    iconName: "globe.badge.chevron.backward",
                    color: .orange
                )
            case .providerNoData:
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("ZONE_RESULT_UNAVAILABLE_TITLE", comment: "Unavailable title"),
                    message: NSLocalizedString("ZONE_RESULT_NO_DATA_MESSAGE", comment: "No data message"),
                    iconName: "questionmark.circle",
                    color: .orange
                )
            case .invalidResponse:
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("ZONE_RESULT_UNAVAILABLE_TITLE", comment: "Unavailable title"),
                    message: NSLocalizedString("ZONE_RESULT_INVALID_RESPONSE_MESSAGE", comment: "Invalid response message"),
                    iconName: "exclamationmark.circle",
                    color: .orange
                )
            case .requestFailed(let details):
                return ZoneResultHeaderPresentation(
                    title: NSLocalizedString("ZONE_RESULT_UNAVAILABLE_TITLE", comment: "Unavailable title"),
                    message: details.map { String(format: NSLocalizedString("QUERY_FAILED", comment: "Query failed"), $0) }
                        ?? NSLocalizedString("ZONE_RESULT_REQUEST_FAILED_MESSAGE", comment: "Request failed message"),
                    iconName: "wifi.exclamationmark",
                    color: .red
                )
            }
        }
    }
}
