//
//  CoverageMaskOverlay.swift
//  safeFLY
//
//  Dims the map by coverage state so users see at a glance where safeFLY has data and which of
//  those areas are switched on:
//
//   • Areas no provider covers at all are dimmed with a slightly darker gray.
//   • Areas a provider covers but the user hasn't enabled are dimmed with a lighter gray.
//   • Areas an enabled provider covers stay fully clear.
//
//  Rendered as a single native MKOverlay on the map's underlying MKMapView (the same path the
//  WMS geozone tiles use). A custom renderer fills the whole world dark, then punches every
//  covered country *clear* using the `.clear` blend mode — so adjacent or overlapping countries
//  union seamlessly with no dark seam along their shared border — and finally repaints the
//  covered-but-disabled countries with the lighter dim. Because it is a world-anchored native
//  overlay it pans and zooms with the map for free, with no per-frame geometry to rebuild.
//

import MapKit
import SwiftUI
import UIKit

// Lightweight, value-type description of one provider's coverage and whether it's active.
struct ProviderCoverageMask: Equatable {
    let providerID: String
    let isActive: Bool
    // The provider's country outline as one or more rings of [longitude, latitude] points.
    let polygons: [[[Double]]]
}

nonisolated enum CoverageMask {
    // Areas with no provider coverage at all: the heaviest dim.
    static let notCoveredFill = UIColor(white: 0.08, alpha: 0.52)
    // Areas covered by a provider the user hasn't enabled: visibly dimmed, but still
    // lighter than the "not covered" mask so users can tell the two states apart.
    static let coveredInactiveFill = UIColor(white: 0.18, alpha: 0.45)

    // Stable identity of a mask set, so the host only rebuilds the overlay when it changes.
    static func key(for masks: [ProviderCoverageMask]) -> String {
        masks.map { "\($0.providerID):\($0.isActive)" }.joined(separator: "|")
    }

    static func hasCoverage(_ masks: [ProviderCoverageMask]) -> Bool {
        masks.contains { !$0.polygons.isEmpty }
    }
}

nonisolated final class CoverageMaskOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    // Every covered country (active or inactive): punched clear so the map shows through.
    let coveredRings: [[CLLocationCoordinate2D]]
    // Covered-but-disabled countries: repainted with the lighter dim over the clear punch.
    let inactiveRings: [[CLLocationCoordinate2D]]
    // Enabled-provider countries: re-punched clear last so that where an active and an inactive
    // provider overlap (e.g. Austro Control + the disabled EU nature layer both cover Austria),
    // the active provider wins and the area is not left dimmed.
    let activeRings: [[CLLocationCoordinate2D]]

    init(masks: [ProviderCoverageMask]) {
        coveredRings = masks.flatMap { $0.polygons.map(Self.ring) }
        inactiveRings = masks.filter { !$0.isActive }.flatMap { $0.polygons.map(Self.ring) }
        activeRings = masks.filter { $0.isActive }.flatMap { $0.polygons.map(Self.ring) }
        super.init()
    }

    private static func ring(_ ring: [[Double]]) -> [CLLocationCoordinate2D] {
        ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }
}

nonisolated final class CoverageMaskRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let mask = overlay as? CoverageMaskOverlay else { return }

        // 1. Dark dim across the whole tile.
        context.setFillColor(CoverageMask.notCoveredFill.cgColor)
        context.fill(rect(for: mapRect))

        // 2. Punch every covered country clear. Filling each polygon on its own with the
        //    .clear blend mode means overlapping or adjacent countries union seamlessly, instead
        //    of leaving the dark even-odd seam a single multi-hole polygon would produce.
        context.setBlendMode(.clear)
        for ring in mask.coveredRings {
            fill(ring, in: context)
        }

        // 3. Repaint the covered-but-disabled countries with the lighter dim, as a single
        //    unioned fill. Painting each ring on its own would compound the translucent colour
        //    wherever polygons overlap — two providers over the same country (e.g. the
        //    Netherlands + the EU nature layer), or two neighbours' outward-buffered borders —
        //    darkening those areas toward the "not covered" shade and drawing a zig-zag seam
        //    along shared borders. One fill path paints the union with a single coat.
        context.setBlendMode(.normal)
        context.setFillColor(CoverageMask.coveredInactiveFill.cgColor)
        fillUnion(mask.inactiveRings, in: context)

        // 4. Punch the enabled-provider countries clear again, so a country an active provider
        //    covers is never left dimmed just because a disabled provider also overlaps it.
        context.setBlendMode(.clear)
        for ring in mask.activeRings {
            fill(ring, in: context)
        }
    }

    private func fill(_ ring: [CLLocationCoordinate2D], in context: CGContext) {
        guard ring.count > 2 else { return }
        context.beginPath()
        context.move(to: point(for: MKMapPoint(ring[0])))
        for coordinate in ring.dropFirst() {
            context.addLine(to: point(for: MKMapPoint(coordinate)))
        }
        context.closePath()
        context.fillPath()
    }

    // Fills every ring as one path so overlapping polygons are painted with a single coat of a
    // translucent colour rather than compounding. All rings are normalised to the same winding
    // first, so the nonzero-winding fill unions overlaps (they never cancel into a gap).
    private func fillUnion(_ rings: [[CLLocationCoordinate2D]], in context: CGContext) {
        context.beginPath()
        for ring in rings where ring.count > 2 {
            var points = ring.map { point(for: MKMapPoint($0)) }
            if Self.signedArea(points) < 0 { points.reverse() }
            context.move(to: points[0])
            for p in points.dropFirst() {
                context.addLine(to: p)
            }
            context.closePath()
        }
        context.fillPath()
    }

    // Shoelace signed area in the renderer's point space (no reflection in the map→point
    // transform, so orientation is preserved). Only the sign is used, to make winding uniform.
    private static func signedArea(_ points: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }
}

// Hosts the coverage overlay on the SwiftUI Map's underlying MKMapView, drawn beneath the WMS
// geozone tiles. Re-adds itself whenever the Map reasserts its own delegate and wipes the
// native overlays — the same resilience the WMS host relies on.
struct CoverageMaskNativeOverlay: UIViewRepresentable {
    let masks: [ProviderCoverageMask]
    let isVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WMSOverlayHostView {
        let view = WMSOverlayHostView()
        view.onLayout = { [weak coordinator = context.coordinator] hostView in
            coordinator?.sync(in: hostView)
        }
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: WMSOverlayHostView, context: Context) {
        context.coordinator.masks = masks
        context.coordinator.isVisible = isVisible
        context.coordinator.sync(in: uiView)
    }

    final class Coordinator: NSObject {
        var masks: [ProviderCoverageMask] = []
        var isVisible = false

        // Strong reference to the shared delegate proxy. MKMapView.delegate is weak, so without
        // this the proxy deallocates the moment it's installed and the overlay renders with no
        // renderer — i.e. no dim shows at all.
        private var delegateProxy: MapDelegateProxy?
        private weak var currentOverlay: CoverageMaskOverlay?
        private var appliedKey: String?

        func sync(in host: WMSOverlayHostView) {
            guard let mapView = host.findMKMapView() else { return }
            delegateProxy = MapDelegateProxy.installShared(on: mapView)

            let key = (isVisible && CoverageMask.hasCoverage(masks)) ? CoverageMask.key(for: masks) : "hidden"
            let overlayMissing = currentOverlay.map { overlay in
                !mapView.overlays.contains { $0 === overlay }
            } ?? true

            guard key != appliedKey || overlayMissing else { return }
            appliedKey = key

            removeCurrentOverlay(from: mapView)
            guard isVisible, CoverageMask.hasCoverage(masks) else { return }

            let overlay = CoverageMaskOverlay(masks: masks)
            currentOverlay = overlay
            // Below the labels so city names stay crisp over the dim.
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        private func removeCurrentOverlay(from mapView: MKMapView) {
            let existing = mapView.overlays.compactMap { $0 as? CoverageMaskOverlay }
            if !existing.isEmpty {
                mapView.removeOverlays(existing)
            }
            currentOverlay = nil
        }
    }
}
