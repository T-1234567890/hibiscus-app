import AVKit
import Photos
import SwiftUI

struct CameraView: View {
    @ObservedObject var preferences: AppPreferences
#if DEBUG && targetEnvironment(simulator)
    @EnvironmentObject private var simulatorDemoMode: SimulatorDemoMode
#endif
    @StateObject private var camera: CameraService
    @State private var showsExposure = false
    @State private var isSelectionPanelExpanded = true
    @State private var showsCharacterPad = false
    @State private var cameraControlRotation: Angle = .zero
    @State private var cameraControlSide: CGFloat = 0
    @State private var capturePrintProgress: CGFloat = 0
    @State private var captureDevelopmentProgress: CGFloat = 1
    @State private var captureLivePhotoPreview: PHLivePhoto?
    @State private var captureLivePhotoPlaybackID = 0
    @State private var captureAnimationTask: Task<Void, Never>?
    @Namespace private var characterPadTransition
    let isActive: Bool
    let sendToGrade: (GradeImportItem) -> Void

    init(
        preferences: AppPreferences,
        isActive: Bool,
        sendToGrade: @escaping (GradeImportItem) -> Void
    ) {
        self.preferences = preferences
        self.isActive = isActive
        self.sendToGrade = sendToGrade
        _camera = StateObject(wrappedValue: CameraService(preferences: preferences))
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color(white: 0.065)
                LinearGradient(
                    colors: [Color.black.opacity(0.45), cameraSurfaceTint.opacity(0.12), Color(white: 0.065)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()

            if let captured = camera.capturedImage {
                captureResult(captured)
            } else {
                liveCamera
            }

            if let status = camera.statusMessage {
                StatusPill(message: status)
                    .zIndex(10)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) {
                            camera.statusMessage = nil
                        }
                    }
                    .task(id: status) {
                        do {
                            try await Task.sleep(for: .seconds(3))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled, camera.statusMessage == status else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            camera.statusMessage = nil
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: camera.statusMessage)
        .tint(.white)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateCameraControlRotation(UIDevice.current.orientation)
            if isActive {
#if DEBUG && targetEnvironment(simulator)
                syncSimulatorDemoCamera()
#endif
                camera.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateCameraControlRotation(UIDevice.current.orientation)
        }
        .onChange(of: isActive) { _, active in
            if active {
#if DEBUG && targetEnvironment(simulator)
                syncSimulatorDemoCamera()
#endif
                camera.start()
            } else {
                camera.stop()
            }
        }
        .onChange(of: camera.capturedImage != nil) { _, hasCapture in
            captureAnimationTask?.cancel()
            guard hasCapture else {
                capturePrintProgress = 0
                captureDevelopmentProgress = 1
                captureLivePhotoPreview = nil
                captureLivePhotoPlaybackID = 0
                return
            }
            capturePrintProgress = 0
            captureDevelopmentProgress = 0
            captureAnimationTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.18, 0.72, 0.20, 1, duration: 1.3)) {
                    capturePrintProgress = 1
                }
                do {
                    try await Task.sleep(for: .seconds(1.3))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.9)) {
                    captureDevelopmentProgress = 1
                }
            }
        }
        .onChange(of: camera.selectedCamera) { _, selection in
            guard showsCharacterPad, selection.character == nil else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                showsCharacterPad = false
            }
        }
        .onDisappear {
            captureAnimationTask?.cancel()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            camera.stop()
        }
    }

    private var liveCamera: some View {
        GeometryReader { proxy in
            let previewHeight = min(proxy.size.height, proxy.size.width / camera.selectedRatio.portraitRatio)
            let zoomBottomInset: CGFloat = switch camera.selectedRatio {
            case .widescreen, .standard: 232
            case .square: 245
            }
            let zoomY = max(150, proxy.size.height - zoomBottomInset)
            let previewTop = camera.selectedRatio == .square
                ? max(0, zoomY - previewHeight + 24)
                : 0
            let isLandscapeControlLayout = cameraControlSide != 0
            let topControlX = isLandscapeControlLayout
                ? (cameraControlSide > 0 ? proxy.size.width - 29 : 29)
                : proxy.size.width / 2
            let topControlY = isLandscapeControlLayout
                ? previewTop + previewHeight / 2
                : previewTop + 28
            let zoomX = isLandscapeControlLayout
                ? (cameraControlSide > 0 ? 35 : proxy.size.width - 35)
                : proxy.size.width / 2
            let positionedZoomY = isLandscapeControlLayout ? proxy.size.height / 2 : zoomY

            ZStack(alignment: .top) {
                cameraPreview
                    .frame(width: proxy.size.width, height: previewHeight)
                    .clipped()
                    .offset(y: previewTop)
                    .scaleEffect(camera.isSwitchingCamera ? 1.012 : 1)
                    .blur(radius: camera.isSwitchingCamera ? 1.2 : 0)
                    .overlay {
                        if camera.isSwitchingCamera {
                            Color.black.opacity(0.13)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.28), value: camera.isSwitchingCamera)

                if camera.authorizationState == .authorized {
                    if preferences.cameraGridEnabled {
                        CameraGrid()
                            .frame(width: proxy.size.width, height: previewHeight)
                            .offset(y: previewTop)
                            .allowsHitTesting(false)
                    }

                    CameraCaptureEventOverlay(
                        isCaptureEnabled: isActive
                            && camera.isRunning
                            && camera.countdown == nil
                            && !camera.isCapturing
                            && !camera.isConfiguringLivePhoto
                            && !showsCharacterPad,
                        onCapture: camera.capture
                    )
                    .frame(width: proxy.size.width, height: previewHeight)
                    .offset(y: previewTop)

                    cameraTopBar
                        .frame(width: isLandscapeControlLayout ? 68 : proxy.size.width - 24)
                        .position(x: topControlX, y: topControlY)
                        .zIndex(3)

                    cameraControls
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: .bottom
                        )
                        .overlay {
                            zoomControl
                                .rotationEffect(cameraControlRotation)
                                .position(x: zoomX, y: positionedZoomY)
                        }
                        .zIndex(3)

                    if showsCharacterPad {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    showsCharacterPad = false
                                }
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .zIndex(2)
                    }

                    if showsCharacterPad, let character = camera.selectedCamera.character {
                        cameraCharacterPadOverlay(character: character)
                            .frame(width: 136, height: 136)
                            .position(
                                x: proxy.size.width - 76,
                                y: previewTop + 76
                            )
                            .zIndex(4)
                    }

                    if let countdown = camera.countdown {
                        Text("\(countdown)")
                            .font(.system(size: 72, weight: .light, design: .rounded))
                            .contentTransition(.numericText())
                            .shadow(color: .black.opacity(0.55), radius: 12)
                            .frame(width: proxy.size.width, height: previewHeight)
                            .offset(y: previewTop)
                    }

                }
            }
        }
    }

    private var zoomControl: some View {
        Button(action: camera.selectNextLens) {
            Text(camera.lensLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 36, minHeight: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zoom \(camera.lensLabel)")
        .accessibilityHint("Cycles through the available lenses")
        .padding(2)
        .hibiscusGlass(tint: .black.opacity(0.18), in: Capsule())
        .frame(minWidth: 40, minHeight: 34)
        .zIndex(2)
    }

    @ViewBuilder
    private var cameraPreview: some View {
        switch camera.authorizationState {
        case .authorized:
            CameraMetalPreview(
                renderer: camera.previewRenderer,
                isActive: isActive && (!camera.isCapturing || camera.isRecordingLivePhoto),
                onPreviewLayerReady: camera.attachPreviewLayer
            )
                .background(Color(white: 0.025))
        case .unknown:
            ZStack {
                Color(white: 0.04)
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Preparing camera…").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        case .denied:
            permissionState(
                title: "Camera access is off",
                message: "Allow camera access in Settings to shoot with Hibiscus.",
                showsSettings: true
            )
        case .unavailable:
            permissionState(
                title: "Camera unavailable",
                message: "A camera isn’t available on this device.",
                showsSettings: false
            )
        }
    }

    private var cameraTopBar: some View {
        HibiscusGlassContainer(spacing: 7) {
            if cameraControlSide == 0 {
                HStack(spacing: 7) {
                    flashTopControl
                    livePhotoTopControl
                    Spacer()
                    if !showsCharacterPad {
                        ratioTimerTopControl
                        qualityTopControl
                        if camera.selectedCamera.character != nil {
                            characterPadTopControl
                        }
                    }
                }
            } else {
                VStack(spacing: 9) {
                    flashTopControl
                    livePhotoTopControl
                    if !showsCharacterPad {
                        ratioTimerTopControl
                        qualityTopControl
                        if camera.selectedCamera.character != nil {
                            characterPadTopControl
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showsCharacterPad)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: camera.selectedCamera)
    }

    private var flashTopControl: some View {
        Menu {
            Picker("Flash", selection: $camera.flashMode) {
                ForEach(CaptureFlashMode.allCases) { mode in
                    Label {
                        Text(LocalizedStringKey(mode.rawValue))
                    } icon: {
                        Image(systemName: mode.systemImage)
                    }
                    .tag(mode)
                }
            }
        } label: {
            Image(systemName: camera.flashMode.systemImage)
                .frame(width: 18, height: 18)
        }
        .hibiscusGlassButtonStyle()
        .disabled(!camera.flashAvailable)
        .opacity(camera.flashAvailable ? 1 : 0.46)
        .rotationEffect(cameraControlRotation)
    }

    private var livePhotoTopControl: some View {
        Button {
            camera.toggleLivePhoto()
        } label: {
            Group {
                if camera.isConfiguringLivePhoto {
                    ProgressView().controlSize(.mini)
                } else {
                    // Apple's Live Photo glyph is used only for the Live Photo
                    // capture state it represents.
                    Image(systemName: camera.selectedMotion == .livePhoto ? "livephoto" : "livephoto.slash")
                }
            }
            .frame(width: 18, height: 18)
        }
        .hibiscusGlassButtonStyle()
        .disabled(camera.isConfiguringLivePhoto || camera.selectedFormat == .raw)
        .opacity(camera.selectedFormat == .processed ? 1 : 0.46)
        .rotationEffect(cameraControlRotation)
    }

    private var characterPadTopControl: some View {
        Button {
            if camera.selectedCamera.character != nil {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    showsCharacterPad = true
                }
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                camera.statusMessage = L10n.string("Choose a Camera Character to use the Character Pad.")
            }
        } label: {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
        }
        .hibiscusGlassButtonStyle()
        .matchedGeometryEffect(id: "camera-character-pad", in: characterPadTransition)
        .transition(.opacity.combined(with: .scale(scale: 0.72, anchor: .center)))
        .rotationEffect(cameraControlRotation)
        .accessibilityLabel("Character Pad")
        .accessibilityHint(
            camera.selectedCamera.character == nil
                ? "Choose a Camera Character first."
                : "Opens live Camera Character customization."
        )
    }

    private var ratioTimerTopControl: some View {
        Menu {
            Section("Ratio") {
                Picker("Photo Ratio", selection: $camera.selectedRatio) {
                    ForEach(CameraAspectRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
            }
            Section("Timer") {
                Picker("Timer", selection: $camera.selectedTimer) {
                    ForEach(CaptureTimerOption.allCases) { timer in
                        Text(LocalizedStringKey(timer.rawValue)).tag(timer)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(camera.selectedRatio.rawValue)
                if camera.selectedTimer != .off {
                    Image(systemName: "timer")
                    Text(LocalizedStringKey(camera.selectedTimer.rawValue))
                }
            }
            .font(.caption2.weight(.bold))
            .frame(minHeight: 18)
        }
        .hibiscusGlassButtonStyle()
        .rotationEffect(cameraControlRotation)
    }

    private var qualityTopControl: some View {
        Menu {
            Section("Current") {
                Button(selectedCaptureQualityTitle) { }
                    .disabled(true)
            }
            Menu("HEIF") {
                ForEach(camera.availableMegapixels, id: \.self) { megapixels in
                    Button {
                        camera.selectCapture(format: .processed, megapixels: megapixels)
                    } label: {
                        if camera.selectedFormat == .processed,
                           camera.selectedMegapixels == megapixels {
                            Label("\(megapixels) MP", systemImage: "checkmark")
                        } else {
                            Text("\(megapixels) MP")
                        }
                    }
                }
            }
            Menu("RAW") {
                if camera.availableRawMegapixels.isEmpty {
                    Button("Unavailable") { }
                        .disabled(true)
                } else {
                    ForEach(camera.availableRawMegapixels, id: \.self) { megapixels in
                        Button {
                            camera.selectCapture(format: .raw, megapixels: megapixels)
                        } label: {
                            if camera.selectedFormat == .raw,
                               camera.selectedMegapixels == megapixels {
                                Label("\(megapixels) MP", systemImage: "checkmark")
                            } else {
                                Text("\(megapixels) MP")
                            }
                        }
                    }
                }
            }
            .disabled(camera.availableRawMegapixels.isEmpty)
        } label: {
            topSettingLabel("\(camera.selectedMegapixels) MP")
        }
        .hibiscusGlassButtonStyle()
        .rotationEffect(cameraControlRotation)
    }

    private var selectedCaptureQualityTitle: String {
        camera.selectedFormat == .raw
            ? "RAW \(camera.selectedMegapixels) MP"
            : "HEIF \(camera.selectedMegapixels) MP"
    }

    private func topSettingLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .frame(minWidth: 24, minHeight: 18)
    }

    private var cameraControls: some View {
        HibiscusGlassContainer(spacing: 6) {
            VStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.28)) {
                        isSelectionPanelExpanded.toggle()
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 6) {
                        Text(camera.selectedCamera.symbol)
                            .font(.system(size: 17))
                            .foregroundStyle(Color.hibiscusAccent)
                            .frame(width: 29, height: 29)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(camera.selectedCamera.name)
                                .font(.subheadline.weight(.semibold))
                            Text(LocalizedStringKey(camera.selectedCamera.subtitle))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(LocalizedStringKey(isSelectionPanelExpanded ? "Hide" : "Controls"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: isSelectionPanelExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isSelectionPanelExpanded {
                    expandedCameraSelections
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if showsExposure {
                    exposureControl
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }

                shutterRow
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .hibiscusGlass(
                tint: cameraSurfaceTint.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
        }
    }

    private var cameraSurfaceTint: Color {
        camera.selectedCamera.identityColor
    }

    private var expandedCameraSelections: some View {
        VStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(CameraSelection.allCases) { selection in
                        Button {
                            camera.selectedCamera = selection
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(spacing: 5) {
                                Text(selection.symbol)
                                    .font(.system(size: 23))
                                    .foregroundStyle(.white)
                                    .frame(height: 29)

                                Text(selection.name)
                                    .font(.caption2.weight(camera.selectedCamera == selection ? .bold : .medium))
                                    .foregroundStyle(.white.opacity(camera.selectedCamera == selection ? 1 : 0.78))
                                    .lineLimit(1)
                            }
                            .frame(width: 54, height: 55)
                            .background {
                                if camera.selectedCamera == selection {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(Color.hibiscusAccent)
                                }
                            }
                            .animation(.snappy(duration: 0.18), value: camera.selectedCamera)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 3)
            }

            Button {
                preferences.cameraGridEnabled.toggle()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                Label("Grid", systemImage: preferences.cameraGridEnabled ? "grid" : "square")
                    .frame(maxWidth: .infinity)
            }
            .hibiscusGlassButtonStyle(.clear)
            .font(.caption.weight(.semibold))
        }
    }

    private func cameraCharacterPadOverlay(character: CameraCharacter) -> some View {
        CameraCharacterPad(
            character: character,
            point: camera.characterPoint,
            onChange: camera.updateCharacterPoint,
            onReset: camera.resetCharacterPoint
        )
        .frame(width: 136, height: 136)
        .shadow(color: .black.opacity(0.30), radius: 3, y: 2)
        .shadow(color: .black.opacity(0.68), radius: 16, y: 8)
        .matchedGeometryEffect(id: "camera-character-pad", in: characterPadTransition)
        .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .topTrailing)))
    }

    private var exposureControl: some View {
        HStack(spacing: 9) {
            Image(systemName: "minus")
            Slider(value: Binding(get: { camera.exposure }, set: camera.setExposure), in: -2...2)
                .tint(.white)
            Image(systemName: "plus")
        }
        .font(.caption2)
        .padding(.horizontal, 20)
        .frame(height: 30)
    }

    private var shutterRow: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.22)) { showsExposure.toggle() }
            } label: {
                Image(systemName: "plusminus.circle")
                    .font(.system(size: 21, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .hibiscusGlassButtonStyle(.clear)

            Spacer()

            Button(action: camera.capture) {
                LivePhotoShutter(
                    isRecordingLivePhoto: camera.isRecordingLivePhoto,
                    isProcessingCapture: camera.isProcessingCapture
                )
            }
            .buttonStyle(.plain)
            .hibiscusGlass(.clear, in: Circle())
            .overlay {
                LivePhotoCaptureRing(isRecording: camera.isRecordingLivePhoto)
            }
            .allowsHitTesting(
                camera.isRunning
                && camera.countdown == nil
                && !camera.isCapturing
                && !camera.isConfiguringLivePhoto
            )
            .accessibilityValue(
                camera.isRecordingLivePhoto ? Text("Capturing Live Photo") : Text("")
            )

            Spacer()

            Button(action: camera.switchCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 21, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .hibiscusGlassButtonStyle(.clear)
            .disabled(camera.isSwitchingCamera)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
    }

    private func permissionState(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        showsSettings: Bool
    ) -> some View {
        ZStack {
            Color(white: 0.04)
            VStack(spacing: 10) {
                Image(systemName: "camera.fill").font(.title)
                Text(title).font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                if showsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .hibiscusGlassButtonStyle(tint: .white)
                    .foregroundStyle(.black)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .hibiscusGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(20)
        }
    }

    private func captureResult(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            let displayImage = camera.capturedPreviewImage ?? image
            let imageRatio = max(0.01, displayImage.size.width / displayImage.size.height)
            let maximumWidth = max(1, proxy.size.width - 24)
            let maximumHeight = max(1, proxy.size.height - 170)
            let photoWidth = min(maximumWidth, maximumHeight * imageRatio)
            let photoHeight = photoWidth / imageRatio
            let resultVerticalOffset: CGFloat = camera.selectedRatio == .widescreen ? -24 : 0
            let shadowDevelopment = phaseProgress(captureDevelopmentProgress, from: 0, to: 0.42)
            let midtoneDevelopment = phaseProgress(captureDevelopmentProgress, from: 0.25, to: 0.78)
            let highlightDevelopment = phaseProgress(captureDevelopmentProgress, from: 0.62, to: 1)

            ZStack(alignment: .bottom) {
                ZStack(alignment: .top) {
                    VStack(spacing: 10) {
                        ZStack {
                            // Instant-film development establishes density first,
                            // followed by midtone color and finally clean highlights.
                            PhotoFitView(image: displayImage)
                                .saturation(0.06)
                                .contrast(0.58)
                                .brightness(-0.24)
                                .overlay {
                                    Color(red: 0.055, green: 0.065, blue: 0.06)
                                        .opacity(0.28)
                                }

                            PhotoFitView(image: displayImage)
                                .saturation(0.22)
                                .contrast(1.16)
                                .blendMode(.multiply)
                                .opacity(0.78 * shadowDevelopment)

                            PhotoFitView(image: displayImage)
                                .saturation(0.72)
                                .contrast(1.04)
                                .blendMode(.softLight)
                                .opacity(0.72 * midtoneDevelopment)

                            PhotoFitView(image: displayImage)
                                .opacity(highlightDevelopment)

                            if let captureLivePhotoPreview,
                               !camera.isProcessingCapture,
                               captureDevelopmentProgress >= 1 {
                                HibiscusLivePhotoView(
                                    livePhoto: captureLivePhotoPreview,
                                    playbackID: captureLivePhotoPlaybackID,
                                    onPlaybackEnded: { }
                                )
                                .allowsHitTesting(false)
                                .transition(.opacity)
                            }
                        }
                            .frame(width: photoWidth, height: photoHeight)
                            .background(.black)
                            .compositingGroup()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(.white.opacity(0.10), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.26), radius: 10, y: 4)
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .onTapGesture {
                                guard captureLivePhotoPreview != nil,
                                      !camera.isProcessingCapture,
                                      captureDevelopmentProgress >= 1 else { return }
                                captureLivePhotoPlaybackID &+= 1
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            .task(id: camera.capturedLivePhoto?.motionURL) {
                                captureLivePhotoPreview = nil
                                captureLivePhotoPlaybackID = 0
                                guard let output = camera.capturedLivePhoto else { return }
                                captureLivePhotoPreview = await LivePhotoPreviewFactory.make(
                                    from: output,
                                    placeholder: displayImage
                                )
                            }

                        captureMetadata
                    }
                    .mask(alignment: .top) {
                        Rectangle()
                            .scaleEffect(y: capturePrintProgress, anchor: .top)
                    }
                    .offset(y: -18 * (1 - capturePrintProgress))
                    .opacity(capturePrintProgress > 0 ? 1 : 0)
                }
                .frame(width: maximumWidth, height: photoHeight + 56, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: resultVerticalOffset)

                HibiscusGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        resultButton("Retake", systemImage: "arrow.counterclockwise", action: camera.retake)
                            .disabled(camera.isSavingCapture)
                            .opacity(camera.isSavingCapture ? 0.52 : 1)
                        resultButton("Grade", systemImage: "circle.lefthalf.filled") {
                            if let result = camera.capturedImage {
                                let thumbnail = ImageRenderer.resizedImage(result, maxDimension: 384) ?? result
                                sendToGrade(GradeImportItem(
                                    image: result,
                                    thumbnail: thumbnail,
                                    metadata: PhotoMetadata(
                                        date: camera.capturedDate,
                                        location: nil,
                                        cameraCharacter: camera.selectedCamera.character
                                    ),
                                    livePhoto: camera.takeCapturedLivePhotoSource()
                                ))
                            }
                        }
                        .disabled(camera.isProcessingCapture || camera.isSavingCapture)
                        .opacity(camera.isProcessingCapture || camera.isSavingCapture ? 0.52 : 1)
                        if !camera.didAutoSaveCapture {
                            resultButton("Save", systemImage: "square.and.arrow.down", action: camera.saveCapture)
                                .disabled(camera.isProcessingCapture || camera.isSavingCapture)
                                .opacity(camera.isProcessingCapture || camera.isSavingCapture ? 0.52 : 1)
                        }
                    }
                }
                .frame(height: 46)
                .padding(.bottom, 26)
            }
            .padding(.horizontal, 12)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var captureMetadata: some View {
        HStack(spacing: 9) {
            Text(camera.selectedCamera.symbol)
                .font(.system(size: 19))
                .foregroundStyle(Color.hibiscusAccent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(camera.selectedCamera.name)
                    .font(.caption.weight(.semibold))
                Text(LocalizedStringKey(camera.selectedCamera.subtitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if capturePrintProgress < 1 || captureDevelopmentProgress < 1 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Developing")
                    }
                } else if camera.isProcessingCapture {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Finishing")
                    }
                } else if camera.isSavingCapture {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Saving")
                    }
                } else {
                    Text("Ready")
                }
                Text(captureTechnicalMetadata)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 11)
        .frame(height: 46)
        .hibiscusGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    private var captureTechnicalMetadata: String {
        let live = camera.capturedLivePhoto == nil ? "" : " · LIVE"
        return "\(camera.selectedMegapixels) MP · \(camera.selectedFormat.rawValue) · \(camera.selectedRatio.rawValue)\(live)"
    }

    private func resultButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .hibiscusGlassButtonStyle()
    }

    private func phaseProgress(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(1, max(0, (progress - start) / (end - start)))
    }

#if DEBUG && targetEnvironment(simulator)
    private func syncSimulatorDemoCamera() {
        camera.configureSimulatorDemoCamera(
            enabled: simulatorDemoMode.isCameraEnabled,
            image: simulatorDemoMode.selectedCameraImage
        )
    }
#endif

    private func updateCameraControlRotation(_ orientation: UIDeviceOrientation) {
        let rotation: Angle?
        let side: CGFloat?
        switch orientation {
        case .landscapeLeft:
            rotation = .degrees(90)
            side = 1
        case .landscapeRight:
            rotation = .degrees(-90)
            side = -1
        case .portrait, .portraitUpsideDown:
            rotation = .zero
            side = 0
        default:
            rotation = nil
            side = nil
        }
        guard let rotation, let side else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            cameraControlRotation = rotation
            cameraControlSide = side
        }
    }
}

private struct CameraGrid: View {
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(width: 0.5)
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(width: 0.5)
                Spacer()
            }
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(height: 0.5)
                Spacer()
                Rectangle().fill(.white.opacity(0.22)).frame(height: 0.5)
                Spacer()
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 1)
    }
}

private struct CameraCharacterPad: View {
    let character: CameraCharacter
    let point: CGPoint
    let onChange: (CGPoint) -> Void
    let onReset: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let controlDiameter = max(14, size.width * 0.125)
            let controlRadius = controlDiameter / 2
            let centerMarkerDiameter = max(5, size.width * 0.046)
            let cornerRadius = size.width * 0.086
            ZStack {
                ZStack {
                    character.identityColor
                    LinearGradient(
                        colors: [
                            Color(white: 0.56),
                            character.identityColor,
                            character.identityColor
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.72), location: 0),
                            .init(color: .clear, location: 0.43),
                            .init(color: .black.opacity(0.82), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                Canvas { context, canvasSize in
                    let inset = canvasSize.width * 0.09
                    for row in 0..<11 {
                        for column in 0..<11 {
                            let x = inset + (canvasSize.width - inset * 2) * CGFloat(column) / 10
                            let y = inset + (canvasSize.height - inset * 2) * CGFloat(row) / 10
                            let radius = canvasSize.width * (row > 7 ? 0.0094 : 0.0077)
                            context.fill(
                                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                with: .color(.white.opacity(0.38 + Double(row) * 0.038))
                            )
                        }
                    }
                }
                .allowsHitTesting(false)

                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 1)
                    .frame(width: centerMarkerDiameter, height: centerMarkerDiameter)
                    .position(x: size.width / 2, y: size.height / 2)

                Circle()
                    .fill(.white)
                    .frame(width: controlDiameter, height: controlDiameter)
                    .overlay { Circle().stroke(.black.opacity(0.30), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1.5)
                    .position(
                        x: controlRadius + point.x * max(0, size.width - controlDiameter),
                        y: controlRadius + point.y * max(0, size.height - controlDiameter)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hibiscusGlass(
                tint: character.identityColor.opacity(0.08),
                interactive: true,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(CGPoint(
                            x: min(1, max(0, value.location.x / size.width)),
                            y: min(1, max(0, value.location.y / size.height))
                        ))
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            .accessibilityLabel("Character Pad")
            .accessibilityHint("Drag to vary this Camera Character. Double-tap to reset.")
        }
    }
}

private struct LivePhotoShutter: View {
    let isRecordingLivePhoto: Bool
    let isProcessingCapture: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)

            Circle()
                .stroke(.black.opacity(0.78), lineWidth: 3)
                .padding(5)

            if isProcessingCapture && !isRecordingLivePhoto {
                ProgressView()
                    .controlSize(.small)
                    .tint(.black)
            }
        }
        .frame(width: 58, height: 58)
    }
}

private struct LivePhotoCaptureRing: View {
    let isRecording: Bool

    @State private var recordingStartedAt: Date?
    @State private var completionProgress: CGFloat = 0
    @State private var progressOpacity: Double = 0
    @State private var completionTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isRecording)) { timeline in
            ZStack {
                Circle()
                    .stroke(Color.hibiscusAccent.opacity(0.72), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: max(0.012, displayedProgress(at: timeline.date)))
                    .stroke(
                        Color.hibiscusAccent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .opacity(progressOpacity)
        }
        .allowsHitTesting(false)
        .onAppear {
            if isRecording {
                beginProgress()
            }
        }
        .onChange(of: isRecording) { _, recording in
            recording ? beginProgress() : completeProgress()
        }
        .onDisappear {
            completionTask?.cancel()
        }
        .accessibilityHidden(true)
    }

    private func beginProgress() {
        completionTask?.cancel()
        recordingStartedAt = Date()
        completionProgress = 0
        progressOpacity = 1
    }

    private func completeProgress() {
        guard progressOpacity > 0 else { return }
        completionTask?.cancel()
        completionProgress = displayedProgress(at: Date())
        recordingStartedAt = nil
        withAnimation(.easeOut(duration: 0.18)) {
            completionProgress = 1
        }

        completionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(0.20))
            } catch {
                return
            }
            guard !Task.isCancelled, !isRecording else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                progressOpacity = 0
            }
            do {
                try await Task.sleep(for: .seconds(0.18))
            } catch {
                return
            }
            guard !Task.isCancelled, !isRecording else { return }
            completionProgress = 0
        }
    }

    private func displayedProgress(at date: Date) -> CGFloat {
        guard let recordingStartedAt else { return completionProgress }
        let elapsed = max(0, date.timeIntervalSince(recordingStartedAt))
        // This elapsed-time curve never reaches completion on its own. It stays
        // active for however long AVFoundation records, and the real recording
        // completion callback supplies the final segment of the ring.
        return min(0.97, CGFloat(1 - exp(-elapsed / 1.25)))
    }
}

private struct CameraCaptureEventOverlay: UIViewRepresentable {
    let isCaptureEnabled: Bool
    let onCapture: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        if #available(iOS 17.2, *) {
            let captureInteraction = AVCaptureEventInteraction { [weak coordinator = context.coordinator] event in
                guard event.phase == .ended else { return }
                Task { @MainActor in coordinator?.parent.onCapture() }
            }
            captureInteraction.isEnabled = isCaptureEnabled
            view.addInteraction(captureInteraction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        if #available(iOS 17.2, *) {
            uiView.interactions
                .compactMap { $0 as? AVCaptureEventInteraction }
                .forEach { $0.isEnabled = isCaptureEnabled }
        }
    }

    final class Coordinator: NSObject {
        var parent: CameraCaptureEventOverlay

        init(parent: CameraCaptureEventOverlay) {
            self.parent = parent
        }
    }
}
