//
//  ED269.swift
//  safeFLY
//
//  Shared model + offline geometry engine for providers backed by an ED-269 UAS-zone
//  dataset (e.g. Netherlands, Austria). The decode structs for a zone's geometry and the
//  point/region tests are identical across countries; only the surrounding envelope and the
//  national regulatory mapping differ, so those stay in each provider.
//

import Foundation
import CoreLocation

nonisolated struct ED269Geometry: Codable, Sendable {
    let upperLimit: Double?
    let lowerLimit: Double?
    let uomDimensions: String?
    let upperVerticalReference: String?
    let lowerVerticalReference: String?
    let horizontalProjection: ED269HorizontalProjection
}

nonisolated struct ED269HorizontalProjection: Codable, Sendable {
    let type: String
    let center: [Double]?           // [lon, lat]
    let radius: Double?             // meters
    let coordinates: [[[Double]]]?  // exterior/interior rings, each point [lon, lat]
}

nonisolated extension Array where Element == ED269Geometry {
    // Axis-aligned bounds across every geometry, used to cheaply pre-filter a zone before
    // running the more expensive point-in-polygon / geodesic tests.
    var boundingBox: BoundingBox? {
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        var hasCoords = false

        for geometry in self {
            let projection = geometry.horizontalProjection
            if projection.type == "Circle",
               let center = projection.center, center.count >= 2,
               let radius = projection.radius {
                let lat = center[1]
                let lon = center[0]
                let latDelta = radius / 111_111.0
                let lonDelta = radius / (111_111.0 * cos(lat * .pi / 180.0))
                minLat = Swift.min(minLat, lat - latDelta)
                maxLat = Swift.max(maxLat, lat + latDelta)
                minLon = Swift.min(minLon, lon - lonDelta)
                maxLon = Swift.max(maxLon, lon + lonDelta)
                hasCoords = true
            } else if projection.type == "Polygon", let rings = projection.coordinates {
                for ring in rings {
                    for pt in ring where pt.count >= 2 {
                        minLat = Swift.min(minLat, pt[1])
                        maxLat = Swift.max(maxLat, pt[1])
                        minLon = Swift.min(minLon, pt[0])
                        maxLon = Swift.max(maxLon, pt[0])
                        hasCoords = true
                    }
                }
            }
        }

        return hasCoords ? BoundingBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon) : nil
    }

    // Whether the coordinate is covered by any of these geometries.
    func contains(_ coordinate: MapCoordinate) -> Bool {
        for geometry in self {
            let projection = geometry.horizontalProjection
            if projection.type == "Circle",
               let center = projection.center, center.count >= 2,
               let radius = projection.radius {
                let centerLoc = CLLocation(latitude: center[1], longitude: center[0])
                let pointLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                if centerLoc.distance(from: pointLoc) <= radius {
                    return true
                }
            } else if projection.type == "Polygon",
                      let rings = projection.coordinates,
                      GeoMath.contains(coordinate, rings: rings) {
                return true
            }
        }
        return false
    }

    // One closed coordinate ring per geometry, ready to hand to a polygon render payload.
    // Circles are approximated; polygons use their exterior ring.
    func renderRings() -> [[MapCoordinate]] {
        var rings: [[MapCoordinate]] = []
        for geometry in self {
            let projection = geometry.horizontalProjection
            if projection.type == "Circle",
               let center = projection.center, center.count >= 2,
               let radius = projection.radius {
                rings.append(GeoMath.approximateCircle(centerLon: center[0], centerLat: center[1], radiusMeters: radius))
            } else if projection.type == "Polygon",
                      let coordinates = projection.coordinates,
                      let exteriorRing = coordinates.first {
                let ring = exteriorRing.compactMap { pt -> MapCoordinate? in
                    guard pt.count >= 2 else { return nil }
                    return MapCoordinate(latitude: pt[1], longitude: pt[0])
                }
                if !ring.isEmpty {
                    rings.append(ring)
                }
            }
        }
        return rings
    }
}

// Strips a UTF-8 BOM and any leading junk before the first JSON token, then returns the
// remaining bytes. ED-269 downloads from several authorities are prefixed this way.
nonisolated func ed269StrippedJSONData(_ data: Data) throws -> Data {
    guard let raw = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "ED269", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode UTF-8"])
    }

    let firstToken = raw.firstIndex { $0 == "{" || $0 == "[" }
    let cleaned = firstToken.map { String(raw[$0...]) } ?? raw
    guard let cleanData = cleaned.data(using: .utf8) else {
        throw NSError(domain: "ED269", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to re-encode JSON"])
    }
    return cleanData
}
