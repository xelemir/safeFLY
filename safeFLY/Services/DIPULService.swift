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
import SwiftUI

struct ZoneInfo: Identifiable {
    let id = UUID()
    let name: String?
    let type: String?
    let restriction: String?
    let lowerLimitAltitude: String?
    let lowerLimitUnit: String?
    let lowerLimitReference: String?
    let upperLimitAltitude: String?
    let upperLimitUnit: String?
    let upperLimitReference: String?
    let legalRef: String?
    let layerName: String?
    
    // Priority ranking for display (lower number = higher priority)
    var displayPriority: Int {
        guard let layer = layerName else { return 999 }
        
        // Tier 1: Critical aviation zones (0-9)
        if layer.contains("flughaefen") { return 0 }
        if layer.contains("kontrollzonen") { return 1 }
        if layer.contains("flugplaetze") { return 2 }
        if layer.contains("temporaere_betriebseinschraenkungen") { return 3 }
        if layer.contains("flugbeschraenkungsgebiete") { return 4 }
        
        // Tier 2: Security and sensitive facilities (10-19)
        if layer.contains("militaerische_anlagen") { return 10 }
        if layer.contains("justizvollzugsanstalten") { return 11 }
        if layer.contains("labore") { return 12 }
        if layer.contains("kraftwerke") { return 13 }
        if layer.contains("umspannwerke") { return 14 }
        
        // Tier 3: Government and authorities (20-29)
        if layer.contains("sicherheitsbehoerden") { return 20 }
        if layer.contains("polizei") { return 21 }
        if layer.contains("diplomatische_vertretungen") { return 22 }
        if layer.contains("internationale_organisationen") { return 23 }
        if layer.contains("behoerden") { return 24 }
        
        // Tier 4: Infrastructure (30-39)
        if layer.contains("industrieanlagen") { return 30 }
        if layer.contains("stromleitungen") { return 31 }
        if layer.contains("windkraftanlagen") { return 32 }
        if layer.contains("bundesautobahnen") { return 33 }
        if layer.contains("bundesstrassen") { return 34 }
        if layer.contains("bahnanlagen") { return 35 }
        
        // Tier 5: Waterways and shipping (40-49)
        if layer.contains("seewasserstrassen") { return 40 }
        if layer.contains("binnenwasserstrassen") { return 41 }
        if layer.contains("schifffahrtsanlagen") { return 42 }
        
        // Tier 6: Nature reserves (50-59)
        if layer.contains("nationalparks") { return 50 }
        if layer.contains("naturschutzgebiete") { return 51 }
        if layer.contains("ffh-gebiete") { return 52 }
        if layer.contains("vogelschutzgebiete") { return 53 }
        
        // Tier 7: Public facilities (60-69)
        if layer.contains("krankenhaeuser") { return 60 }
        if layer.contains("freibaeder") { return 61 }
        
        // Tier 8: Residential and low priority (70-79)
        if layer.contains("wohngrundstuecke") { return 70 }
        
        // Tier 9: Informational zones (80-89)
        if layer.contains("modellflugplaetze") { return 80 }
        if layer.contains("inaktive_temporaere_betriebseinschraenkungen") { return 81 }
        
        return 100 // Unknown layers
    }
    
    var formattedLowerLimit: String? {
        guard let altitude = lowerLimitAltitude else { return nil }
        let unit = lowerLimitUnit ?? "m"
        let reference = lowerLimitReference ?? ""
        return "\(altitude) \(unit) \(reference)".trimmingCharacters(in: .whitespaces)
    }
    
    var formattedUpperLimit: String? {
        guard let altitude = upperLimitAltitude else { return nil }
        let unit = upperLimitUnit ?? "m"
        let reference = upperLimitReference ?? ""
        return "\(altitude) \(unit) \(reference)".trimmingCharacters(in: .whitespaces)
    }
    
    var altitudeRestriction: String? {
        if let lower = formattedLowerLimit, let upper = formattedUpperLimit {
            return "\(lower) - \(upper)"
        } else if let upper = formattedUpperLimit {
            return String(format: NSLocalizedString("ALTITUDE_UP_TO", comment: "Altitude upper limit format"), upper)
        } else if let lower = formattedLowerLimit {
            return String(format: NSLocalizedString("ALTITUDE_FROM", comment: "Altitude lower limit format"), lower)
        }
        return nil
    }
    
    var canFly: Bool {
        // If there's a layer name, it's a restricted zone
        if let layer = layerName {
            // Check if it's a model flying field (allowed with caution)
            if layer.contains("modellflugplaetze") {
                return false // Still requires caution
            }
            // All other layers are restricted zones
            return false
        }
        
        // If any restriction data exists, it's restricted
        if restriction != nil || type != nil || legalRef != nil {
            return false
        }
        
        // If there's altitude limits, it's restricted
        if lowerLimitAltitude != nil || upperLimitAltitude != nil {
            return false
        }
        
        // Only truly clear if no data at all
        return name == "Clear Zone"
    }
    
    var flightStatus: (allowed: Bool, conditional: Bool, message: String) {
        // Clear zone - unconditionally allowed
        if name == "Clear Zone" {
            // Keep business logic using the API value 'Clear Zone' for identification.
            return (true, false, NSLocalizedString("FLIGHT_ALLOWED", comment: "Flight allowed message"))
        }
        
        guard let layer = layerName else {
            // Has data but no layer info - assume restricted
            return (false, false, NSLocalizedString("FLIGHT_RESTRICTED", comment: "Flight restricted message"))
        }
        
        // Check layer type and provide specific guidance based on §21h LuftVO
        
        // Aerodromes (within 1.5 km)
        if layer.contains("flugplaetze") {
            return (false, true, NSLocalizedString("AERODROME_CONDITIONAL", comment: "Aerodrome operation conditional message"))
        }
        
        // Airports (within 1 km or extended runway centerlines)
        if layer.contains("flughaefen") {
            return (false, false, NSLocalizedString("AIRPORT_PROHIBITED", comment: "Airport prohibited message"))
        }
        
        // Control zones
        if layer.contains("kontrollzonen") {
            return (false, true, NSLocalizedString("CONTROL_ZONE_CLEARANCE", comment: "Control zone requires clearance"))
        }
        
        // Industrial installations (within 100m)
        if layer.contains("industrieanlagen") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Prisons and secure psychiatric facilities (within 100m)
        if layer.contains("justizvollzugsanstalten") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Military installations (within 100m)
        if layer.contains("militaerische_anlagen") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Power plants (within 100m)
        if layer.contains("kraftwerke") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Substations (within 100m)
        if layer.contains("umspannwerke") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // BSL-4 laboratories (within 100m)
        if layer.contains("labore") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Government buildings and authorities (within 100m)
        if layer.contains("behoerden") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Diplomatic and consular missions (within 100m)
        if layer.contains("diplomatische_vertretungen") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // International organizations (within 100m)
        if layer.contains("internationale_organisationen") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Police properties (within 100m)
        if layer.contains("polizei") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Security authorities (within 100m)
        if layer.contains("sicherheitsbehoerden") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Federal motorways (within 100m)
        if layer.contains("bundesautobahnen") {
            return (false, true, NSLocalizedString("MOTORWAY_HIGHWAY_RAILWAY_CONDITIONS", comment: "Highways/motorways/railways conditions"))
        }
        
        // Federal highways (within 100m)
        if layer.contains("bundesstrassen") {
            return (false, true, NSLocalizedString("MOTORWAY_HIGHWAY_RAILWAY_CONDITIONS", comment: "Highways/motorways/railways conditions"))
        }
        
        // Railway installations (within 100m)
        if layer.contains("bahnanlagen") {
            return (false, true, NSLocalizedString("MOTORWAY_HIGHWAY_RAILWAY_CONDITIONS", comment: "Highways/motorways/railways conditions"))
        }
        
        // Inland waterways (within 100m)
        if layer.contains("binnenwasserstrassen") {
            return (false, true, NSLocalizedString("WATERWAYS_CONDITIONS", comment: "Waterways flight conditions"))
        }
        
        // Maritime waterways (within 100m)
        if layer.contains("seewasserstrassen") {
            return (false, true, NSLocalizedString("WATERWAYS_CONDITIONS", comment: "Waterways flight conditions"))
        }
        
        // Shipping installations
        if layer.contains("schifffahrtsanlagen") {
            return (false, true, NSLocalizedString("WATERWAYS_CONDITIONS", comment: "Waterways flight conditions"))
        }
        
        // Power lines
        if layer.contains("stromleitungen") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Wind farms
        if layer.contains("windkraftanlagen") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Nature reserves
        if layer.contains("naturschutzgebiete") {
            return (false, true, NSLocalizedString("NATURE_AUTHORITY_CONSENT", comment: "Nature area consent message"))
        }
        
        // National parks
        if layer.contains("nationalparks") {
            return (false, true, NSLocalizedString("NATIONAL_PARK_CONDITIONS", comment: "National park conditions"))
        }
        
        // Natura 2000 FFH areas
        if layer.contains("ffh-gebiete") {
            return (false, true, NSLocalizedString("NATURE_AUTHORITY_CONSENT", comment: "Nature area consent message"))
        }
        
        // Bird sanctuaries
        if layer.contains("vogelschutzgebiete") {
            return (false, true, NSLocalizedString("NATURE_AUTHORITY_CONSENT", comment: "Nature area consent message"))
        }
        
        // Residential property
        if layer.contains("wohngrundstuecke") {
            return (false, true, NSLocalizedString("RESIDENTIAL_CONDITIONS", comment: "Residential property restrictions"))
        }
        
        // Hospitals (within 100m)
        if layer.contains("krankenhaeuser") {
            return (false, true, NSLocalizedString("CONSENT_REQUIRED", comment: "Consent required from authority or facility operator"))
        }
        
        // Outdoor pools and beaches
        if layer.contains("freibaeder") {
            return (false, true, NSLocalizedString("OUTSIDE_OPERATING_HOURS", comment: "Outdoor pools restriction"))
        }
        
        // Temporary restrictions (active)
        if layer.contains("temporaere_betriebseinschraenkungen") {
            return (false, false, NSLocalizedString("TEMP_NO_FLY_PROHIBITED", comment: "Temporary no-fly zone"))
        }
        
        // Inactive temporary restrictions
        if layer.contains("inaktive_temporaere_betriebseinschraenkungen") {
            return (true, true, NSLocalizedString("INACTIVE_TEMP_RESTRICTION", comment: "Inactive temporary restriction"))
        }
        
        // General restricted areas
        if layer.contains("flugbeschraenkungsgebiete") {
            return (false, true, NSLocalizedString("RESTRICTED_ZONE_CHECK", comment: "Restricted zone check message"))
        }
        
        // Model flying fields
        if layer.contains("modellflugplaetze") {
            return (true, true, NSLocalizedString("MODEL_FLYING_FIELD_CAUTION", comment: "Model flying field caution message"))
        }
        
        // Default for any other restricted zone
        return (false, true, NSLocalizedString("RESTRICTED_ZONE_DEFAULT", comment: "Default restricted zone message"))
    }
    
    var displayTitle: String {
        // If we have a name (not Clear Zone), combine it with type info
        if let name = name, name != "Clear Zone" {
            if let type = type {
                return "\(name) - \(formatTypeCode(type))"
            } else if let layer = layerName {
                let layerFormatted = formatLayerName(layer)
                return "\(name) - \(layerFormatted)"
            }
            return name
        }
        
        // No specific name, use type or layer
        if let type = type {
            return formatTypeCode(type)
        }
        if let layer = layerName {
            return formatLayerName(layer)
        }
            return NSLocalizedString("ZONE_INFO_TITLE", comment: "Default zone title")
    }
    
    func formatTypeCode(_ typeCode: String) -> String {
        // Translate type codes to readable format
        let typeMap: [String: String] = [
            "FLUGPLATZ": NSLocalizedString("TYPE.FLUGPLATZ", comment: "Aerodrome/Helipad"),
            "FLUGHAFEN": NSLocalizedString("TYPE.FLUGHAFEN", comment: "Airport"),
            "KONTROLLZONE": NSLocalizedString("TYPE.KONTROLLZONE", comment: "Control Zone"),
            "ED-R": NSLocalizedString("TYPE.ED-R", comment: "Restricted Area"),
            "WOHNGRUNDSTÜCK": NSLocalizedString("TYPE.WOHNGRUNDSTUECK", comment: "Residential Property"),
            "WOHNGRUNDSTUECK": NSLocalizedString("TYPE.WOHNGRUNDSTUECK", comment: "Residential Property"),
            "FREIBAD": NSLocalizedString("TYPE.FREIBAD", comment: "Outdoor Pool/Beach"),
            "INDUSTRIEANLAGE": NSLocalizedString("TYPE.INDUSTRIEANLAGE", comment: "Industrial Installation"),
            "KRAFTWERK": NSLocalizedString("TYPE.KRAFTWERK", comment: "Power Plant"),
            "UMSPANNWERK": NSLocalizedString("TYPE.UMSPANNWERK", comment: "Substation"),
            "STROMLEITUNG": NSLocalizedString("TYPE.STROMLEITUNG", comment: "Power Line"),
            "WINDKRAFTANLAGE": NSLocalizedString("TYPE.WINDKRAFTANLAGE", comment: "Wind Farm"),
            "JVA": NSLocalizedString("TYPE.JVA", comment: "Prison"),
            "MILITÄRANLAGE": NSLocalizedString("TYPE.MILITAERANLAGE", comment: "Military Installation"),
            "MILITAERANLAGE": NSLocalizedString("TYPE.MILITAERANLAGE", comment: "Military Installation"),
            "LABOR": NSLocalizedString("TYPE.LABOR", comment: "BSL-4 Facility"),
            "BEHÖRDE": NSLocalizedString("TYPE.BEHORDE", comment: "Authority"),
            "BEHOERDE": NSLocalizedString("TYPE.BEHORDE", comment: "Authority"),
            "KRANKENHAUS": NSLocalizedString("TYPE.KRANKENHAUS", comment: "Hospital"),
            "NATIONALPARK": NSLocalizedString("TYPE.NATIONALPARK", comment: "National Park"),
            "NSG": NSLocalizedString("TYPE.NSG", comment: "Nature Reserve"),
            "FFH-GEBIET": NSLocalizedString("TYPE.FFH-GEBIET", comment: "Habitats Directive Site"),
            "VOGELSCHUTZGEBIET": NSLocalizedString("TYPE.VOGELSCHUTZGEBIET", comment: "Bird Sanctuary")
        ]
        
        return typeMap[typeCode.uppercased()] ?? typeCode
    }
    
    func formatLayerName(_ layer: String) -> String {
        // Convert layer names to readable format
        let layerMap: [String: String] = [
            "flugplaetze": NSLocalizedString("LAYER.flugplaetze", comment: "Aerodrome/Helipad"),
            "flughaefen": NSLocalizedString("LAYER.flughaefen", comment: "Airport"),
            "kontrollzonen": NSLocalizedString("LAYER.kontrollzonen", comment: "Control Zone"),
            "flugbeschraenkungsgebiete": NSLocalizedString("LAYER.flugbeschraenkungsgebiete", comment: "Restricted Zone"),
            "bundesautobahnen": NSLocalizedString("LAYER.bundesautobahnen", comment: "Federal Motorway"),
            "bundesstrassen": NSLocalizedString("LAYER.bundesstrassen", comment: "Federal Highway"),
            "bahnanlagen": NSLocalizedString("LAYER.bahnanlagen", comment: "Railway Installation"),
            "binnenwasserstrassen": NSLocalizedString("LAYER.binnenwasserstrassen", comment: "Inland Waterway"),
            "seewasserstrassen": NSLocalizedString("LAYER.seewasserstrassen", comment: "Maritime Waterway"),
            "schifffahrtsanlagen": NSLocalizedString("LAYER.schifffahrtsanlagen", comment: "Shipping Installation"),
            "wohngrundstuecke": NSLocalizedString("LAYER.wohngrundstuecke", comment: "Residential Property"),
            "freibaeder": NSLocalizedString("LAYER.freibaeder", comment: "Outdoor Pool/Beach"),
            "industrieanlagen": NSLocalizedString("LAYER.industrieanlagen", comment: "Industrial Installation"),
            "kraftwerke": NSLocalizedString("LAYER.kraftwerke", comment: "Power Plant"),
            "umspannwerke": NSLocalizedString("LAYER.umspannwerke", comment: "Substation"),
            "stromleitungen": NSLocalizedString("LAYER.stromleitungen", comment: "Power Line"),
            "windkraftanlagen": NSLocalizedString("LAYER.windkraftanlagen", comment: "Wind Farm"),
            "justizvollzugsanstalten": NSLocalizedString("LAYER.justizvollzugsanstalten", comment: "Prison/Secure Psychiatric Unit"),
            "militaerische_anlagen": NSLocalizedString("LAYER.militaerische_anlagen", comment: "Military Installation"),
            "labore": NSLocalizedString("LAYER.labore", comment: "BSL-4 Facility"),
            "behoerden": NSLocalizedString("LAYER.behoerden", comment: "Authority"),
            "diplomatische_vertretungen": NSLocalizedString("LAYER.diplomatische_vertretungen", comment: "Diplomatic/Consular Mission"),
            "internationale_organisationen": NSLocalizedString("LAYER.internationale_organisationen", comment: "International Organization"),
            "polizei": NSLocalizedString("LAYER.polizei", comment: "Police Property"),
            "sicherheitsbehoerden": NSLocalizedString("LAYER.sicherheitsbehoerden", comment: "Security Authority"),
            "krankenhaeuser": NSLocalizedString("LAYER.krankenhaeuser", comment: "Hospital"),
            "nationalparks": NSLocalizedString("LAYER.nationalparks", comment: "National Park"),
            "naturschutzgebiete": NSLocalizedString("LAYER.naturschutzgebiete", comment: "Nature Reserve"),
            "ffh-gebiete": NSLocalizedString("LAYER.ffh-gebiete", comment: "Habitats Directive Site"),
            "vogelschutzgebiete": NSLocalizedString("LAYER.vogelschutzgebiete", comment: "Bird Sanctuary"),
            "temporaere_betriebseinschraenkungen": NSLocalizedString("LAYER.temporaere_betriebseinschraenkungen", comment: "Temporary No-Fly Zone"),
            "inaktive_temporaere_betriebseinschraenkungen": NSLocalizedString("LAYER.inaktive_temporaere_betriebseinschraenkungen", comment: "Inactive Temporary No-Fly Zone"),
            "modellflugplaetze": NSLocalizedString("LAYER.modellflugplaetze", comment: "Model Flying Field")
        ]
        
        for (key, value) in layerMap {
            if layer.contains(key) {
                return value
            }
        }
        return NSLocalizedString("RESTRICTED_ZONE_DEFAULT_TITLE", comment: "Restricted Zone")
    }
    
    var displayIcon: String {
        guard let layer = layerName else { return "exclamationmark.triangle.fill" }
        
        // Aviation
        if layer.contains("flugplaetze") || layer.contains("flughaefen") { return "airplane" }
        if layer.contains("kontrollzonen") { return "dot.radiowaves.left.and.right" }
        if layer.contains("modellflugplaetze") { return "paperplane.fill" }
        
        // Infrastructure
        if layer.contains("industrieanlagen") { return "building.2.fill" }
        if layer.contains("kraftwerke") || layer.contains("stromleitungen") || layer.contains("umspannwerke") { return "bolt.fill" }
        if layer.contains("windkraftanlagen") { return "wind" }
        if layer.contains("bundesautobahnen") || layer.contains("bundesstrassen") { return "car.fill" }
        if layer.contains("bahnanlagen") { return "tram.fill" }
        
        // Water
        if layer.contains("binnenwasserstrassen") || layer.contains("seewasserstrassen") || layer.contains("schifffahrtsanlagen") { return "ferry.fill" }
        
        // Nature
        if layer.contains("nationalparks") || layer.contains("naturschutzgebiete") || layer.contains("ffh-gebiete") { return "leaf.fill" }
        if layer.contains("vogelschutzgebiete") { return "bird.fill" }
        
        // Government/Security
        if layer.contains("militaerische_anlagen") || layer.contains("sicherheitsbehoerden") { return "shield.fill" }
        if layer.contains("justizvollzugsanstalten") { return "lock.fill" }
        if layer.contains("polizei") { return "shield.checkered" }
        if layer.contains("behoerden") || layer.contains("diplomatische_vertretungen") { return "building.columns.fill" }
        
        // Public/Other
        if layer.contains("krankenhaeuser") { return "cross.case.fill" }
        if layer.contains("wohngrundstuecke") { return "house.fill" }
        if layer.contains("freibaeder") { return "figure.pool.swim" }
        if layer.contains("temporaere") { return "clock.badge.exclamationmark" }
        if layer.contains("labore") { return "flask.fill" }
        
        return "exclamationmark.triangle.fill"
    }
    
    var displayColors: (Color, Color) {
        guard let layer = layerName else { return (.orange, .gray) }
        
        // Aviation
        if layer.contains("flugplaetze") || layer.contains("flughaefen") { return (.white, .blue) }
        if layer.contains("kontrollzonen") { return (.blue, .blue.opacity(0.3)) }
        if layer.contains("modellflugplaetze") { return (.white, .orange) }
        
        // Infrastructure
        if layer.contains("industrieanlagen") { return (.gray, .orange) }
        if layer.contains("kraftwerke") || layer.contains("stromleitungen") || layer.contains("umspannwerke") { return (.yellow, .gray) }
        if layer.contains("windkraftanlagen") { return (.blue, .gray) }
        if layer.contains("bundesautobahnen") || layer.contains("bundesstrassen") { return (.white, .gray) }
        if layer.contains("bahnanlagen") { return (.white, .gray) }
        
        // Water
        if layer.contains("binnenwasserstrassen") || layer.contains("seewasserstrassen") || layer.contains("schifffahrtsanlagen") { return (.white, .blue) }
        
        // Nature
        if layer.contains("nationalparks") || layer.contains("naturschutzgebiete") || layer.contains("ffh-gebiete") { return (.white, .green) }
        if layer.contains("vogelschutzgebiete") { return (.orange, .green) }
        
        // Government/Security
        if layer.contains("militaerische_anlagen") || layer.contains("sicherheitsbehoerden") { return (.yellow, .gray) }
        if layer.contains("justizvollzugsanstalten") { return (.white, .gray) }
        if layer.contains("polizei") { return (.blue, .gray) }
        if layer.contains("behoerden") || layer.contains("diplomatische_vertretungen") { return (.gray, .gray.opacity(0.3)) }
        
        // Public/Other
        if layer.contains("krankenhaeuser") { return (.white, .red) }
        if layer.contains("wohngrundstuecke") { return (.white, .brown) }
        if layer.contains("freibaeder") { return (.blue, .yellow) }
        if layer.contains("temporaere") { return (.white, .red) }
        if layer.contains("labore") { return (.white, .purple) }
        
        return (.orange, .gray)
    }
}

class DIPULService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var zoneInfo: [ZoneInfo] = []
    
    @Published var failedLayers: Set<String> = []
    private var isVerifying = false
    
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
            self.failedLayers = Set(savedFailed)
        }
        
        Task {
            await verifyLayersIfNeeded()
        }
    }
    
    private func verifyLayersIfNeeded() async {
        let lastCheck = UserDefaults.standard.double(forKey: "lastLayerCheckTime")
        let now = Date().timeIntervalSince1970
        
        // Run verification if never run, or if it's been more than 12 hours
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
        
        // If many network errors, or no working layers with network errors, likely offline
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
    
    private enum LayerStatus {
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
    
    // DFS DIPUL WMS endpoint - Official endpoint from documentation
    private let baseURL = "https://uas-betrieb.de/geoservices/dipul/wms"
    
    // Generate WMS URL for current region
    func getWMSURL(for region: MKCoordinateRegion, size: CGSize, settings: DroneSettings) -> URL? {
        let expandedRegion = region
        
        let minLat = expandedRegion.center.latitude - (expandedRegion.span.latitudeDelta / 2)
        let maxLat = expandedRegion.center.latitude + (expandedRegion.span.latitudeDelta / 2)
        let minLon = expandedRegion.center.longitude - (expandedRegion.span.longitudeDelta / 2)
        let maxLon = expandedRegion.center.longitude + (expandedRegion.span.longitudeDelta / 2)
        
        let layers = getAllLayers(settings: settings)
        
        if layers.isEmpty {
            return nil
        }
        
        let width = Int(size.width)
        let height = Int(size.height)
        
        // WMS 1.3.0 with EPSG:4326 uses lat,lon order
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
    
    // Get all layer names for GetFeatureInfo query, filtered by settings
    private func getAllLayers(settings: DroneSettings) -> String {
        var layers: [String] = []
        
        func appendLayer(_ name: String) {
            if !failedLayers.contains(name) {
                layers.append(name)
            }
        }
        
        // Aviation layers
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
        
        // Infrastructure layers
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
        
        // Restricted areas
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
        
        return layers.map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .joined(separator: ",")
    }
    
    // Query zone information at a specific coordinate
    func getFeatureInfo(at coordinate: CLLocationCoordinate2D, region: MKCoordinateRegion, viewSize: CGSize, settings: DroneSettings) {
        isLoading = true
        errorMessage = nil
        zoneInfo = []
        
        // Use the same region as getWMSURL (no expansion)
        let expandedRegion = region
        
        let minLat = expandedRegion.center.latitude - (expandedRegion.span.latitudeDelta / 2)
        let maxLat = expandedRegion.center.latitude + (expandedRegion.span.latitudeDelta / 2)
        let minLon = expandedRegion.center.longitude - (expandedRegion.span.longitudeDelta / 2)
        let maxLon = expandedRegion.center.longitude + (expandedRegion.span.longitudeDelta / 2)
        
        let width = Int(viewSize.width)
        let height = Int(viewSize.height)
        
        // Convert coordinate to pixel position
        let x = Int((coordinate.longitude - minLon) / (maxLon - minLon) * Double(width))
        let y = Int((maxLat - coordinate.latitude) / (maxLat - minLat) * Double(height))
        
        let layers = getAllLayers(settings: settings)
        
        // If no layers enabled, return clear zone
        if layers.isEmpty {
            isLoading = false
            zoneInfo = [ZoneInfo(
                name: "Clear Zone",
                type: nil,
                restriction: nil,
                lowerLimitAltitude: nil,
                lowerLimitUnit: nil,
                lowerLimitReference: nil,
                upperLimitAltitude: nil,
                upperLimitUnit: nil,
                upperLimitReference: nil,
                legalRef: nil,
                layerName: nil
            )]
            return
        }
        
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
            return
        }
        
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    self?.errorMessage = String(format: NSLocalizedString("QUERY_FAILED", comment: "Query failed message"), error.localizedDescription)
                    return
                }
                
                guard let data = data,
                      let responseText = String(data: data, encoding: .utf8) else {
                    return
                }
                
                self?.parseFeatureInfo(responseText)
            }
        }.resume()
    }
    
    private func parseFeatureInfo(_ text: String) {
        // Parse the plain text response
        let lines = text.components(separatedBy: .newlines)
        
        // Check if no features found
        if text.contains("no features were found") || lines.isEmpty {
            zoneInfo = [ZoneInfo(
                name: "Clear Zone",
                type: nil,
                restriction: nil,
                lowerLimitAltitude: nil,
                lowerLimitUnit: nil,
                lowerLimitReference: nil,
                upperLimitAltitude: nil,
                upperLimitUnit: nil,
                upperLimitReference: nil,
                legalRef: nil,
                layerName: nil
            )]
            return
        }
        
        var zones: [ZoneInfo] = []
        var currentZone: [String: String] = [:]
        var currentLayer: String?
        
        for line in lines {
            // Check for new feature type section
            if line.contains("Results for FeatureType") {
                // Save previous zone if exists
                if !currentZone.isEmpty, let layer = currentLayer {
                    let zone = createZoneInfo(from: currentZone, layer: layer)
                    zones.append(zone)
                }
                
                // Extract new layer name
                if let range = line.range(of: "dipul:") {
                    let afterDipul = line[range.upperBound...]
                    if let endRange = afterDipul.range(of: "'") {
                        currentLayer = String(afterDipul[..<endRange.lowerBound])
                    }
                }
                currentZone = [:]
            }
            // Check for separator (new feature within same type)
            else if line.contains("--------------------------------------------") {
                // Save current zone if exists and not just after FeatureType header
                if !currentZone.isEmpty, let layer = currentLayer {
                    let zone = createZoneInfo(from: currentZone, layer: layer)
                    zones.append(zone)
                    currentZone = [:]
                }
            }
            // Parse field values
            else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains(" = ") {
                    let parts = trimmed.components(separatedBy: " = ")
                    if parts.count == 2 {
                        currentZone[parts[0]] = parts[1]
                    }
                }
            }
        }
        
        // Don't forget the last zone
        if !currentZone.isEmpty, let layer = currentLayer {
            let zone = createZoneInfo(from: currentZone, layer: layer)
            zones.append(zone)
        }
        
        zoneInfo = zones.isEmpty ? [ZoneInfo(
            name: "Clear Zone",
            type: nil,
            restriction: nil,
            lowerLimitAltitude: nil,
            lowerLimitUnit: nil,
            lowerLimitReference: nil,
            upperLimitAltitude: nil,
            upperLimitUnit: nil,
            upperLimitReference: nil,
            legalRef: nil,
            layerName: nil
        )] : zones
    }
    
    private func createZoneInfo(from data: [String: String], layer: String) -> ZoneInfo {
        let name = data["name"]
        let type = data["type"] ?? data["type_code"]
        let restriction = data["restriction"]
        let lowerLimitAltitude = data["lower_limit_altitude"]
        let lowerLimitUnit = data["lower_limit_unit"]
        let lowerLimitReference = data["lower_limit_reference"] ?? data["lower_limit_alt_ref"]
        let upperLimitAltitude = data["upper_limit_altitude"]
        let upperLimitUnit = data["upper_limit_unit"]
        let upperLimitReference = data["upper_limit_reference"] ?? data["upper_limit_alt_ref"]
        let legalRef = data["legal_ref"]
        
        // Filter out empty strings and "null" values
        let finalName = (name?.isEmpty == false && name?.lowercased() != "null") ? name : nil
        let finalType = (type?.isEmpty == false && type?.lowercased() != "null") ? type : nil
        
        return ZoneInfo(
            name: finalName,
            type: finalType,
            restriction: restriction,
            lowerLimitAltitude: lowerLimitAltitude,
            lowerLimitUnit: lowerLimitUnit,
            lowerLimitReference: lowerLimitReference,
            upperLimitAltitude: upperLimitAltitude,
            upperLimitUnit: upperLimitUnit,
            upperLimitReference: upperLimitReference,
            legalRef: legalRef,
            layerName: layer
        )
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
