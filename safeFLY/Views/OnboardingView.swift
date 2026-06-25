//
//  OnboardingView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 14.06.26.
//

import SwiftUI
import UIKit
import CoreLocation
import MapKit

struct OnboardingStep: Identifiable {
    let id: Int
    let title: String
    let description: String
    let type: StepType
}

enum StepType {
    case welcome
    case airspace
    case weather
    case location
    case ready
}

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @EnvironmentObject var droneSettings: DroneSettings
    @EnvironmentObject var providersStore: ProvidersStore
    @StateObject private var locationManager = LocationManager()
    @State private var currentPage = 0
    @State private var slideDirection: CGFloat = 1 // 1 for forward, -1 for backward
    @State private var showLocationStep: Bool? = nil // Captured on first appear
    @Environment(\.colorScheme) private var colorScheme
    
    // Computed list of steps. Uses captured showLocationStep so the list doesn't shift mid-flow.
    private var activeSteps: [OnboardingStep] {
        var list = [
            OnboardingStep(
                id: 0,
                title: NSLocalizedString("ONBOARDING.WELCOME.TITLE", comment: "Onboarding welcome title"),
                description: NSLocalizedString("ONBOARDING.WELCOME.DESCRIPTION", comment: "Onboarding welcome description"),
                type: .welcome
            ),
            OnboardingStep(
                id: 1,
                title: NSLocalizedString("ONBOARDING.AIRSPACE.TITLE", comment: "Onboarding airspace title"),
                description: NSLocalizedString("ONBOARDING.AIRSPACE.DESCRIPTION", comment: "Onboarding airspace description"),
                type: .airspace
            )
        ]
        
        // Location step right after airspace — frozen based on initial state so indices don't shift
        if showLocationStep == true {
            list.append(OnboardingStep(
                id: 2,
                title: NSLocalizedString("ONBOARDING.LOCATION.TITLE", comment: "Onboarding location title"),
                description: NSLocalizedString("ONBOARDING.LOCATION.DESCRIPTION", comment: "Onboarding location description"),
                type: .location
            ))
        }
        
        list.append(OnboardingStep(
            id: 3,
            title: NSLocalizedString("ONBOARDING.WEATHER.TITLE", comment: "Onboarding weather title"),
            description: NSLocalizedString("ONBOARDING.WEATHER.DESCRIPTION", comment: "Onboarding weather description"),
            type: .weather
        ))
        
        list.append(OnboardingStep(
            id: 4,
            title: NSLocalizedString("ONBOARDING.READY.TITLE", comment: "Onboarding ready title"),
            description: NSLocalizedString("ONBOARDING.READY.DESCRIPTION", comment: "Onboarding ready description"),
            type: .ready
        ))
        
        return list
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // MARK: - Full-screen touch interceptor (blocks map interaction during onboarding)
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                
                // MARK: - Step 1: Custom Floating Zone Information Popup Card (Real Data)
                if activeSteps[currentPage].type == .airspace {
                    Group {
                        if case .matches(let features, let assessment) = providersStore.zoneQueryResult,
                           let feature = features.sorted(by: { $0.category.displayPriority < $1.category.displayPriority }).first {
                            let header = ZoneQueryPresentation.header(for: .matches(features: features, assessment: assessment))

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(header.color.opacity(0.15))
                                            .frame(width: 38, height: 38)
                                        Image(systemName: ZonePresentation.iconName(for: feature.category))
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(header.color)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        let titleText: String = {
                                            return ZonePresentation.title(for: feature)
                                        }()
                                        Text(titleText)
                                            .font(.system(.headline, design: .rounded))
                                            .fontWeight(.bold)
                                            .foregroundColor(.primary)
                                        if let subtitle = ZonePresentation.subtitle(for: feature) {
                                            Text(subtitle)
                                                .font(.system(.subheadline, design: .rounded))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }

                                if let message = feature.sourceDeclaredRestriction ?? header.message {
                                    Text(message)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                if let legal = feature.legalReference {
                                    HStack(spacing: 6) {
                                        Image(systemName: "book.pages")
                                        Text(legal)
                                    }
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(header.color.opacity(0.25), lineWidth: 1.5)
                            )
                        } else if providersStore.isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(.white)
                                Text(NSLocalizedString("Checking zone information...", comment: ""))
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(.primary)
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(.ultraThinMaterial)
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.32)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                }
                
                // MARK: - Floating Bottom Overlay (Static position, contents transition dynamically)
                VStack(spacing: 0) {
                    // Page dots indicator
                    HStack(spacing: 8) {
                        ForEach(0..<activeSteps.count, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentPage ? Color.blue : Color.white.opacity(0.35))
                                .frame(width: 8, height: 8)
                                .scaleEffect(idx == currentPage ? 1.2 : 1.0)
                        }
                    }
                    .padding(.bottom, 14)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentPage)
                    
                    // Sliding/Crossfading details text matching swipe direction
                    VStack(spacing: 8) {
                        Text(activeSteps[currentPage].title)
                            .font(.system(.title, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 24)
                            .id("guide-title-\(activeSteps[currentPage].id)")
                            .transition(.asymmetric(
                                insertion: .move(edge: slideDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: slideDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                            ))
                            .padding(.bottom, 4)
                        
                        Text(activeSteps[currentPage].description)
                            .font(.system(.body, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.horizontal, 32)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 75, alignment: .top)
                            .id("guide-desc-\(activeSteps[currentPage].id)")
                            .transition(.asymmetric(
                                insertion: .move(edge: slideDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: slideDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                            ))
                    }
                    .padding(.bottom, 24)
                    
                    // Crossfading button layout in place
                    VStack {
                        let step = activeSteps[currentPage]
                        if step.type == .welcome {
                            Button(action: {
                                nextPage()
                            }) {
                                Text(NSLocalizedString("ONBOARDING.BUTTON.GET_STARTED", comment: "Get Started button"))
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .blue))
                        } else if step.type == .location {
                            if locationManager.authorizationStatus == .notDetermined {
                                Button(action: {
                                    enableLocation()
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "location.fill")
                                        Text(NSLocalizedString("ONBOARDING.BUTTON.ACTIVATE_LOCATION", comment: "Activate Location button"))
                                    }
                                }
                                .buttonStyle(PremiumButtonStyle(backgroundColor: .blue))
                            } else {
                                Button(action: {
                                    nextPage()
                                }) {
                                    Text(NSLocalizedString("ONBOARDING.BUTTON.CONTINUE", comment: "Continue button"))
                                }
                                .buttonStyle(PremiumButtonStyle(backgroundColor: .blue))
                            }
                        } else if step.type == .ready {
                            Button(action: {
                                completeOnboarding()
                            }) {
                                Text(NSLocalizedString("ONBOARDING.BUTTON.SAFE_FLIGHT", comment: "Safe Flight button"))
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .blue))
                        } else {
                            Button(action: {
                                nextPage()
                            }) {
                                Text(NSLocalizedString("ONBOARDING.BUTTON.CONTINUE", comment: "Continue button"))
                            }
                            .buttonStyle(PremiumButtonStyle(backgroundColor: .blue))
                        }
                    }
                    .id("guide-buttons-\(activeSteps[currentPage].id)")
                    .transition(.opacity)
                    .padding(.horizontal, 32)
                }
                .padding(.top, 40)
                .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? geometry.safeAreaInsets.bottom + 10 : 30)
                .frame(maxWidth: .infinity)
                .background(
                    ZStack {
                        // UIKit blur with gradient mask — fades from no-blur to full blur
                        GradientBlurView()
                        // Dark gradient tint for text legibility
                        LinearGradient(
                            stops: [
                                .init(color: Color.black.opacity(0.0), location: 0.0),
                                .init(color: Color.black.opacity(0.35), location: 0.2),
                                .init(color: Color.black.opacity(0.65), location: 0.45),
                                .init(color: Color.black.opacity(0.85), location: 0.7),
                                .init(color: Color.black.opacity(0.92), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea(edges: .bottom)
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .gesture(
                DragGesture()
                    .onEnded { value in
                        let threshold: CGFloat = 45
                        if value.translation.width < -threshold {
                            slideDirection = 1
                            nextPage()
                        } else if value.translation.width > threshold {
                            slideDirection = -1
                            prevPage()
                        }
                    }
            )
            .onAppear {
                // Capture initial location auth status so activeSteps doesn't shift mid-flow
                if showLocationStep == nil {
                    showLocationStep = (locationManager.authorizationStatus == .notDetermined)
                }
                handlePageChange(to: currentPage)
            }
            .onChange(of: currentPage) { _, newPage in
                handlePageChange(to: newPage)
            }
            .onChange(of: locationManager.lastLocation?.latitude) { _, newLat in
                // When location is received during the location step, animate camera to user
                guard let coord = locationManager.lastLocation,
                      currentPage < activeSteps.count,
                      activeSteps[currentPage].type == .location else { return }
                
                // Smoothly animate camera to user's real position
                droneSettings.simulatedCameraUpdate = CameraUpdate(
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    distance: 8000
                )
            }
        }
    }
    
    // MARK: - Navigation Logic
    
    private func nextPage() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        if currentPage < activeSteps.count - 1 {
            slideDirection = 1
            currentPage += 1
        }
    }
    
    private func prevPage() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        if currentPage > 0 {
            slideDirection = -1
            currentPage -= 1
        }
    }
    
    private func enableLocation() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        locationManager.requestPermission()
        // Don't auto-advance immediately — the .onChange(of: locationManager.lastLocation)
        // observer will animate the camera to the user's position first, then we advance.
    }
    
    private func completeOnboarding() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        withAnimation(.easeInOut(duration: 0.4)) {
            hasCompletedOnboarding = true
            droneSettings.activeTab = 0 // Switch back to map tab when finished
            droneSettings.onboardingPinCoordinate = nil // Clear pin
        }
    }
    
    private func handlePageChange(to page: Int) {
        guard page < activeSteps.count else { return }
        let step = activeSteps[page]
        
        // Always dismiss any active sheets when shifting stages
        droneSettings.dismissActiveSheet = true
        droneSettings.onboardingPinCoordinate = nil // Clear pin
        
        switch step.type {
        case .welcome:
            withAnimation(.easeInOut(duration: 0.35)) {
                droneSettings.activeTab = 0
            }
            // Zoom out to show general Stuttgart area
            droneSettings.simulatedCameraUpdate = CameraUpdate(
                latitude: 48.7758,
                longitude: 9.1829,
                distance: 35000
            )
            
        case .airspace:
            withAnimation(.easeInOut(duration: 0.35)) {
                droneSettings.activeTab = 0
            }
            // Zoom in on target coordinate: 48°47'03.9"N 9°11'26.3"E (Schlossplatz Stuttgart)
            let targetLat = 48.784417
            let targetLng = 9.190638
            droneSettings.simulatedCameraUpdate = CameraUpdate(
                latitude: targetLat,
                longitude: targetLng,
                distance: 3500 // Close view showing Schlossplatz
            )
            
            // Programmatically show map pin marker and fetch real zone data after camera pans
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if activeSteps[currentPage].type == .airspace {
                    droneSettings.onboardingPinCoordinate = SearchCoordinate(latitude: targetLat, longitude: targetLng)
                    
                    // Fetch real restriction data from DFS DIPUL WMS
                    let queryRegion = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: targetLat, longitude: targetLng),
                        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                    )
                    let querySize = CGSize(width: 256, height: 256)
                    Task {
                        await providersStore.queryLocation(
                            for: ProviderPointQueryRequest(
                                coordinate: MapCoordinate(latitude: targetLat, longitude: targetLng),
                                region: MapRegion(
                                    center: MapCoordinate(queryRegion.center),
                                    latitudeDelta: queryRegion.span.latitudeDelta,
                                    longitudeDelta: queryRegion.span.longitudeDelta
                                ),
                                viewportSize: MapViewportSize(width: Int(querySize.width), height: Int(querySize.height))
                            )
                        )
                    }
                }
            }
            
        case .weather:
            // Switch active tab to WeatherView
            droneSettings.activeTab = 1
            
        case .location:
            // Show map tab with broader Stuttgart overview
            droneSettings.activeTab = 0
            droneSettings.simulatedCameraUpdate = CameraUpdate(
                latitude: 48.7758,
                longitude: 9.1829,
                distance: 35000
            )
            
        case .ready:
            // Switch back to map tab
            droneSettings.activeTab = 0
            // Zoom to broader Stuttgart or user location if available
            if let userLoc = locationManager.lastLocation {
                droneSettings.simulatedCameraUpdate = CameraUpdate(
                    latitude: userLoc.latitude,
                    longitude: userLoc.longitude,
                    distance: 12000
                )
            } else {
                droneSettings.simulatedCameraUpdate = CameraUpdate(
                    latitude: 48.7758,
                    longitude: 9.1829,
                    distance: 35000
                )
            }
        }
    }
}

// MARK: - Gradient Blur Background (UIKit-based)
class GradientBlurUIView: UIView {
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let gradientMask = CAGradientLayer()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        backgroundColor = .clear
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        gradientMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        gradientMask.locations = [0.0, 0.35]
        gradientMask.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientMask.endPoint = CGPoint(x: 0.5, y: 1.0)
        blurView.layer.mask = gradientMask
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        gradientMask.frame = blurView.bounds
    }
}

struct GradientBlurView: UIViewRepresentable {
    func makeUIView(context: Context) -> GradientBlurUIView {
        GradientBlurUIView()
    }
    
    func updateUIView(_ uiView: GradientBlurUIView, context: Context) {}
}

// MARK: - Premium Click-Scaling Button Style
struct PremiumButtonStyle: ButtonStyle {
    let backgroundColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(backgroundColor)
            .cornerRadius(26)
            .shadow(color: backgroundColor.opacity(0.3), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Previews
#Preview {
    OnboardingView()
        .environmentObject(DroneSettings())
}
