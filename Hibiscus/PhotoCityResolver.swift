import CoreLocation
import Foundation
import MapKit

actor PhotoCityResolver {
    static let shared = PhotoCityResolver()

    private var cache: [String: String] = [:]

    func cityName(
        latitude: Double,
        longitude: Double,
        locale: Locale
    ) async -> String? {
        let key = String(
            format: "%.3f,%.3f,%@",
            latitude,
            longitude,
            locale.identifier
        )
        if let cached = cache[key] { return cached }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        let resolved: String?
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = locale
            let mapItems = try? await request.mapItems
            resolved = mapItems?.first?.addressRepresentations?.cityName
        } else {
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
                location,
                preferredLocale: locale
            )
            let placemark = placemarks?.first
            resolved = placemark?.locality
                ?? placemark?.subAdministrativeArea
                ?? placemark?.administrativeArea
        }

        guard let city = resolved?.trimmingCharacters(in: .whitespacesAndNewlines),
              !city.isEmpty else { return nil }
        cache[key] = city
        return city
    }
}
