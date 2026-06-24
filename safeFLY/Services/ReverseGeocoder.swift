//
//  ReverseGeocoder.swift
//  safeFLY
//
//  Helper to reverse geocode coordinates into a placename
//

import Foundation
import CoreLocation

final class ReverseGeocoder {
    private let geocoder = CLGeocoder()

    func placename(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let _ = error {
                    continuation.resume(returning: nil)
                    return
                }

                guard let pm = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }

                let locality = pm.locality ?? pm.subLocality ?? pm.thoroughfare
                let administrativeArea = pm.administrativeArea

                let comps = [locality, administrativeArea].compactMap { $0 }
                if comps.isEmpty {
                    // As a fallback, return the coordinate string
                    let formatted = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
                    continuation.resume(returning: formatted)
                } else {
                    continuation.resume(returning: comps.joined(separator: ", "))
                }
            }
        }
    }
}
