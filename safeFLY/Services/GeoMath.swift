//
//  GeoMath.swift
//  safeFLY
//
//  Provider-agnostic geographic primitives shared across providers: ray-casting
//  point-in-polygon tests, polygon-with-holes containment, and circle approximation.
//  These used to be duplicated as static helpers inside individual providers and as a
//  one-off ray-cast on MapRegion.
//

import Foundation
import CoreLocation

enum GeoMath {
    // Ray-casting point-in-polygon for a single ring of [lon, lat] pairs.
    nonisolated static func contains(_ coordinate: MapCoordinate, polygon: [[Double]]) -> Bool {
        var isInside = false
        let x = coordinate.longitude
        let y = coordinate.latitude
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            guard pi.count >= 2, pj.count >= 2 else { continue }

            let xi = pi[0]
            let yi = pi[1]
            let xj = pj[0]
            let yj = pj[1]

            if (yi < y && yj >= y) || (yj < y && yi >= y) {
                if xi + (y - yi) / (yj - yi) * (xj - xi) < x {
                    isInside.toggle()
                }
            }
            j = i
        }
        return isInside
    }

    // GeoJSON-style rings: the first ring is the exterior, the rest are holes.
    nonisolated static func contains(_ coordinate: MapCoordinate, rings: [[[Double]]]) -> Bool {
        guard let exteriorRing = rings.first, !exteriorRing.isEmpty else {
            return false
        }

        guard contains(coordinate, polygon: exteriorRing) else {
            return false
        }

        for hole in rings.dropFirst() where contains(coordinate, polygon: hole) {
            return false
        }

        return true
    }

    // Ray-casting against a coarse country outline expressed as (lat, lon) vertices. Used to
    // decide which provider owns the map's attribution: neighbouring countries share diagonal
    // borders that a bounding box can't separate, so the center alone settles "which country
    // am I looking at".
    nonisolated static func contains(_ coordinate: MapCoordinate, outline: [(lat: Double, lon: Double)]) -> Bool {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        var isInside = false
        var j = outline.count - 1
        for i in 0..<outline.count {
            let vi = outline[i]
            let vj = outline[j]
            if (vi.lat > lat) != (vj.lat > lat),
               lon < (vj.lon - vi.lon) * (lat - vi.lat) / (vj.lat - vi.lat) + vi.lon {
                isInside.toggle()
            }
            j = i
        }
        return isInside
    }

    // Approximates a geodesic circle as a closed polygon for rendering and bbox math.
    nonisolated static func approximateCircle(
        centerLon: Double,
        centerLat: Double,
        radiusMeters: Double,
        segments: Int = 36
    ) -> [MapCoordinate] {
        var coords: [MapCoordinate] = []
        let earthRadius: Double = 6378137.0
        let latRad = centerLat * .pi / 180.0
        let lonRad = centerLon * .pi / 180.0
        let dDivR = radiusMeters / earthRadius

        for i in 0..<segments {
            let bearing = Double(i) * (360.0 / Double(segments)) * .pi / 180.0
            let newLatRad = asin(sin(latRad) * cos(dDivR) + cos(latRad) * sin(dDivR) * cos(bearing))
            let newLonRad = lonRad + atan2(
                sin(bearing) * sin(dDivR) * cos(latRad),
                cos(dDivR) - sin(latRad) * sin(newLatRad)
            )
            coords.append(MapCoordinate(latitude: newLatRad * 180.0 / .pi, longitude: newLonRad * 180.0 / .pi))
        }
        if let first = coords.first {
            coords.append(first)
        }
        return coords
    }
}

// An axis-aligned lat/lon bounding box used to cheaply pre-filter features before running
// the more expensive point-in-polygon / geodesic tests.
struct BoundingBox: Sendable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    nonisolated func intersects(_ other: MapRegion) -> Bool {
        let minLatRegion = other.center.latitude - other.latitudeDelta / 2
        let maxLatRegion = other.center.latitude + other.latitudeDelta / 2
        let minLonRegion = other.center.longitude - other.longitudeDelta / 2
        let maxLonRegion = other.center.longitude + other.longitudeDelta / 2

        return !(minLat > maxLatRegion || maxLat < minLatRegion || minLon > maxLonRegion || maxLon < minLonRegion)
    }

    nonisolated func contains(_ coord: MapCoordinate) -> Bool {
        coord.latitude >= minLat && coord.latitude <= maxLat &&
            coord.longitude >= minLon && coord.longitude <= maxLon
    }
}
