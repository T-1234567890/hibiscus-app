import Combine
import Foundation

nonisolated enum DefaultCameraPreference: String, CaseIterable, Identifiable, Sendable {
    case lastUsed = "Last Used"
    case original = "Original"
    case clear = "Clear"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .lastUsed: "Last Used"
        case .original: "Original"
        case .clear: "Clear"
        }
    }
}

nonisolated enum DefaultLivePhotoPreference: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case on = "On"

    var id: Self { self }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var cameraGridEnabled: Bool { didSet { save(cameraGridEnabled, for: .cameraGridEnabled) } }
    @Published var defaultCamera: DefaultCameraPreference { didSet { save(defaultCamera.rawValue, for: .defaultCamera) } }
    @Published var defaultLivePhoto: DefaultLivePhotoPreference {
        didSet { save(defaultLivePhoto.rawValue, for: .defaultLivePhoto) }
    }
    @Published var defaultAspectRatio: CameraAspectRatio { didSet { save(defaultAspectRatio.rawValue, for: .defaultAspectRatio) } }
    @Published var autoSaveCaptures: Bool { didSet { save(autoSaveCaptures, for: .autoSaveCaptures) } }
    @Published var saveLocation: Bool {
        didSet {
            save(saveLocation, for: .saveLocation)
            CaptureLocationProvider.shared.setEnabled(saveLocation)
        }
    }
    @Published var rememberExposure: Bool {
        didSet {
            save(rememberExposure, for: .rememberExposure)
            if !rememberExposure { lastExposure = 0 }
        }
    }
    @Published var rememberLastStyle: Bool { didSet { save(rememberLastStyle, for: .rememberLastStyle) } }
    @Published var longPressToShowOriginal: Bool { didSet { save(longPressToShowOriginal, for: .longPressToShowOriginal) } }
    @Published var autoAccent: Bool { didSet { save(autoAccent, for: .autoAccent) } }
    @Published var resetEditsForNewPhoto: Bool { didSet { save(resetEditsForNewPhoto, for: .resetEditsForNewPhoto) } }
    @Published var experimentalEnhance: Bool { didSet { save(experimentalEnhance, for: .experimentalEnhance) } }
    @Published var preserveMetadata: Bool { didSet { save(preserveMetadata, for: .preserveMetadata) } }
    @Published var includeLocation: Bool { didSet { save(includeLocation, for: .includeLocation) } }
    @Published var polaroidMetadata: Bool { didSet { save(polaroidMetadata, for: .polaroidMetadata) } }
    @Published var hibiscusMark: Bool { didSet { save(hibiscusMark, for: .hibiscusMark) } }
    @Published var exploreMoreAfterExport: Bool {
        didSet {
            save(exploreMoreAfterExport, for: .exploreMoreAfterExport)
            if exploreMoreAfterExport, !oldValue {
                resetExploreMoreEligibility()
            }
        }
    }

    var lastCameraSelection: CameraSelection {
        didSet { save(lastCameraSelection.storageValue, for: .lastCameraSelection) }
    }
    var lastExposure: Double {
        didSet { save(lastExposure, for: .lastExposure) }
    }
    var lastFlashMode: CaptureFlashMode {
        didSet { save(lastFlashMode.rawValue, for: .lastFlashMode) }
    }
    var lastGradeStyle: GradeStyle {
        didSet { save(lastGradeStyle.rawValue, for: .lastGradeStyle) }
    }

    private let defaults: UserDefaults
    private var exploreMoreDismissedAt: Date?
    private var exploreMoreOpenedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cameraGridEnabled = defaults.object(forKey: Key.cameraGridEnabled.rawValue) as? Bool ?? true
        let storedDefaultCamera = defaults.string(forKey: Key.defaultCamera.rawValue)
        defaultCamera = storedDefaultCamera == "Alpha"
            ? .clear
            : DefaultCameraPreference(rawValue: storedDefaultCamera ?? "") ?? .original
        defaultLivePhoto = DefaultLivePhotoPreference(
            rawValue: defaults.string(forKey: Key.defaultLivePhoto.rawValue) ?? ""
        ) ?? .off
        defaultAspectRatio = CameraAspectRatio(
            rawValue: defaults.string(forKey: Key.defaultAspectRatio.rawValue) ?? ""
        ) ?? .standard
        autoSaveCaptures = defaults.object(forKey: Key.autoSaveCaptures.rawValue) as? Bool ?? true
        saveLocation = defaults.object(forKey: Key.saveLocation.rawValue) as? Bool ?? false
        rememberExposure = defaults.object(forKey: Key.rememberExposure.rawValue) as? Bool ?? false
        rememberLastStyle = defaults.object(forKey: Key.rememberLastStyle.rawValue) as? Bool ?? true
        longPressToShowOriginal = defaults.object(forKey: Key.longPressToShowOriginal.rawValue) as? Bool ?? true
        autoAccent = defaults.object(forKey: Key.autoAccent.rawValue) as? Bool ?? true
        resetEditsForNewPhoto = defaults.object(forKey: Key.resetEditsForNewPhoto.rawValue) as? Bool ?? true
        experimentalEnhance = defaults.object(forKey: Key.experimentalEnhance.rawValue) as? Bool ?? false
        preserveMetadata = defaults.object(forKey: Key.preserveMetadata.rawValue) as? Bool ?? true
        includeLocation = defaults.object(forKey: Key.includeLocation.rawValue) as? Bool ?? true
        polaroidMetadata = defaults.object(forKey: Key.polaroidMetadata.rawValue) as? Bool ?? false
        hibiscusMark = defaults.object(forKey: Key.hibiscusMark.rawValue) as? Bool ?? true
        exploreMoreAfterExport = defaults.object(forKey: Key.exploreMoreAfterExport.rawValue) as? Bool ?? true
        exploreMoreDismissedAt = defaults.object(forKey: Key.exploreMoreDismissedAt.rawValue) as? Date
        exploreMoreOpenedAt = defaults.object(forKey: Key.exploreMoreOpenedAt.rawValue) as? Date
        let formerCharacter = CameraCharacter(
            rawValue: defaults.string(forKey: Key.lastCameraCharacter.rawValue) ?? ""
        ) ?? .alpha
        lastCameraSelection = CameraSelection(
            storageValue: defaults.string(forKey: Key.lastCameraSelection.rawValue) ?? ""
        ) ?? .character(formerCharacter)
        lastExposure = defaults.object(forKey: Key.lastExposure.rawValue) as? Double ?? 0
        lastFlashMode = CaptureFlashMode(
            rawValue: defaults.string(forKey: Key.lastFlashMode.rawValue) ?? ""
        ) ?? .auto
        lastGradeStyle = GradeStyle(
            rawValue: defaults.string(forKey: Key.lastGradeStyle.rawValue) ?? ""
        ) ?? .pure
    }

    func shouldPresentExploreMoreAfterExport(at date: Date = Date()) -> Bool {
        guard exploreMoreAfterExport else { return false }
        if let dismissedAt = exploreMoreDismissedAt,
           date < dismissedAt.addingTimeInterval(7 * 24 * 60 * 60) {
            return false
        }
        if let openedAt = exploreMoreOpenedAt,
           date < openedAt.addingTimeInterval(20 * 24 * 60 * 60) {
            return false
        }
        return true
    }

    func recordExploreMoreDismissal(at date: Date = Date()) {
        exploreMoreDismissedAt = date
        save(date, for: .exploreMoreDismissedAt)
    }

    func recordExploreMoreEcosystemOpen(at date: Date = Date()) {
        exploreMoreOpenedAt = date
        exploreMoreDismissedAt = nil
        save(date, for: .exploreMoreOpenedAt)
        defaults.removeObject(forKey: Key.exploreMoreDismissedAt.rawValue)
    }

    private func resetExploreMoreEligibility() {
        exploreMoreDismissedAt = nil
        exploreMoreOpenedAt = nil
        defaults.removeObject(forKey: Key.exploreMoreDismissedAt.rawValue)
        defaults.removeObject(forKey: Key.exploreMoreOpenedAt.rawValue)
    }

    private func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private enum Key: String {
        case cameraGridEnabled = "settings.camera.grid"
        case defaultCamera = "settings.camera.defaultCharacter"
        case defaultLivePhoto = "settings.camera.defaultLivePhoto"
        case defaultAspectRatio = "settings.camera.defaultAspectRatio"
        case autoSaveCaptures = "settings.camera.autoSaveCaptures"
        case saveLocation = "settings.camera.saveLocation"
        case rememberExposure = "settings.camera.rememberExposure"
        case rememberLastStyle = "settings.grade.rememberLastStyle"
        case longPressToShowOriginal = "settings.grade.longPressToShowOriginal"
        case autoAccent = "settings.grade.autoAccent"
        case resetEditsForNewPhoto = "settings.grade.resetEditsForNewPhoto"
        case experimentalEnhance = "settings.grade.experimentalEnhance"
        case preserveMetadata = "settings.export.preserveMetadata"
        case includeLocation = "settings.export.includeLocation"
        case polaroidMetadata = "settings.export.polaroidMetadata"
        case hibiscusMark = "settings.export.hibiscusMark"
        case exploreMoreAfterExport = "settings.discovery.exploreMoreAfterExport"
        case exploreMoreDismissedAt = "state.discovery.exploreMoreDismissedAt"
        case exploreMoreOpenedAt = "state.discovery.exploreMoreOpenedAt"
        case lastCameraCharacter = "state.camera.lastCharacter"
        case lastCameraSelection = "state.camera.lastSelection"
        case lastExposure = "state.camera.lastExposure"
        case lastFlashMode = "state.camera.flashMode"
        case lastGradeStyle = "state.grade.lastStyle"
    }
}
