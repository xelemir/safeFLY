//
//  CoverageMaskOverlay.swift
//  safeFLY
//
//  Dims the map by coverage state so users see at a glance where safeFLY has data and which
//  of those areas are switched on:
//
//   • Areas no provider covers at all are dimmed with a slightly darker gray.
//   • Areas a provider covers but that the user hasn't enabled are dimmed with a lighter gray.
//   • Areas an enabled provider covers stay fully clear.
//
//  Rendered with SwiftUI's own MapPolygon inside the Map content (the same path the geozone
//  polygons use) rather than by injecting overlays into the underlying MKMapView, which the
//  SwiftUI Map doesn't render reliably. The "not covered" shape is a single MKPolygon whose
//  exterior is the current viewport (sized generously) with every supported country punched
//  out as an interior hole.
//

import SwiftUI
import MapKit

// Lightweight, value-type description of one provider's coverage and whether it's active.
struct ProviderCoverageMask: Equatable {
    let providerID: String
    let isActive: Bool
    // The provider's country outline as one or more rings of [longitude, latitude] points.
    let polygons: [[[Double]]]
}

// One filled ring for a covered-but-disabled country.
struct InactiveCoverageRing: Identifiable, Equatable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]

    static func == (lhs: InactiveCoverageRing, rhs: InactiveCoverageRing) -> Bool {
        lhs.id == rhs.id
    }
}

enum CoverageMask {
    // Areas with no provider coverage at all: the heaviest dim.
    static let notCoveredFill = Color(.sRGB, white: 0.08, opacity: 0.52)
    // Areas covered by a provider the user hasn't enabled: a clearly lighter gray, but still
    // distinct from the fully-clear enabled areas.
    static let coveredInactiveFill = Color(.sRGB, white: 0.45, opacity: 0.30)

    // The "not covered" polygon: a rectangle with every supported country (active or not) cut
    // out as a hole. A single globe-spanning exterior won't tessellate in MapKit, so the
    // exterior tracks the visible region with margin — but it's always grown to also enclose
    // every country, because an MKPolygon whose interior holes spill outside its exterior
    // renders inverted (the holes fill instead of cut out). `nil` when no provider declares
    // coverage.
    static func notCoveredPolygon(masks: [ProviderCoverageMask], region: MKCoordinateRegion) -> MKPolygon? {
        let holes = masks.flatMap { $0.polygons.map(polygon) }
        guard !holes.isEmpty, let holesBox = boundingBox(of: masks) else { return nil }
        let exterior = exteriorRing(for: region, enclosing: holesBox)
        return MKPolygon(coordinates: exterior, count: exterior.count, interiorPolygons: holes)
    }

    // Bounding box of every country ring, padded slightly so the holes sit strictly inside the
    // exterior built around it.
    private static func boundingBox(of masks: [ProviderCoverageMask]) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        var sawPoint = false
        for mask in masks {
            for ring in mask.polygons {
                for point in ring {
                    sawPoint = true
                    minLon = min(minLon, point[0]); maxLon = max(maxLon, point[0])
                    minLat = min(minLat, point[1]); maxLat = max(maxLat, point[1])
                }
            }
        }
        guard sawPoint else { return nil }
        return (minLat - 1, maxLat + 1, minLon - 1, maxLon + 1)
    }

    // Filled rings for every provider the user hasn't enabled.
    static func inactiveRings(masks: [ProviderCoverageMask]) -> [InactiveCoverageRing] {
        masks.filter { !$0.isActive }.flatMap { mask in
            mask.polygons.enumerated().map { index, ring in
                InactiveCoverageRing(id: "\(mask.providerID)-\(index)", coordinates: coordinates(ring))
            }
        }
    }

    static func coordinates(_ ring: [[Double]]) -> [CLLocationCoordinate2D] {
        ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }

    private static func polygon(_ ring: [[Double]]) -> MKPolygon {
        let coords = coordinates(ring)
        return MKPolygon(coordinates: coords, count: coords.count)
    }

    // A rectangle around the region center, extended one full span beyond the visible edges so
    // a moderate pan stays covered before the next rebuild, then grown to also enclose every
    // country (`enclosing`). The viewport reach is capped so the ring never approaches the
    // antimeridian or the whole globe: a wrapped or world-sized exterior flips MapKit's winding
    // and won't tessellate. Enclosing the holes guarantees they sit inside the exterior even
    // when the region is tiny or stale, which otherwise renders the mask inverted.
    private static func exteriorRing(
        for region: MKCoordinateRegion,
        enclosing box: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    ) -> [CLLocationCoordinate2D] {
        let latReach = min(max(region.span.latitudeDelta, 0.2) * 1.5, 30)
        let lonReach = min(max(region.span.longitudeDelta, 0.2) * 1.5, 40)
        let north = min(max(region.center.latitude + latReach, box.maxLat), 89)
        let south = max(min(region.center.latitude - latReach, box.minLat), -89)
        let west = max(min(region.center.longitude - lonReach, box.minLon), -179)
        let east = min(max(region.center.longitude + lonReach, box.maxLon), 179)
        return [
            CLLocationCoordinate2D(latitude: north, longitude: west),
            CLLocationCoordinate2D(latitude: north, longitude: east),
            CLLocationCoordinate2D(latitude: south, longitude: east),
            CLLocationCoordinate2D(latitude: south, longitude: west)
        ]
    }
}
