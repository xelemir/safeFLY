//
//  OfflineMapLibreView.swift
//  safeFLY
//
//  UIViewRepresentable wrapping MLNMapView to render OpenFreeMap vector tiles.
//  Used as the 4th "Offline" map style, swapped in when selectedMapStyle == 3.
//  Mirrors the MapKit map's camera, geozone overlays, and tap handling.
//

import SwiftUI
import MapKit
import MapLibre
import Network

struct OfflineMapLibreView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var centerOnUser: Bool
    let wmsPayloads: [WMSRenderPayload]
    let polygonPayloads: [PolygonRenderPayload]
    let tappedLocation: CLLocationCoordinate2D?
    let onboardingPinCoordinate: SearchCoordinate?
    let onTap: (CLLocationCoordinate2D) -> Void
    let onCameraChange: (MKCoordinateRegion) -> Void
    let onCameraChangeEnd: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        // Initialize with a non-zero frame to ensure MapLibre starts layout properly
        let mapView = MLNMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), styleURL: OfflineMapStore.styleURL)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.compassView.isHidden = true
        mapView.attributionButton.isHidden = true

        // Disable rotation and pitch to match the MapKit setup
        mapView.allowsRotating = false
        mapView.allowsTilting = false

        // Set initial camera from current region
        let center = region.center
        if CLLocationCoordinate2DIsValid(center) && center.latitude != 0 && center.longitude != 0 {
            mapView.setCenter(center, zoomLevel: zoomLevel(for: region), animated: false)
            context.coordinator.lastDelegateRegion = region
        }

        // Add tap gesture
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        if let gestureRecognizers = mapView.gestureRecognizers {
            for recognizer in gestureRecognizers {
                if let tapRecognizer = recognizer as? UITapGestureRecognizer,
                   tapRecognizer.numberOfTapsRequired == 2 {
                    tap.require(toFail: tapRecognizer)
                }
            }
        }
        mapView.addGestureRecognizer(tap)

        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        // Keep the coordinator's copy fresh: it reads parent.wmsPayloads/polygonPayloads in
        // didFinishLoading, which would otherwise see the values from the first render.
        coordinator.parent = self

        if centerOnUser {
            if let userLocation = mapView.userLocation, CLLocationCoordinate2DIsValid(userLocation.coordinate), userLocation.coordinate.latitude != 0 || userLocation.coordinate.longitude != 0 {
                mapView.setCenter(userLocation.coordinate, zoomLevel: 14.0, animated: true)
            } else {
                mapView.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
            }
            DispatchQueue.main.async {
                self.centerOnUser = false
            }
        }

        // Update camera from SwiftUI state (e.g. search result, onboarding)
        // but guard against feedback loops using lastDelegateRegion comparison & isDragging flags.
        let targetCenter = region.center
        if CLLocationCoordinate2DIsValid(targetCenter) && targetCenter.latitude != 0 && targetCenter.longitude != 0 {
            if coordinator.isDragging {
                // Skips setCenter if the user is actively dragging/animating the map
            } else if let lastRegion = coordinator.lastDelegateRegion, coordinator.regionsAreEqual(region, lastRegion) {
                // Skips setCenter if the region update originated from map interaction
            } else {
                // Re-deriving zoom from the span (a lossy log2 approximation) doesn't round-trip
                // to the map's real zoom, so a pure re-center — e.g. tapping to open the zone
                // sheet, which shifts only `region.center` — would visibly jog the zoom. When the
                // span is unchanged, keep the map's actual zoom; only recompute for genuine zoom
                // changes like a search result setting a fresh span.
                let spanUnchanged = coordinator.lastDelegateRegion.map { last in
                    abs(last.span.latitudeDelta - region.span.latitudeDelta) < 0.00001 &&
                    abs(last.span.longitudeDelta - region.span.longitudeDelta) < 0.00001
                } ?? false
                let targetZoom = spanUnchanged ? mapView.zoomLevel : zoomLevel(for: region)
                mapView.setCenter(targetCenter, zoomLevel: targetZoom, animated: true)
                coordinator.lastDelegateRegion = region
            }
        }

        // Update geozone overlays
        coordinator.updateOverlays(
            wmsPayloads: wmsPayloads,
            polygonPayloads: polygonPayloads,
            on: mapView
        )

        // Update annotations (tapped pin, onboarding pin)
        coordinator.updateAnnotations(
            tappedLocation: tappedLocation,
            onboardingPin: onboardingPinCoordinate,
            on: mapView
        )
    }

    // Convert MKCoordinateRegion span to MapLibre zoom level.
    private func zoomLevel(for region: MKCoordinateRegion) -> Double {
        let maxDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
        guard maxDelta > 0 && !maxDelta.isNaN && !maxDelta.isInfinite else { return 14 }
        // Rough approximation: zoom ≈ log2(360 / delta)
        let zoom = log2(360.0 / maxDelta)
        return min(max(zoom, 0), 20)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: OfflineMapLibreView
        weak var mapView: MLNMapView?
        var lastDelegateRegion: MKCoordinateRegion?
        var isDragging = false
        private var styleLoaded = false

        // Track current overlay IDs to diff updates
        private var currentWMSIDs: Set<String> = []
        private var currentPolygonIDs: Set<String> = []
        private var currentWMSPayloads: [WMSRenderPayload] = []
        private var currentPolygonPayloads: [PolygonRenderPayload] = []
        private var lastNetworkConnected = true
        private var downloadTasks: [String: URLSessionDataTask] = [:]

        // Annotation tracking
        private var tappedAnnotation: MLNPointAnnotation?
        private var onboardingAnnotation: MLNPointAnnotation?

        private var lastTappedLocation: CLLocationCoordinate2D?
        private var lastOnboardingPin: SearchCoordinate?

        init(parent: OfflineMapLibreView) {
            self.parent = parent
        }

        func regionsAreEqual(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.00001 &&
            abs(lhs.center.longitude - rhs.center.longitude) < 0.00001 &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.00001 &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.00001
        }

        // MARK: - Map Delegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            updateOverlays(
                wmsPayloads: parent.wmsPayloads,
                polygonPayloads: parent.polygonPayloads,
                on: mapView
            )
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            print("OfflineMapLibreView: Map style failed to load: \(error.localizedDescription)")
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            isDragging = true
            let newRegion = mkRegion(from: mapView)
            lastDelegateRegion = newRegion
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onCameraChange(newRegion)
                self.parent.region = newRegion
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            isDragging = false
            let newRegion = mkRegion(from: mapView)
            lastDelegateRegion = newRegion
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.region = newRegion
                self.parent.onCameraChangeEnd(newRegion)
            }
        }

        // MARK: - Annotation Views

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is MLNUserLocation {
                let reuseID = "userLocation"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? SafeFlyUserLocationAnnotationView
                if annotationView == nil {
                    annotationView = SafeFlyUserLocationAnnotationView(reuseIdentifier: reuseID)
                }
                return annotationView
            }

            guard annotation is MLNPointAnnotation else { return nil }

            let isTapped = annotation === tappedAnnotation
            let reuseID = isTapped ? "tappedPin" : "onboardingPin"

            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
            if annotationView == nil {
                annotationView = MLNAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
                annotationView?.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            }

            // Remove existing subviews to prevent duplicate images on dequeued views
            annotationView?.subviews.forEach { $0.removeFromSuperview() }

            var config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
            let symbolName: String
            let tintColor: UIColor
            let paletteColors: [UIColor]?

            if isTapped {
                if #available(iOS 26.0, *) {
                    symbolName = "dot.crosshair"
                    tintColor = .systemRed
                    paletteColors = nil
                } else {
                    symbolName = "mappin.circle.fill"
                    tintColor = .systemBlue
                    paletteColors = [.white, .systemBlue]
                }
            } else {
                symbolName = "mappin.circle.fill"
                tintColor = .systemRed
                paletteColors = [.white, .systemRed]
            }

            if let paletteColors = paletteColors {
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: paletteColors))
            }

            let image = UIImage(systemName: symbolName, withConfiguration: config)
            let imageView = UIImageView(image: image)
            if paletteColors == nil {
                imageView.tintColor = tintColor
            }
            
            imageView.frame = annotationView!.bounds
            imageView.contentMode = .center
            annotationView?.addSubview(imageView)
            return annotationView
        }

        // MARK: - Tap Gesture

        @objc func handleMapTap(_ sender: UITapGestureRecognizer) {
            guard let mapView = sender.view as? MLNMapView else { return }
            let point = sender.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: nil)
            parent.onTap(coordinate)
        }

        // MARK: - Overlay Management

        func updateOverlays(
            wmsPayloads: [WMSRenderPayload],
            polygonPayloads: [PolygonRenderPayload],
            on mapView: MLNMapView
        ) {
            guard styleLoaded, let style = mapView.style else { return }

            // If overlays haven't changed, skip style modification to prevent main-thread freeze.
            // Connectivity is part of the check: going offline strips the live WMS layers below,
            // so coming back online with identical payloads must not short-circuit here.
            let isNetworkConnected = NetworkMonitor.shared.isConnected
            if wmsPayloads == currentWMSPayloads && polygonPayloads == currentPolygonPayloads
                && isNetworkConnected == lastNetworkConnected {
                return
            }
            lastNetworkConnected = isNetworkConnected

            // --- Polygon overlays ---
            let newPolygonIDs = Set(polygonPayloads.map { "safeFLY-poly-\($0.id)" })
            let newWMSIDs = Set(wmsPayloads.map { "safeFLY-wms-\($0.id)" })

            // Remove stale polygon layers/sources
            for oldID in currentPolygonIDs.subtracting(newPolygonIDs) {
                if let layer = style.layer(withIdentifier: "\(oldID)-fill") {
                    style.removeLayer(layer)
                }
                if let layer = style.layer(withIdentifier: "\(oldID)-line") {
                    style.removeLayer(layer)
                }
                if let source = style.source(withIdentifier: oldID) {
                    style.removeSource(source)
                }
            }

            // Add/update polygon layers
            for payload in polygonPayloads {
                let sourceID = "safeFLY-poly-\(payload.id)"
                let fillLayerID = "\(sourceID)-fill"
                let lineLayerID = "\(sourceID)-line"

                // Check if the polygon is already added and has not changed
                if let oldPayload = currentPolygonPayloads.first(where: { $0.id == payload.id }),
                   oldPayload == payload {
                    if style.source(withIdentifier: sourceID) != nil {
                        continue // Already added and unchanged
                    }
                }

                // If it changed, or doesn't exist, remove the old layer/source first
                if style.source(withIdentifier: sourceID) != nil {
                    if let fillLayer = style.layer(withIdentifier: fillLayerID) {
                        style.removeLayer(fillLayer)
                    }
                    if let lineLayer = style.layer(withIdentifier: lineLayerID) {
                        style.removeLayer(lineLayer)
                    }
                    if let source = style.source(withIdentifier: sourceID) {
                        style.removeSource(source)
                    }
                }

                let coordinates = payload.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                guard coordinates.count > 2 else { continue }

                let polygon = MLNPolygon(coordinates: coordinates, count: UInt(coordinates.count))
                let source = MLNShapeSource(identifier: sourceID, shape: polygon, options: nil)
                style.addSource(source)

                let fillLayer = MLNFillStyleLayer(identifier: fillLayerID, source: source)
                fillLayer.fillColor = NSExpression(forConstantValue: uiColor(hex: payload.fillColorHex))
                fillLayer.fillOpacity = NSExpression(forConstantValue: NSNumber(value: payload.fillOpacity))
                style.addLayer(fillLayer)

                let lineLayer = MLNLineStyleLayer(identifier: lineLayerID, source: source)
                lineLayer.lineColor = NSExpression(forConstantValue: uiColor(hex: payload.strokeColorHex))
                lineLayer.lineOpacity = NSExpression(forConstantValue: NSNumber(value: payload.strokeOpacity))
                lineLayer.lineWidth = NSExpression(forConstantValue: NSNumber(value: payload.lineWidth))
                style.addLayer(lineLayer)
            }
            currentPolygonIDs = newPolygonIDs
            currentPolygonPayloads = polygonPayloads

            // Remove stale WMS layers/sources
            for oldID in currentWMSIDs.subtracting(newWMSIDs) {
                if let layer = style.layer(withIdentifier: "\(oldID)-raster") {
                    style.removeLayer(layer)
                }
                if let source = style.source(withIdentifier: oldID) {
                    style.removeSource(source)
                }
            }

            // Cancel stale downloads
            for (id, task) in downloadTasks where !newWMSIDs.contains(id) {
                task.cancel()
                downloadTasks[id] = nil
            }

            // Add/update WMS image sources
            for payload in wmsPayloads {
                let sourceID = "safeFLY-wms-\(payload.id)"
                let layerID = "\(sourceID)-raster"

                // If actually offline, remove any live provider overlays immediately and cancel active tasks
                if !isNetworkConnected {
                    if let existingLayer = style.layer(withIdentifier: layerID) {
                        style.removeLayer(existingLayer)
                    }
                    if let existingSource = style.source(withIdentifier: sourceID) {
                        style.removeSource(existingSource)
                    }
                    if let activeTask = downloadTasks[sourceID] {
                        activeTask.cancel()
                        downloadTasks[sourceID] = nil
                    }
                    continue
                }

                // Check if the WMS overlay is already added and has not changed
                if let oldPayload = currentWMSPayloads.first(where: { $0.id == payload.id }),
                   oldPayload == payload {
                    if style.source(withIdentifier: sourceID) != nil {
                        continue // Already added and unchanged
                    }
                }

                // If the payload changed or it doesn't exist, cancel any active download for this WMS overlay
                if let activeTask = downloadTasks[sourceID] {
                    activeTask.cancel()
                    downloadTasks[sourceID] = nil
                }

                // Download the image then add/replace the MLNImageSource
                let task = URLSession.shared.dataTask(with: payload.imageURL) { data, _, error in
                    if let data = data, let image = UIImage(data: data), error == nil {
                        Task { @MainActor [weak self] in
                            guard let self, let mapView = self.mapView, let style = mapView.style else { return }
                            self.downloadTasks[sourceID] = nil

                            if let existingLayer = style.layer(withIdentifier: layerID) {
                                style.removeLayer(existingLayer)
                            }
                            if let existingSource = style.source(withIdentifier: sourceID) {
                                style.removeSource(existingSource)
                            }

                            let quad = self.coordinateQuad(for: payload.region)
                            let imageSource = MLNImageSource(identifier: sourceID, coordinateQuad: quad, image: image)
                            style.addSource(imageSource)

                            let rasterLayer = MLNRasterStyleLayer(identifier: layerID, source: imageSource)
                            rasterLayer.rasterOpacity = NSExpression(forConstantValue: NSNumber(value: payload.opacity))
                            style.addLayer(rasterLayer)
                        }
                    } else {
                        // Download failed (e.g. offline/timeout). Remove layer/source
                        Task { @MainActor [weak self] in
                            guard let self, let mapView = self.mapView, let style = mapView.style else { return }
                            self.downloadTasks[sourceID] = nil
                            if let existingLayer = style.layer(withIdentifier: layerID) {
                                style.removeLayer(existingLayer)
                            }
                            if let existingSource = style.source(withIdentifier: sourceID) {
                                style.removeSource(existingSource)
                            }
                        }
                    }
                }
                downloadTasks[sourceID] = task
                task.resume()
            }
            currentWMSIDs = newWMSIDs
            currentWMSPayloads = wmsPayloads
        }

        // MARK: - Annotation Management

        func updateAnnotations(
            tappedLocation: CLLocationCoordinate2D?,
            onboardingPin: SearchCoordinate?,
            on mapView: MLNMapView
        ) {
            let tappedChanged = tappedLocation?.latitude != lastTappedLocation?.latitude || tappedLocation?.longitude != lastTappedLocation?.longitude
            let onboardingChanged = onboardingPin?.latitude != lastOnboardingPin?.latitude || onboardingPin?.longitude != lastOnboardingPin?.longitude

            if !tappedChanged && !onboardingChanged {
                return
            }

            lastTappedLocation = tappedLocation
            lastOnboardingPin = onboardingPin

            // Tapped location
            if tappedChanged {
                if let existing = tappedAnnotation {
                    mapView.removeAnnotation(existing)
                    tappedAnnotation = nil
                }
                if let location = tappedLocation {
                    let annotation = MLNPointAnnotation()
                    annotation.coordinate = location
                    tappedAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            }

            // Onboarding pin
            if onboardingChanged {
                if let existing = onboardingAnnotation {
                    mapView.removeAnnotation(existing)
                    onboardingAnnotation = nil
                }
                if let pin = onboardingPin {
                    let coord = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
                    let annotation = MLNPointAnnotation()
                    annotation.coordinate = coord
                    onboardingAnnotation = annotation
                    mapView.addAnnotation(annotation)
                }
            }
        }

        // MARK: - Helpers

        private func mkRegion(from mapView: MLNMapView) -> MKCoordinateRegion {
            let bounds = mapView.visibleCoordinateBounds
            let center = CLLocationCoordinate2D(
                latitude: (bounds.ne.latitude + bounds.sw.latitude) / 2,
                longitude: (bounds.ne.longitude + bounds.sw.longitude) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta: abs(bounds.ne.latitude - bounds.sw.latitude),
                longitudeDelta: abs(bounds.ne.longitude - bounds.sw.longitude)
            )
            return MKCoordinateRegion(center: center, span: span)
        }

        private func coordinateQuad(for region: MapRegion) -> MLNCoordinateQuad {
            let halfLat = region.latitudeDelta / 2
            let halfLon = region.longitudeDelta / 2
            let center = region.center

            return MLNCoordinateQuad(
                topLeft: CLLocationCoordinate2D(
                    latitude: center.latitude + halfLat,
                    longitude: center.longitude - halfLon
                ),
                bottomLeft: CLLocationCoordinate2D(
                    latitude: center.latitude - halfLat,
                    longitude: center.longitude - halfLon
                ),
                bottomRight: CLLocationCoordinate2D(
                    latitude: center.latitude - halfLat,
                    longitude: center.longitude + halfLon
                ),
                topRight: CLLocationCoordinate2D(
                    latitude: center.latitude + halfLat,
                    longitude: center.longitude + halfLon
                )
            )
        }

        private func uiColor(hex: String) -> UIColor {
            let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard sanitized.count == 6, let value = UInt64(sanitized, radix: 16) else {
                return .red
            }
            let red = CGFloat((value & 0xFF0000) >> 16) / 255
            let green = CGFloat((value & 0x00FF00) >> 8) / 255
            let blue = CGFloat(value & 0x0000FF) / 255
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        }
    }
}

class SafeFlyUserLocationAnnotationView: MLNUserLocationAnnotationView {
    private let dotView = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        setupView()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupView()
    }

    private func setupView() {
        scalesWithViewingDistance = false
        backgroundColor = .clear

        dotView.layer.cornerRadius = 11
        dotView.layer.borderWidth = 3
        dotView.layer.borderColor = UIColor.white.cgColor
        dotView.backgroundColor = UIColor(red: 0.0, green: 122.0/255.0, blue: 1.0, alpha: 1.0)
        
        // Drop shadow matching standard iOS maps
        dotView.layer.shadowColor = UIColor.black.cgColor
        dotView.layer.shadowOpacity = 0.25
        dotView.layer.shadowOffset = CGSize(width: 0, height: 1)
        dotView.layer.shadowRadius = 2

        addSubview(dotView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Override size and subview positions
        self.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        dotView.frame = self.bounds
        
        // Hide default subviews
        for subview in subviews where subview !== dotView {
            subview.isHidden = true
        }
        
        // Hide default sublayers
        if let sublayers = layer.sublayers {
            for sublayer in sublayers where sublayer !== dotView.layer {
                sublayer.isHidden = true
            }
        }
    }
}

// MARK: - Network Monitor

class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")
    private var _isConnected = true
    
    var isConnected: Bool {
        queue.sync { _isConnected }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.queue.async(flags: .barrier) {
                self?._isConnected = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }
}
