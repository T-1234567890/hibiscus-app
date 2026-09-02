@preconcurrency import AVFoundation
import Combine
import CoreImage
import Photos
import SwiftUI
import UIKit

enum CameraAuthorizationState {
    case unknown
    case authorized
    case denied
    case unavailable
}

nonisolated struct CameraLensOption: Identifiable, Equatable, Sendable {
    let factor: Double
    let label: String

    var id: String { label }
}

nonisolated private struct CameraLensTarget {
    let displayFactor: CGFloat
    let device: AVCaptureDevice
    let deviceZoomFactor: CGFloat
}

@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var capturedPreviewImage: UIImage?
    @Published private(set) var capturedLivePhoto: ProcessedLivePhoto?
    @Published private(set) var capturedDate: Date?
    @Published private(set) var authorizationState: CameraAuthorizationState = .unknown
    @Published private(set) var isRunning = false
    @Published private(set) var flashAvailable = false
    @Published var flashMode: CaptureFlashMode = .auto {
        didSet { preferences.lastFlashMode = flashMode }
    }
    @Published private(set) var lensLabel = "1×"
    @Published private(set) var lensOptions = [CameraLensOption(factor: 1, label: "1×")]
    @Published private(set) var exposure: Double = 0
    @Published private(set) var characterPoint = CGPoint(x: 0.5, y: 0.5)
    @Published private(set) var isSwitchingCamera = false
    @Published var selectedCamera: CameraSelection = .character(.alpha) {
        didSet {
            if let oldCharacter = oldValue.character {
                characterAdjustments[oldCharacter] = CameraCharacterAdjustment(point: characterPoint)
            }
            let character = selectedCamera.character
            let adjustment = character.flatMap { characterAdjustments[$0] } ?? .centered
            characterPoint = adjustment.point
            renderCharacter = character
            renderCharacterAdjustment = adjustment
#if DEBUG && targetEnvironment(simulator)
            refreshSimulatorDemoPreview()
#endif
            if !isApplyingSessionDefaults {
                preferences.lastCameraSelection = selectedCamera
            }
        }
    }
    @Published var selectedRatio: CameraAspectRatio = .standard {
        didSet { captureAspectRatio = selectedRatio.portraitRatio }
    }
    @Published var selectedTimer: CaptureTimerOption = .off
    @Published var selectedMotion: CaptureMotionOption = .photo
    @Published private(set) var isLivePhotoAvailable = false
    @Published private(set) var isConfiguringLivePhoto = false
    @Published private(set) var availableMegapixels: [Int] = [12]
    @Published private(set) var availableRawMegapixels: [Int] = []
    @Published private(set) var selectedMegapixels = 12
    @Published var selectedFormat: CaptureFormatOption = .processed {
        didSet { captureFormat = selectedFormat }
    }
    @Published private(set) var isRAWAvailable = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecordingLivePhoto = false
    @Published private(set) var isProcessingCapture = false
    @Published private(set) var isSavingCapture = false
    @Published private(set) var didAutoSaveCapture = false
    @Published private(set) var countdown: Int?
    @Published var statusMessage: String?

    nonisolated let previewRenderer = CameraPreviewRenderer()
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated private let sessionQueue = DispatchQueue(label: "dev.hibiscus.camera-session", qos: .userInitiated)
    nonisolated private let videoQueue = DispatchQueue(label: "dev.hibiscus.camera-preview", qos: .userInteractive)
    nonisolated private let photoProcessingQueue = DispatchQueue(label: "dev.hibiscus.camera-processing", qos: .userInitiated)
    nonisolated(unsafe) private var cameraInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var audioInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var position: AVCaptureDevice.Position = .back
    nonisolated(unsafe) private var lensFactors: [CGFloat] = [1]
    nonisolated(unsafe) private var lensIndex = 0
    nonisolated(unsafe) private var renderCharacter: CameraCharacter? = .alpha
    nonisolated(unsafe) private var renderCharacterAdjustment = CameraCharacterAdjustment.centered
    nonisolated(unsafe) private var captureAspectRatio: CGFloat = CameraAspectRatio.standard.portraitRatio
    nonisolated(unsafe) private var captureFormat: CaptureFormatOption = .processed
    nonisolated private let resolutionLock = NSLock()
    nonisolated(unsafe) private var supportedPhotoDimensions: [CMVideoDimensions] = []
    nonisolated(unsafe) private var capturePhotoDimensions = CMVideoDimensions(width: 0, height: 0)
    nonisolated(unsafe) private var captureTargetMegapixels = 12
    nonisolated(unsafe) private var requestedPhotoMegapixels: Int?
    nonisolated(unsafe) private var pendingProcessedImage: UIImage?
    nonisolated(unsafe) private var pendingPreviewImage: UIImage?
    nonisolated(unsafe) private var pendingRawData: Data?
    nonisolated(unsafe) private var pendingLivePhotoData: Data?
    nonisolated(unsafe) private var pendingLivePhotoMovieURL: URL?
    nonisolated(unsafe) private var captureUsesLivePhoto = false
    nonisolated(unsafe) private var captureCharacter: CameraCharacter? = .alpha
    nonisolated(unsafe) private var captureCharacterAdjustment = CameraCharacterAdjustment.centered
    nonisolated(unsafe) private var captureLiveAspectRatio = CameraAspectRatio.standard.portraitRatio
    nonisolated(unsafe) private var captureLiveTargetMegapixels = 12
    nonisolated(unsafe) private var captureProcessingToken = UUID()
    nonisolated(unsafe) private var acceptsPreviewFrames = true
    nonisolated(unsafe) private var pendingCameraSwitchToken: UUID?
    nonisolated(unsafe) private var currentPreviewRotationAngle: CGFloat = 90
    private var previewLayer: CALayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var timerTask: Task<Void, Never>?
    private var cameraSwitchRecoveryTask: Task<Void, Never>?
    private let preferences: AppPreferences
    private var isApplyingSessionDefaults = false
    private var shouldApplyDefaultMotionOnStart = false
    private var didAttemptAutoSaveForCapture = false
    private var characterAdjustments: [CameraCharacter: CameraCharacterAdjustment] = [:]
#if DEBUG && targetEnvironment(simulator)
    nonisolated(unsafe) private var isSimulatorDemoCameraEnabled = false
    private var simulatorDemoSourceImage: UIImage?
#endif

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init()
        isApplyingSessionDefaults = true
        let initialCamera = Self.cameraSelection(
            for: preferences.defaultCamera,
            lastUsed: preferences.lastCameraSelection
        )
        selectedCamera = initialCamera
        renderCharacter = initialCamera.character
        renderCharacterAdjustment = .centered
        selectedRatio = preferences.defaultAspectRatio
        captureAspectRatio = preferences.defaultAspectRatio.portraitRatio
        flashMode = preferences.lastFlashMode
        exposure = preferences.rememberExposure ? preferences.lastExposure : 0
        isApplyingSessionDefaults = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorizationState = .authorized
        case .denied, .restricted: authorizationState = .denied
        case .notDetermined: authorizationState = .unknown
        @unknown default: authorizationState = .denied
        }
    }

    private static func cameraSelection(
        for preference: DefaultCameraPreference,
        lastUsed: CameraSelection
    ) -> CameraSelection {
        switch preference {
        case .lastUsed:
            lastUsed
        case .original:
            .original
        case .clear:
            .character(.alpha)
        }
    }

#if DEBUG && targetEnvironment(simulator)
    func configureSimulatorDemoCamera(enabled: Bool, image: UIImage?) {
        let wasEnabled = isSimulatorDemoCameraEnabled
        isSimulatorDemoCameraEnabled = enabled
        simulatorDemoSourceImage = image

        if enabled {
            authorizationState = .authorized
            flashAvailable = true
            lensOptions = [
                CameraLensOption(factor: 0.5, label: "0.5×"),
                CameraLensOption(factor: 1, label: "1×"),
                CameraLensOption(factor: 2, label: "2×"),
                CameraLensOption(factor: 4, label: "4×"),
                CameraLensOption(factor: 8, label: "8×")
            ]
            if !lensOptions.contains(where: { $0.label == lensLabel }) {
                lensLabel = "1×"
            }
            availableMegapixels = [12, 24, 48]
            availableRawMegapixels = []
            isRAWAvailable = false
            selectedFormat = .processed
            if !availableMegapixels.contains(selectedMegapixels) {
                selectedMegapixels = 24
            }
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
            if isRunning || wasEnabled {
                startSimulatorDemoCamera()
            }
        } else if wasEnabled {
            previewRenderer.clear()
            isRunning = false
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorizationState = .authorized
            case .denied, .restricted: authorizationState = .denied
            case .notDetermined: authorizationState = .unknown
            @unknown default: authorizationState = .denied
            }
        }
    }
#endif

    func start() {
        previewRenderer.resume()
        shouldApplyDefaultMotionOnStart = true
        isApplyingSessionDefaults = true
        selectedCamera = Self.cameraSelection(
            for: preferences.defaultCamera,
            lastUsed: preferences.lastCameraSelection
        )
        selectedRatio = preferences.defaultAspectRatio
        isApplyingSessionDefaults = false
        capturedImage = nil
        capturedPreviewImage = nil
        capturedLivePhoto?.cleanUp()
        capturedLivePhoto = nil
        capturedDate = nil
        isSavingCapture = false
        didAutoSaveCapture = false
        didAttemptAutoSaveForCapture = false
        if cameraInput != nil {
            setExposure(preferences.rememberExposure ? preferences.lastExposure : 0)
        } else if !preferences.rememberExposure {
            exposure = 0
        }
#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            startSimulatorDemoCamera()
            return
        }
#endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorizationState = .authorized
        case .denied, .restricted: authorizationState = .denied
        case .notDetermined: authorizationState = .unknown
        @unknown default: authorizationState = .denied
        }
        switch authorizationState {
        case .authorized:
            configureAndStartIfNeeded()
        case .unknown:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let service = self else { return }
                Task { @MainActor in
                    service.authorizationState = granted ? .authorized : .denied
                    if granted { service.configureAndStartIfNeeded() }
                }
            }
        case .denied, .unavailable:
            break
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        cameraSwitchRecoveryTask?.cancel()
        cameraSwitchRecoveryTask = nil
        isSwitchingCamera = false
        countdown = nil
        previewRenderer.clear()
#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            isRunning = false
            return
        }
#endif
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in self.isRunning = false }
        }
    }

    func capture() {
        guard isRunning, countdown == nil, !isCapturing, !isConfiguringLivePhoto else { return }
        let seconds = selectedTimer.seconds
        guard seconds > 0 else {
            captureNow()
            return
        }
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                countdown = remaining
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            countdown = nil
            captureNow()
        }
    }

    private func captureNow() {
        let recordsLivePhoto = selectedMotion == .livePhoto
            && captureFormat == .processed
            && photoOutput.isLivePhotoCaptureEnabled
        // A still freezes at shutter time. A Live Photo must keep presenting fresh
        // preview frames until AVFoundation reports that motion recording ended.
        if recordsLivePhoto {
            isRecordingLivePhoto = true
            previewRenderer.resume()
        } else {
            isRecordingLivePhoto = false
            previewRenderer.freeze()
        }
        isCapturing = true
        isProcessingCapture = true
        capturedDate = Date()
        pendingProcessedImage = nil
        pendingPreviewImage = nil
        pendingRawData = nil
        pendingLivePhotoData = nil
        if let pendingLivePhotoMovieURL { try? FileManager.default.removeItem(at: pendingLivePhotoMovieURL) }
        pendingLivePhotoMovieURL = nil
        captureUsesLivePhoto = recordsLivePhoto
        captureProcessingToken = UUID()
        isSavingCapture = false
        didAutoSaveCapture = false
        didAttemptAutoSaveForCapture = false

#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            captureSimulatorDemoPhoto()
            return
        }
#endif

        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let processedFormat: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let preferredRawType = rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) ?? rawTypes.first
        if captureFormat == .raw, let rawType = preferredRawType {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processedFormat)
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(rawType) {
                // Full-sensor RAW requires the physical lens at its native zoom.
                // AVFoundation requires speed prioritization for Bayer RAW.
                settings.photoQualityPrioritization = .speed
                if let device = cameraInput?.device, device.videoZoomFactor != 1 {
                    do {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = 1
                        device.unlockForConfiguration()
                    } catch { }
                }
            } else {
                settings.photoQualityPrioritization = .quality
            }
        } else {
            settings = AVCapturePhotoSettings(format: processedFormat)
            settings.photoQualityPrioritization = .quality
        }
        captureCharacter = renderCharacter
        captureCharacterAdjustment = renderCharacterAdjustment
        captureLiveAspectRatio = captureAspectRatio
        captureLiveTargetMegapixels = selectedTargetMegapixels()
        if captureUsesLivePhoto {
            let movieURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Hibiscus-Live-Capture-\(UUID().uuidString).mov")
            pendingLivePhotoMovieURL = movieURL
            settings.livePhotoMovieFileURL = movieURL
        }
        let photoDimensions = selectedPhotoDimensions()
        if photoDimensions.width > 0, photoDimensions.height > 0 {
            settings.maxPhotoDimensions = photoDimensions
        }
        if flashAvailable {
            settings.flashMode = switch flashMode {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        }
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(captureAngle) {
            connection.videoRotationAngle = captureAngle
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    func retake() {
        if let capturedPreviewImage,
           let heldImage = ImageRenderer.sourceCIImage(capturedPreviewImage) {
            previewRenderer.hold(heldImage)
        } else {
            previewRenderer.freeze()
        }
        let resumeToken = UUID()
        videoQueue.sync {
            acceptsPreviewFrames = false
            pendingCameraSwitchToken = resumeToken
        }
        isSwitchingCamera = true
        cameraSwitchRecoveryTask?.cancel()
        cameraSwitchRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recoverCameraSwitchIfNeeded(token: resumeToken)
        }
        capturedImage = nil
        capturedPreviewImage = nil
        capturedLivePhoto?.cleanUp()
        capturedLivePhoto = nil
        capturedDate = nil
        pendingProcessedImage = nil
        pendingPreviewImage = nil
        pendingRawData = nil
        pendingLivePhotoData = nil
        if let pendingLivePhotoMovieURL { try? FileManager.default.removeItem(at: pendingLivePhotoMovieURL) }
        pendingLivePhotoMovieURL = nil
        captureUsesLivePhoto = false
        isRecordingLivePhoto = false
        isProcessingCapture = false
        isSavingCapture = false
        didAutoSaveCapture = false
        didAttemptAutoSaveForCapture = false
        captureProcessingToken = UUID()
        statusMessage = nil
#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            isSwitchingCamera = false
            videoQueue.async { [weak self] in
                self?.pendingCameraSwitchToken = nil
                self?.acceptsPreviewFrames = true
            }
            startSimulatorDemoCamera()
            return
        }
#endif
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let device = self.cameraInput?.device {
                self.configureVideoConnectionFallback(for: device)
            }
            self.startSessionOnlyFromQueue()
        }
    }

    func switchCamera() {
        guard capturedImage == nil, !isSwitchingCamera else { return }
#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            position = position == .back ? .front : .back
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
#endif
        previewRenderer.freeze()
        isSwitchingCamera = true
        let switchToken = UUID()
        cameraSwitchRecoveryTask?.cancel()
        cameraSwitchRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recoverCameraSwitchIfNeeded(token: switchToken)
        }
        position = position == .back ? .front : .back
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.acceptsPreviewFrames = false
            self.pendingCameraSwitchToken = switchToken
            self.sessionQueue.async { [weak self] in
                self?.replaceCameraInput(switchToken: switchToken)
            }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func updateCharacterPoint(_ point: CGPoint) {
        guard let selectedCharacter = selectedCamera.character else { return }
        let bounded = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        guard characterPoint != bounded else { return }
        characterPoint = bounded
        let adjustment = CameraCharacterAdjustment(point: bounded)
        characterAdjustments[selectedCharacter] = adjustment
        renderCharacterAdjustment = adjustment
#if DEBUG && targetEnvironment(simulator)
        refreshSimulatorDemoPreview()
#endif
    }

    func resetCharacterPoint() {
        updateCharacterPoint(CGPoint(x: 0.5, y: 0.5))
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func selectLens(_ option: CameraLensOption) {
#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            lensLabel = option.label
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
#endif
        if position == .back {
            lensLabel = option.label
            sessionQueue.async { [weak self] in
                self?.selectRearLens(displayFactor: CGFloat(option.factor))
            }
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        guard let device = cameraInput?.device,
              let factor = lensFactors.min(by: {
                  abs(Double($0) - option.factor) < abs(Double($1) - option.factor)
              }) else { return }
        setDeviceZoom(factor, on: device)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func selectNextLens() {
        guard !lensOptions.isEmpty else { return }
        let currentIndex = lensOptions.firstIndex(where: { $0.label == lensLabel }) ?? 0
        selectLens(lensOptions[(currentIndex + 1) % lensOptions.count])
    }

    func setExposure(_ value: Double) {
#if DEBUG && targetEnvironment(simulator)
        if isSimulatorDemoCameraEnabled {
            exposure = min(2, max(-2, value))
            if preferences.rememberExposure { preferences.lastExposure = exposure }
            refreshSimulatorDemoPreview()
            return
        }
#endif
        guard let device = cameraInput?.device else { return }
        let maximum = min(2, Double(device.maxExposureTargetBias))
        let minimum = max(-2, Double(device.minExposureTargetBias))
        exposure = min(maximum, max(minimum, value))
        if preferences.rememberExposure { preferences.lastExposure = exposure }
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(Float(exposure))
            device.unlockForConfiguration()
        } catch {
            statusMessage = L10n.string("Exposure adjustment isn’t available.")
        }
    }

    func attachPreviewLayer(_ layer: CALayer) {
        let layerChanged = previewLayer !== layer
        previewLayer = layer
        if let device = cameraInput?.device,
           layerChanged || pendingCameraSwitchToken != nil {
            configureRotationCoordinator(
                for: device,
                switchToken: pendingCameraSwitchToken
            )
        }
    }

    func selectCapture(format: CaptureFormatOption, megapixels: Int) {
        guard format == .processed || isRAWAvailable else { return }
        resolutionLock.lock()
        let hasNativeTarget = supportedPhotoDimensions.contains {
            Self.megapixels(for: $0) == megapixels
        }
        let selected: CMVideoDimensions?
        if format == .processed, megapixels == 24, !hasNativeTarget {
            // Some devices expose 12 MP and 48 MP capture dimensions but no
            // native 24 MP request. Capture the smallest valid higher source
            // and let the existing final renderer produce the 24 MP result.
            selected = supportedPhotoDimensions.first {
                Self.megapixels(for: $0) > megapixels
            }
        } else {
            selected = supportedPhotoDimensions.min {
                abs(Self.megapixels(for: $0) - megapixels) < abs(Self.megapixels(for: $1) - megapixels)
            }
        }
        if let selected { capturePhotoDimensions = selected }
        captureTargetMegapixels = megapixels
        requestedPhotoMegapixels = megapixels
        resolutionLock.unlock()
        selectedFormat = format
        selectedMegapixels = megapixels
        if format == .raw { selectedMotion = .photo }
#if DEBUG
        sessionQueue.async { [weak self] in
            self?.debugLogCameraConfiguration(context: "resolution selected")
        }
#endif
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func selectMotion(_ option: CaptureMotionOption) {
        guard selectedFormat == .processed || option == .photo else { return }
        guard !isConfiguringLivePhoto else { return }
        if option == .photo {
            selectedMotion = .photo
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        if isLivePhotoAvailable {
            selectedMotion = .livePhoto
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        prepareLivePhotoCapture()
    }

    func toggleLivePhoto() {
        selectMotion(selectedMotion == .livePhoto ? .photo : .livePhoto)
    }

    private func prepareLivePhotoCapture() {
        isConfiguringLivePhoto = true
        statusMessage = nil
        previewRenderer.freeze()
        let service = self
        let finishAuthorization: @Sendable (Bool) -> Void = { granted in
            Task { @MainActor in
                guard granted else {
                    service.isConfiguringLivePhoto = false
                    service.previewRenderer.resume()
                    service.selectedMotion = .photo
                    service.statusMessage = L10n.string("Microphone access is required for Live Photos.")
                    return
                }
                service.sessionQueue.async { [weak service] in
                    service?.configureLivePhotoPipeline()
                }
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            finishAuthorization(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: finishAuthorization)
        case .denied, .restricted:
            finishAuthorization(false)
        @unknown default:
            finishAuthorization(false)
        }
    }

    func saveCapture() {
        saveCapture(automatic: false)
    }

    private func saveCapture(automatic: Bool) {
        guard !isSavingCapture else { return }
        isSavingCapture = true
        if let capturedLivePhoto {
            LivePhotoLibrarySaver.save([capturedLivePhoto], cleanUpAfterSave: false) { [weak self] success in
                guard let self else { return }
                self.finishCaptureSave(
                    success: success,
                    automatic: automatic,
                    successMessage: L10n.string("Saved Live Photo"),
                    failureMessage: L10n.string("Couldn’t save this Live Photo.")
                )
            }
            return
        }
        guard let capturedImage else {
            isSavingCapture = false
            return
        }
        let rawData = pendingRawData
        let processedData = capturedImage.jpegData(compressionQuality: 0.98)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let service = self else { return }
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    service.isSavingCapture = false
                    service.didAutoSaveCapture = false
                    service.statusMessage = L10n.string("Allow photo access in Settings to save.")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                if let rawData, let processedData {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: processedData, options: nil)
                    request.addResource(with: .alternatePhoto, data: rawData, options: nil)
                } else {
                    PHAssetChangeRequest.creationRequestForAsset(from: capturedImage)
                }
            } completionHandler: { success, _ in
                Task { @MainActor in
                    service.finishCaptureSave(
                        success: success,
                        automatic: automatic,
                        successMessage: L10n.string("Saved to Photos"),
                        failureMessage: L10n.string("Couldn’t save this photo.")
                    )
                }
            }
        }
    }

    private func finishCaptureSave(
        success: Bool,
        automatic: Bool,
        successMessage: String,
        failureMessage: String
    ) {
        isSavingCapture = false
        didAutoSaveCapture = automatic && success
        statusMessage = success
            ? (automatic ? L10n.string("Saved") : successMessage)
            : failureMessage
        if success { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func autoSaveCaptureIfReady(token: UUID) {
        guard preferences.autoSaveCaptures,
              captureProcessingToken == token,
              !didAttemptAutoSaveForCapture,
              !isProcessingCapture,
              capturedImage != nil,
              !captureUsesLivePhoto || capturedLivePhoto != nil else { return }
        didAttemptAutoSaveForCapture = true
        saveCapture(automatic: true)
    }

    func takeCapturedLivePhotoSource() -> LivePhotoSource? {
        guard let capturedLivePhoto else { return nil }
        self.capturedLivePhoto = nil
        return LivePhotoSource(
            directoryURL: capturedLivePhoto.directoryURL,
            stillURL: capturedLivePhoto.stillURL,
            motionURL: capturedLivePhoto.motionURL,
            assetIdentifier: nil
        )
    }

#if DEBUG && targetEnvironment(simulator)
    private func startSimulatorDemoCamera() {
        guard isSimulatorDemoCameraEnabled else { return }
        authorizationState = .authorized
        isRunning = simulatorDemoSourceImage != nil
        statusMessage = simulatorDemoSourceImage == nil
            ? "No Simulator demo photo is available."
            : nil
        refreshSimulatorDemoPreview()
    }

    private func refreshSimulatorDemoPreview() {
        guard isSimulatorDemoCameraEnabled,
              !isCapturing,
              let sourceImage = simulatorDemoSourceImage,
              var source = ImageRenderer.sourceCIImage(sourceImage) else { return }
        if exposure != 0 {
            source = source.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: exposure
            ])
        }
        previewRenderer.resume()
        previewRenderer.submit(
            source,
            character: selectedCamera.character,
            adjustment: CameraCharacterAdjustment(point: characterPoint)
        )
    }

    private func captureSimulatorDemoPhoto() {
        guard let sourceImage = simulatorDemoSourceImage else {
            isCapturing = false
            isProcessingCapture = false
            previewRenderer.resume()
            statusMessage = "No Simulator demo photo is available."
            return
        }

        let character = selectedCamera.character
        let aspectRatio = captureAspectRatio
        let targetMegapixels = selectedMegapixels
        let inputExposureEV = exposure
        let adjustment = CameraCharacterAdjustment(point: characterPoint)
        let token = captureProcessingToken
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)

        photoProcessingQueue.async { [weak self] in
            let preview = autoreleasepool {
                ImageRenderer.cameraImage(
                    sourceImage,
                    character: character,
                    adjustment: adjustment,
                    aspectRatio: aspectRatio,
                    targetMegapixels: min(2, targetMegapixels),
                    inputExposureEV: inputExposureEV
                ) ?? sourceImage
            }
            Task { @MainActor [weak self] in
                guard let self, self.captureProcessingToken == token else { return }
                self.pendingPreviewImage = preview
                self.pendingProcessedImage = preview
                self.capturedPreviewImage = preview
                self.capturedImage = preview
                self.isCapturing = false
                self.isRunning = false
            }

            let processed = autoreleasepool {
                ImageRenderer.cameraImage(
                    sourceImage,
                    character: character,
                    adjustment: adjustment,
                    aspectRatio: aspectRatio,
                    targetMegapixels: targetMegapixels,
                    inputExposureEV: inputExposureEV
                ) ?? sourceImage
            }
            Task { @MainActor [weak self] in
                guard let self, self.captureProcessingToken == token else { return }
                self.pendingProcessedImage = processed
                self.capturedImage = processed
                self.capturedPreviewImage = processed
                self.isProcessingCapture = false
                self.autoSaveCaptureIfReady(token: token)
            }
        }
    }
#endif

    private func configureAndStartIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG && targetEnvironment(simulator)
            guard !self.isSimulatorDemoCameraEnabled else { return }
#endif
            if self.cameraInput == nil { self.configureSession() }
            if let device = self.cameraInput?.device {
                Task { @MainActor in self.configureRotationCoordinator(for: device) }
            }
            self.refreshRAWAvailability()
            self.startSessionOnlyFromQueue()
            Task { @MainActor in
                self.applyDefaultMotionIfNeeded()
            }
        }
    }

    private func applyDefaultMotionIfNeeded() {
        guard shouldApplyDefaultMotionOnStart else { return }
        shouldApplyDefaultMotionOnStart = false
        switch preferences.defaultLivePhoto {
        case .off:
            if selectedMotion == .livePhoto {
                selectMotion(.photo)
            } else {
                selectedMotion = .photo
            }
        case .on:
            selectMotion(.livePhoto)
        }
    }

    nonisolated private func configureSession() {
        session.beginConfiguration()
        guard session.canSetSessionPreset(.photo) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.authorizationState = .unavailable
                self.statusMessage = L10n.string("Hibiscus couldn’t start the camera.")
            }
            return
        }
        session.sessionPreset = .photo
        var didConfigureSession = false
        defer {
            session.commitConfiguration()
            if didConfigureSession {
                refreshRAWAvailability()
                reevaluateLivePhotoCompatibility()
#if DEBUG
                debugLogCameraConfiguration(context: "initial configuration")
#endif
            }
        }

        guard let device = preferredDevice(position: position) else {
            Task { @MainActor in self.authorizationState = .unavailable }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            cameraInput = input

            videoOutput.alwaysDiscardsLateVideoFrames = true
            // The .photo preset otherwise allows AVFoundation to hand the data
            // output a deliberately small proxy buffer. Hibiscus renders that
            // buffer directly, so request the active format's full video stream
            // and let Core Image scale it to the Metal drawable instead.
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            let preferredPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoOutput.availableVideoPixelFormatTypes.contains(preferredPixelFormat) {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: preferredPixelFormat
                ]
            }
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
                enableAppleProRAWIfSupported()
                updatePhotoResolutionCapabilities(for: device)
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                _ = addAudioInputDuringConfiguration()
            }

            configureVideoConnectionFallback(for: device)
            updateDeviceState(device)
            didConfigureSession = true
        } catch {
            Task { @MainActor in
                self.authorizationState = .unavailable
                self.statusMessage = L10n.string("Hibiscus couldn’t start the camera.")
            }
        }
    }

    nonisolated private func replaceCameraInput(switchToken: UUID? = nil) {
        guard let device = preferredDevice(position: position) else {
            finishCameraSwitchFailure(token: switchToken)
            Task { @MainActor in
                self.statusMessage = L10n.string("Couldn’t switch cameras.")
            }
            return
        }
        replaceCameraInput(with: device, switchToken: switchToken)
    }

    nonisolated private func replaceCameraInput(
        with device: AVCaptureDevice,
        requestedZoomFactor: CGFloat? = nil,
        requestedDisplayFactor: CGFloat? = nil,
        switchToken: UUID? = nil
    ) {
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        session.beginConfiguration()
        let hasCompatiblePreset = session.canSetSessionPreset(.photo)
        if hasCompatiblePreset {
            session.sessionPreset = .photo
        }
        // Disable the old device's capability before replacing its input. The
        // final configuration is reevaluated and enabled again after commit.
        photoOutput.isLivePhotoCaptureEnabled = false
        photoOutput.isLivePhotoAutoTrimmingEnabled = false
        if let cameraInput { session.removeInput(cameraInput) }
        var didReplaceInput = false
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                cameraInput = newInput
                didReplaceInput = true
                enableAppleProRAWIfSupported()
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    _ = addAudioInputDuringConfiguration()
                }
                updatePhotoResolutionCapabilities(for: device)
                configureVideoConnectionFallback(for: device)
                updateDeviceState(
                    device,
                    requestedZoomFactor: requestedZoomFactor,
                    requestedDisplayFactor: requestedDisplayFactor
                )
            }
        } catch {
            Task { @MainActor in self.statusMessage = L10n.string("Couldn’t switch cameras.")
            }
        }
        session.commitConfiguration()
        guard didReplaceInput else {
            finishCameraSwitchFailure(token: switchToken)
            return
        }
        refreshRAWAvailability()
        reevaluateLivePhotoCompatibility(allowingCapture: hasCompatiblePreset)
#if DEBUG
        debugLogCameraConfiguration(context: "camera input replaced")
#endif
        if wasRunning { session.startRunning() }
        Task { @MainActor in
            self.configureRotationCoordinator(for: device, switchToken: switchToken)
            self.isRunning = self.session.isRunning
        }
    }

    nonisolated private func refreshRAWAvailability() {
        enableAppleProRAWIfSupported()
        let rawAvailable = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let rawMegapixels = rawAvailable ? supportedRAWPhotoMegapixels() : []
        Task { @MainActor in
#if DEBUG && targetEnvironment(simulator)
            guard !self.isSimulatorDemoCameraEnabled else { return }
#endif
            self.isRAWAvailable = rawAvailable
            self.availableRawMegapixels = rawMegapixels
            if !rawAvailable { self.selectedFormat = .processed }
        }
    }

    @discardableResult
    nonisolated private func reevaluateLivePhotoCompatibility(
        allowingCapture: Bool = true
    ) -> Bool {
        let available = allowingCapture
            && audioInput != nil
            && photoOutput.isLivePhotoCaptureSupported
        if photoOutput.isLivePhotoCaptureEnabled != available {
            photoOutput.isLivePhotoCaptureEnabled = available
        }
        photoOutput.isLivePhotoAutoTrimmingEnabled = available
        Task { @MainActor in
#if DEBUG && targetEnvironment(simulator)
            guard !self.isSimulatorDemoCameraEnabled else { return }
#endif
            self.isLivePhotoAvailable = available
            if !available { self.selectedMotion = .photo }
        }
        return available
    }

    nonisolated private func addAudioInputDuringConfiguration() -> Bool {
        if audioInput != nil { return true }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        audioInput = input
        return true
    }

    nonisolated private func configureLivePhotoPipeline() {
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }

        session.beginConfiguration()
        photoOutput.isLivePhotoCaptureEnabled = false
        photoOutput.isLivePhotoAutoTrimmingEnabled = false
        let hasAudio = addAudioInputDuringConfiguration()
        let hasCompatiblePreset = session.canSetSessionPreset(.photo)
        if hasCompatiblePreset {
            session.sessionPreset = .photo
        }
        if let device = cameraInput?.device {
            updatePhotoResolutionCapabilities(for: device)
        }
        session.commitConfiguration()

        refreshRAWAvailability()
        let available = reevaluateLivePhotoCompatibility(
            allowingCapture: hasAudio && hasCompatiblePreset
        )
#if DEBUG
        debugLogCameraConfiguration(context: "Live Photo configuration")
#endif
        if wasRunning { session.startRunning() }

        Task { @MainActor in
            self.isRunning = self.session.isRunning
            self.isLivePhotoAvailable = available
            self.isConfiguringLivePhoto = false
            self.previewRenderer.resume()
            self.selectedMotion = available ? .livePhoto : .photo
            if available {
                self.statusMessage = nil
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                self.statusMessage = L10n.string("Live Photo isn’t available with the current camera configuration.")
            }
        }
    }

    nonisolated private func enableAppleProRAWIfSupported() {
        if photoOutput.isAppleProRAWSupported && !photoOutput.isAppleProRAWEnabled {
            photoOutput.isAppleProRAWEnabled = true
        }
    }

    /// Discovers still resolutions from the format selected by AVFoundation's
    /// `.photo` preset. Resolution changes only update photo-output/settings
    /// dimensions; they never take ownership of `device.activeFormat`.
    nonisolated private func updatePhotoResolutionCapabilities(for device: AVCaptureDevice) {
        let supported = device.activeFormat.supportedMaxPhotoDimensions.sorted(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        })
        guard let maximum = supported.last else { return }
        photoOutput.maxPhotoDimensions = maximum

        var distinct: [CMVideoDimensions] = []
        for dimensions in supported where !distinct.contains(where: {
            Self.megapixels(for: $0) == Self.megapixels(for: dimensions)
        }) {
            distinct.append(dimensions)
        }
        if distinct.isEmpty { distinct = [maximum] }
        var values = Array(Set(distinct.map(Self.megapixels(for:)).filter { $0 > 0 })).sorted()
        if values.isEmpty { values = [Self.megapixels(for: maximum)] }
        // Hibiscus can produce a true 24 MP processed output from a larger
        // supported source without assigning an unsupported capture dimension.
        // Keep RAW choices limited to dimensions the active format reports.
        if values.contains(where: { $0 > 24 }), !values.contains(24) {
            values.append(24)
            values.sort()
        }

        resolutionLock.lock()
        let requestedMegapixels = requestedPhotoMegapixels
        resolutionLock.unlock()
        let preferredMegapixels: Int
        if let requestedMegapixels, values.contains(requestedMegapixels) {
            preferredMegapixels = requestedMegapixels
        } else if values.contains(24) {
            preferredMegapixels = 24
        } else if values.contains(12) {
            preferredMegapixels = 12
        } else {
            preferredMegapixels = values[0]
        }
        let hasNativePreferred = distinct.contains {
            Self.megapixels(for: $0) == preferredMegapixels
        }
        let preferred: CMVideoDimensions
        if preferredMegapixels == 24, !hasNativePreferred {
            preferred = distinct.first {
                Self.megapixels(for: $0) > preferredMegapixels
            } ?? maximum
        } else {
            preferred = distinct.min {
                abs(Self.megapixels(for: $0) - preferredMegapixels)
                    < abs(Self.megapixels(for: $1) - preferredMegapixels)
            } ?? maximum
        }
        resolutionLock.lock()
        supportedPhotoDimensions = distinct
        capturePhotoDimensions = preferred
        captureTargetMegapixels = preferredMegapixels
        resolutionLock.unlock()
        let publishedValues = values
        let publishedMegapixels = preferredMegapixels
        Task { @MainActor in
#if DEBUG && targetEnvironment(simulator)
            guard !self.isSimulatorDemoCameraEnabled else { return }
#endif
            self.availableMegapixels = publishedValues
            self.selectedMegapixels = publishedMegapixels
        }
    }

    nonisolated private func selectedPhotoDimensions() -> CMVideoDimensions {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        return capturePhotoDimensions
    }

    nonisolated private func selectedTargetMegapixels() -> Int {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        return captureTargetMegapixels
    }

    nonisolated private static func megapixels(for dimensions: CMVideoDimensions) -> Int {
        let measured = Double(dimensions.width) * Double(dimensions.height) / 1_000_000
        let nativeLabels = [12, 24, 48]
        if let label = nativeLabels.min(by: { abs(Double($0) - measured) < abs(Double($1) - measured) }),
           abs(Double(label) - measured) < 3 {
            return label
        }
        return Int(measured.rounded())
    }

    nonisolated private func supportedRAWPhotoMegapixels() -> [Int] {
        resolutionLock.lock()
        let values = supportedPhotoDimensions.map(Self.megapixels(for:))
        resolutionLock.unlock()
        // Surface every photo dimension the active camera format reports. RAW
        // selection then requests that exact native dimension rather than using
        // the processed 24 MP downsampling path.
        return Array(Set(values.filter { $0 > 0 })).sorted()
    }

    nonisolated private func preferredDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            // Virtual multi-camera devices currently cap photo delivery below
            // the native resolution of their 48 MP constituents. Use the main
            // physical camera and switch physical inputs for discrete lenses.
            ? [.builtInWideAngleCamera, .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
            : [.builtInWideAngleCamera, .builtInTrueDepthCamera]
        for type in types {
            if let device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [type],
                mediaType: .video,
                position: position
            ).devices.first {
                return device
            }
        }
        return nil
    }

    nonisolated private func configureVideoConnectionFallback(for device: AVCaptureDevice) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let angle = currentPreviewRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position == .front
        }
    }

    private func configureRotationCoordinator(for device: AVCaptureDevice, switchToken: UUID? = nil) {
        guard let previewLayer else {
            prepareFirstFrameAfterSwitch(token: switchToken)
            return
        }
        previewRotationObservation = nil

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(
            coordinator.videoRotationAngleForHorizonLevelPreview,
            position: device.position,
            switchToken: switchToken
        )

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self, weak coordinator] _, change in
            guard let coordinator, let angle = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.rotationCoordinator === coordinator else { return }
                self.applyPreviewRotation(angle, position: device.position)
            }
        }
    }

    private func applyPreviewRotation(
        _ angle: CGFloat,
        position: AVCaptureDevice.Position,
        switchToken: UUID? = nil
    ) {
        currentPreviewRotationAngle = angle
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.videoOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
            self.prepareFirstFrameAfterSwitch(token: switchToken)
        }
    }

    nonisolated private func prepareFirstFrameAfterSwitch(token: UUID?) {
        guard let token else { return }
        videoQueue.async { [weak self] in
            guard let self, self.pendingCameraSwitchToken == token else { return }
            self.acceptsPreviewFrames = true
        }
    }

    private func recoverCameraSwitchIfNeeded(token: UUID) {
        videoQueue.async { [weak self] in
            guard let self, self.pendingCameraSwitchToken == token else { return }
            self.pendingCameraSwitchToken = nil
            self.acceptsPreviewFrames = true
            self.previewRenderer.resume()
            Task { @MainActor in
                guard self.isSwitchingCamera else { return }
                self.cameraSwitchRecoveryTask = nil
                withAnimation(.easeOut(duration: 0.18)) {
                    self.isSwitchingCamera = false
                }
            }
        }
    }

    nonisolated private func finishCameraSwitchFailure(token: UUID?) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if let token {
                guard self.pendingCameraSwitchToken == token else { return }
                self.pendingCameraSwitchToken = nil
            }
            self.acceptsPreviewFrames = true
            self.previewRenderer.resume()
            Task { @MainActor in
                self.cameraSwitchRecoveryTask?.cancel()
                self.cameraSwitchRecoveryTask = nil
                self.isSwitchingCamera = false
            }
        }
    }

    nonisolated private func selectRearLens(displayFactor: CGFloat) {
        guard let target = rearLensTargets().min(by: {
            abs($0.displayFactor - displayFactor) < abs($1.displayFactor - displayFactor)
        }) else { return }

        if cameraInput?.device.uniqueID == target.device.uniqueID {
            updateDeviceState(
                target.device,
                requestedZoomFactor: target.deviceZoomFactor,
                requestedDisplayFactor: target.displayFactor
            )
        } else {
            replaceCameraInput(
                with: target.device,
                requestedZoomFactor: target.deviceZoomFactor,
                requestedDisplayFactor: target.displayFactor
            )
        }
    }

    /// Builds the native rear-camera rail from the physical constituents. The
    /// virtual device provides Apple's display-space focal-length mapping, while
    /// each physical device keeps access to its full still-photo dimensions.
    nonisolated private func rearLensTargets() -> [CameraLensTarget] {
        let virtualTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        let virtualDevice = virtualTypes.lazy.compactMap { type in
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [type],
                mediaType: .video,
                position: .back
            ).devices.first
        }.first

        var physicalDevices = virtualDevice?.constituentDevices ?? []
        if physicalDevices.isEmpty {
            physicalDevices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video,
                position: .back
            ).devices
        }
        var seenDeviceIDs = Set<String>()
        physicalDevices = physicalDevices.filter { seenDeviceIDs.insert($0.uniqueID).inserted }
        physicalDevices.sort {
            Self.videoFieldOfView(for: $0) > Self.videoFieldOfView(for: $1)
        }
        guard !physicalDevices.isEmpty else { return [] }

        var nativeDisplayFactors: [CGFloat] = []
        if let virtualDevice {
            let multiplier = displayZoomMultiplier(for: virtualDevice)
            nativeDisplayFactors = [virtualDevice.minAvailableVideoZoomFactor]
            nativeDisplayFactors.append(contentsOf: virtualDevice.virtualDeviceSwitchOverVideoZoomFactors.map {
                CGFloat(truncating: $0)
            })
            nativeDisplayFactors = nativeDisplayFactors.map { $0 * multiplier }.sorted()
        }
        if nativeDisplayFactors.count != physicalDevices.count {
            nativeDisplayFactors = physicalDevices.enumerated().map { index, device in
                switch device.deviceType {
                case .builtInUltraWideCamera: 0.5
                case .builtInWideAngleCamera: 1
                case .builtInTelephotoCamera: index > 1 ? 3 : 2
                default: CGFloat(index + 1)
                }
            }
        }

        var targets = zip(physicalDevices, nativeDisplayFactors).map { device, displayFactor in
            CameraLensTarget(displayFactor: displayFactor, device: device, deviceZoomFactor: 1)
        }
        for (device, baseDisplayFactor) in zip(physicalDevices, nativeDisplayFactors) {
            for zoomFactor in device.activeFormat.secondaryNativeResolutionZoomFactors {
                let displayFactor = baseDisplayFactor * zoomFactor
                guard zoomFactor >= device.minAvailableVideoZoomFactor,
                      zoomFactor <= device.maxAvailableVideoZoomFactor,
                      !targets.contains(where: { abs($0.displayFactor - displayFactor) < 0.025 }) else { continue }
                targets.append(CameraLensTarget(
                    displayFactor: displayFactor,
                    device: device,
                    deviceZoomFactor: zoomFactor
                ))
            }
        }

        // Single-camera iPhones (including Air/SE/e configurations) do not
        // have a telephoto constituent to contribute to the native rail. Keep
        // every system-reported option above, then provide only the requested
        // 3× and 4× crop targets when the active format can actually reach them.
        if physicalDevices.count == 1,
           let device = physicalDevices.first,
           let baseDisplayFactor = nativeDisplayFactors.first {
            for displayFactor in [CGFloat(3), CGFloat(4)] {
                let zoomFactor = displayFactor / max(0.01, baseDisplayFactor)
                guard zoomFactor >= device.minAvailableVideoZoomFactor,
                      zoomFactor <= device.activeFormat.videoMaxZoomFactor,
                      !targets.contains(where: { abs($0.displayFactor - displayFactor) < 0.025 }) else { continue }
                targets.append(CameraLensTarget(
                    displayFactor: displayFactor,
                    device: device,
                    deviceZoomFactor: zoomFactor
                ))
            }
        }
        return targets.sorted { $0.displayFactor < $1.displayFactor }
    }

    nonisolated private static func videoFieldOfView(for device: AVCaptureDevice) -> Float {
        device.formats.map(\.videoFieldOfView).max() ?? device.activeFormat.videoFieldOfView
    }

    nonisolated private func updateDeviceState(
        _ device: AVCaptureDevice,
        requestedZoomFactor: CGFloat? = nil,
        requestedDisplayFactor: CGFloat? = nil
    ) {
        let multiplier = displayZoomMultiplier(for: device)
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = device.maxAvailableVideoZoomFactor
        let selectedFactor: CGFloat
        let selectedLabel: String
        let publishedOptions: [CameraLensOption]

        if device.position == .back {
            let targets = rearLensTargets()
            let selectedTarget = targets.min(by: { lhs, rhs in
                if let requestedDisplayFactor {
                    return abs(lhs.displayFactor - requestedDisplayFactor) < abs(rhs.displayFactor - requestedDisplayFactor)
                }
                let lhsMatchesDevice = lhs.device.uniqueID == device.uniqueID
                let rhsMatchesDevice = rhs.device.uniqueID == device.uniqueID
                if lhsMatchesDevice != rhsMatchesDevice { return lhsMatchesDevice }
                return abs(lhs.displayFactor - 1) < abs(rhs.displayFactor - 1)
            })
            selectedFactor = max(minimum, min(requestedZoomFactor ?? selectedTarget?.deviceZoomFactor ?? 1, maximum))
            let displayFactor = requestedDisplayFactor ?? selectedTarget?.displayFactor ?? 1
            selectedLabel = formatLens(displayFactor)
            publishedOptions = Self.uniqueLensOptions(targets.map {
                CameraLensOption(factor: Double($0.displayFactor), label: formatLens($0.displayFactor))
            })
            lensFactors = [selectedFactor]
            lensIndex = 0
        } else {
            var factors: [CGFloat] = [minimum, 1 / multiplier]
            factors.append(contentsOf: device.activeFormat.secondaryNativeResolutionZoomFactors)
            factors = factors
                .filter { $0 >= minimum && $0 <= maximum }
                .sorted()
                .reduce(into: []) { result, factor in
                    if result.last.map({ abs($0 - factor) > 0.025 }) ?? true {
                        result.append(factor)
                    }
                }
            let systemFacingFactors = factors.filter {
                let displayFactor = $0 * multiplier
                return abs(displayFactor - 1) < 0.01 || abs(displayFactor - 1) >= 0.15
            }
            if !systemFacingFactors.isEmpty {
                factors = systemFacingFactors
            }
            if factors.isEmpty { factors = [minimum] }
            lensFactors = factors
            lensIndex = factors.enumerated().min(by: {
                abs($0.element * multiplier - 1) < abs($1.element * multiplier - 1)
            })?.offset ?? 0
            selectedFactor = factors[lensIndex]
            selectedLabel = formatLens(selectedFactor * multiplier)
            publishedOptions = Self.uniqueLensOptions(factors.map {
                CameraLensOption(factor: Double($0), label: formatLens($0 * multiplier))
            })
        }

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.videoZoomFactor = selectedFactor
            device.unlockForConfiguration()
        } catch { }
        Task { @MainActor in
#if DEBUG && targetEnvironment(simulator)
            guard !self.isSimulatorDemoCameraEnabled else { return }
#endif
            self.flashAvailable = device.hasFlash && device.position == .back
            self.lensLabel = selectedLabel
            self.lensOptions = publishedOptions
            self.setExposure(self.preferences.rememberExposure ? self.preferences.lastExposure : 0)
        }
    }

    private func setDeviceZoom(_ requestedFactor: CGFloat, on device: AVCaptureDevice) {
        let factor = max(device.minAvailableVideoZoomFactor, min(requestedFactor, device.maxAvailableVideoZoomFactor))
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
            let displayFactor = Double(factor * displayZoomMultiplier(for: device))
            lensLabel = formatLens(CGFloat(displayFactor))
            lensIndex = lensFactors.enumerated().min(by: {
                abs($0.element - factor) < abs($1.element - factor)
            })?.offset ?? 0
        } catch {
            statusMessage = L10n.string("Zoom isn’t available right now.")
        }
    }

    nonisolated private func displayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return max(0.01, device.displayVideoZoomFactorMultiplier)
        }
        return device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) ? 0.5 : 1
    }

#if DEBUG
    nonisolated private func debugLogCameraConfiguration(context: String) {
        let device = cameraInput?.device
        let activeDimensions = device.map {
            CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
        } ?? CMVideoDimensions(width: 0, height: 0)
        let supportedDimensions = device?.activeFormat.supportedMaxPhotoDimensions.map {
            "\($0.width)x\($0.height) (~\(Self.megapixels(for: $0)) MP)"
        }.joined(separator: ", ") ?? "none"
        let selectedDimensions = selectedPhotoDimensions()
        let selectedMegapixels = selectedTargetMegapixels()
        print(
            """
            [Hibiscus Camera] \(context)
              sessionPreset: \(session.sessionPreset.rawValue)
              activeDevice: \(device?.localizedName ?? "none") [\(device?.uniqueID ?? "none")]
              activeFormatDimensions: \(activeDimensions.width)x\(activeDimensions.height)
              supportedMaxPhotoDimensions: [\(supportedDimensions)]
              selectedPhotoResolution: \(selectedDimensions.width)x\(selectedDimensions.height) (~\(selectedMegapixels) MP)
              isLivePhotoCaptureSupported: \(photoOutput.isLivePhotoCaptureSupported)
              isLivePhotoCaptureEnabled: \(photoOutput.isLivePhotoCaptureEnabled)
              hasAudioInput: \(audioInput != nil)
            """
        )
    }
#endif

    private func startSessionOnly() {
        sessionQueue.async { [weak self] in self?.startSessionOnlyFromQueue() }
    }

    nonisolated private func startSessionOnlyFromQueue() {
#if DEBUG && targetEnvironment(simulator)
        guard !isSimulatorDemoCameraEnabled else { return }
#endif
        guard !session.isRunning, cameraInput != nil else { return }
        session.startRunning()
        Task { @MainActor in self.isRunning = true }
    }

    nonisolated private func formatLens(_ factor: CGFloat) -> String {
        // Some devices expose a near-unity display multiplier (for example
        // 0.9) even though it is not a distinct native lens selection. Present
        // that optical state as the system-facing 1× option.
        let displayFactor = abs(factor - 1) < 0.15 ? CGFloat(1) : factor
        return abs(displayFactor - displayFactor.rounded()) < 0.01
            ? "\(Int(displayFactor.rounded()))×"
            : "\(String(format: "%.1f", Double(displayFactor)))×"
    }

    nonisolated private static func uniqueLensOptions(_ options: [CameraLensOption]) -> [CameraLensOption] {
        var labels = Set<String>()
        return options.filter { labels.insert($0.label).inserted }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
#if DEBUG && targetEnvironment(simulator)
        guard !isSimulatorDemoCameraEnabled else { return }
#endif
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The video connection delivers physically rotated portrait buffers.
        // Front-camera mirroring is also applied at the connection level.
        let image = CIImage(cvPixelBuffer: buffer)
        let character = renderCharacter
        let adjustment = renderCharacterAdjustment
        guard acceptsPreviewFrames else { return }
        if pendingCameraSwitchToken != nil {
            // Connection changes can leave one stale, pre-rotation buffer queued.
            // Keep the held frame until dimensions agree with the coordinator.
            guard previewBufferMatchesCurrentRotation(buffer) else { return }
            pendingCameraSwitchToken = nil
            acceptsPreviewFrames = true
            previewRenderer.reveal(image, character: character, adjustment: adjustment) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isSwitchingCamera else { return }
                    self.cameraSwitchRecoveryTask?.cancel()
                    self.cameraSwitchRecoveryTask = nil
                    withAnimation(.easeOut(duration: 0.28)) {
                        self.isSwitchingCamera = false
                    }
                }
            }
        } else {
            previewRenderer.submit(image, character: character, adjustment: adjustment)
        }
    }

    nonisolated private func previewBufferMatchesCurrentRotation(_ buffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width != height else { return true }
        let normalizedAngle = Int(currentPreviewRotationAngle.rounded()).quotientAndRemainder(dividingBy: 180).remainder
        let expectsPortrait = abs(normalizedAngle) == 90
        return expectsPortrait ? height > width : width > height
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return
        }
        if photo.isRawPhoto {
            pendingRawData = data
            return
        }
        if captureUsesLivePhoto { pendingLivePhotoData = data }
        guard let image = UIImage(data: data) else { return }
        let character = captureCharacter
        let adjustment = captureCharacterAdjustment
        let aspectRatio = captureLiveAspectRatio
        let targetMegapixels = captureLiveTargetMegapixels
        let token = captureProcessingToken
        let preview = ImageRenderer.cameraImage(
            image,
            character: character,
            adjustment: adjustment,
            aspectRatio: aspectRatio,
            targetMegapixels: min(2, targetMegapixels)
        ) ?? image
        pendingPreviewImage = preview
        pendingProcessedImage = preview

        photoProcessingQueue.async { [weak self] in
            let processed = autoreleasepool {
                ImageRenderer.cameraImage(
                    image,
                    character: character,
                    adjustment: adjustment,
                    aspectRatio: aspectRatio,
                    targetMegapixels: targetMegapixels
                ) ?? image
            }
            Task { @MainActor [weak self] in
                guard let self, self.captureProcessingToken == token else { return }
                self.pendingProcessedImage = processed
                if self.capturedImage != nil {
                    self.capturedImage = processed
                    self.capturedPreviewImage = processed
                }
                if !self.captureUsesLivePhoto {
                    self.isProcessingCapture = false
                    self.autoSaveCaptureIfReady(token: token)
                }
            }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL,
        resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.captureUsesLivePhoto else { return }
            // This delegate boundary is the authoritative end of Live Photo
            // motion capture. Freeze only now, while file/color processing runs.
            self.isRecordingLivePhoto = false
            self.previewRenderer.freeze()
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            pendingLivePhotoMovieURL = nil
            return
        }
        pendingLivePhotoMovieURL = outputFileURL
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let processed = pendingProcessedImage
        let preview = pendingPreviewImage
        let usesLivePhoto = captureUsesLivePhoto
        let livePhotoData = pendingLivePhotoData
        let livePhotoMovieURL = pendingLivePhotoMovieURL
        let liveCharacter = captureCharacter
        let liveAdjustment = captureCharacterAdjustment
        let liveAspectRatio = captureLiveAspectRatio
        let liveTargetMegapixels = captureLiveTargetMegapixels
        let token = captureProcessingToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRecordingLivePhoto = false
            self.isCapturing = false
            guard error == nil, let processed else {
                self.isProcessingCapture = false
                self.previewRenderer.resume()
                self.statusMessage = L10n.string("Couldn’t capture this photo.")
                return
            }
            self.capturedImage = processed
            self.capturedPreviewImage = preview ?? processed
            if !usesLivePhoto {
                self.autoSaveCaptureIfReady(token: token)
            }
            self.stop()
        }
        guard error == nil, usesLivePhoto,
              let livePhotoData, let livePhotoMovieURL else {
            if usesLivePhoto {
                Task { @MainActor [weak self] in
                    guard let self, self.captureProcessingToken == token else { return }
                    self.isProcessingCapture = false
                    self.statusMessage = L10n.string("Couldn’t capture this Live Photo.")
                }
            }
            return
        }
        Task { @MainActor [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                await LivePhotoProcessor.processCameraCapture(
                    photoData: livePhotoData,
                    motionURL: livePhotoMovieURL,
                    character: liveCharacter,
                    adjustment: liveAdjustment,
                    aspectRatio: liveAspectRatio,
                    targetMegapixels: liveTargetMegapixels
                )
            }.value
            try? FileManager.default.removeItem(at: livePhotoMovieURL)
            guard let self, self.captureProcessingToken == token else {
                output?.cleanUp()
                return
            }
            self.capturedLivePhoto?.cleanUp()
            self.capturedLivePhoto = output
            self.isProcessingCapture = false
            if output == nil {
                self.statusMessage = L10n.string("Couldn’t capture this Live Photo.")
            } else {
                self.autoSaveCaptureIfReady(token: token)
            }
        }
    }
}
