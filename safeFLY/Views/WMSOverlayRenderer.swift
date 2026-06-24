//
//  WMSOverlayRenderer.swift
//  safeFLY
//
//  Adds a native MKOverlay to the SwiftUI Map's underlying MKMapView.
//  The overlay image moves perfectly with the map during panning.
//

import SwiftUI
import MapKit

/// MKOverlay that covers a geographic bounding box with a WMS image.
class WMSImageOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let imageURL: URL
    var image: UIImage?
    
    init(region: MKCoordinateRegion, imageURL: URL) {
        self.imageURL = imageURL
        self.coordinate = region.center
        
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        self.boundingMapRect = MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
        super.init()
    }
}

/// Renderer that draws the WMS image into the overlay's geographic bounds.
class WMSImageRenderer: MKOverlayRenderer {
    var overlayImage: UIImage?
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image = overlayImage?.cgImage else { return }
        let rect = self.rect(for: overlay.boundingMapRect)
        
        // CGContext.draw() uses y-up, but MKOverlayRenderer's context is y-down.
        // Flip vertically to draw the image right-side up.
        context.saveGState()
        context.translateBy(x: rect.origin.x, y: rect.origin.y + rect.size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// A delegate proxy that intercepts only rendererFor: and forwards
/// ALL other delegate calls to the original delegate transparently.
/// This preserves SwiftUI Map's internal delegate behavior.
class MapDelegateProxy: NSObject, MKMapViewDelegate {
    weak var originalDelegate: MKMapViewDelegate?
    var rendererProvider: ((MKOverlay) -> MKOverlayRenderer?)?
    
    // Intercept rendererFor: to provide our WMS renderer
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let renderer = rendererProvider?(overlay) {
            return renderer
        }
        // Forward to original delegate
        return originalDelegate?.mapView?(mapView, rendererFor: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }
    
    // Forward ALL other messages to the original delegate
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }
    
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Invisible UIViewRepresentable that finds the MKMapView in the view hierarchy
/// and manages WMS overlays on it directly.
struct WMSNativeOverlay: UIViewRepresentable {
    var overlayURL: URL?
    var overlayRegion: MKCoordinateRegion?
    var opacity: Double = 0.8
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> WMSOverlayHostView {
        let view = WMSOverlayHostView()
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }
    
    func updateUIView(_ uiView: WMSOverlayHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.targetOpacity = opacity
        
        // Check if overlay URL changed
        if overlayURL != coordinator.currentURL {
            coordinator.currentURL = overlayURL
            
            if let url = overlayURL, let region = overlayRegion {
                let newOverlay = WMSImageOverlay(region: region, imageURL: url)
                
                // Download image, then swap overlays
                coordinator.downloadImage(url: url) { image in
                    guard let image = image else { return }
                    guard let mapView = uiView.findMKMapView() else { return }
                    
                    // Only proceed if this is still the current request
                    guard coordinator.currentURL == url else { return }
                    
                    newOverlay.image = image
                    
                    // Capture old overlays before adding new one
                    let oldOverlays = mapView.overlays.filter { $0 is WMSImageOverlay }
                    
                    // Install delegate proxy if needed (preserves ALL original delegate behavior)
                    coordinator.installDelegateProxy(on: mapView)
                    
                    // Set as current and add to map
                    coordinator.activeOverlay = newOverlay
                    mapView.addOverlay(newOverlay, level: .aboveLabels)
                    
                    // Remove old overlays AFTER adding new (seamless swap)
                    if !oldOverlays.isEmpty {
                        mapView.removeOverlays(oldOverlays)
                    }
                }
            } else {
                // Clear overlays
                if let mapView = uiView.findMKMapView() {
                    let existing = mapView.overlays.filter { $0 is WMSImageOverlay }
                    mapView.removeOverlays(existing)
                }
                coordinator.activeOverlay = nil
            }
        }
    }
    
    class Coordinator: NSObject {
        var currentURL: URL?
        var activeOverlay: WMSImageOverlay?
        var targetOpacity: Double = 0.8
        private var downloadTask: URLSessionDataTask?
        private var delegateProxy: MapDelegateProxy?
        
        func downloadImage(url: URL, completion: @escaping (UIImage?) -> Void) {
            downloadTask?.cancel()
            downloadTask = URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    if let data = data, let image = UIImage(data: data) {
                        completion(image)
                    } else {
                        completion(nil)
                    }
                }
            }
            downloadTask?.resume()
        }
        
        func installDelegateProxy(on mapView: MKMapView) {
            // Only install once — check if we're already proxied
            if mapView.delegate is MapDelegateProxy {
                return
            }
            
            let proxy = MapDelegateProxy()
            proxy.originalDelegate = mapView.delegate
            proxy.rendererProvider = { [weak self] overlay in
                guard let self = self else { return nil }
                if let wmsOverlay = overlay as? WMSImageOverlay {
                    let renderer = WMSImageRenderer(overlay: wmsOverlay)
                    renderer.alpha = CGFloat(self.targetOpacity)
                    renderer.overlayImage = wmsOverlay.image
                    return renderer
                }
                return nil
            }
            
            self.delegateProxy = proxy
            mapView.delegate = proxy
        }
    }
}

/// Host view that can traverse up the view hierarchy to find MKMapView.
class WMSOverlayHostView: UIView {
    weak var coordinator: WMSNativeOverlay.Coordinator?
    
    func findMKMapView() -> MKMapView? {
        var current: UIView? = self
        while let view = current {
            if let mapView = view as? MKMapView {
                return mapView
            }
            if let found = view.findSubview(ofType: MKMapView.self) {
                return found
            }
            current = view.superview
        }
        return nil
    }
}

extension UIView {
    func findSubview<T: UIView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let found = subview.findSubview(ofType: type) {
                return found
            }
        }
        return nil
    }
}
