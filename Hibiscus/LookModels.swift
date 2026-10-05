import CoreImage
import SwiftUI

nonisolated enum AppDestination: String, CaseIterable {
    case camera = "Camera"
    case grade = "Grade"
    case settings = "Settings"

    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .grade: "circle.lefthalf.filled"
        case .settings: "gearshape.fill"
        }
    }
}

nonisolated enum CameraCharacter: String, CaseIterable, Identifiable, Sendable {
    case alpha, beta, gamma, delta, epsilon, zeta, eta, theta, sigma, omega

    var id: Self { self }

    var symbol: String {
        switch self {
        case .alpha: "✨"
        case .beta: "🎞️"
        case .gamma: "💿"
        case .delta: "⚡️"
        case .epsilon: "🖼️"
        case .zeta: "🎟️"
        case .eta: "🌙"
        case .theta: "🌸"
        case .sigma: "🏙️"
        case .omega: "🌓"
        }
    }

    var name: String {
        switch self {
        case .alpha: "Clear"
        case .beta: "Negative"
        case .gamma: "Digital"
        case .delta: "Flash"
        case .epsilon: "Instant"
        case .zeta: "Disposable"
        case .eta: "Night"
        case .theta: "Portrait"
        case .sigma: "Street"
        case .omega: "Mono"
        }
    }

    var subtitle: String {
        switch self {
        case .alpha: "Clean Modern"
        case .beta: "Color Negative"
        case .gamma: "Early Digital / CCD"
        case .delta: "Flash Compact"
        case .epsilon: "Instant"
        case .zeta: "Disposable"
        case .eta: "Night Digital"
        case .theta: "Portrait"
        case .sigma: "Street"
        case .omega: "Monochrome"
        }
    }

    var identityColor: Color {
        switch self {
        case .alpha: Color(red: 0.38, green: 0.45, blue: 0.50)
        case .beta: Color(red: 0.61, green: 0.39, blue: 0.29)
        case .gamma: Color(red: 0.19, green: 0.48, blue: 0.62)
        case .delta: Color(red: 0.69, green: 0.32, blue: 0.20)
        case .epsilon: Color(red: 0.67, green: 0.52, blue: 0.39)
        case .zeta: Color(red: 0.52, green: 0.50, blue: 0.25)
        case .eta: Color(red: 0.12, green: 0.38, blue: 0.48)
        case .theta: Color(red: 0.64, green: 0.43, blue: 0.45)
        case .sigma: Color(red: 0.34, green: 0.36, blue: 0.29)
        case .omega: Color(red: 0.28, green: 0.29, blue: 0.30)
        }
    }
}

/// The Camera rail contains one unprocessed reference option plus the ten
/// designed Camera Characters. Original deliberately is not a character.
nonisolated enum CameraSelection: Identifiable, Equatable, Sendable {
    case original
    case character(CameraCharacter)

    static let allCases: [CameraSelection] = [.original] + CameraCharacter.allCases.map(Self.character)

    var id: String {
        switch self {
        case .original: "original"
        case .character(let character): "character.\(character.rawValue)"
        }
    }

    var storageValue: String { id }

    init?(storageValue: String) {
        if storageValue == "original" {
            self = .original
        } else if storageValue.hasPrefix("character."),
                  let character = CameraCharacter(rawValue: String(storageValue.dropFirst("character.".count))) {
            self = .character(character)
        } else if let character = CameraCharacter(rawValue: storageValue) {
            // Compatibility with the former character-only preference.
            self = .character(character)
        } else {
            return nil
        }
    }

    var character: CameraCharacter? {
        guard case .character(let character) = self else { return nil }
        return character
    }

    var symbol: String {
        switch self {
        case .original: "📷"
        case .character(let character): character.symbol
        }
    }

    var name: String {
        switch self {
        case .original: "Original"
        case .character(let character): character.name
        }
    }

    var subtitle: String {
        switch self {
        case .original: "Unfiltered"
        case .character(let character): character.subtitle
        }
    }

    var identityColor: Color {
        switch self {
        case .original: Color(red: 0.54, green: 0.69, blue: 0.64)
        case .character(let character): character.identityColor
        }
    }
}

nonisolated enum GradeStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case pure = "Pure"
    case air = "Air"
    case glow = "Glow"
    case soft = "Soft"
    case rich = "Rich"
    case chrome = "Chrome"
    case fade = "Fade"
    case ember = "Ember"
    case blush = "Blush"
    case moss = "Moss"
    case tide = "Tide"
    case dusk = "Dusk"
    case cinema = "Cinema"
    case neon = "Neon"
    case silver = "Silver"
    case ink = "Ink"

    var id: Self { self }

    var tint: Color {
        switch self {
        case .pure: Color(white: 0.78)
        case .air: Color(red: 0.67, green: 0.83, blue: 0.92)
        case .glow: Color(red: 0.96, green: 0.75, blue: 0.48)
        case .soft: Color(red: 0.84, green: 0.75, blue: 0.82)
        case .rich: Color(red: 0.52, green: 0.22, blue: 0.26)
        case .chrome: Color(red: 0.22, green: 0.61, blue: 0.84)
        case .fade: Color(red: 0.68, green: 0.64, blue: 0.51)
        case .ember: Color(red: 0.92, green: 0.38, blue: 0.17)
        case .blush: Color(red: 0.94, green: 0.53, blue: 0.57)
        case .moss: Color(red: 0.42, green: 0.53, blue: 0.28)
        case .tide: Color(red: 0.10, green: 0.62, blue: 0.70)
        case .dusk: Color(red: 0.39, green: 0.33, blue: 0.68)
        case .cinema: Color(red: 0.18, green: 0.52, blue: 0.48)
        case .neon: Color(red: 0.78, green: 0.15, blue: 0.67)
        case .silver: Color(white: 0.66)
        case .ink: Color(white: 0.20)
        }
    }
}

nonisolated enum ActiveGradeSurface: Sendable {
    case style
    case accent
}

nonisolated enum CameraAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case standard = "4:3"
    case square = "1:1"
    case widescreen = "16:9"

    var id: Self { self }

    /// Width divided by height for a portrait camera viewport.
    var portraitRatio: CGFloat {
        switch self {
        case .standard: 3.0 / 4.0
        case .square: 1
        case .widescreen: 9.0 / 16.0
        }
    }
}

nonisolated enum CaptureTimerOption: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case three = "3s"
    case ten = "10s"

    var id: Self { self }

    var seconds: Int {
        switch self {
        case .off: 0
        case .three: 3
        case .ten: 10
        }
    }
}

nonisolated enum CaptureFlashMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto"
    case on = "On"
    case off = "Off"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .auto: "bolt.badge.a.fill"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }
}

nonisolated enum CaptureFormatOption: String, CaseIterable, Identifiable, Sendable {
    case processed = "HEIF"
    case raw = "RAW + JPEG"

    var id: Self { self }
}

nonisolated enum CaptureMotionOption: String, CaseIterable, Identifiable, Sendable {
    case photo = "Photo"
    case livePhoto = "Live Photo"

    var id: Self { self }
}

nonisolated struct CameraCharacterAdjustment: Equatable, Sendable {
    var point = CGPoint(x: 0.5, y: 0.5)

    static let centered = CameraCharacterAdjustment()
}

nonisolated struct EnhanceAdjustment: Equatable, Sendable {
    var isEnabled = false
    var exposureEV = 0.0
    var redGain = 1.0
    var greenGain = 1.0
    var blueGain = 1.0
    var highlightAmount = 1.0
    var shadowAmount = 0.0
    var contrast = 1.0

    static let neutral = EnhanceAdjustment()
}

nonisolated struct GradeSettings: Equatable, Sendable {
    var style: GradeStyle = .pure
    var stylePoint = CGPoint(x: 0.5, y: 0.5)
    var accentPoint = CGPoint(x: 0.5, y: 0.5)
    var styleStrength: Double = 0.78
    var accentStrength: Double = 0.52
    var accent = AccentColor.warmGray
    var enhance = EnhanceAdjustment.neutral
}

nonisolated struct AccentColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let warmGray = AccentColor(red: 0.55, green: 0.52, blue: 0.48)
    static let coolGray = AccentColor(red: 0.45, green: 0.50, blue: 0.55)

    var color: Color { Color(red: red, green: green, blue: blue) }
    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue) }
}
