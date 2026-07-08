//
//  DIPULZoneNormalizer.swift
//  safeFLY
//
//  Maps DIPUL (German) raw records into ZoneFeatures, and owns the German regulatory
//  verdict + explanation text. Each country's provider ships its own normalizer, so all
//  national-rule knowledge stays local to its provider.
//

import Foundation

struct DIPULZoneNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            guard let dipulRecord = record as? DIPULFeatureInfoRecord else {
                return nil
            }

            return normalize(dipulRecord)
        }
    }

    nonisolated private func normalize(_ record: DIPULFeatureInfoRecord) -> ZoneFeature {
        let category = mapCategory(from: record.layerName)

        return ZoneFeature(
            category: category,
            restrictionLevel: restrictionLevel(for: category),
            name: record.name,
            sourceDeclaredType: record.sourceDeclaredType,
            sourceDeclaredRestriction: record.sourceDeclaredRestriction ?? regulatoryText(for: category),
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: record.legalReference,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: record.layerName),
            // Raw restriction text from the API is German; our localized fallback is not.
            restrictionSourceLanguage: record.sourceDeclaredRestriction != nil ? "de" : nil
        )
    }

    // German LuftVO verdict: airports and active temporary no-fly zones are hard
    // prohibitions; everything else DIPUL reports is permitted only under conditions.
    nonisolated private func restrictionLevel(for category: ZoneCategory) -> FlightAssessmentOutcome {
        switch category {
        case .airport, .temporaryRestrictionActive:
            return .prohibited
        default:
            return .conditional
        }
    }

    nonisolated private func mapCategory(from layerName: String) -> ZoneCategory {
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

    // German regulatory explanation used when the source record does not declare its own
    // restriction text.
    nonisolated private func regulatoryText(for category: ZoneCategory) -> String {
        switch category {
        case .aerodrome:
            return NSLocalizedString("AERODROME_CONDITIONAL", comment: "Aerodrome operation conditional message")
        case .airport:
            return NSLocalizedString("AIRPORT_PROHIBITED", comment: "Airport prohibited message")
        case .controlZone:
            return NSLocalizedString("CONTROL_ZONE_CLEARANCE", comment: "Control zone requires clearance")
        case .industrialInstallation,
             .prison,
             .militaryInstallation,
             .powerPlant,
             .substation,
             .bsl4Facility,
             .authority,
             .diplomaticMission,
             .internationalOrganization,
             .policeProperty,
             .securityAuthority,
             .powerLine,
             .windFarm,
             .hospital:
            return NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator")
        case .motorway, .highway, .railway:
            return NSLocalizedString("MOTORWAY_HIGHWAY_RAILWAY_CONDITIONS", comment: "Highways/motorways/railways conditions")
        case .inlandWaterway, .maritimeWaterway, .shippingInstallation:
            return NSLocalizedString("WATERWAYS_CONDITIONS", comment: "Waterways flight conditions")
        case .natureReserve, .habitatDirectiveSite, .birdSanctuary:
            return NSLocalizedString("NATURE_AUTHORITY_CONSENT", comment: "Nature area consent message")
        case .nationalPark:
            return NSLocalizedString("NATIONAL_PARK_CONDITIONS", comment: "National park conditions")
        case .residentialProperty:
            return NSLocalizedString("RESIDENTIAL_CONDITIONS", comment: "Residential property restrictions")
        case .recreationalArea:
            return NSLocalizedString("OUTSIDE_OPERATING_HOURS", comment: "Outdoor pools restriction")
        case .temporaryRestrictionActive:
            return NSLocalizedString("TEMP_NO_FLY_PROHIBITED", comment: "Temporary no-fly zone")
        case .temporaryRestrictionInactive:
            return NSLocalizedString("INACTIVE_TEMP_RESTRICTION", comment: "Inactive temporary restriction")
        // .populatedArea is a non-German (Czech HOP) category and never reached here, but the
        // switch must stay exhaustive; fall back to the generic "check the zone" advisory.
        case .restrictedArea, .populatedArea:
            return NSLocalizedString("RESTRICTED_ZONE_CHECK", comment: "Restricted zone check message")
        case .modelFlyingField:
            return NSLocalizedString("MODEL_FLYING_FIELD_CAUTION", comment: "Model flying field caution message")
        }
    }
}
