//
//  GeoJSONGeometry.swift
//  safeFLY
//
//  Bridges plain GeoJSON (RFC 7946) geometry into the app's shared `[ED269Geometry]`
//  representation, so the *live* GeoJSON-backed providers — Belgium (skeyes WFS) and Denmark
//  (Trafikstyrelsen ArcGIS `f=geojson`) — reuse the very same offline point-in-polygon,
//  bounding-box and render-ring engine the ED-269 *file* providers (Netherlands, Austria,
//  Luxembourg) already use. Only areal geometries are relevant to drone zones, so Polygon and
//  MultiPolygon are converted and every other geometry type decodes to no rings.
//

import Foundation

// A decoded GeoJSON geometry, exposed only as the ED-269 polygon rings the rest of the app
// understands. A GeoJSON MultiPolygon fans out into one `ED269Geometry` per member polygon,
// mirroring how a zone with several disjoint areas is modelled elsewhere.
nonisolated struct GeoJSONGeometry: Decodable, Sendable {
    let ed269: [ED269Geometry]

    private enum CodingKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "Polygon":
            let rings = (try? container.decode([[[Double]]].self, forKey: .coordinates)) ?? []
            ed269 = rings.isEmpty ? [] : [GeoJSONGeometry.polygon(rings)]
        case "MultiPolygon":
            let polygons = (try? container.decode([[[[Double]]]].self, forKey: .coordinates)) ?? []
            ed269 = polygons.compactMap { $0.isEmpty ? nil : GeoJSONGeometry.polygon($0) }
        default:
            // Points, lines, GeometryCollections etc. are not drone-zone areas.
            ed269 = []
        }
    }

    // Wraps GeoJSON polygon rings ([[[lon, lat]]]) in an ED-269 "Polygon" horizontal projection.
    // Altitude limits live on the owning feature's properties for these providers, not on the
    // geometry, so the vertical fields stay nil here.
    private static func polygon(_ rings: [[[Double]]]) -> ED269Geometry {
        ED269Geometry(
            upperLimit: nil,
            lowerLimit: nil,
            uomDimensions: nil,
            upperVerticalReference: nil,
            lowerVerticalReference: nil,
            horizontalProjection: ED269HorizontalProjection(
                type: "Polygon",
                center: nil,
                radius: nil,
                coordinates: rings
            )
        )
    }
}

// A minimal GeoJSON FeatureCollection generic over each provider's own properties model. Both
// the skeyes WFS and the ArcGIS `f=geojson` responses are standard FeatureCollections, so this
// one decoder serves both; a feature whose geometry is null or non-areal simply contributes no
// rings.
nonisolated struct GeoJSONFeatureCollection<Properties: Decodable & Sendable>: Decodable, Sendable {
    let features: [GeoJSONFeature<Properties>]
}

nonisolated struct GeoJSONFeature<Properties: Decodable & Sendable>: Decodable, Sendable {
    let geometry: GeoJSONGeometry?
    let properties: Properties

    var ed269Geometry: [ED269Geometry] { geometry?.ed269 ?? [] }
}
