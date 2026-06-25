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

    @EnvironmentObject private var providersStore: ProvidersStore
    @EnvironmentObject var droneSettings: DroneSettings
    @State private var region = MKCoordinateRegion.germany
    @State private var selectedMapStyle: Int = 0
    @State private var cameraPosition: MapCameraPosition = .region(.germany)
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

    private var providerAttributionText: String {
        let providerNames = providersStore.enabledSessions.map { $0.provider.displayName }.joined(separator: ", ")
        guard !providerNames.isEmpty else {
            return NSLocalizedString("Source geodata: No enabled providers", comment: "Map attribution when no providers are enabled")
        }

        return String.localizedStringWithFormat(
            NSLocalizedString("Source geodata: %@", comment: "Map attribution for enabled providers"),
            providerNames
        )
    }
    
    // Only show geozones when zoomed in enough
    private var shouldShowGeozones: Bool {
        region.span.latitudeDelta < 0.8 && region.span.longitudeDelta < 0.8
    }

    private var renderPayloads: [WMSRenderPayload] {
        providersStore.renderPayloads.compactMap { payload in
            guard case .wmsImage(let wmsPayload) = payload else {
                return nil
            }

            return wmsPayload
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
                    providersStore.clearZoneQueryResult()
                    droneSettings.dismissActiveSheet = false
                }
            }
    }
    
    // MARK: - View Components
    
    private var mapContentView: some View {
        GeometryReader { geometry in
            ZStack {
                mapView

                WMSNativeOverlay(payloads: shouldShowGeozones ? renderPayloads : [])
                .allowsHitTesting(false)
                .ignoresSafeArea()
                
                if !shouldShowGeozones {
                    zoomHintView
                }
                
                if providersStore.isLoading {
                    loadingView
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
        ZoneInfoSheet(result: providersStore.zoneQueryResult) {
            // Setting this false dismisses the sheet, which triggers handleSheetDismiss
            // (the sheet's onDismiss) where the marker and query result are cleared.
            showZoneInfo = false
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
        // Runs for every dismissal — the X button and an interactive swipe-down — so the
        // tapped-location marker and query result are always cleared, not just via the X.
        tappedLocation = nil
        providersStore.clearZoneQueryResult()

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
            providersStore.clearRenderPayloads()
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
                )
            )
        }
        showZoneInfo = true
    }

    private func providerRenderRequest(viewSize: CGSize) -> ProviderRenderRequest {
        ProviderRenderRequest(region: MapRegion(region), viewportSize: MapViewportSize(viewSize))
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

                    if showsZoneCount {
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
            ForEach(Array(sortedFeatures.enumerated()), id: \.element.id) { index, feature in
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
                    .foregroundStyle(.secondary)
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
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    MapView()
        .environmentObject(DroneSettings())
        .environmentObject(ProvidersStore(registrations: BuiltInProviders.all))
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
