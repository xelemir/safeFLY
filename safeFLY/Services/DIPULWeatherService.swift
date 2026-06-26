//
//  DIPULWeatherService.swift
//  safeFLY
//
//  Fetches drone-relevant weather from the DIPUL/DFS Weather API.
//  Provides wind at 10/50/100/150 m AGL, QNH, temperature, precipitation,
//  cloud cover and humidity for locations in Central Europe (ICON-D2 model).
//

import Foundation
import CoreLocation

// MARK: - DIPUL Weather Data Models

struct DIPULWeatherData {
    struct WindAtHeight {
        let heightMeters: Int
        let speed: Double            // m/s
        let directionDegrees: Double // 0–360°, meteorological (FROM which wind blows)
        let gust: Double?            // m/s, only available at 10 m AGL
    }

    struct ForecastData {
        let timestamp: Date
        let qnhPa: Double?
        let temperatureCelsius: Double?
        let winds: [WindAtHeight]       // sorted ascending by height
        let rainMmPerHour: Double?
        let snowCmPerHour: Double?
        let totalCloudCoverPercent: Double?
        let humidityPercent: Double?

        var qnhHPa: Double? { qnhPa.map { $0 / 100.0 } }

        var wind10m:  WindAtHeight? { winds.first(where: { $0.heightMeters == 10  }) }
        var wind50m:  WindAtHeight? { winds.first(where: { $0.heightMeters == 50  }) }
        var wind100m: WindAtHeight? { winds.first(where: { $0.heightMeters == 100 }) }
        var wind150m: WindAtHeight? { winds.first(where: { $0.heightMeters == 150 }) }
    }

    let calculationTime: Date
    let latitude: Double
    let longitude: Double
    let forecasts: [ForecastData]   // sorted ascending by timestamp

    var current: ForecastData? { forecasts.first }
}

// MARK: - DIPUL Weather Service

final class DIPULWeatherService {
    enum DIPULError: Error, LocalizedError {
        case invalidURL
        case requestFailed(Int)
        case decodingFailed(String)
        case noData
        case outsideCoverage

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return NSLocalizedString("Invalid DIPUL URL", comment: "DIPUL weather service invalid URL error")
            case .requestFailed(let code):
                return String.localizedStringWithFormat(
                    NSLocalizedString("DIPUL request failed (HTTP %d)", comment: "DIPUL weather service request failed error"),
                    code
                )
            case .decodingFailed(let message):
                return String.localizedStringWithFormat(
                    NSLocalizedString("DIPUL decoding: %@", comment: "DIPUL weather service decoding failed error"),
                    message
                )
            case .noData:
                return NSLocalizedString("No DIPUL weather data available", comment: "DIPUL weather service no data error")
            case .outsideCoverage:
                return NSLocalizedString("Location outside DIPUL coverage (Central Europe only)", comment: "DIPUL weather service outside coverage error")
            }
        }
    }

    // Bounding box from the DIPUL OpenAPI spec
    private static let minLat =  43.19, maxLat = 58.01
    private static let minLon =  -3.87, maxLon = 20.19

    static func isWithinCoverage(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude  >= minLat && c.latitude  <= maxLat &&
        c.longitude >= minLon && c.longitude <= maxLon
    }

    /// Fetches drone-relevant weather from the DIPUL/DFS Weather API.
    ///
    /// Returns wind at 10 / 50 / 100 / 150 m AGL, QNH, temperature (2 m),
    /// rain & snow precipitation, total cloud cover, and air humidity for
    /// the next 24 hours.  Uses the high-resolution ICON-D2 model (~2 km).
    ///
    /// Throws `DIPULError.outsideCoverage` when the coordinate is outside
    /// Central Europe (Germany, Austria, Switzerland, Benelux, Denmark…).
    static func fetchDroneWeather(for coordinate: CLLocationCoordinate2D) async throws -> DIPULWeatherData {
        guard isWithinCoverage(coordinate) else { throw DIPULError.outsideCoverage }

        guard let url = URL(string: "https://utm-service.dfs.de/api/weather/v1/weather") else {
            throw DIPULError.invalidURL
        }

        let timestamps = hourlyTimestamps(count: 24)
        let body = requestBody(lat: coordinate.latitude, lon: coordinate.longitude, forecasts: timestamps)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DIPULError.requestFailed(-1) }
        guard (200...299).contains(http.statusCode) else { throw DIPULError.requestFailed(http.statusCode) }

        return try parseResponse(data: data, lat: coordinate.latitude, lon: coordinate.longitude)
    }

    // MARK: - Private Helpers

    private static func hourlyTimestamps(count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        guard let currentHour = cal.date(from: comps) else { return [] }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone(identifier: "UTC")

        return (0..<count).compactMap { offset in
            cal.date(byAdding: .hour, value: offset, to: currentHour).map { fmt.string(from: $0) }
        }
    }

    private static func requestBody(lat: Double, lon: Double, forecasts: [String]) -> [String: Any] {
        [
            "positions": [
                [
                    "latitude":  lat,
                    "longitude": lon,
                    "forecasts": forecasts,
                    "qnh":       ["unit": "Pa"],
                    "temperature": [
                        "unit":    "C",
                        "heights": [["reference": "AGL", "unit": "m", "value": 2]]
                    ],
                    "wind": [
                        "unit": "m/s",
                        "heights": [10, 50, 100, 150].map { h -> [String: Any] in
                            ["reference": "AGL", "unit": "m", "value": h]
                        }
                    ],
                    "rainPrecipitation": ["unit": "mm"],
                    "snowPrecipitation": ["unit": "cm"],
                    "totalCloudCover":   ["unit": "%"],
                    "airHumidity": [
                        "unit":    "%",
                        "heights": [["reference": "AGL", "unit": "m", "value": 50]]
                    ]
                ] as [String: Any]
            ]
        ]
    }

    private static func parseResponse(data: Data, lat: Double, lon: Double) throws -> DIPULWeatherData {
        guard
            let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let positions  = json["positions"]  as? [[String: Any]],
            let position   = positions.first,
            let forecastsJ = position["forecasts"] as? [[String: Any]]
        else {
            throw DIPULError.decodingFailed("Unexpected JSON structure")
        }

        let iso      = ISO8601DateFormatter()
        let calcTime = (json["calculationTime"] as? String).flatMap { iso.date(from: $0) } ?? Date()
        let respLat  = position["latitude"]  as? Double ?? lat
        let respLon  = position["longitude"] as? Double ?? lon

        var forecasts: [DIPULWeatherData.ForecastData] = []

        for f in forecastsJ {
            guard
                let tsStr = f["timestamp"] as? String,
                let ts    = iso.date(from: tsStr)
            else { continue }

            let qnh  = (f["qnh"]  as? [String: Any])?["value"] as? Double
            let temp = (f["temperature"] as? [[String: Any]])?.first?["value"] as? Double

            var winds: [DIPULWeatherData.WindAtHeight] = []
            if let windArray = f["wind"] as? [[String: Any]] {
                for w in windArray {
                    guard
                        let u    = w["uComponent"] as? Double,
                        let v    = w["vComponent"] as? Double,
                        let hJ   = w["height"] as? [String: Any],
                        let hVal = hJ["value"] as? Int
                    else { continue }

                    let speed = (u * u + v * v).squareRoot()
                    // Meteorological wind direction per DIPUL spec: atan2(u, v) × (180/π)
                    // Gives degrees clockwise from north (direction FROM which wind blows).
                    var dir = atan2(u, v) * (180.0 / Double.pi)
                    if dir < 0 { dir += 360.0 }

                    winds.append(DIPULWeatherData.WindAtHeight(
                        heightMeters:     hVal,
                        speed:            speed,
                        directionDegrees: dir,
                        gust:             w["windSpeedGust"] as? Double
                    ))
                }
                winds.sort { $0.heightMeters < $1.heightMeters }
            }

            let rain     = (f["rainPrecipitation"] as? [String: Any])?["value"] as? Double
            let snow     = (f["snowPrecipitation"] as? [String: Any])?["value"] as? Double
            let cloud    = (f["totalCloudCover"]   as? [String: Any])?["value"] as? Double
            let humidity = (f["airHumidity"] as? [[String: Any]])?.first?["value"] as? Double

            forecasts.append(DIPULWeatherData.ForecastData(
                timestamp:              ts,
                qnhPa:                  qnh,
                temperatureCelsius:     temp,
                winds:                  winds,
                rainMmPerHour:          rain,
                snowCmPerHour:          snow,
                totalCloudCoverPercent: cloud,
                humidityPercent:        humidity
            ))
        }

        forecasts.sort { $0.timestamp < $1.timestamp }
        if forecasts.isEmpty { throw DIPULError.noData }

        return DIPULWeatherData(
            calculationTime: calcTime,
            latitude:        respLat,
            longitude:       respLon,
            forecasts:       forecasts
        )
    }
}
