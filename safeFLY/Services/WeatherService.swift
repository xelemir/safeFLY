//
//  WeatherService.swift
//  safeFLY
//
//  Weather service using Open-Meteo API with drone-relevant parameters
//  Refactored to use Open-Meteo instead of DIPUL/DFS API
//

import Foundation
import CoreLocation

struct WeatherResponse: Codable {
    struct Current: Codable {
        let temperature: Double
        let windspeed: Double
        let winddirection: Double
        let windgusts: Double?
        let pressureMsl: Double?
        let weathercode: Int
        let time: String
        let relativehumidity: Int?
        let apparentTemperature: Double?
        let precipitation: Double?
        let precipitationProbability: Int?
        let cloudcover: Int?
        let visibility: Double?
        let isDay: Int?
    }

    let currentWeather: Current

    struct Hourly: Codable {
        let time: [String]
        let temperature2m: [Double]?
        let apparentTemperature: [Double]?
        let relativeHumidity2m: [Int]?
        let precipitation: [Double]?
        let precipitationProbability: [Int]?
        let windspeed10m: [Double]?
        let windgusts10m: [Double]?
        let winddirection10m: [Double]?
        let pressureMsl: [Double]?
        let cloudcover: [Int]?
        let cloudcoverLow: [Int]?
        let cloudcoverMid: [Int]?
        let cloudcoverHigh: [Int]?
        let visibility: [Double]?
        let dewpoint2m: [Double]?
        let weathercode: [Int]?
    }

    let hourly: Hourly?

    struct Daily: Codable {
        let time: [String]?
        let temperature2mMax: [Double]?
        let temperature2mMin: [Double]?
        let sunrise: [String]?
        let sunset: [String]?
        let uvIndexMax: [Double]?
        let precipitationSum: [Double]?
        let precipitationProbabilityMax: [Int]?
        let windspeed10mMax: [Double]?
        let windgusts10mMax: [Double]?
        let winddirection10mDominant: [Double]?
        let pressureMslMean: [Double]?
        let cloudcoverMean: [Int]?
    }

    let daily: Daily?
}

final class WeatherService {
    enum WeatherError: Error, LocalizedError {
        case invalidURL
        case requestFailed
        case missingCurrentWeather
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid request URL"
            case .requestFailed: return "Request failed"
            case .missingCurrentWeather: return "No current weather in response"
            case .decodingFailed(let msg): return "Decoding failed: \(msg)"
            }
        }
    }

    /// Fetches current weather for the given coordinate using Open-Meteo API
    /// - Parameters:
    ///   - coordinate: location coordinate
    /// - Returns: `WeatherResponse` including current weather, hourly and daily forecasts
    static func fetchCurrentWeather(for coordinate: CLLocationCoordinate2D) async throws -> WeatherResponse {
        // Build Open-Meteo API URL with all drone-relevant parameters
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,precipitation_probability,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,visibility"),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,precipitation,precipitation_probability,weather_code,pressure_msl,cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,visibility,wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,pressure_msl_mean,cloud_cover_mean"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        
        guard let url = components.url else { throw WeatherError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WeatherError.requestFailed
        }

        // Decode Open-Meteo response
        let decoder = JSONDecoder()
        // Don't use automatic snake_case conversion - Open-Meteo uses mixed formats
        
        let openMeteoResp: OpenMeteoResponse
        do {
            openMeteoResp = try decoder.decode(OpenMeteoResponse.self, from: data)
        } catch {
            throw WeatherError.decodingFailed(error.localizedDescription)
        }

        guard let current = openMeteoResp.current else {
            throw WeatherError.missingCurrentWeather
        }

        // Map Open-Meteo response to our WeatherResponse model
        // Note: Open-Meteo returns wind speeds in km/h, convert to m/s
        let currentWeather = WeatherResponse.Current(
            temperature: current.temperature_2m,
            windspeed: current.wind_speed_10m / 3.6, // Convert km/h to m/s
            winddirection: current.wind_direction_10m,
            windgusts: current.wind_gusts_10m != nil ? current.wind_gusts_10m! / 3.6 : nil, // Convert km/h to m/s
            pressureMsl: current.pressure_msl,
            weathercode: current.weather_code,
            time: current.time,
            relativehumidity: current.relative_humidity_2m,
            apparentTemperature: current.apparent_temperature,
            precipitation: current.precipitation,
            precipitationProbability: current.precipitation_probability,
            cloudcover: current.cloud_cover,
            visibility: current.visibility,
            isDay: current.is_day
        )

        // Map hourly data
        var hourly: WeatherResponse.Hourly? = nil
        if let h = openMeteoResp.hourly {
            // Convert wind speeds from km/h to m/s
            let windspeed10m = h.wind_speed_10m?.map { $0 / 3.6 }
            let windgusts10m = h.wind_gusts_10m?.map { $0 / 3.6 }
            
            hourly = WeatherResponse.Hourly(
                time: h.time,
                temperature2m: h.temperature_2m,
                apparentTemperature: h.apparent_temperature,
                relativeHumidity2m: h.relative_humidity_2m,
                precipitation: h.precipitation,
                precipitationProbability: h.precipitation_probability,
                windspeed10m: windspeed10m,
                windgusts10m: windgusts10m,
                winddirection10m: h.wind_direction_10m,
                pressureMsl: h.pressure_msl,
                cloudcover: h.cloud_cover,
                cloudcoverLow: h.cloud_cover_low,
                cloudcoverMid: h.cloud_cover_mid,
                cloudcoverHigh: h.cloud_cover_high,
                visibility: h.visibility,
                dewpoint2m: h.dew_point_2m,
                weathercode: h.weather_code
            )
        }

        // Map daily data
        var daily: WeatherResponse.Daily? = nil
        if let d = openMeteoResp.daily {
            // Convert wind speeds from km/h to m/s
            let windspeed10mMax = d.wind_speed_10m_max?.map { $0 / 3.6 }
            let windgusts10mMax = d.wind_gusts_10m_max?.map { $0 / 3.6 }
            
            daily = WeatherResponse.Daily(
                time: d.time,
                temperature2mMax: d.temperature_2m_max,
                temperature2mMin: d.temperature_2m_min,
                sunrise: d.sunrise,
                sunset: d.sunset,
                uvIndexMax: d.uv_index_max,
                precipitationSum: d.precipitation_sum,
                precipitationProbabilityMax: d.precipitation_probability_max,
                windspeed10mMax: windspeed10mMax,
                windgusts10mMax: windgusts10mMax,
                winddirection10mDominant: d.wind_direction_10m_dominant,
                pressureMslMean: d.pressure_msl_mean,
                cloudcoverMean: d.cloud_cover_mean
            )
        }

        return WeatherResponse(currentWeather: currentWeather, hourly: hourly, daily: daily)
    }
}

// MARK: - Open-Meteo Response Models

private struct OpenMeteoResponse: Codable {
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
    let current: OpenMeteoCurrent?
    let hourly: OpenMeteoHourly?
    let daily: OpenMeteoDaily?
}

private struct OpenMeteoCurrent: Codable {
    let time: String
    let temperature_2m: Double
    let relative_humidity_2m: Int?
    let apparent_temperature: Double?
    let is_day: Int?
    let precipitation: Double?
    let precipitation_probability: Int?
    let weather_code: Int
    let cloud_cover: Int?
    let pressure_msl: Double?
    let wind_speed_10m: Double
    let wind_direction_10m: Double
    let wind_gusts_10m: Double?
    let visibility: Double?
}

private struct OpenMeteoHourly: Codable {
    let time: [String]
    let temperature_2m: [Double]?
    let apparent_temperature: [Double]?
    let relative_humidity_2m: [Int]?
    let dew_point_2m: [Double]?
    let precipitation: [Double]?
    let precipitation_probability: [Int]?
    let weather_code: [Int]?
    let pressure_msl: [Double]?
    let cloud_cover: [Int]?
    let cloud_cover_low: [Int]?
    let cloud_cover_mid: [Int]?
    let cloud_cover_high: [Int]?
    let visibility: [Double]?
    let wind_speed_10m: [Double]?
    let wind_direction_10m: [Double]?
    let wind_gusts_10m: [Double]?
}

private struct OpenMeteoDaily: Codable {
    let time: [String]?
    let weather_code: [Int]?
    let temperature_2m_max: [Double]?
    let temperature_2m_min: [Double]?
    let sunrise: [String]?
    let sunset: [String]?
    let uv_index_max: [Double]?
    let precipitation_sum: [Double]?
    let precipitation_probability_max: [Int]?
    let wind_speed_10m_max: [Double]?
    let wind_gusts_10m_max: [Double]?
    let wind_direction_10m_dominant: [Double]?
    let pressure_msl_mean: [Double]?
    let cloud_cover_mean: [Int]?
}