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
        let category = Self.effectiveCategory(
            mapCategory(from: record.layerName),
            start: record.startTime,
            end: record.endTime,
            now: Date()
        )

        return ZoneFeature(
            category: category,
            restrictionLevel: Self.restrictionLevel(for: category),
            name: record.name,
            sourceDeclaredType: record.sourceDeclaredType,
            sourceDeclaredRestriction: record.sourceDeclaredRestriction ?? Self.regulatoryText(for: category),
            lowerLimit: record.lowerLimit,
            upperLimit: record.upperLimit,
            legalReference: record.legalReference,
            legalReferenceURL: Self.legalReferenceURL(for: record.legalReference),
            source: SourceProvenance(providerID: record.providerID, sourceLayerID: record.layerName),
            // Raw restriction text from the API is German; our localized fallback is not.
            restrictionSourceLanguage: record.sourceDeclaredRestriction != nil ? "de" : nil,
            supplementaryNote: Self.supplementaryNote(
                for: category, record: record, droneClass: Self.currentDroneClass()
            )
        )
    }

    // DIPUL's "active" temporary-restriction layer (temporaere_betriebseinschraenkungen) publishes
    // every valid record, including ones whose window is still in the FUTURE (and, briefly, ones
    // that just expired) — the NOTAM for a bridge demolition next week already sits in it today. A
    // temporary no-fly zone is only a real, currently-enforced prohibition while `now` is inside
    // [start, end]; before or after that it is known but not in force, so it drops to the inactive
    // category (whose verdict is conditional) instead of showing a red no-fly days early. A record
    // with no window at all is left as published (we can't prove it's dormant).
    nonisolated static func effectiveCategory(
        _ category: ZoneCategory, start: Date?, end: Date?, now: Date
    ) -> ZoneCategory {
        guard case .temporaryRestrictionActive = category else { return category }
        if let start, now < start { return .temporaryRestrictionInactive }
        if let end, now > end { return .temporaryRestrictionInactive }
        return .temporaryRestrictionActive
    }

    // Extra information shown in a zone's expandable details: a temporary restriction's validity
    // window or the drone-class advisory for residential. A feature has one category, so these
    // never collide.
    nonisolated static func supplementaryNote(
        for category: ZoneCategory, record: DIPULFeatureInfoRecord, droneClass: DroneClass
    ) -> String? {
        if let window = temporaryWindowNote(for: category, start: record.startTime, end: record.endTime) {
            return window
        }
        return classNote(for: category, droneClass: droneClass)
    }

    // The validity window for a temporary restriction (active or scheduled), shown so the pilot
    // sees exactly when it applies. Rendered in German local time (Europe/Berlin) to match the
    // published NOTAM regardless of the device's timezone; a same-day window shows the end as a
    // bare time ("25 Jul 2026, 13:30 to 15:30").
    nonisolated static func temporaryWindowNote(
        for category: ZoneCategory, start: Date?, end: Date?
    ) -> String? {
        switch category {
        case .temporaryRestrictionActive, .temporaryRestrictionInactive:
            break
        default:
            return nil
        }

        guard let start, let end else { return nil }

        let berlin = TimeZone(identifier: "Europe/Berlin")
        let dateTime = DateFormatter()
        dateTime.dateStyle = .medium
        dateTime.timeStyle = .short
        dateTime.timeZone = berlin

        var calendar = Calendar(identifier: .gregorian)
        if let berlin { calendar.timeZone = berlin }

        let startText = dateTime.string(from: start)
        let endText: String
        if calendar.isDate(start, inSameDayAs: end) {
            let timeOnly = DateFormatter()
            timeOnly.dateStyle = .none
            timeOnly.timeStyle = .short
            timeOnly.timeZone = berlin
            endText = timeOnly.string(from: end)
        } else {
            endText = dateTime.string(from: end)
        }

        return String(
            format: NSLocalizedString("DE.TEMP.WINDOW", comment: "Temporary restriction validity window"),
            startText, endText
        )
    }

    // The pilot's configured drone class, read from where DroneSettings persists it. Kept out of
    // the pure `classNote` below so that function stays testable without touching UserDefaults.
    nonisolated static func currentDroneClass() -> DroneClass {
        let raw = UserDefaults.standard.string(forKey: "droneClass") ?? DroneClass.c0.rawValue
        return DroneClass(rawValue: raw) ?? .c0
    }

    // A class-specific advisory appended below a German residential zone, for C3/C4 only.
    //
    // Only C3/C4 get one, deliberately. For C0/C1/C2 the relevant rule is already the §21h text in
    // the main tile (owner consent, the sub-0.25 kg exemption, the ≥100 m option), so a class line
    // there would just re-state part of it — and a partial re-statement reads as a contradiction
    // (e.g. mentioning consent but omitting the 100 m route). C3/C4 is different: the EU open
    // category's A3 rule adds a 150 m horizontal distance that the §21h text does not mention and
    // that removes open-category overflight entirely, so it is genuinely new information.
    // Verdict is untouched: the note informs, it does not turn the zone green.
    nonisolated static func classNote(for category: ZoneCategory, droneClass: DroneClass) -> String? {
        guard case .residentialProperty = category else { return nil }
        switch droneClass {
        case .c3, .c4:
            return NSLocalizedString("DE.RESIDENTIAL.CLASS.C3C4", comment: "German residential zone, C3/C4 drone")
        case .c0, .c1, .c2:
            return nil
        }
    }

    // German LuftVO verdict: airports and active temporary no-fly zones are hard
    // prohibitions; everything else DIPUL reports is permitted only under conditions.
    // Shared with the offline DIPUL provider so both express the same German rules.
    nonisolated static func restrictionLevel(for category: ZoneCategory) -> FlightAssessmentOutcome {
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
    // restriction text. Shared with the offline DIPUL provider (whose GeoJSON carries no
    // free-text restriction, so it always uses this localized explanation).
    nonisolated static func regulatoryText(for category: ZoneCategory) -> String {
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

    nonisolated private static func legalReferenceURL(for legalReference: String?) -> URL? {
        guard
            let legalReference,
            let match = legalReference.range(of: #"§\s*([0-9]+[a-z]?)"#, options: .regularExpression)
        else {
            return nil
        }

        let paragraph = legalReference[match]
            .replacingOccurrences(of: "§", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !paragraph.isEmpty else { return nil }
        return URL(string: "https://www.gesetze-im-internet.de/luftvo_2015/__\(paragraph).html")
    }
}
