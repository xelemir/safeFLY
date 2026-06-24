//
//  MapView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI
import MapKit
import StoreKit

struct MapView: View {
    @Environment(\.requestReview) private var requestReview
    @AppStorage("sheetClosedCount") private var sheetClosedCount = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasShownRatingPrompt") private var hasShownRatingPrompt = false
    
    @StateObject private var dipulService = DIPULService()
    @EnvironmentObject var droneSettings: DroneSettings
    @State private var region = MKCoordinateRegion.germany
    @State private var selectedMapStyle: Int = 0
    @State private var cameraPosition: MapCameraPosition = .region(.germany)
    @State private var overlayURL: URL?
    @State private var overlayRegion: MKCoordinateRegion?
    @State private var tappedLocation: CLLocationCoordinate2D?
    @State private var showZoneInfo = false
    @State private var currentViewSize: CGSize = .zero
    @State private var updateTask: Task<Void, Never>?
    @State private var isInitialLoad = true
    @State private var hasCompletedInitialSetup = false
    @State private var showSettings = false
    
    
    private var mapStyle: MapStyle {
        switch selectedMapStyle {
        case 1: return .hybrid
        case 2: return .imagery
        default: return .standard
        }
    }
    
    // Only show geozones when zoomed in enough
    private var shouldShowGeozones: Bool {
        region.span.latitudeDelta < 0.8 && region.span.longitudeDelta < 0.8
    }


    var body: some View {
        navigationStackView
            .onChange(of: droneSettings.searchedCoordinate) { _, newValue in
                handleSearchedCoordinate(newValue)
            }
    }
    
    // MARK: - Main Navigation Stack
    
    private var navigationStackView: some View {
        NavigationStack {
            contentWithSheet
                .navigationTitle("Drone Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    toolbarContent
                }
                .onAppear {
                    handleViewAppear()
                }
        }
    }
    
    private var contentWithSheet: some View {
        mapContentView
            .sheet(isPresented: $showZoneInfo, onDismiss: handleSheetDismiss) {
                zoneInfoSheet
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .modifier(SettingsChangeModifiers(refreshAction: refreshOverlay))
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DIPULLayersVerified"))) { _ in
                refreshOverlay()
            }
            .onChange(of: droneSettings.simulatedTapCoordinate) { _, newValue in
                if let searchCoord = newValue {
                    handleMapTap(at: searchCoord.coordinate, viewSize: currentViewSize)
                    droneSettings.simulatedTapCoordinate = nil
                }
            }
            .onChange(of: droneSettings.simulatedCameraUpdate) { _, newValue in
                if let update = newValue {
                    withAnimation(.easeInOut(duration: 0.85)) {
                        cameraPosition = .camera(
                            MapCamera(
                                centerCoordinate: CLLocationCoordinate2D(latitude: update.latitude, longitude: update.longitude),
                                distance: update.distance,
                                heading: 0,
                                pitch: 0
                            )
                        )
                    }
                    droneSettings.simulatedCameraUpdate = nil
                }
            }
            .onChange(of: droneSettings.dismissActiveSheet) { _, newValue in
                if newValue {
                    showZoneInfo = false
                    tappedLocation = nil
                    dipulService.zoneInfo = []
                    droneSettings.dismissActiveSheet = false
                }
            }
    }
    
    // MARK: - View Components
    
    private var mapContentView: some View {
        GeometryReader { geometry in
            ZStack {
                mapView
                
                // Native MKOverlay rendered directly on the map — zero lag
                WMSNativeOverlay(
                    overlayURL: shouldShowGeozones ? overlayURL : nil,
                    overlayRegion: shouldShowGeozones ? overlayRegion : nil
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
                
                if !shouldShowGeozones {
                    zoomHintView
                }
                
                if dipulService.isLoading {
                    loadingView
                }
                
                if let error = dipulService.errorMessage {
                    errorView(error: error)
                }
                
                attributionView
            }
            .onAppear {
                currentViewSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                currentViewSize = newSize
            }
        }
    }
    
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: .all.subtracting(.rotate).subtracting(.pitch)) {
                UserAnnotation()
                
                if let location = tappedLocation {
                    Annotation("", coordinate: location) {
                        if #available(iOS 26.0, *) {
                            Image(systemName: "dot.crosshair")
                                .font(.title2)
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .blue)
                        }
                    }
                }
                
                if let onboardingPin = droneSettings.onboardingPinCoordinate {
                    Annotation("", coordinate: onboardingPin.coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .shadow(radius: 4)
                    }
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapScaleView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                handleContinuousCameraChange(context)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                handleCameraChangeEnd(context)
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if let coordinate = proxy.convert(value.location, from: .local) {
                            handleMapTap(at: coordinate, viewSize: currentViewSize)
                        }
                    }
            )
        }
        .ignoresSafeArea()
    }
    

    
    private var zoomHintView: some View {
        VStack {
            Spacer()
            if #available(iOS 26.0, *) {
                Text("Zoom in to see geozones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect()
            } else {
                Text("Zoom in to see geozones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }
    }
    
    private var loadingView: some View {
        GeometryReader { geometry in
            ProgressView()
                .scaleEffect(1.6)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.25)
        }
    }
    
    private func errorView(error: String) -> some View {
        VStack {
            Spacer()
            Text(error)
                .font(.caption)
                .foregroundStyle(.white)
                .padding()
                .background(.red, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }
    
    private var attributionView: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if #available(iOS 26.0, *) {
                    Text("Source geodata: DFS, BKG 2026")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect()
                } else {
                    Text("Source geodata: DFS, BKG 2026")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 8)
        }
        .allowsHitTesting(false)
    }
    
    private var zoneInfoSheet: some View {
        ZoneInfoSheet(zones: dipulService.zoneInfo) {
            showZoneInfo = false
            tappedLocation = nil
            dipulService.zoneInfo = []
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Map Style", selection: $selectedMapStyle) {
                    Label("Standard", systemImage: "map").tag(0)
                    Label("Hybrid", systemImage: "square.3.layers.3d").tag(1)
                    Label("Satellite", systemImage: "globe.europe.africa.fill").tag(2)
                }
            } label: {
                Image(systemName: "map")
            }
        }
        
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                cameraPosition = .userLocation(fallback: .automatic)
            } label: {
                Image(systemName: "location")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gear")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleSheetDismiss() {
        if sheetClosedCount < 2 {
            sheetClosedCount += 1
        }
        
if sheetClosedCount == 2 && !hasShownRatingPrompt {
            requestReview()
            hasShownRatingPrompt = true
        }
    }
    
    private func handleViewAppear() {
        guard isInitialLoad else { return }
        isInitialLoad = false
        
        let useStuttgart = !hasCompletedOnboarding
        let startLatitude = useStuttgart ? 48.7758 : droneSettings.lastCameraLatitude
        let startLongitude = useStuttgart ? 9.1829 : droneSettings.lastCameraLongitude
        let startDistance = useStuttgart ? 35000 : droneSettings.lastCameraDistance

        let savedCoordinate = CLLocationCoordinate2D(
            latitude: startLatitude,
            longitude: startLongitude
        )
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: savedCoordinate,
                distance: startDistance,
                heading: 0,
                pitch: 0
            )
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            hasCompletedInitialSetup = true

            if shouldShowGeozones && currentViewSize != .zero {
                updateOverlay(size: currentViewSize)
            }
        }
    }
    
    private func handleContinuousCameraChange(_ context: MapCameraUpdateContext) {
        region = context.region
        
        if context.camera.heading != 0 || context.camera.pitch != 0 {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: context.camera.centerCoordinate,
                    distance: context.camera.distance,
                    heading: 0,
                    pitch: 0
                )
            )
        }
    }
    
    private func handleCameraChangeEnd(_ context: MapCameraUpdateContext) {
        region = context.region
        
        droneSettings.lastCameraLatitude = context.camera.centerCoordinate.latitude
        droneSettings.lastCameraLongitude = context.camera.centerCoordinate.longitude
        droneSettings.lastCameraDistance = context.camera.distance
        
        if !hasCompletedInitialSetup {
            return
        }
        
        if shouldShowGeozones {
            updateOverlay(size: currentViewSize)
        } else {
            overlayURL = nil
            overlayRegion = nil
        }
    }
    

    
    private func handleSearchedCoordinate(_ searchCoord: SearchCoordinate?) {
        if let searchCoord = searchCoord {
            let coord = searchCoord.coordinate
            let region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            cameraPosition = .region(region)
            droneSettings.searchedCoordinate = nil
        }
    }
    
    func updateOverlay(size: CGSize) {
        // Cancel any pending update
        updateTask?.cancel()
        
        guard shouldShowGeozones, size.width > 0, size.height > 0 else {
            overlayURL = nil
            overlayRegion = nil
            return
        }
        
        // Debounce the update to avoid multiple simultaneous requests
        updateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 second debounce
            
            guard !Task.isCancelled else { return }
            
            if let url = dipulService.getWMSURL(for: region, size: size, settings: droneSettings) {
                overlayURL = url
                overlayRegion = region
            } else {
                // No layers enabled, clear overlay
                overlayURL = nil
                overlayRegion = nil
            }
        }
    }
    
    func refreshOverlay() {
        guard hasCompletedInitialSetup, shouldShowGeozones, currentViewSize != .zero else { return }
        updateOverlay(size: currentViewSize)
    }
    
    func handleMapTap(at coordinate: CLLocationCoordinate2D, viewSize: CGSize) {
        guard shouldShowGeozones, viewSize.width > 0, viewSize.height > 0 else { return }
        
        tappedLocation = coordinate
        
        // Calculate new camera position to place tapped point at 25% from top
        let verticalOffset = region.span.latitudeDelta * (0.5 - 0.25)
        let newCenter = CLLocationCoordinate2D(
            latitude: coordinate.latitude - verticalOffset,
            longitude: coordinate.longitude
        )
        
        // Animate camera to new position
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: newCenter,
                    distance: droneSettings.lastCameraDistance,
                    heading: 0,
                    pitch: 0
                )
            )
        }
        
        // Query feature info
        dipulService.getFeatureInfo(at: coordinate, region: region, viewSize: viewSize, settings: droneSettings)
        showZoneInfo = true
    }
}

// MARK: - Settings Change Modifiers

struct SettingsChangeModifiers: ViewModifier {
    @EnvironmentObject var droneSettings: DroneSettings
    let refreshAction: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onChange(of: droneSettings.showAirports) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showAerodromes) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showControlZones) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showRestrictedAreas) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showMotorways) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showHighways) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showRailways) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showWaterways) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showResidential) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showRecreational) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showIndustrial) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showGovernment) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showNatureReserves) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showTemporaryRestrictions) { _, _ in refreshAction() }
            .onChange(of: droneSettings.showModelFlyingFields) { _, _ in refreshAction() }
    }
}

// MARK: - Zone Info Sheet

struct ZoneInfoSheet: View {
    let zones: [ZoneInfo]
    let onDismiss: () -> Void
    
    // Sort zones by priority (most restrictive first)
    private var sortedZones: [ZoneInfo] {
        zones.sorted { $0.displayPriority < $1.displayPriority }
    }
    
    // Get the most restrictive status from all zones
    private var combinedStatus: (allowed: Bool, conditional: Bool, message: String) {
        if zones.isEmpty {
            return (true, false, NSLocalizedString("FLIGHT_ALLOWED", comment: "Flight allowed default message"))
        }
        
        let statuses = zones.map { $0.flightStatus }
        
        // If any zone is completely restricted (not allowed, not conditional), that takes precedence
        if let restricted = statuses.first(where: { !$0.allowed && !$0.conditional }) {
            return restricted
        }
        
        // If any zone requires conditions, combine those messages
        let conditionalZones = statuses.filter { !$0.allowed && $0.conditional }
        if !conditionalZones.isEmpty {
            return (false, true, NSLocalizedString("MULTIPLE_RESTRICTIONS", comment: "Multiple restrictions header"))
        }
        
        // If any zone has warnings (allowed but conditional)
        let warningZones = statuses.filter { $0.allowed && $0.conditional }
        if !warningZones.isEmpty {
            return (true, true, NSLocalizedString("FLIGHT_ALLOWED_CAUTION", comment: "Flight allowed with caution header"))
        }
        
        return (true, false, NSLocalizedString("FLIGHT_ALLOWED", comment: "Flight allowed default message"))
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !zones.isEmpty {
                        if zones.count > 1 || !combinedStatus.allowed {
                            combinedStatusHeader
                        }
                        zonesListView
                    } else {
                        ProgressView("Checking zone information...")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Zone Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    private var combinedStatusHeader: some View {
        let status = combinedStatus
        let mainColor = status.allowed ? Color.green : (status.conditional ? Color.orange : Color.red)
        
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(mainColor)
                    .frame(width: 44, height: 44)
                
                Image(systemName: status.allowed ? "checkmark" : 
                       (status.conditional ? "exclamationmark.triangle.fill" : "xmark"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(status.allowed ? NSLocalizedString("FLIGHT_PERMITTED", comment: "Header: flight permitted") : 
                    (status.conditional ? NSLocalizedString("PERMITTED_UNDER_CONDITIONS", comment: "Header: permitted under conditions") : NSLocalizedString("FLIGHT_PROHIBITED", comment: "Header: flight prohibited")))
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                
                if zones.count > 1 {
                    Text(String.localizedStringWithFormat(NSLocalizedString("%d overlapping zones", comment: "Number of overlapping zones in the zone header"), zones.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(mainColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var zonesListView: some View {
        VStack(spacing: 0) {
            ForEach(Array(sortedZones.enumerated()), id: \.element.id) { index, info in
                CompactZoneRow(info: info)
                
                if index < sortedZones.count - 1 {
                    Divider()
                }
            }
        }
    }
}

// MARK: - Compact Zone Row

struct CompactZoneRow: View {
    let info: ZoneInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if info.name == "Clear Zone" {
                clearZoneView
            } else {
                zoneDetailsView(status: info.flightStatus)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var clearZoneView: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.green)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("No Restrictions")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                
                Text("Drone flight is permitted at this location")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func zoneDetailsView(status: (allowed: Bool, conditional: Bool, message: String)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Row: Icon and Title
            HStack(spacing: 12) {
                // Circle Background Icon
                ZStack {
                    Circle()
                        .fill(status.allowed ? Color.green.opacity(0.15) : (status.conditional ? Color.orange.opacity(0.15) : Color.red.opacity(0.15)))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: info.displayIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(status.allowed ? .green : (status.conditional ? .orange : .red))
                }
                
                // Title Section
                VStack(alignment: .leading, spacing: 2) {
                    if let layer = info.layerName {
                        Text(info.formatLayerName(layer))
                            .font(.system(.headline, design: .rounded)) 
                            .fontWeight(.bold)
                            .lineLimit(1)
                    } else if let name = info.name {
                        Text(name)
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                    
                    if let name = info.name, info.layerName != nil {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            
            // Content Row: Message and Legal
            VStack(alignment: .leading, spacing: 6) {
                Text(status.message)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.9)) 
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2) 
                
                if let legal = info.legalRef {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "book.pages")
                        Text(legal)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    var icon: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    MapView()
        .environmentObject(DroneSettings())
}
