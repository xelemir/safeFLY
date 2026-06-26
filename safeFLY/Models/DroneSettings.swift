//
//  DroneSettings.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import Foundation
import Combine
import CoreLocation

struct SearchCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    static func == (lhs: SearchCoordinate, rhs: SearchCoordinate) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

enum DroneClass: String, CaseIterable, Codable {
    case c0 = "C0"
    case c1 = "C1"
    case c2 = "C2"
    case c3 = "C3"
    case c4 = "C4"
    
    var description: String {
        switch self {
        case .c0: return NSLocalizedString("C0 - <250g", comment: "Drone class C0 label")
        case .c1: return NSLocalizedString("C1 - <900g", comment: "Drone class C1 label")
        case .c2: return NSLocalizedString("C2 - <4kg", comment: "Drone class C2 label")
        case .c3: return NSLocalizedString("C3 - <25kg", comment: "Drone class C3 label")
        case .c4: return NSLocalizedString("C4 - <25kg", comment: "Drone class C4 label")
        }
    }
}

struct CameraUpdate: Equatable {
    let latitude: Double
    let longitude: Double
    let distance: Double
}

class DroneSettings: ObservableObject {
    @Published var activeTab: Int = 0
    @Published var simulatedTapCoordinate: SearchCoordinate?
    @Published var dismissActiveSheet: Bool = false
    @Published var simulatedCameraUpdate: CameraUpdate?
    @Published var onboardingPinCoordinate: SearchCoordinate?
    
    @Published var droneClass: DroneClass {
        didSet {
            UserDefaults.standard.set(droneClass.rawValue, forKey: "droneClass")
        }
    }
    
    @Published var operatorID: String {
        didSet {
            UserDefaults.standard.set(operatorID, forKey: "operatorID")
        }
    }


    // Map Layer Toggles
    @Published var showAirports: Bool {
        didSet { UserDefaults.standard.set(showAirports, forKey: "showAirports") }
    }
    
    @Published var showAerodromes: Bool {
        didSet { UserDefaults.standard.set(showAerodromes, forKey: "showAerodromes") }
    }
    
    @Published var showControlZones: Bool {
        didSet { UserDefaults.standard.set(showControlZones, forKey: "showControlZones") }
    }
    
    @Published var showRestrictedAreas: Bool {
        didSet { UserDefaults.standard.set(showRestrictedAreas, forKey: "showRestrictedAreas") }
    }
    
    @Published var showMotorways: Bool {
        didSet { UserDefaults.standard.set(showMotorways, forKey: "showMotorways") }
    }
    
    @Published var showHighways: Bool {
        didSet { UserDefaults.standard.set(showHighways, forKey: "showHighways") }
    }
    
    @Published var showRailways: Bool {
        didSet { UserDefaults.standard.set(showRailways, forKey: "showRailways") }
    }
    
    @Published var showWaterways: Bool {
        didSet { UserDefaults.standard.set(showWaterways, forKey: "showWaterways") }
    }
    
    @Published var showResidential: Bool {
        didSet { UserDefaults.standard.set(showResidential, forKey: "showResidential") }
    }
    
    @Published var showRecreational: Bool {
        didSet { UserDefaults.standard.set(showRecreational, forKey: "showRecreational") }
    }
    
    @Published var showIndustrial: Bool {
        didSet { UserDefaults.standard.set(showIndustrial, forKey: "showIndustrial") }
    }
    
    @Published var showGovernment: Bool {
        didSet { UserDefaults.standard.set(showGovernment, forKey: "showGovernment") }
    }
    
    @Published var showNatureReserves: Bool {
        didSet { UserDefaults.standard.set(showNatureReserves, forKey: "showNatureReserves") }
    }
    
    @Published var showTemporaryRestrictions: Bool {
        didSet { UserDefaults.standard.set(showTemporaryRestrictions, forKey: "showTemporaryRestrictions") }
    }
    
    @Published var showModelFlyingFields: Bool {
        didSet { UserDefaults.standard.set(showModelFlyingFields, forKey: "showModelFlyingFields") }
    }
    
    @Published var lastCameraLatitude: Double {
        didSet {
            UserDefaults.standard.set(lastCameraLatitude, forKey: "lastCameraLatitude")
        }
    }
    
    @Published var lastCameraLongitude: Double {
        didSet {
            UserDefaults.standard.set(lastCameraLongitude, forKey: "lastCameraLongitude")
        }
    }
    
    @Published var lastCameraDistance: Double {
        didSet {
            UserDefaults.standard.set(lastCameraDistance, forKey: "lastCameraDistance")
        }
    }

    
    @Published var searchedCoordinate: SearchCoordinate?
    
    init() {
        let savedClass = UserDefaults.standard.string(forKey: "droneClass") ?? DroneClass.c0.rawValue
        self.droneClass = DroneClass(rawValue: savedClass) ?? .c0
        self.operatorID = UserDefaults.standard.string(forKey: "operatorID") ?? ""


        // Initialize layer toggles - default to true if not yet set
        if UserDefaults.standard.object(forKey: "showAirports") == nil {
            self.showAirports = true
        } else {
            self.showAirports = UserDefaults.standard.bool(forKey: "showAirports")
        }
        
        if UserDefaults.standard.object(forKey: "showAerodromes") == nil {
            self.showAerodromes = true
        } else {
            self.showAerodromes = UserDefaults.standard.bool(forKey: "showAerodromes")
        }
        
        if UserDefaults.standard.object(forKey: "showControlZones") == nil {
            self.showControlZones = true
        } else {
            self.showControlZones = UserDefaults.standard.bool(forKey: "showControlZones")
        }
        
        if UserDefaults.standard.object(forKey: "showRestrictedAreas") == nil {
            self.showRestrictedAreas = true
        } else {
            self.showRestrictedAreas = UserDefaults.standard.bool(forKey: "showRestrictedAreas")
        }
        
        if UserDefaults.standard.object(forKey: "showMotorways") == nil {
            self.showMotorways = true
        } else {
            self.showMotorways = UserDefaults.standard.bool(forKey: "showMotorways")
        }
        
        if UserDefaults.standard.object(forKey: "showHighways") == nil {
            self.showHighways = true
        } else {
            self.showHighways = UserDefaults.standard.bool(forKey: "showHighways")
        }
        
        if UserDefaults.standard.object(forKey: "showRailways") == nil {
            self.showRailways = true
        } else {
            self.showRailways = UserDefaults.standard.bool(forKey: "showRailways")
        }
        
        if UserDefaults.standard.object(forKey: "showWaterways") == nil {
            self.showWaterways = true
        } else {
            self.showWaterways = UserDefaults.standard.bool(forKey: "showWaterways")
        }
        
        if UserDefaults.standard.object(forKey: "showResidential") == nil {
            self.showResidential = true
        } else {
            self.showResidential = UserDefaults.standard.bool(forKey: "showResidential")
        }
        
        if UserDefaults.standard.object(forKey: "showRecreational") == nil {
            self.showRecreational = true
        } else {
            self.showRecreational = UserDefaults.standard.bool(forKey: "showRecreational")
        }
        
        if UserDefaults.standard.object(forKey: "showIndustrial") == nil {
            self.showIndustrial = true
        } else {
            self.showIndustrial = UserDefaults.standard.bool(forKey: "showIndustrial")
        }
        
        if UserDefaults.standard.object(forKey: "showGovernment") == nil {
            self.showGovernment = true
        } else {
            self.showGovernment = UserDefaults.standard.bool(forKey: "showGovernment")
        }
        
        if UserDefaults.standard.object(forKey: "showNatureReserves") == nil {
            self.showNatureReserves = true
        } else {
            self.showNatureReserves = UserDefaults.standard.bool(forKey: "showNatureReserves")
        }
        
        if UserDefaults.standard.object(forKey: "showTemporaryRestrictions") == nil {
            self.showTemporaryRestrictions = true
        } else {
            self.showTemporaryRestrictions = UserDefaults.standard.bool(forKey: "showTemporaryRestrictions")
        }
        
        if UserDefaults.standard.object(forKey: "showModelFlyingFields") == nil {
            self.showModelFlyingFields = true
        } else {
            self.showModelFlyingFields = UserDefaults.standard.bool(forKey: "showModelFlyingFields")
        }
        
        // Load saved camera position, default to Germany center
        self.lastCameraLatitude = UserDefaults.standard.double(forKey: "lastCameraLatitude")
        self.lastCameraLongitude = UserDefaults.standard.double(forKey: "lastCameraLongitude")
        self.lastCameraDistance = UserDefaults.standard.double(forKey: "lastCameraDistance")
        
        // If no saved position, use default Germany center
        if lastCameraLatitude == 0 && lastCameraLongitude == 0 {
            lastCameraLatitude = 51.1657
            lastCameraLongitude = 10.4515
            lastCameraDistance = 1000000
        }
    }
}
