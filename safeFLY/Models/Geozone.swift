//
//  Geozone.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import Foundation
import CoreLocation

// GeoJSON Feature Collection
struct GeoJSONFeatureCollection: Codable {
    let type: String
    let features: [GeozoneFeature]
}

struct GeozoneFeature: Codable, Identifiable {
    let type: String
    let id: String
    let geometry: GeozoneGeometry
    let properties: GeozoneProperties
    
    enum CodingKeys: String, CodingKey {
        case type, geometry, properties, id
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        geometry = try container.decode(GeozoneGeometry.self, forKey: .geometry)
        properties = try container.decode(GeozoneProperties.self, forKey: .properties)
        
        // Try to get id as string, or generate one
        if let idString = try? container.decode(String.self, forKey: .id) {
            id = idString
        } else if let idInt = try? container.decode(Int.self, forKey: .id) {
            id = String(idInt)
        } else {
            id = UUID().uuidString
        }
    }
}

struct GeozoneGeometry: Codable {
    let type: String
    let coordinates: [[[Double]]]
    
    enum CodingKeys: String, CodingKey {
        case type, coordinates
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        
        // Handle both Polygon and MultiPolygon
        if type == "Polygon" {
            let polyCoords = try container.decode([[[Double]]].self, forKey: .coordinates)
            coordinates = polyCoords
        } else if type == "MultiPolygon" {
            let multiPolyCoords = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            coordinates = multiPolyCoords.first ?? []
        } else {
            coordinates = []
        }
    }
}

struct GeozoneProperties: Codable {
    let name: String?
    let type: String?
    let restriction: String?
    let upperLimit: Double?
    let lowerLimit: Double?
    let legalRef: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case type
        case restriction
        case upperLimit = "upper_limit_altitude"
        case lowerLimit = "lower_limit_altitude"
        case legalRef = "legal_ref"
    }
}
