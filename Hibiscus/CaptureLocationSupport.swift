@preconcurrency import AVFoundation
import CoreLocation
import Foundation
import ImageIO

@MainActor
final class CaptureLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = CaptureLocationProvider()

    private let manager = CLLocationManager()
    private var isEnabled = false
    private var latestLocation: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard enabled else {
            manager.stopUpdatingLocation()
            latestLocation = nil
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func refreshIfEnabled(_ enabled: Bool) {
        guard enabled else { return }
        isEnabled = true
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            // This can occur only when an already-persisted preference is
            // restored. A fresh install defaults Save Location to off.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func recentLocation(maxAge: TimeInterval = 300) -> CLLocation? {
        guard isEnabled else { return nil }
        let candidate = [latestLocation, manager.location]
            .compactMap { $0 }
            .filter { $0.horizontalAccuracy >= 0 }
            .max(by: { $0.timestamp < $1.timestamp })
        guard let candidate,
              Date().timeIntervalSince(candidate.timestamp) <= maxAge else { return nil }
        return candidate
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isEnabled else { return }
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isEnabled else { return }
        latestLocation = locations
            .filter { $0.horizontalAccuracy >= 0 }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError _: Error) {
        // Location is optional. Camera capture and saving continue normally.
    }
}

nonisolated final class CapturePhotoMetadataCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    private let location: CLLocation

    init(location: CLLocation) {
        self.location = location
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        metadata[kCGImagePropertyGPSDictionary as String] = Self.gpsDictionary(for: location)
        return metadata
    }

    static func gpsDictionary(for location: CLLocation) -> [String: Any] {
        let coordinate = location.coordinate
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude >= 0 ? "E" : "W"
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude >= 0 ? 0 : 1
        }
        return gps
    }

    static func coordinateString(for location: CLLocation) -> String {
        let coordinate = location.coordinate
        let northSouth = coordinate.latitude >= 0 ? "N" : "S"
        let eastWest = coordinate.longitude >= 0 ? "E" : "W"
        return String(
            format: "%.2f°%@ · %.2f°%@",
            abs(coordinate.latitude), northSouth,
            abs(coordinate.longitude), eastWest
        )
    }
}
