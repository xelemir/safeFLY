//
//  MapView.swift
//  safeFLY
//
//  Created by Jan Grüttefien on 17.11.25.
//

import SwiftUI
import MapKit
import StoreKit
import UIKit
import MapLibre


struct MapView: View {
    @Environment(\.requestReview) private var requestReview
    @AppStorage("sheetClosedCount") private var sheetClosedCount = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasShownRatingPrompt") private var hasShownRatingPrompt = false

    @EnvironmentObject private var providersStore: ProvidersStore
    @EnvironmentObject var droneSettings: DroneSettings
    // Both camera states must hold the saved position before the first body evaluation — the
    // offline MapLibre view reads `region` in makeUIView, which can run ahead of
    // handleViewAppear — so they bootstrap from UserDefaults directly instead of DroneSettings.
    @State private var region: MKCoordinateRegion = MapView.initialSavedRegion()
    @AppStorage("selectedMapStyle") private var selectedMapStyle: Int = 0
    @State private var cameraPosition: MapCameraPosition = MapView.initialSavedCamera()
    @State private var tappedLocation: CLLocationCoordinate2D?
    @State private var showZoneInfo = false
    @State private var centerOnUser = false
    @State private var currentViewSize: CGSize = .zero
    @State private var updateTask: Task<Void, Never>?
    @State private var isInitialLoad = true
    @State private var hasCompletedInitialSetup = false
    @State private var showSettings = false
    @State private var showDownloadSheet = false
    @State private var downloadAreaName = ""
    @EnvironmentObject var offlineMapStore: OfflineMapStore


    private var mapStyle: MapStyle {
        switch selectedMapStyle {
        case 1: return .hybrid
        case 2: return .imagery
        default: return .standard
        }
    }

    private var providerAttributionText: String {
        let visibleProviderNames = providersStore.enabledSessions
            .filter { $0.provider.intersects(MapRegion(region)) }
            .map { $0.provider.attributionName }
            .joined(separator: ", ")
        guard !visibleProviderNames.isEmpty else {
            if providersStore.enabledSessions.isEmpty {
                return NSLocalizedString("Source geodata: No enabled providers", comment: "Map attribution when no providers are enabled")
            }
            // Providers are enabled, but none of them cover the area currently in view.
            return NSLocalizedString("Source geodata: No coverage in this area", comment: "Map attribution when enabled providers don't cover the visible map")
        }

        return String.localizedStringWithFormat(
            NSLocalizedString("Source geodata: %@", comment: "Map attribution for enabled providers"),
            visibleProviderNames
        )
    }
    
    // Only show geozones when zoomed in enough
    private var shouldShowGeozones: Bool {
        region.span.latitudeDelta < 0.8 && region.span.longitudeDelta < 0.8
    }

    // The coverage dim is shown from full zoom-in all the way out to a near-global view, and
    // only hidden once the map is essentially showing the whole world. The native overlay is
    // world-anchored, so there is no floating-rectangle artefact at any zoom in between.
    private var coverageMaskVisible: Bool {
        region.span.latitudeDelta < 90 && region.span.longitudeDelta < 120
    }

    private var renderPayloads: [WMSRenderPayload] {
        providersStore.renderPayloads.compactMap { payload in
            guard case .wmsImage(let wmsPayload) = payload else {
                return nil
            }

            return wmsPayload
        }
    }

    // Coverage state for the dim mask: every provider that declares a country outline, tagged
    // with whether the user has it enabled. Recomputed when the enabled set changes.
    private var coverageMasks: [ProviderCoverageMask] {
        providersStore.sessions.compactMap { session in
            guard let coverage = session.provider.coverage else { return nil }
            return ProviderCoverageMask(
                providerID: session.provider.id,
                // "Active" mirrors the test that decides whether the provider renders, so the
                // dim mask and the actual overlays never disagree.
                isActive: providersStore.isProviderActive(session.provider.id),
                polygons: coverage.polygons
            )
        }
    }

    private var polygonRenderPayloads: [PolygonRenderPayload] {
        providersStore.renderPayloads.compactMap { payload in
            guard case .polygon(let polygonPayload) = payload else {
                return nil
            }

            return polygonPayload
        }
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
            .onChange(of: showZoneInfo) { _, isPresented in
                // Clear the tapped-location marker the instant dismissal begins. Doing this
                // in the sheet's onDismiss instead made the pin linger, because onDismiss
                // only fires once the slide-down animation has fully finished.
                if !isPresented {
                    tappedLocation = nil
                    providersStore.clearZoneQueryResult()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onChange(of: providersStore.configurationRevision) { _, _ in
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
                    let center = CLLocationCoordinate2D(latitude: update.latitude, longitude: update.longitude)
                    // Same distance↔span approximation used when leaving the offline map, so
                    // the MapLibre view lands at the equivalent zoom.
                    let spanDelta = update.distance / 111000.0
                    withAnimation(.easeInOut(duration: 0.85)) {
                        region = MKCoordinateRegion(
                            center: center,
                            span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
                        )
                        cameraPosition = .camera(
                            MapCamera(
                                centerCoordinate: center,
                                distance: update.distance,
                                heading: 0,
                                pitch: 0
                            )
                        )
                    }
                    droneSettings.simulatedCameraUpdate = nil
                }
            }
            .onChange(of: selectedMapStyle) { oldValue, newValue in
                // Hand the camera back to MapKit when leaving the offline style: while the
                // MapLibre view is up only `region` tracks the user's panning, so without this
                // the MapKit map would restore wherever it last was.
                if oldValue == 3 && newValue != 3 {
                    cameraPosition = .region(region)
                }
            }
            .onChange(of: droneSettings.dismissActiveSheet) { _, newValue in
                if newValue {
                    // Marker and query result are cleared by onChange(of: showZoneInfo).
                    showZoneInfo = false
                    droneSettings.dismissActiveSheet = false
                }
            }
    }
    
    // MARK: - View Components
    
    private var mapContentView: some View {
        GeometryReader { geometry in
            ZStack {
                mapView

                if selectedMapStyle != 3 {
                    CoverageMaskNativeOverlay(masks: coverageMasks, isVisible: coverageMaskVisible)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }

                if selectedMapStyle != 3 {
                    WMSNativeOverlay(payloads: shouldShowGeozones ? renderPayloads : [])
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }
                
                if providersStore.isLoading {
                    loadingView
                }

                if shouldShowGeozones {
                    attributionView
                }

                if offlineMapStore.activeDownload != nil {
                    centeredDownloadOrProgressView
                } else if !shouldShowGeozones {
                    zoomHintView
                } else if selectedMapStyle == 3 {
                    centeredDownloadOrProgressView
                }
            }
            .onAppear {
                currentViewSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                currentViewSize = newSize
            }
        }
    }
    
    @ViewBuilder
    private var mapView: some View {
        if selectedMapStyle == 3 {
            OfflineMapLibreView(
                region: $region,
                centerOnUser: $centerOnUser,
                wmsPayloads: shouldShowGeozones ? renderPayloads : [],
                polygonPayloads: shouldShowGeozones ? polygonRenderPayloads : [],
                tappedLocation: tappedLocation,
                onboardingPinCoordinate: droneSettings.onboardingPinCoordinate,
                onTap: { coordinate in
                    handleMapTap(at: coordinate, viewSize: currentViewSize)
                },
                onCameraChange: { newRegion in
                    region = newRegion
                },
                onCameraChangeEnd: { newRegion in
                    region = newRegion
                    droneSettings.lastCameraLatitude = newRegion.center.latitude
                    droneSettings.lastCameraLongitude = newRegion.center.longitude
                    droneSettings.lastCameraLatitudeDelta = newRegion.span.latitudeDelta
                    droneSettings.lastCameraLongitudeDelta = newRegion.span.longitudeDelta
                    droneSettings.lastCameraDistance = newRegion.span.latitudeDelta * 111000.0

                    if !hasCompletedInitialSetup { return }
                    if shouldShowGeozones {
                        updateOverlay(size: currentViewSize)
                    } else {
                        providersStore.clearRenderPayloads()
                    }
                }
            )
            .ignoresSafeArea()
        } else {
            MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: .all.subtracting(.rotate).subtracting(.pitch)) {
                // The coverage dim mask is a native MKOverlay drawn beneath the labels (see
                // CoverageMaskNativeOverlay); only the geozones and annotations live here.
                UserAnnotation()

                ForEach(shouldShowGeozones ? polygonRenderPayloads : []) { payload in
                    MapPolygon(coordinates: payload.coordinates.map(\.clLocationCoordinate2D))
                        .stroke(color(hex: payload.strokeColorHex, opacity: payload.strokeOpacity), lineWidth: payload.lineWidth)
                        .foregroundStyle(color(hex: payload.fillColorHex, opacity: payload.fillOpacity))
                }
                 
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
    
    private var attributionView: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if #available(iOS 26.0, *) {
                    Text(providerAttributionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect()
                } else {
                    Text(providerAttributionText)
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
        ZoneInfoSheet(
            result: providersStore.zoneQueryResult
        ) {
            // Setting this false dismisses the sheet, which triggers handleSheetDismiss
            // (the sheet's onDismiss) where the marker and query result are cleared.
            showZoneInfo = false
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .background(
            // Swipe-to-dismiss is interactive: SwiftUI only flips `showZoneInfo` (and runs
            // onDismiss) once the slide-out animation finishes, so clearing the marker there
            // makes it linger. presentationControllerWillDismiss fires the moment the swipe
            // is committed, so the pin clears in step with the gesture.
            SheetInteractiveDismissDetector {
                tappedLocation = nil
            }
        )
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Map Style", selection: $selectedMapStyle) {
                    Label("Standard", systemImage: "map").tag(0)
                    Label("Hybrid", systemImage: "square.3.layers.3d").tag(1)
                    Label("Satellite", systemImage: "globe.europe.africa.fill").tag(2)
                    Label(NSLocalizedString("Offline", comment: "Offline map style label"),
                          systemImage: "arrow.down.circle").tag(3)
                }
            } label: {
                Image(systemName: "map")
            }
        }


        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if selectedMapStyle == 3 {
                    centerOnUser = true
                } else {
                    cameraPosition = .userLocation(fallback: .automatic)
                }
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
        // Marker/query-result clearing is handled eagerly in onChange(of: showZoneInfo) so
        // the pin doesn't linger through the dismiss animation; this only runs the
        // rating-prompt bookkeeping once the sheet has fully closed.
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
        let startLatDelta = useStuttgart ? 0.5 : droneSettings.lastCameraLatitudeDelta
        let startLonDelta = useStuttgart ? 0.5 : droneSettings.lastCameraLongitudeDelta

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

        region = MKCoordinateRegion(
            center: savedCoordinate,
            span: MKCoordinateSpan(latitudeDelta: startLatDelta, longitudeDelta: startLonDelta)
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
        droneSettings.lastCameraLatitudeDelta = context.region.span.latitudeDelta
        droneSettings.lastCameraLongitudeDelta = context.region.span.longitudeDelta
        
        if !hasCompletedInitialSetup {
            return
        }
        
        if shouldShowGeozones {
            updateOverlay(size: currentViewSize)
        } else {
            providersStore.clearRenderPayloads()
        }
    }
    

    
    private func handleSearchedCoordinate(_ searchCoord: SearchCoordinate?) {
        if let searchCoord = searchCoord {
            let coord = searchCoord.coordinate
            let target = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            // Drive both engines: `cameraPosition` moves the MapKit map, `region` is the
            // binding the offline MapLibre view follows.
            region = target
            cameraPosition = .region(target)
            droneSettings.searchedCoordinate = nil
        }
    }
    
    func updateOverlay(size: CGSize) {
        updateTask?.cancel()

        guard shouldShowGeozones, size.width > 0, size.height > 0 else {
            providersStore.clearRenderPayloads()
            return
        }

        updateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard !Task.isCancelled else { return }

            await providersStore.refreshRenderPayloads(for: providerRenderRequest(viewSize: size))
        }
    }

    func refreshOverlay() {
        guard hasCompletedInitialSetup, shouldShowGeozones, currentViewSize != .zero else { return }
        updateOverlay(size: currentViewSize)
    }

    func handleMapTap(at coordinate: CLLocationCoordinate2D, viewSize: CGSize) {
        guard shouldShowGeozones, viewSize.width > 0, viewSize.height > 0 else { return }

        tappedLocation = coordinate

        let verticalOffset = region.span.latitudeDelta * (0.5 - 0.25)
        let newCenter = CLLocationCoordinate2D(
            latitude: coordinate.latitude - verticalOffset,
            longitude: coordinate.longitude
        )

        withAnimation(.easeInOut(duration: 0.3)) {
            region.center = newCenter
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: newCenter,
                    distance: droneSettings.lastCameraDistance,
                    heading: 0,
                    pitch: 0
                )
            )
        }

        Task {
            await providersStore.queryLocation(
                for: ProviderPointQueryRequest(
                    coordinate: MapCoordinate(coordinate),
                    region: MapRegion(region),
                    viewportSize: MapViewportSize(viewSize)
                ),
                isOfflineMapStyle: selectedMapStyle == 3
            )
        }
        showZoneInfo = true
    }

    private func providerRenderRequest(viewSize: CGSize) -> ProviderRenderRequest {
        ProviderRenderRequest(region: MapRegion(region), viewportSize: MapViewportSize(viewSize))
    }

    // MARK: - Saved Camera Bootstrap

    private static let onboardingStartCenter = CLLocationCoordinate2D(latitude: 48.7758, longitude: 9.1829)

    private static func savedDouble(_ key: String, fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value != 0 ? value : fallback
    }

    private static func initialSavedCenter() -> CLLocationCoordinate2D {
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else {
            return onboardingStartCenter
        }
        return CLLocationCoordinate2D(
            latitude: savedDouble("lastCameraLatitude", fallback: 51.1657),
            longitude: savedDouble("lastCameraLongitude", fallback: 10.4515)
        )
    }

    private static func initialSavedRegion() -> MKCoordinateRegion {
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let span = hasCompletedOnboarding
            ? MKCoordinateSpan(
                latitudeDelta: savedDouble("lastCameraLatitudeDelta", fallback: 0.5),
                longitudeDelta: savedDouble("lastCameraLongitudeDelta", fallback: 0.5)
            )
            : MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        return MKCoordinateRegion(center: initialSavedCenter(), span: span)
    }

    private static func initialSavedCamera() -> MapCameraPosition {
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let distance = hasCompletedOnboarding ? savedDouble("lastCameraDistance", fallback: 1000000) : 35000
        return .camera(
            MapCamera(
                centerCoordinate: initialSavedCenter(),
                distance: distance,
                heading: 0,
                pitch: 0
            )
        )
    }

    // MARK: - Offline Download UI

    @ViewBuilder
    private var centeredDownloadOrProgressView: some View {
        if let download = offlineMapStore.activeDownload {
            VStack {
                Spacer()
                if #available(iOS 26.0, *) {
                    HStack(spacing: 8) {
                        ProgressView(value: download.progress)
                            .frame(maxWidth: 120)
                        Text("\(Int(download.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect()
                } else {
                    HStack(spacing: 8) {
                        ProgressView(value: download.progress)
                            .frame(maxWidth: 120)
                        Text("\(Int(download.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
            }
        } else if !offlineMapStore.isWithinDownloadedArea(region) {
            VStack {
                Spacer()
                Button {
                    downloadAreaName = ""
                    showDownloadSheet = true
                } label: {
                    if #available(iOS 26.0, *) {
                        Text(NSLocalizedString("Download Visible Map", comment: "Download map area centered button"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect()
                    } else {
                        Text(NSLocalizedString("Download Visible Map", comment: "Download map area centered button"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .alert(
                NSLocalizedString("Download Area", comment: "Download area alert title"),
                isPresented: $showDownloadSheet
            ) {
                TextField(
                    NSLocalizedString("Area Name", comment: "Area name text field placeholder"),
                    text: $downloadAreaName
                )
                Button(NSLocalizedString("Download", comment: "Download button")) {
                    startDownload()
                }
                Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("Enter a name for this area", comment: "Download area alert message"))
            }
        }
    }

    private func startDownload() {
        let name = downloadAreaName.isEmpty
            ? NSLocalizedString("Unnamed Area", comment: "Default offline area name")
            : downloadAreaName

        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            ),
            ne: CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            )
        )

        offlineMapStore.downloadRegion(name: name, bounds: bounds)
    }
}

// MARK: - Zone Info Sheet

struct ZoneInfoSheet: View {
    let result: ZoneQueryResult?
    let onDismiss: () -> Void

    private var sortedFeatures: [ZoneFeature] {
        guard case .matches(let features, _) = result else {
            return []
        }

        return features.sorted { lhs, rhs in
            if lhs.category.displayPriority != rhs.category.displayPriority {
                return lhs.category.displayPriority < rhs.category.displayPriority
            }

            return lhs.id < rhs.id
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result {
                        resultContent(result)
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

    @ViewBuilder
    private func resultContent(_ result: ZoneQueryResult) -> some View {
        switch result {
        case .clear, .nonAssessment, .unavailable:
            resultHeader(for: result)
        case .matches:
            resultHeader(for: result)
            zonesListView
        }
    }

    private func resultHeader(for result: ZoneQueryResult) -> some View {
        let presentation = ZoneQueryPresentation.header(for: result)
        let showsZoneCount: Bool = {
            if case .matches = result, sortedFeatures.count > 1 {
                return true
            }
            return false
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: showsZoneCount ? .top : .center, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(presentation.color)
                        .frame(width: 44, height: 44)

                    Image(systemName: presentation.iconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    if let subtitle = presentation.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if showsZoneCount {
                        Text(String.localizedStringWithFormat(NSLocalizedString("%d overlapping zones", comment: "Number of overlapping zones in the zone header"), sortedFeatures.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let message = presentation.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(presentation.color.opacity(0.3), lineWidth: 1)
        )
    }

    private var zonesListView: some View {
        VStack(spacing: 0) {
            // Positional identity: overlapping zones can share the same content-derived
            // feature.id, and a shared identity would make each row's expand state apply
            // to all of them. The list is a static snapshot, so the index is stable.
            ForEach(Array(sortedFeatures.enumerated()), id: \.offset) { index, feature in
                ZoneFeatureRow(feature: feature)

                if index < sortedFeatures.count - 1 {
                    Divider()
                }
            }
        }
    }
}

// MARK: - Zone Feature Row

struct ZoneFeatureRow: View {
    let feature: ZoneFeature
    @State private var areDetailsExpanded = false

    // Each provider's normalizer already localizes the known advisory strings, so the row
    // simply shows the source-declared text.
    private var restrictionText: String? {
        ZonePresentation.explanation(for: feature)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var altitudeText: String? {
        ZonePresentation.formattedAltitude(for: feature)
    }

    private var hasDetails: Bool {
        altitudeText != nil || feature.legalReference != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow

            if let restrictionText {
                Text(restrictionText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasDetails {
                detailsSection
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topRow: some View {
        let tint = ZonePresentation.tintColor(for: feature.category)

        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: ZonePresentation.iconName(for: feature.category))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ZonePresentation.title(for: feature))
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .lineLimit(2)

                if let subtitle = ZonePresentation.subtitle(for: feature) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    areDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(
                        areDetailsExpanded
                            ? NSLocalizedString("Show Less", comment: "Collapse zone details")
                            : NSLocalizedString("Show More", comment: "Expand zone details")
                    )

                    Image(systemName: areDetailsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if areDetailsExpanded {
                if let altitudeText {
                    DetailRow(
                        label: NSLocalizedString("ZONE_FEATURE_ALTITUDE", comment: "Altitude label"),
                        value: altitudeText,
                        icon: "arrow.up.and.down"
                    )
                }

                if let legalReference = feature.legalReference {
                    DetailRow(
                        label: NSLocalizedString("ZONE_FEATURE_LEGAL_REFERENCE", comment: "Legal reference label"),
                        value: legalReference,
                        icon: "book.pages"
                    )
                }
            }
        }
    }
}

private func color(hex: String, opacity: Double) -> Color {
    let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard sanitized.count == 6, let value = UInt64(sanitized, radix: 16) else {
        return .red.opacity(opacity)
    }

    let red = Double((value & 0xFF0000) >> 16) / 255
    let green = Double((value & 0x00FF00) >> 8) / 255
    let blue = Double(value & 0x0000FF) / 255
    return Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
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
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    MapView()
        .environmentObject(DroneSettings())
        .environmentObject(ProvidersStore(registrations: BuiltInProviders.all))
        .environmentObject(OfflineMapStore())
}

// Bridges to UIKit's `presentationControllerWillDismiss`, the only callback that fires when
// an interactive (swipe-down) sheet dismissal is committed rather than after its animation
// completes — which is what SwiftUI's `onDismiss` and the isPresented binding report. It
// installs itself as the sheet's delegate and forwards every other call to SwiftUI's own
// delegate, so standard dismissal behaviour is preserved.
private struct SheetInteractiveDismissDetector: UIViewControllerRepresentable {
    let onWillDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onWillDismiss = onWillDismiss

        // Walk up to the presented controller that actually owns the sheet.
        var controller: UIViewController = uiViewController
        while let parent = controller.parent { controller = parent }
        guard let sheet = controller.sheetPresentationController else { return }
        if sheet.delegate !== context.coordinator {
            context.coordinator.forwardee = sheet.delegate
            sheet.delegate = context.coordinator
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWillDismiss: onWillDismiss)
    }

    final class Coordinator: NSObject, UISheetPresentationControllerDelegate {
        var onWillDismiss: () -> Void
        // Touched only on the main thread (set during updateUIViewController, read while
        // forwarding delegate calls), so the nonisolated overrides can reach it safely.
        nonisolated(unsafe) weak var forwardee: (any UIAdaptivePresentationControllerDelegate)?

        init(onWillDismiss: @escaping () -> Void) {
            self.onWillDismiss = onWillDismiss
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            onWillDismiss()
            forwardee?.presentationControllerWillDismiss?(presentationController)
        }

        // Forward every other delegate call to SwiftUI's original delegate so the sheet's
        // own dismissal handling (binding sync, onDismiss, interactive-dismiss policy) stays
        // intact.
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardee?.responds(to: aSelector) == true {
                return forwardee
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

private extension MapRegion {
    init(_ region: MKCoordinateRegion) {
        self.init(
            center: MapCoordinate(region.center),
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
    }
}

private extension MapViewportSize {
    init(_ size: CGSize) {
        self.init(width: Int(size.width), height: Int(size.height))
    }
}
