//
//  WeatherView.swift
//  safeFLY
//
//  Enhanced weather view with drone-specific flight advisories
//  Shows precipitation probability, visibility, and comprehensive flight conditions
//

import SwiftUI
import Combine
import CoreLocation
import MapKit

struct WeatherView: View {
    @EnvironmentObject var droneSettings: DroneSettings
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var viewModel = WeatherViewModel()
    
    var body: some View {
        ZStack {
            if viewModel.isLoading {
                loadingView
            } else {
                Form {
                    if let weather = viewModel.currentWeather {
                        // Compact header with location, flight assessment, and current conditions
                        headerCard(weather)
                        
                        // Hourly forecast - horizontal scroll
                        if !viewModel.hourlyForecasts.isEmpty {
                            hourlyForecastSection
                        }

                        // Wind at multiple AGL heights (DIPUL only)
                        if viewModel.dipulAvailable && !viewModel.windProfile.isEmpty {
                            windProfileSection
                        }

                        // Additional info in compact rows
                        additionalInfoSection
                        
                    } else if let error = viewModel.errorMessage {
                        errorView(error)
                    } else {
                        emptyStateView
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationTitle(NSLocalizedString("Weather", comment: "Weather navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.update(for: CLLocationCoordinate2D(
                latitude: droneSettings.lastCameraLatitude,
                longitude: droneSettings.lastCameraLongitude
            ))
        }
        .onChange(of: droneSettings.lastCameraLatitude) { _, _ in
            viewModel.update(for: CLLocationCoordinate2D(
                latitude: droneSettings.lastCameraLatitude,
                longitude: droneSettings.lastCameraLongitude
            ))
        }
        .onChange(of: droneSettings.lastCameraLongitude) { _, _ in
            viewModel.update(for: CLLocationCoordinate2D(
                latitude: droneSettings.lastCameraLatitude,
                longitude: droneSettings.lastCameraLongitude
            ))
        }
    }

    // MARK: - Header Card (Compact)

    private func headerCard(_ weather: WeatherResponse) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                Text(viewModel.locationName ?? NSLocalizedString("Unknown Location", comment: "Unknown location placeholder"))
                    .font(.headline)
                    .foregroundStyle(.primary)

                currentWeatherRow(weather)

                Divider()

                flightAssessmentView
            }
            .padding(.vertical, 8)
        }
    }

    private func currentWeatherRow(_ weather: WeatherResponse) -> some View {
        let weatherIcon = viewModel.weatherIcon(
            weathercode: weather.currentWeather.weathercode,
            isNight: viewModel.isCurrentlyNight(),
            colorScheme: colorScheme
        )
        let displayTemp = viewModel.dipulWeather?.current?.temperatureCelsius
            ?? weather.currentWeather.temperature

        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: weatherIcon.symbol)
                .symbolRenderingMode(.palette)
                .font(.system(size: 56))
                .foregroundStyle(weatherIcon.colors[0], weatherIcon.colors.count > 1 ? weatherIcon.colors[1] : .clear, weatherIcon.colors.count > 2 ? weatherIcon.colors[2] : .clear)
                .shadow(color: weatherIcon.colors[0].opacity(0.3), radius: 10)
                .frame(width: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.0f°", displayTemp))
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.primary)

                Text(viewModel.conditionDescription(for: weather.currentWeather.weathercode))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let feels = weather.currentWeather.apparentTemperature {
                    Text(String(format: NSLocalizedString("Feels like %@", comment: "Feels like temperature"), String(format: "%.0f°", feels)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            rainChipView(for: weather)
        }
    }

    @ViewBuilder
    private func rainChipView(for weather: WeatherResponse) -> some View {
        if let rain = viewModel.dipulWeather?.current?.rainMmPerHour, rain > 0.01 {
            rainChip(icon: "cloud.rain.fill", iconColors: [.gray, .blue], value: String(format: "%.1f", rain), unit: "mm/h")
        } else if let precipProb = weather.currentWeather.precipitationProbability, precipProb > 0 {
            rainChip(icon: "cloud.rain.fill", iconColors: [.gray, .blue], value: "\(precipProb)", unit: "%")
        }
    }

    private func rainChip(icon: String, iconColors: [Color], value: String, unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Image(systemName: icon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(iconColors[0], iconColors.count > 1 ? iconColors[1] : iconColors[0])
                .font(.title3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Flight Assessment (merged into header card)

    private var flightAssessmentView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: viewModel.flightConditionIcon)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, viewModel.flightConditionColor)
                    .font(.title2)

                Text(viewModel.flightConditionText)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()
            }

            if !viewModel.flightAdvisories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.flightAdvisories, id: \.self) { advisory in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(advisory)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Wind Profile Section (DIPUL)

    private var windProfileSection: some View {
        Section {
            ForEach(viewModel.windProfile, id: \.heightMeters) { wind in
                HStack(spacing: 12) {
                    Text("\(wind.heightMeters) m")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(windColor(wind.speed).opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 58, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f m/s", wind.speed))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(windColor(wind.speed))
                            Text(viewModel.windDirectionText(deg: wind.directionDegrees))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let gust = wind.gust {
                            Text(String(format: NSLocalizedString("Gust: %.1f m/s", comment: "Wind gust label"), gust))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    // Arrow pointing in the direction the wind is coming FROM
                    Image(systemName: "arrow.up")
                        .font(.body)
                        .rotationEffect(.degrees(wind.directionDegrees))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(NSLocalizedString("Wind Profile (AGL)", comment: "Wind profile section header"))
        }
    }

    private func windColor(_ speed: Double) -> Color {
        switch speed {
        case ..<5:   return .green
        case 5..<8:  return .yellow
        case 8..<12: return .orange
        default:     return .red
        }
    }

    // MARK: - Hourly Forecast (Compact)
    
    private var hourlyForecastSection: some View {
        Section {
            VStack(alignment: .leading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(viewModel.hourlyForecasts.enumerated()), id: \.element.id) { index, item in
                            compactHourlyCard(item)
                                .padding(.leading, index == 0 ? 0 : 6)
                                .padding(.trailing, index == viewModel.hourlyForecasts.count - 1 ? 0 : 6)
                                .padding(.vertical, 12)
                        }
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("Hourly Forecast", comment: "Hourly forecast section header"))
        }
    }
    
    private func compactHourlyCard(_ item: WeatherViewModel.HourlyForecast) -> some View {
        let weatherIcon = viewModel.weatherIcon(
            weathercode: item.weathercode,
            cloudcover: item.cloudcover,
            isNight: viewModel.isNightTime(at: item.time),
            colorScheme: colorScheme
        )
        
        return VStack(spacing: 6) {
            Text(hourFormatter.string(from: item.time))
                .font(.caption)
                .fontWeight(.medium)
            
            Image(systemName: weatherIcon.symbol)
                .symbolRenderingMode(.palette)
                .font(.title3)
                .foregroundStyle(weatherIcon.colors[0], weatherIcon.colors.count > 1 ? weatherIcon.colors[1] : .clear, weatherIcon.colors.count > 2 ? weatherIcon.colors[2] : .clear)
                .frame(height: 24)
            
            Text(String(format: "%.0f°", item.temperature ?? 0.0))
                .font(.subheadline)
                .fontWeight(.semibold)
                        
            // Precipitation probability
            HStack(spacing: 3) {
                Image(systemName: "drop.fill")
                    .font(.caption2)
                Text("\(item.precipProbability ?? 0) %")
                    .font(.caption2)
            }
            .foregroundStyle(
                (item.precipProbability ?? 0) > 0 ? .blue : .secondary
            )

            // Wind at the assessed altitude: DIPUL 100 m AGL when available, otherwise 10 m.
            let displayWind = item.wind100mSpeed ?? item.windspeed ?? 0.0
            HStack(spacing: 3) {
                Image(systemName: "wind")
                    .font(.caption2)
                Text(String(format: "%.0f m/s", displayWind))
                    .font(.caption2)
            }
            .foregroundStyle(
                displayWind >= 10 ? .orange : .secondary
            )

        }
    }
    
    // MARK: - Additional Info (Compact rows)
    
    private var additionalInfoSection: some View {
        Section {
            VStack(alignment: .leading) {
                if let high = viewModel.dailyHigh, let low = viewModel.dailyLow {
                    infoRow(
                        icon: "thermometer.medium",
                        label: NSLocalizedString("Temperature", comment: "Temperature label"),
                        value: String(format: "%.0f° / %.0f°", high, low),
                        colors: [.red, .orange]
                    )
                }

                if let sunrise = viewModel.sunrise, let sunset = viewModel.sunset {
                    infoRow(
                        icon: "sun.horizon.fill",
                        label: NSLocalizedString("Sun", comment: "Sun label"),
                        value: "\(sunrise) - \(sunset)",
                        colors: [.yellow, .orange]
                    )
                }

                if let qnh = viewModel.qnh {
                    infoRow(
                        icon: "gauge.with.needle",
                        label: NSLocalizedString("Pressure (QNH)", comment: "Pressure QNH label"),
                        value: String(format: "%.0f hPa", qnh),
                        colors: [.blue, .gray.opacity(0.7)]
                    )
                }

                if let cloud = viewModel.cloudCover {
                    infoRow(
                        icon: "cloud.fill",
                        label: NSLocalizedString("Cloud Cover", comment: "Cloud cover label"),
                        value: String(format: "%d%%", cloud),
                        colors: [.gray.opacity(0.85), .cyan.opacity(0.55)]
                    )
                }

                if let dewpoint = viewModel.dewpoint {
                    infoRow(
                        icon: "humidity.fill",
                        label: NSLocalizedString("Dew Point", comment: "Dew point label"),
                        value: String(format: "%.1f°", dewpoint),
                        colors: [.cyan, .blue.opacity(0.85)]
                    )
                }

                if let gust = viewModel.dailyMaxGust {
                    infoRow(
                        icon: "wind",
                        label: NSLocalizedString("Max Gust", comment: "Max gust label"),
                        value: String(format: "%.1f m/s", gust),
                        colors: [gust > 10 ? .orange : .cyan, gust > 10 ? .red.opacity(0.8) : .blue.opacity(0.7)]
                    )
                }

                if let precip = viewModel.precipitationDay, precip > 0 {
                    infoRow(
                        icon: "cloud.rain.fill",
                        label: NSLocalizedString("Precipitation", comment: "Precipitation label"),
                        value: String(format: "%.1f mm", precip),
                        colors: [.gray, .blue]
                    )
                }

                if let precipProb = viewModel.precipitationProbMax, precipProb > 0 {
                    infoRow(
                        icon: "umbrella.fill",
                        label: NSLocalizedString("Rain Chance", comment: "Rain chance label"),
                        value: "\(precipProb) %",
                        colors: [.blue, .cyan]
                    )
                }

                if let uv = viewModel.uvIndex {
                    infoRow(
                        icon: "sun.max.fill",
                        label: NSLocalizedString("UV Index", comment: "UV index label"),
                        value: String(format: "%.0f - %@", uv, uvLevel(uv)),
                        colors: [.yellow, .orange.opacity(0.9)]
                    )
                }
            }
        } header: {
            Text(NSLocalizedString("Detailed Information", comment: "Detailed information section header"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Link(destination: URL(string: "https://open-meteo.com")!) {
                    Text(NSLocalizedString("Weather data by Open-Meteo.com", comment: "Open-Meteo attribution"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.dipulAvailable {
                    Link(destination: URL(string: "https://www.dipul.de/homepage/en/help/instruction-for-weather-service/")!) {
                        Text(NSLocalizedString("Wind profile data by DIPUL/DFS (ICON-D2)", comment: "DIPUL attribution"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    private func infoRow(icon: String, label: String, value: String, colors: [Color]) -> some View {
        let primary = colors.first ?? .secondary
        let secondary = colors.count > 1 ? colors[1] : primary
        let tertiary = colors.count > 2 ? colors[2] : secondary

        return HStack(spacing: 12) {
            Image(systemName: icon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(primary, secondary, tertiary)
                .font(.title3)
                .frame(width: 32)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
    
    // MARK: - State Views
    
    private var loadingView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .yellow)
                    .font(.system(size: 56))
                    .shadow(radius: 4)
            }
            .padding(.bottom, 8)
            
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                
                Text(NSLocalizedString("Fetching Forecast...", comment: "Loading weather data title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Text(NSLocalizedString("Getting the latest drone flight conditions for this area.", comment: "Loading description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.sun.fill")
                .font(.system(size: 50))
                .foregroundStyle(
                    .linearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text(NSLocalizedString("No Weather Data", comment: "No weather data title"))
                .font(.headline)
            
            Text(NSLocalizedString("Move the map to see weather conditions", comment: "Move map instruction"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Helpers
    
    private var hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    
    private func uvLevel(_ index: Double) -> String {
        switch index {
        case 0..<3: return NSLocalizedString("Low", comment: "UV level low")
        case 3..<6: return NSLocalizedString("Moderate", comment: "UV level moderate")
        case 6..<8: return NSLocalizedString("High", comment: "UV level high")
        case 8..<11: return NSLocalizedString("Very High", comment: "UV level very high")
        default: return NSLocalizedString("Extreme", comment: "UV level extreme")
        }
    }
}

// MARK: - ViewModel

@MainActor
final class WeatherViewModel: ObservableObject {
    @Published var currentWeather: WeatherResponse?
    @Published var dipulWeather: DIPULWeatherData?
    @Published var currentHumidity: Int?
    @Published var locationName: String?
    @Published var qnh: Double?
    @Published var windGust: Double?
    @Published var cloudCover: Int?
    @Published var dewpoint: Double?
    @Published var visibility: Double?
    @Published var currentPrecipitationProbability: Int?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var timeText: String = ""
    
    private let geocoder = ReverseGeocoder()
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastFetchedCoordinate: CLLocationCoordinate2D?
    private var fetchTask: Task<Void, Never>?
    
    func update(for coordinate: CLLocationCoordinate2D) {
        // Only trigger auto-fetch if location changed significantly (> 2km) to prevent jitter reloading
        if let last = lastFetchedCoordinate {
            let loc1 = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let loc2 = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if loc1.distance(from: loc2) < 2000 {
                lastCoordinate = coordinate // Allow manual retry to pick up this small change
                return
            }
        }
        
        lastCoordinate = coordinate
        fetchTask?.cancel()
        
        // Show loading immediately if we have no data yet, so the nice loading
        // screen appears directly instead of briefly flashing the empty state.
        if currentWeather == nil {
            isLoading = true
        }
        
        fetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await fetchWeatherAndLocation()
        }
    }
    
    func retry() {
        guard lastCoordinate != nil else { return }
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            await fetchWeatherAndLocation()
        }
    }
    
    func refresh() async {
        guard lastCoordinate != nil else { return }
        fetchTask?.cancel()
        await fetchWeatherAndLocation(isRefresh: true)
    }
    
    private func fetchWeatherAndLocation(isRefresh: Bool = false) async {
        guard let coordinate = lastCoordinate else { return }
        lastFetchedCoordinate = coordinate
        
        if !isRefresh {
            isLoading = true
        }
        
        errorMessage = nil

        // Start DIPUL drone-weather fetch concurrently with Open-Meteo (best-effort, no failure on error)
        let dipulTask = Task { () -> DIPULWeatherData? in
            guard DIPULWeatherService.isWithinCoverage(coordinate) else { return nil }
            return try? await DIPULWeatherService.fetchDroneWeather(for: coordinate)
        }

        do {
            async let weather = WeatherService.fetchCurrentWeather(for: coordinate)
            async let name = geocoder.placename(for: coordinate)
            let (w, n) = try await (weather, name)
            self.currentWeather = w
            self.locationName = n
            self.timeText = formattedTime(for: w.currentWeather.time)
            self.dipulWeather = await dipulTask.value
            self.updateCurrentDetails()
            self.errorMessage = nil
        } catch let err as WeatherService.WeatherError {
            self.errorMessage = err.localizedDescription
            self.currentWeather = nil
            dipulTask.cancel()
        } catch {
            self.errorMessage = NSLocalizedString("Unable to fetch weather.", comment: "Weather fetch error")
            self.currentWeather = nil
            dipulTask.cancel()
        }
        
        isLoading = false
    }
    
    func conditionDescription(for code: Int) -> String {
        switch code {
        case 0: return NSLocalizedString("Clear", comment: "Weather condition")
        case 1: return NSLocalizedString("Mainly clear", comment: "Weather condition")
        case 2: return NSLocalizedString("Partly cloudy", comment: "Weather condition")
        case 3: return NSLocalizedString("Overcast", comment: "Weather condition")
        case 45, 48: return NSLocalizedString("Fog", comment: "Weather condition")
        case 51, 53, 55: return NSLocalizedString("Drizzle", comment: "Weather condition")
        case 56, 57: return NSLocalizedString("Freezing Drizzle", comment: "Weather condition")
        case 61, 63, 65: return NSLocalizedString("Rain", comment: "Weather condition")
        case 66, 67: return NSLocalizedString("Freezing Rain", comment: "Weather condition")
        case 71, 73, 75, 77: return NSLocalizedString("Snow", comment: "Weather condition")
        case 80, 81, 82: return NSLocalizedString("Showers", comment: "Weather condition")
        case 85, 86: return NSLocalizedString("Snow Showers", comment: "Weather condition")
        case 95, 96, 99: return NSLocalizedString("Thunderstorm", comment: "Weather condition")
        default: return NSLocalizedString("Unknown", comment: "Unknown weather condition")
        }
    }
    
    func windDirectionText(deg: Double) -> String {
        let keys = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
        let idx = Int((deg + 22.5) / 45.0) & 7
        return NSLocalizedString(keys[idx], comment: "Wind direction")
    }
    
    private func formattedTime(for timeStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let date = formatter.date(from: timeStr) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }
        return timeStr
    }
    
    // MARK: - Hourly Forecast helpers
    
    struct HourlyForecast: Identifiable {
        var id: String { timeString }
        let timeString: String
        let time: Date
        let temperature: Double?
        let precipitation: Double?
        let precipProbability: Int?
        let windspeed: Double?
        let winddirection: Double?
        let humidity: Int?
        let apparentTemperature: Double?
        let windgust: Double?
        let pressure: Double?
        let cloudcover: Int?
        let visibility: Double?
        let dewpoint: Double?
        let weathercode: Int?
        // DIPUL-specific fields (nil when outside coverage)
        let wind100mSpeed: Double?
        let wind100mDirection: Double?
        let dipulRain: Double?
    }
    
    var hourlyForecasts: [HourlyForecast] {
        guard let h = currentWeather?.hourly, !h.time.isEmpty else { return [] }
        
        var results: [HourlyForecast] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        for (index, timeStr) in h.time.enumerated() {
            let dt = formatter.date(from: timeStr) ?? Date()
            let temp = h.temperature2m?.element(at: index)
            let precip = h.precipitation?.element(at: index)
            let prob = h.precipitationProbability?.element(at: index)
            let wsp = h.windspeed10m?.element(at: index)
            let wdir = h.winddirection10m?.element(at: index)
            let gust = h.windgusts10m?.element(at: index)
            let pres = h.pressureMsl?.element(at: index)
            let cc = h.cloudcover?.element(at: index)
            let humid = h.relativeHumidity2m?.element(at: index)
            let app = h.apparentTemperature?.element(at: index)
            let vis = h.visibility?.element(at: index)
            let dew = h.dewpoint2m?.element(at: index)
            let wcode = h.weathercode?.element(at: index)

            // Match nearest DIPUL forecast to this hour slot (DIPUL timestamps are on full hours)
            let dipulSlot = dipulWeather?.forecasts.min(by: {
                abs($0.timestamp.timeIntervalSince(dt)) < abs($1.timestamp.timeIntervalSince(dt))
            })

            results.append(HourlyForecast(
                timeString: timeStr,
                time: dt,
                temperature: dipulSlot?.temperatureCelsius ?? temp,
                precipitation: precip,
                precipProbability: prob,
                windspeed: dipulSlot?.wind10m?.speed ?? wsp,
                winddirection: dipulSlot?.wind10m?.directionDegrees ?? wdir,
                humidity: humid,
                apparentTemperature: app,
                windgust: dipulSlot?.wind10m?.gust ?? gust,
                pressure: pres,
                cloudcover: cc,
                visibility: vis,
                dewpoint: dew,
                weathercode: wcode,
                wind100mSpeed: dipulSlot?.wind100m?.speed,
                wind100mDirection: dipulSlot?.wind100m?.directionDegrees,
                dipulRain: dipulSlot?.rainMmPerHour
            ))
        }
        let now = Date()
        let currentHour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        return results.filter { $0.time >= currentHour && $0.time < now.addingTimeInterval(24 * 3600) }
    }
    
    private var currentIndex: Int? {
        guard let current = currentWeather?.currentWeather.time,
              let times = currentWeather?.hourly?.time else { return nil }
        if let idx = times.firstIndex(of: current) { return idx }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let currentDate = formatter.date(from: current) else { return nil }
        var nearestIndex: Int? = nil
        var nearestInterval: TimeInterval = Double.greatestFiniteMagnitude
        for (i, t) in times.enumerated() {
            if let dt = formatter.date(from: t) {
                let interval = abs(dt.timeIntervalSince(currentDate))
                if interval < nearestInterval {
                    nearestInterval = interval
                    nearestIndex = i
                }
            }
        }
        return nearestIndex
    }
    
    /// Wind at multiple AGL heights from the current DIPUL forecast slot.
    var windProfile: [DIPULWeatherData.WindAtHeight] {
        dipulWeather?.current?.winds ?? []
    }

    var dipulAvailable: Bool { dipulWeather != nil }

    private func updateCurrentDetails() {
        currentHumidity = nil
        currentPrecipitationProbability = nil
        qnh = nil
        cloudCover = nil
        dewpoint = nil
        visibility = nil
        windGust = nil
        dailyHigh = nil
        dailyLow = nil
        sunrise = nil
        sunset = nil
        sunriseTime = nil
        sunsetTime = nil
        uvIndex = nil
        precipitationDay = nil
        precipitationProbMax = nil
        dailyMaxGust = nil

        guard let idx = currentIndex, let h = currentWeather?.hourly else { return }
        self.currentHumidity = h.relativeHumidity2m?.element(at: idx)
        self.currentPrecipitationProbability = h.precipitationProbability?.element(at: idx)
        if let p = h.pressureMsl?.element(at: idx) { self.qnh = p }
        if let cc = h.cloudcover?.element(at: idx) { self.cloudCover = cc }
        if let dew = h.dewpoint2m?.element(at: idx) { self.dewpoint = dew }
        if let vis = h.visibility?.element(at: idx) { self.visibility = vis }
        
        if let gust = currentWeather?.currentWeather.windgusts { self.windGust = gust }
        else if let g = h.windgusts10m?.element(at: idx) { self.windGust = g }

        // Prefer DIPUL data where available – ICON-D2 is higher resolution and aviation-grade
        if let dipulCurrent = dipulWeather?.current {
            if let dipulQNH   = dipulCurrent.qnhHPa                { self.qnh         = dipulQNH }
            if let cloud       = dipulCurrent.totalCloudCoverPercent { self.cloudCover  = Int(cloud.rounded()) }
            if let humid       = dipulCurrent.humidityPercent        { self.currentHumidity = Int(humid.rounded()) }
            if let gust        = dipulCurrent.wind10m?.gust          { self.windGust    = gust }
        }

        if let d = currentWeather?.daily {
            self.dailyHigh = d.temperature2mMax?.first
            self.dailyLow = d.temperature2mMin?.first
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            
            if let sr = d.sunrise?.first { 
                self.sunrise = formatTimeOnly(sr)
                self.sunriseTime = formatter.date(from: sr)
            }
            if let ss = d.sunset?.first { 
                self.sunset = formatTimeOnly(ss)
                self.sunsetTime = formatter.date(from: ss)
            }
            
            self.uvIndex = d.uvIndexMax?.first
            self.precipitationDay = d.precipitationSum?.first
            self.precipitationProbMax = d.precipitationProbabilityMax?.first
            if let g = d.windgusts10mMax?.first { self.dailyMaxGust = g }
        }
    }
    
    private func formatTimeOnly(_ isoString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let dt = formatter.date(from: isoString) {
            let outputFormatter = DateFormatter()
            outputFormatter.timeStyle = .short
            outputFormatter.dateStyle = .none
            return outputFormatter.string(from: dt)
        }
        return isoString
    }
    
    @Published var dailyHigh: Double?
    @Published var dailyLow: Double?
    @Published var sunrise: String?
    @Published var sunset: String?
    @Published var uvIndex: Double?
    @Published var precipitationDay: Double?
    @Published var precipitationProbMax: Int?
    @Published var dailyMaxGust: Double?
    
    private var sunriseTime: Date?
    private var sunsetTime: Date?
    
    // MARK: - Unified Day/Night Detection
    
    func isNightTime(at date: Date) -> Bool {
        guard let sunrise = sunriseTime, let sunset = sunsetTime else {
            // Fallback: simple hour-based check
            let hour = Calendar.current.component(.hour, from: date)
            return hour >= 18 || hour < 6
        }

        let cal = Calendar.current
        let nowComps = cal.dateComponents([.hour, .minute], from: date)
        let sunriseComps = cal.dateComponents([.hour, .minute], from: sunrise)
        let sunsetComps = cal.dateComponents([.hour, .minute], from: sunset)

        guard
            let nowH = nowComps.hour, let nowM = nowComps.minute,
            let srH = sunriseComps.hour, let srM = sunriseComps.minute,
            let ssH = sunsetComps.hour, let ssM = sunsetComps.minute
        else { return false }

        let nowMinutes = nowH * 60 + nowM
        let sunriseMinutes = srH * 60 + srM
        let sunsetMinutes = ssH * 60 + ssM

        return nowMinutes < sunriseMinutes || nowMinutes >= sunsetMinutes
    }
    
    func isCurrentlyNight() -> Bool {
        if let isDay = currentWeather?.currentWeather.isDay {
            return isDay == 0
        }
        return isNightTime(at: Date())
    }
    
    // MARK: - Unified Weather Icon Logic
    
    struct WeatherIcon {
        let symbol: String
        // Colors for multicolor symbols: Primary, Secondary, Tertiary
        let colors: [Color]
    }
    
    /// Returns the appropriate SF Symbol and colors for weather conditions
    /// - Parameters:
    ///   - weathercode: WMO weather code (optional - takes priority)
    ///   - cloudcover: Cloud cover percentage (optional - used as fallback)
    ///   - isNight: Whether it's nighttime
    ///   - colorScheme: Current color scheme for adapting colors (e.g. snow)
    func weatherIcon(weathercode: Int? = nil, cloudcover: Int? = nil, isNight: Bool, colorScheme: ColorScheme) -> WeatherIcon {
        let snowColor: Color = colorScheme == .dark ? .white : .gray

        // Priority 1: Weather code (specific conditions)
        if let code = weathercode {
            switch code {
            // Fog
            case 45, 48:
                return WeatherIcon(symbol: "cloud.fog.fill", colors: [.gray, .white.opacity(0.8)])
            
            // Drizzle
            case 51, 53, 55, 56, 57:
                return WeatherIcon(symbol: "cloud.drizzle.fill", colors: [.gray, .cyan])
            
            // Rain
            case 61, 63, 65, 66, 67:
                return WeatherIcon(symbol: "cloud.rain.fill", colors: [.gray, .blue])
            
            // Snow
            case 71, 73, 75, 77:
                return WeatherIcon(symbol: "cloud.snow.fill", colors: [.gray, snowColor])
            
            // Rain showers (Sun/Cloud rain) - Using multicolor symbols that typically have sun+cloud+rain
            case 80, 81, 82:
                if isNight {
                    // cloud.moon.rain.fill: Cloud, Moon, Rain
                    return WeatherIcon(symbol: "cloud.moon.rain.fill", colors: [.gray, .indigo, .blue])
                } else {
                    // cloud.sun.rain.fill: Cloud, Sun, Rain or similar mapping. 
                    // Providing 3 colors usually maps to the layers.
                    return WeatherIcon(symbol: "cloud.sun.rain.fill", colors: [.gray, .yellow, .blue])
                }
            
            // Snow showers
            case 85, 86:
                return WeatherIcon(symbol: "cloud.snow.fill", colors: [.gray, snowColor])
            
            // Thunderstorm
            case 95, 96, 99:
                return WeatherIcon(symbol: "cloud.bolt.rain.fill", colors: [.gray, .blue])
            
            // Clear or mainly clear
            case 0, 1:
                if isNight {
                    return WeatherIcon(symbol: "moon.stars.fill", colors: [.indigo, .white])
                } else {
                    return WeatherIcon(symbol: "sun.max.fill", colors: [.yellow, .orange])
                }
            
            // Partly cloudy
            case 2:
                if isNight {
                    return WeatherIcon(symbol: "cloud.moon.fill", colors: [.gray, .indigo])
                } else {
                    return WeatherIcon(symbol: "cloud.sun.fill", colors: [.gray, .yellow])
                }
            
            // Overcast
            case 3:
                return WeatherIcon(symbol: "cloud.fill", colors: [.gray, .gray.opacity(0.6)])
            
            default:
                break
            }
        }
        
        // Priority 2: Cloud cover (general conditions)
        if let cloud = cloudcover {
            switch cloud {
            case 0..<20:
                if isNight {
                    return WeatherIcon(symbol: "moon.stars.fill", colors: [.indigo, .white])
                } else {
                    return WeatherIcon(symbol: "sun.max.fill", colors: [.yellow, .orange])
                }
            case 20..<60:
                if isNight {
                    return WeatherIcon(symbol: "cloud.moon.fill", colors: [.gray, .indigo])
                } else {
                    return WeatherIcon(symbol: "cloud.sun.fill", colors: [.gray, .yellow])
                }
            default:
                return WeatherIcon(symbol: "cloud.fill", colors: [.gray, .gray.opacity(0.6)])
            }
        }
        
        // Fallback: default clear icon
        if isNight {
            return WeatherIcon(symbol: "moon.stars.fill", colors: [.indigo, .white])
        } else {
            return WeatherIcon(symbol: "sun.max.fill", colors: [.yellow, .orange])
        }
    }
    
    // MARK: - Flight Conditions Assessment
    
    var flightConditionIcon: String {
        let assessment = flightConditionAssessment()
        switch assessment {
        case .good: return "checkmark.circle.fill"
        case .marginal: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.circle.fill"
        }
    }
    
    var flightConditionColor: Color {
        let assessment = flightConditionAssessment()
        switch assessment {
        case .good: return .green
        case .marginal: return .orange
        case .poor: return .red
        }
    }
    
    var flightConditionText: String {
        let assessment = flightConditionAssessment()
        switch assessment {
        case .good: return NSLocalizedString("Optimal flight conditions", comment: "Flight condition good")
        case .marginal: return NSLocalizedString("Limited - exercise caution", comment: "Flight condition marginal")
        case .poor: return NSLocalizedString("Flight not recommended", comment: "Flight condition poor")
        }
    }
    
    enum FlightCondition {
        case good, marginal, poor
    }
    
    private func flightConditionAssessment() -> FlightCondition {
        guard let weather = currentWeather else { return .poor }

        // Use DIPUL wind at 100 m AGL when available – most representative altitude for drone ops.
        // Fall back through 10 m DIPUL → Open-Meteo 10 m.
        let windspeed = dipulWeather?.current?.wind100m?.speed
            ?? dipulWeather?.current?.wind10m?.speed
            ?? weather.currentWeather.windspeed
        let gust = dipulWeather?.current?.wind10m?.gust
            ?? windGust
            ?? weather.currentWeather.windgusts
            ?? 0
        let visibility = self.visibility ?? 10000
        let precipitation = dipulWeather?.current?.rainMmPerHour
            ?? weather.currentWeather.precipitation
            ?? 0
        let snowPrecipitation = dipulWeather?.current?.snowCmPerHour ?? 0
        let upcomingPrecipitationProbability = self.upcomingPrecipitationProbability ?? 0
        let weathercode = weather.currentWeather.weathercode

        // Poor conditions
        if windspeed >= 12 { return .poor }
        if gust >= 15 { return .poor }
        if visibility < 3000 { return .poor }
        if precipitation > 2.0 { return .poor }
        if snowPrecipitation > 1.0 { return .poor }
        if upcomingPrecipitationProbability > 50 { return .poor }
        if [95, 96, 99].contains(weathercode) { return .poor } // Thunderstorms
        if [66, 67].contains(weathercode) { return .poor }     // Freezing rain

        // Marginal conditions
        if windspeed >= 8 { return .marginal }
        if gust >= 10 { return .marginal }
        if visibility < 5000 { return .marginal }
        if precipitation > 0.5 { return .marginal }
        if snowPrecipitation > 0.1 { return .marginal }
        if upcomingPrecipitationProbability > 20 { return .marginal }

        // Marginal Weather Codes: Rain, Snow, Showers, Fog, Drizzle
        if [45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 71, 73, 75, 80, 81, 82, 85, 86].contains(weathercode) { return .marginal }

        let temp = dipulWeather?.current?.temperatureCelsius ?? weather.currentWeather.temperature
        if temp < -10 || temp > 40 { return .marginal }

        if isCurrentlyNight() { return .marginal }

        return .good
    }
    
    var flightAdvisories: [String] {
        var advisories: [String] = []
        guard let weather = currentWeather else { return advisories }

        let windspeed = dipulWeather?.current?.wind100m?.speed
            ?? dipulWeather?.current?.wind10m?.speed
            ?? weather.currentWeather.windspeed
        let gust = dipulWeather?.current?.wind10m?.gust
            ?? windGust
            ?? weather.currentWeather.windgusts
            ?? 0
        let visibility = self.visibility ?? 10000
        let precipitation = dipulWeather?.current?.rainMmPerHour
            ?? weather.currentWeather.precipitation
            ?? 0
        let snowPrecipitation = dipulWeather?.current?.snowCmPerHour ?? 0
        let upcomingPrecipitationProbability = self.upcomingPrecipitationProbability ?? 0
        let weathercode = weather.currentWeather.weathercode
        let heightNote = dipulWeather != nil ? " @100m AGL" : ""

        if windspeed >= 12 {
            advisories.append(String(format: NSLocalizedString("Dangerous wind speed: %.1f m/s", comment: "Dangerous wind advisory"), windspeed) + heightNote)
        } else if windspeed >= 8 {
            advisories.append(String(format: NSLocalizedString("High wind speed: %.1f m/s", comment: "High wind advisory"), windspeed) + heightNote)
        }

        if gust >= 15 {
            advisories.append(String(format: NSLocalizedString("Dangerous gusts: %.1f m/s", comment: "Dangerous gust advisory"), gust))
        } else if gust >= 10 {
            advisories.append(String(format: NSLocalizedString("Strong gusts: %.1f m/s", comment: "Strong gust advisory"), gust))
        }

        if visibility < 3000 {
            advisories.append(String(format: NSLocalizedString("Very poor visibility: %.1f km", comment: "Very poor visibility advisory"), visibility / 1000))
        } else if visibility < 5000 {
            advisories.append(String(format: NSLocalizedString("Limited visibility: %.1f km", comment: "Limited visibility advisory"), visibility / 1000))
        }

        if precipitation > 2.0 {
            advisories.append(NSLocalizedString("Heavy precipitation", comment: "Heavy precipitation advisory"))
        } else if precipitation > 0.5 {
            advisories.append(NSLocalizedString("Active precipitation", comment: "Active precipitation advisory"))
        }

        if upcomingPrecipitationProbability > 50 {
            advisories.append(String(format: NSLocalizedString("Very high precipitation risk (%d%%) in the next hour", comment: "Very high precipitation risk advisory"), upcomingPrecipitationProbability))
        } else if upcomingPrecipitationProbability > 20 {
            advisories.append(String(format: NSLocalizedString("Precipitation risk (%d%%) in the next hour", comment: "Precipitation risk advisory"), upcomingPrecipitationProbability))
        }

        if snowPrecipitation > 1.0 {
            advisories.append(NSLocalizedString("Snow precipitation - avoid flying", comment: "Snow advisory"))
        } else if snowPrecipitation > 0.1 {
            advisories.append(NSLocalizedString("Snow precipitation present", comment: "Snow present advisory"))
        }

        if [95, 96, 99].contains(weathercode) {
            advisories.append(NSLocalizedString("Thunderstorm activity - DO NOT FLY", comment: "Thunderstorm advisory"))
        } else if [66, 67].contains(weathercode) {
            advisories.append(NSLocalizedString("Freezing rain - avoid flying", comment: "Freezing rain advisory"))
        } else if [45, 48].contains(weathercode) {
            advisories.append(NSLocalizedString("Fog present", comment: "Fog advisory"))
        } else if [51, 53, 55, 56, 57].contains(weathercode) {
            advisories.append(NSLocalizedString("Drizzle present", comment: "Drizzle advisory"))
        } else if [61, 63, 65, 80, 81, 82].contains(weathercode) {
            advisories.append(NSLocalizedString("Rain or showers present", comment: "Rain or showers advisory"))
        } else if [71, 73, 75, 85, 86].contains(weathercode) {
            advisories.append(NSLocalizedString("Snow or snow showers present", comment: "Snow weather code advisory"))
        }

        let temp = dipulWeather?.current?.temperatureCelsius ?? weather.currentWeather.temperature
        if temp < -10 {
            advisories.append(NSLocalizedString("Very cold - battery performance affected", comment: "Cold temperature advisory"))
        } else if temp > 40 {
            advisories.append(NSLocalizedString("Very hot - equipment may overheat", comment: "Hot temperature advisory"))
        }

        if isCurrentlyNight() {
            advisories.append(NSLocalizedString("Nighttime - ensure proper lighting and permissions", comment: "Night flight advisory"))
        }

        return advisories
    }

    private var upcomingPrecipitationProbability: Int? {
        hourlyForecasts.first(where: { $0.time > Date() })?.precipProbability
    }
}

extension Array {
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

#Preview {
    WeatherView()
        .environmentObject(DroneSettings())
}
