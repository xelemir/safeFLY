//
//  WMSOverlayView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI
import MapKit

struct WMSOverlayView: View {
    let region: MKCoordinateRegion
    let wmsURL: URL?
    
    var body: some View {
        GeometryReader { geometry in
            if let url = wmsURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .opacity(0.8)
                    case .failure, .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
