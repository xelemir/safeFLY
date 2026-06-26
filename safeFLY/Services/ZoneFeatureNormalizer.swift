//
//  ZoneFeatureNormalizer.swift
//  safeFLY
//

import Foundation

struct ZoneFeatureNormalizer: ZoneFeatureNormalizing, Sendable {
    nonisolated func normalize(records: [any ProviderRawRecord]) -> [ZoneFeature] {
        records.compactMap { record in
            if let dipulRecord = record as? DIPULFeatureInfoRecord {
                return normalize(dipulRecord)
            }

            return nil
        }
    }

    nonisolated private func normalize(_ record: DIPULFeatureInfoRecord) -> ZoneFeature {
        ZoneFeature(
            category: mapCategory(from: record.layerName),
            name: record.name,
            sourceDeclaredType: record.sourceDeclaredType,
            sourceDeclaredRestriction: record.sourceDeclaredRestriction,
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: record.legalReference,
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: record.layerName)
        )
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
}
