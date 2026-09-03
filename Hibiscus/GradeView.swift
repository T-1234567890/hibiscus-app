import PencilKit
import PhotosUI
import SwiftUI

struct GradeView: View {
    @ObservedObject var store: GradeStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var savedLooks: SavedLooksStore
    let isActive: Bool
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsPicker = false
    @State private var pickerReplacesSession = true
    @State private var pendingStyle: GradeStyle?
    @State private var shareFiles: [URL] = []
    @State private var polaroidRequest: PolaroidExportRequest?
    @State private var paletteRequest: PaletteExportRequest?
    @State private var styleRailMode: GradeStyleRailMode = .builtIn
    @State private var styleRailPosition: String?
    @State private var showsAccentPicker = false
    @State private var showsSaveLookSheet = false
    @State private var saveLookDefaultName = ""
    @State private var showsRenameLookAlert = false
    @State private var renameLookTarget: SavedLook?
    @State private var renameLookName = ""
    @State private var photoSwipeOffset: CGFloat = 0
    @State private var didCompleteShare = false
    @State private var pendingSharePhotoIDs: Set<UUID> = []
    @State private var exportedPhotoIDs: Set<UUID> = []
    @State private var showsCompletionPrompt = false
    @State private var pendingCompletionFlowID: UUID?
    @State private var presentingCompletionFlowID: UUID?
    @State private var postExportDiscoveryRequest: PostExportDiscoveryRequest?
    @State private var postExportDiscoveryOpenedEcosystem = false
    @State private var originalPreviewPressTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color(white: 0.075)
                if store.sourceImage != nil {
                    RadialGradient(
                        colors: [store.settings.style.tint.opacity(0.13), .clear],
                        center: .top,
                        startRadius: 30,
                        endRadius: 520
                    )
                }
            }
            .ignoresSafeArea()

            GeometryReader { proxy in
                let previewHeight = photoHeight(for: proxy.size.height - navigationClearance)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        photoArea
                            .frame(height: previewHeight)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    collapseStyleRailIfNeeded()
                                }
                            )

                        if store.sourceImage != nil {
                            editor(width: proxy.size.width)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .padding(.bottom, navigationClearance)
                    .zIndex(store.isStyleRailExpanded ? 2 : 0)

                    if store.sourceImage != nil, store.isStyleRailExpanded {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.22)) {
                                    store.isStyleRailExpanded = false
                                }
                            }

                        styleRail
                            .frame(width: proxy.size.width)
                            .offset(y: previewHeight)
                            .zIndex(3)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                .animation(.snappy(duration: 0.22), value: store.isStyleRailExpanded)
            }

            if let message = store.statusMessage {
                StatusPill(message: message)
                    .zIndex(10)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) {
                            store.statusMessage = nil
                        }
                    }
                    .task(id: message) {
                        do {
                            try await Task.sleep(for: .seconds(3))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled, store.statusMessage == message else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            store.statusMessage = nil
                        }
                    }
            }

            if store.isExporting {
                ProgressView("Rendering")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .hibiscusGlass(in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.statusMessage)
        .tint(.white)
        .photosPicker(
            isPresented: $showsPicker,
            selection: $pickerItems,
            maxSelectionCount: photoPickerLimit,
            matching: .any(of: [.images, .livePhotos])
        )
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await importPhotos(from: newItems) }
        }
        .onChange(of: preferences.experimentalEnhance) { _, isEnabled in
            if !isEnabled {
                store.disableExperimentalEnhance()
            }
        }
        .onDisappear {
            originalPreviewPressTask?.cancel()
            originalPreviewPressTask = nil
            store.isShowingOriginal = false
        }
        .onChange(of: store.photos.map(\.id)) { _, photoIDs in
            exportedPhotoIDs.formIntersection(photoIDs)
            if photoIDs.isEmpty {
                pendingSharePhotoIDs = []
                didCompleteShare = false
                styleRailMode = .builtIn
            }
        }
        .sheet(isPresented: $showsSaveLookSheet) {
            SaveLookSheet(initialName: saveLookDefaultName) { name, includeAccent in
                guard let look = savedLooks.saveCurrent(
                    name: name,
                    settings: store.settings,
                    isAccentCustomized: store.isAccentCustomized,
                    includeAccent: includeAccent
                ) else { return }
                styleRailPosition = savedLookRailID(look)
                store.generateSavedLookThumbnails(savedLooks.looks)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !shareFiles.isEmpty },
                set: {
                    if !$0 {
                        store.cleanExportFiles(shareFiles)
                        shareFiles = []
                    }
                }
            ),
            onDismiss: {
                let completedPhotoIDs = pendingSharePhotoIDs
                pendingSharePhotoIDs = []
                guard didCompleteShare else { return }
                didCompleteShare = false
                registerCompletedExport(for: completedPhotoIDs)
            }
        ) {
            ShareSheet(items: shareFiles) { completed in
                didCompleteShare = completed
            }
            .ignoresSafeArea()
        }
        .sheet(item: $polaroidRequest) { request in
            PolaroidComposerSheet(
                photos: request.batch ? store.photos : store.currentPhoto.map { [$0] } ?? [],
                primaryActionShares: request.shares,
                showsMetadata: preferences.polaroidMetadata,
                showsMark: preferences.hibiscusMark,
                includesLocation: preferences.includeLocation,
                onComplete: { composition in
                    polaroidRequest = nil
                    performExport(
                        format: .polaroid,
                        batch: request.batch,
                        shares: request.shares,
                        polaroidComposition: composition
                    )
                }
            )
        }
        .sheet(item: $paletteRequest) { request in
            PaletteComposerSheet(
                photos: request.batch ? store.photos : store.currentPhoto.map { [$0] } ?? [],
                primaryActionShares: request.shares,
                showsMark: preferences.hibiscusMark,
                onComplete: { composition in
                    paletteRequest = nil
                    performExport(
                        format: .palette,
                        batch: request.batch,
                        shares: request.shares,
                        paletteComposition: composition
                    )
                }
            )
        }
        .sheet(isPresented: $showsAccentPicker) {
            AccentColorPickerSheet(
                color: Binding(
                    get: { store.settings.accent.color },
                    set: store.setCustomAccent
                ),
                isAutomatic: !store.isAccentCustomized,
                onUseAutomatic: store.useAutomaticAccent
            )
        }
        .sheet(item: $postExportDiscoveryRequest, onDismiss: {
            if !postExportDiscoveryOpenedEcosystem {
                preferences.recordExploreMoreDismissal()
            }
            postExportDiscoveryOpenedEcosystem = false
            presentingCompletionFlowID = nil
        }) { _ in
            PostExportDiscoveryView {
                guard !postExportDiscoveryOpenedEcosystem else { return }
                postExportDiscoveryOpenedEcosystem = true
                preferences.recordExploreMoreEcosystemOpen()
            }
        }
        .alert("Continue Editing?", isPresented: $showsCompletionPrompt) {
            Button("Continue Editing", role: .cancel) {
                completeExportFlow(done: false)
            }
            Button("Done", role: .destructive) {
                completeExportFlow(done: true)
            }
        } message: {
            Text("Your export is complete. Keep this temporary Grade session open?")
        }
        .alert("Rename Look", isPresented: $showsRenameLookAlert) {
            TextField("Name", text: $renameLookName)
            Button("Cancel", role: .cancel) {
                renameLookTarget = nil
            }
            Button("Save") {
                if let renameLookTarget {
                    savedLooks.rename(renameLookTarget, to: renameLookName)
                }
                renameLookTarget = nil
            }
            .disabled(renameLookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var photoArea: some View {
        if let source = store.sourceImage {
            ZStack(alignment: .bottom) {
                GradeMetalPreview(
                    renderer: store.previewRenderer,
                    isActive: isActive && !store.isShowingOriginal
                )
                    .background(Color(uiColor: .secondarySystemBackground))
                    .contentShape(Rectangle())
                    .onLongPressGesture(
                        minimumDuration: 0.38,
                        maximumDistance: 10,
                        pressing: { pressing in
                            originalPreviewPressTask?.cancel()
                            originalPreviewPressTask = nil
                            guard pressing else {
                                store.isShowingOriginal = false
                                return
                            }
                            originalPreviewPressTask = Task { @MainActor in
                                do {
                                    try await Task.sleep(for: .seconds(0.38))
                                } catch {
                                    return
                                }
                                guard !Task.isCancelled else { return }
                                store.isShowingOriginal = true
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                        },
                        perform: {}
                    )
                    .simultaneousGesture(photoPagingGesture)

                if let livePhoto = store.livePhotoPreview, !store.isShowingOriginal {
                    HibiscusLivePhotoView(
                        livePhoto: livePhoto,
                        onPlaybackEnded: store.dismissLivePhotoPreview
                    )
                    .background(Color(uiColor: .secondarySystemBackground))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                PhotoFitView(image: store.comparisonSourceImage ?? source)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .opacity(store.isShowingOriginal ? 1 : 0)
                    .allowsHitTesting(false)

                topPhotoActions
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)

                HStack(spacing: 8) {
                    if preferences.experimentalEnhance, store.currentPhoto?.livePhoto == nil {
                        enhanceButton
                    }
                    if store.currentPhoto?.livePhoto != nil {
                        livePhotoPlaybackButton
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

                if store.batchCount > 1 {
                    pageDots
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }

                if store.isShowingOriginal {
                    Text(LocalizedStringKey(
                        store.settings.enhance.isEnabled ? "Enhanced Original" : "Original"
                    ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .hibiscusGlass(tint: .black.opacity(0.32), in: Capsule())
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .offset(x: photoSwipeOffset)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Choose a photo to start")
                    .font(.title3.weight(.semibold))
                Button("Choose Photo") {
                    pendingStyle = nil
                    pickerReplacesSession = true
                    showsPicker = true
                }
                .hibiscusGlassButtonStyle(tint: .white)
                .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editor(width: CGFloat) -> some View {
        let padSize = max(1, (width - 40) / 2)

        return VStack(spacing: 11) {
            HStack(spacing: 10) {
                Button(action: store.undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .hibiscusGlass(interactive: true, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canUndo)
                .accessibilityLabel("Undo grade edit")

                Button {
                    styleRailMode = .builtIn
                    styleRailPosition = builtInStyleRailID(store.settings.style)
                    withAnimation(.snappy(duration: 0.22)) { store.isStyleRailExpanded = true }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(store.settings.style.tint).frame(width: 8, height: 8)
                        Text(store.settings.style.rawValue)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .hibiscusGlass(interactive: true, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: store.redo) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .hibiscusGlass(interactive: true, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canRedo)
                .accessibilityLabel("Redo grade edit")
            }
            .frame(height: 36)

            HStack(alignment: .top, spacing: 12) {
                padColumn(kind: .style, size: padSize)
                padColumn(kind: .accent, size: padSize)
            }
            .padding(.horizontal, 14)

            VStack(spacing: 5) {
                HStack {
                    Text(LocalizedStringKey(store.activeSurface == .style ? "Style Strength" : "Accent Strength"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(currentStrength * 100))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { currentStrength }, set: store.updateStrength), in: 0...1)
                    .tint(store.activeSurface == .style ? store.settings.style.tint : store.settings.accent.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .hibiscusGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 6)

        }
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    private func padColumn(kind: ActiveGradeSurface, size: CGFloat) -> some View {
        return VStack(spacing: 6) {
            GradePad(
                kind: kind,
                style: store.settings.style,
                accent: store.settings.accent,
                point: kind == .style ? store.settings.stylePoint : store.settings.accentPoint,
                onActivate: {
                    collapseStyleRailIfNeeded()
                    store.activate(kind)
                },
                onChange: kind == .style ? store.updateStylePoint : store.updateAccentPoint
            )
            .frame(width: size, height: size)

            ZStack {
                Text(LocalizedStringKey(kind == .style ? store.settings.style.rawValue : "Accent"))
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                if kind == .accent {
                    Button {
                        showsAccentPicker = true
                    } label: {
                        Circle()
                            .fill(store.settings.accent.color)
                            .frame(width: 13, height: 13)
                            .overlay { Circle().stroke(.primary.opacity(0.24), lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .offset(x: 34)
                    .accessibilityLabel("Select Accent color")
                }
            }
            .frame(height: 44)
            .foregroundStyle(.secondary)
        }
        .frame(width: size)
    }

    private var styleRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                if styleRailMode == .builtIn {
                    ForEach(GradeStyle.allCases) { style in
                        builtInStyleRailItem(style)
                            .id(builtInStyleRailID(style))
                    }

                    Button {
                        store.generateSavedLookThumbnails(savedLooks.looks)
                        withAnimation(.snappy(duration: 0.22)) {
                            styleRailMode = .savedLooks
                            styleRailPosition = saveLookRailID
                        }
                    } label: {
                        railActionTile(
                            title: "My Looks",
                            systemImage: "bookmark.fill",
                            tint: .hibiscusAccent
                        )
                    }
                    .buttonStyle(.plain)
                    .id(myLooksRailID)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                styleRailMode = .builtIn
                                styleRailPosition = builtInStyleRailID(store.settings.style)
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 27, height: 46)
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .hibiscusGlass(
                                    tint: .hibiscusAccent,
                                    interactive: true,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Styles")

                        Button {
                            saveLookDefaultName = L10n.format("%@ Look", store.settings.style.rawValue)
                            showsSaveLookSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 27, height: 46)
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .hibiscusGlass(
                                    interactive: true,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Save Current Look")
                    }
                    .frame(width: 60, height: 46)
                    .id(saveLookRailID)

                    if savedLooks.looks.isEmpty {
                        Text("No saved looks yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 116, height: 68)
                    } else {
                        ForEach(savedLooks.looks) { look in
                            savedLookRailItem(look)
                                .id(savedLookRailID(look))
                        }
                    }

                }
            }
            .padding(.horizontal, 14)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $styleRailPosition, anchor: .center)
        .onAppear {
            styleRailPosition = styleRailMode == .builtIn
                ? builtInStyleRailID(store.settings.style)
                : saveLookRailID
            if styleRailMode == .savedLooks {
                store.generateSavedLookThumbnails(savedLooks.looks)
            }
        }
        .onChange(of: savedLooks.looks) { _, looks in
            guard styleRailMode == .savedLooks else { return }
            store.generateSavedLookThumbnails(looks)
        }
        .onChange(of: store.settings) { _, _ in
            guard styleRailMode == .savedLooks else { return }
            store.generateSavedLookThumbnails(savedLooks.looks)
        }
        .onChange(of: store.automaticAccent) { _, _ in
            guard styleRailMode == .savedLooks else { return }
            store.generateSavedLookThumbnails(savedLooks.looks)
        }
        .onChange(of: store.currentIndex) { _, _ in
            guard styleRailMode == .savedLooks else { return }
            store.generateSavedLookThumbnails(savedLooks.looks)
        }
        .animation(.snappy(duration: 0.22), value: styleRailMode)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .hibiscusGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func builtInStyleRailItem(_ style: GradeStyle) -> some View {
        Button {
            styleRailPosition = builtInStyleRailID(style)
            if store.sourceImage == nil {
                pendingStyle = style
                pickerReplacesSession = true
                showsPicker = true
            } else {
                withAnimation(.snappy(duration: 0.22)) { store.selectStyle(style) }
            }
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let thumbnail = store.thumbnails[style] {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [style.tint.opacity(0.35), style.tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: 60, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            store.settings.style == style ? Color.primary : Color.primary.opacity(0.10),
                            lineWidth: store.settings.style == style ? 1.5 : 0.5
                        )
                }
                .hibiscusGlass(
                    .clear,
                    interactive: true,
                    isEnabled: store.settings.style == style,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

                Text(style.rawValue)
                    .font(.caption2.weight(store.settings.style == style ? .bold : .medium))
                    .foregroundStyle(store.settings.style == style ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func savedLookRailItem(_ look: SavedLook) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                store.applySavedLook(look)
            }
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let thumbnail = store.savedLookThumbnails[look.id] {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [look.style.tint.opacity(0.30), look.style.tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: 60, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
                .animation(.easeInOut(duration: 0.18), value: store.savedLookThumbnails[look.id] != nil)

                Text(look.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 60)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameLookTarget = look
                renameLookName = look.name
                showsRenameLookAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                savedLooks.delete(look)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func railActionTile(title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: 60, height: 46)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 60)
        }
        .frame(width: 60)
    }

    private func builtInStyleRailID(_ style: GradeStyle) -> String { "style.\(style.rawValue)" }
    private func savedLookRailID(_ look: SavedLook) -> String { "look.\(look.id.uuidString)" }
    private var myLooksRailID: String { "my-looks" }
    private var saveLookRailID: String { "save-look" }

    private func collapseStyleRailIfNeeded() {
        guard store.isStyleRailExpanded else { return }
        withAnimation(.snappy(duration: 0.22)) {
            store.isStyleRailExpanded = false
        }
    }

    private var topPhotoActions: some View {
        photoActionsMenu
    }

    private var enhanceButton: some View {
        Button(action: store.toggleEnhance) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.settings.enhance.isEnabled ? Color.hibiscusAccent : .white)
                .frame(width: 19, height: 19)
        }
        .hibiscusGlassButtonStyle()
        .accessibilityLabel(store.settings.enhance.isEnabled ? "Turn Enhance off" : "Enhance")
    }

    private var livePhotoPlaybackButton: some View {
        Button(action: store.playLivePhoto) {
            HStack(spacing: 5) {
                if store.isPreparingLivePhotoPreview {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "livephoto")
                }
                Text("LIVE")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .hibiscusGlass(tint: .black.opacity(0.25), interactive: true, in: Capsule())
            .frame(minWidth: 76, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isPreparingLivePhotoPreview)
        .accessibilityLabel("Play Live Photo")
    }

    private var photoActionsMenu: some View {
        Menu {
            exportDestinationMenu(batch: false, shares: false)
            exportDestinationMenu(batch: false, shares: true)

            if store.batchCount > 1 {
                exportDestinationMenu(batch: true, shares: false)
                exportDestinationMenu(batch: true, shares: true)
            }

            Divider()

            if store.batchCount > 1 {
                Button {
                    store.applyStyleToAll()
                } label: {
                    Label("Apply Style to All", systemImage: "rectangle.on.rectangle")
                }
            }

            Button {
                pendingStyle = nil
                pickerReplacesSession = false
                showsPicker = true
            } label: {
                Label("Add Photos", systemImage: "photo.stack")
            }
            .disabled(store.batchCount >= 10)

            Button {
                pendingStyle = store.settings.style
                pickerReplacesSession = true
                showsPicker = true
            } label: {
                Label("Replace All", systemImage: "photo.on.rectangle")
            }

            Button(role: .destructive) {
                store.removePhoto()
            } label: {
                Label {
                    Text(LocalizedStringKey(store.batchCount > 1 ? "Remove Current" : "Remove"))
                } icon: {
                    Image(systemName: "trash")
                }
            }

            if store.batchCount > 1 {
                Button(role: .destructive) {
                    store.removeAllPhotos()
                } label: {
                    Label("Remove All", systemImage: "trash.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 19, height: 19)
        }
        .hibiscusGlassButtonStyle()
        .accessibilityLabel("Photo actions")
        .menuOrder(.fixed)
        .disabled(store.isExporting)
    }

    private func exportDestinationMenu(batch: Bool, shares: Bool) -> some View {
        let containsLivePhoto = hasLivePhoto(batch: batch)
        return Menu {
            if !shares, containsLivePhoto {
                Button {
                    performLivePhotoExport(batch: batch)
                } label: {
                    Label("Live Photo", systemImage: "livephoto")
                }
                Divider()
            }
            ForEach(HibiscusExportFormat.allCases) { format in
                Button {
                    requestExport(format: format, batch: batch, shares: shares)
                } label: {
                    Label {
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(format.rawValue))
                            if containsLivePhoto {
                                Text("(Static)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: format.systemImage)
                    }
                }
            }
        } label: {
            Label {
                Text(LocalizedStringKey(exportActionTitle(batch: batch, shares: shares)))
            } icon: {
                Image(systemName: shares ? "square.and.arrow.up" : "square.and.arrow.down")
            }
        }
    }

    private func hasLivePhoto(batch: Bool) -> Bool {
        if batch { return store.photos.contains { $0.livePhoto != nil } }
        return store.currentPhoto?.livePhoto != nil
    }

    private func performLivePhotoExport(batch: Bool) {
        let photoIDs: Set<UUID>
        if batch {
            photoIDs = Set(store.photos.filter { $0.livePhoto != nil }.map(\.id))
        } else if let photo = store.currentPhoto, photo.livePhoto != nil {
            photoIDs = [photo.id]
        } else {
            photoIDs = []
        }
        store.saveLivePhotos(batch: batch) { success in
            if success { registerCompletedExport(for: photoIDs) }
        }
    }

    private func exportActionTitle(batch: Bool, shares: Bool) -> String {
        switch (batch, shares) {
        case (false, false): "Export Current"
        case (false, true): "Share Current"
        case (true, false): "Export All"
        case (true, true): "Share All"
        }
    }

    private func requestExport(format: HibiscusExportFormat, batch: Bool, shares: Bool) {
        switch format {
        case .polaroid:
            polaroidRequest = PolaroidExportRequest(batch: batch, shares: shares)
        case .palette:
            paletteRequest = PaletteExportRequest(batch: batch, shares: shares)
        case .photo:
            performExport(format: format, batch: batch, shares: shares)
        }
    }

    private func performExport(
        format: HibiscusExportFormat,
        batch: Bool,
        shares: Bool,
        polaroidComposition: PolaroidComposition = .empty,
        paletteComposition: PaletteComposition = .standard
    ) {
        Task {
            await Task.yield()
            let requestedPhotoIDs = batch
                ? store.photos.map(\.id)
                : store.currentPhoto.map { [$0.id] } ?? []
            let files = await store.exportFiles(
                format: format,
                batch: batch,
                polaroidComposition: polaroidComposition,
                paletteComposition: paletteComposition
            )
            guard !files.isEmpty else {
                store.statusMessage = L10n.string("Couldn’t render this export.")
                return
            }
            let completedPhotoIDs = files.count == requestedPhotoIDs.count
                ? Set(requestedPhotoIDs)
                : []
            if shares {
                pendingSharePhotoIDs = completedPhotoIDs
                shareFiles = files
            } else {
                store.saveFilesToPhotos(files) { success in
                    if success {
                        registerCompletedExport(for: completedPhotoIDs)
                    }
                }
            }
        }
    }

    private func registerCompletedExport(for photoIDs: Set<UUID>) {
        guard !photoIDs.isEmpty else { return }
        let sessionPhotoIDs = Set(store.photos.map(\.id))
        guard !sessionPhotoIDs.isEmpty else { return }
        exportedPhotoIDs.formUnion(photoIDs)
        exportedPhotoIDs.formIntersection(sessionPhotoIDs)
        guard sessionPhotoIDs.isSubset(of: exportedPhotoIDs),
              pendingCompletionFlowID == nil,
              presentingCompletionFlowID == nil,
              postExportDiscoveryRequest == nil else { return }
        pendingCompletionFlowID = UUID()
        showsCompletionPrompt = true
    }

    private func completeExportFlow(done: Bool) {
        guard let flowID = pendingCompletionFlowID else { return }
        pendingCompletionFlowID = nil
        presentingCompletionFlowID = flowID
        showsCompletionPrompt = false
        if done {
            // Cleanup belongs to the Done decision only. Discovery dismissal
            // must never run it a second time.
            store.removeAllPhotos()
            exportedPhotoIDs = []
        }
        guard preferences.shouldPresentExploreMoreAfterExport() else {
            presentingCompletionFlowID = nil
            return
        }
        postExportDiscoveryOpenedEcosystem = false
        Task { @MainActor in
            await Task.yield()
            postExportDiscoveryRequest = PostExportDiscoveryRequest(id: flowID)
        }
    }

    private var currentStrength: Double {
        store.activeSurface == .style ? store.settings.styleStrength : store.settings.accentStrength
    }

    private var pageDots: some View {
        GeometryReader { proxy in
            HStack(spacing: 6) {
                ForEach(store.photos.indices, id: \.self) { index in
                    Circle()
                        .fill(index == store.currentIndex ? Color.white : Color.white.opacity(0.38))
                        .frame(width: index == store.currentIndex ? 7 : 5, height: index == store.currentIndex ? 7 : 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard store.batchCount > 1 else { return }
                        let progress = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                        let index = Int((progress * CGFloat(store.batchCount - 1)).rounded())
                        store.selectPhoto(at: index)
                    }
            )
        }
        .frame(width: max(48, CGFloat(store.batchCount) * 13), height: 28)
        .hibiscusGlass(tint: .black.opacity(0.24), in: Capsule())
        .accessibilityLabel("Photo selector")
        .accessibilityValue(L10n.format("Photo %lld of %lld", Int64(store.currentIndex + 1), Int64(store.batchCount)))
    }

    private var photoPagingGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard store.batchCount > 1,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                photoSwipeOffset = value.translation.width * 0.28
            }
            .onEnded { value in
                defer {
                    withAnimation(.snappy(duration: 0.2)) { photoSwipeOffset = 0 }
                }
                guard store.batchCount > 1,
                      abs(value.translation.width) > abs(value.translation.height),
                      abs(value.predictedEndTranslation.width) > 45 else { return }
                let direction = value.predictedEndTranslation.width < 0 ? 1 : -1
                let nextIndex = min(store.batchCount - 1, max(0, store.currentIndex + direction))
                store.selectPhoto(at: nextIndex)
            }
    }

    // The floating tab bar consumes roughly the bottom safe-area height. Keeping
    // this clearance separate from the editor's own 10-point bottom padding
    // matches the Camera panel without letting Strength slip beneath the bar.
    private var navigationClearance: CGFloat { 34 }

    private var photoPickerLimit: Int {
        pickerReplacesSession ? 10 : max(1, 10 - store.batchCount)
    }

    private func photoHeight(for availableHeight: CGFloat) -> CGFloat {
        if store.sourceImage == nil { return availableHeight }
        let editorReserve: CGFloat = 368
        return min(availableHeight * 0.53, max(280, availableHeight - editorReserve), 438)
    }

    private func importPhotos(from items: [PhotosPickerItem]) async {
        var imports: [GradeImportItem] = []
        var flattenedLivePhoto = false
        for item in items.prefix(10) {
            let result = await LivePhotoImportLoader.load(item)
            if let imported = result.item { imports.append(imported) }
            flattenedLivePhoto = flattenedLivePhoto || result.livePhotoWasFlattened
        }
        await MainActor.run {
            if imports.isEmpty {
                store.statusMessage = L10n.string("These photos couldn’t be opened.")
            } else {
                store.loadBatch(imports, preferredStyle: pendingStyle, replacing: pickerReplacesSession)
                if flattenedLivePhoto {
                    store.statusMessage = L10n.string("Allow full Photos access to preserve Live Photos.")
                }
            }
            pendingStyle = nil
            pickerItems = []
        }
    }
}

private enum GradeStyleRailMode {
    case builtIn
    case savedLooks
}

private struct SaveLookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var includeAccent = false
    let onSave: (String, Bool) -> Void

    init(initialName: String, onSave: @escaping (String, Bool) -> Void) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("Include Accent", isOn: $includeAccent)
                    .tint(.hibiscusAccent)
            }
            .navigationTitle("Save Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, includeAccent)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
    }
}

private struct PolaroidExportRequest: Identifiable {
    let id = UUID()
    let batch: Bool
    let shares: Bool
}

private struct PaletteExportRequest: Identifiable {
    let id = UUID()
    let batch: Bool
    let shares: Bool
}

private struct PostExportDiscoveryRequest: Identifiable {
    let id: UUID
}

struct AccentColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var color: Color
    let isAutomatic: Bool
    let onUseAutomatic: () -> Void

    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double

    init(
        color: Binding<Color>,
        isAutomatic: Bool,
        onUseAutomatic: @escaping () -> Void
    ) {
        _color = color
        self.isAutomatic = isAutomatic
        self.onUseAutomatic = onUseAutomatic

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(color.wrappedValue).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        _hue = State(initialValue: Double(hue))
        _saturation = State(initialValue: Double(max(0.35, saturation)))
        _brightness = State(initialValue: Double(max(0.45, brightness)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Circle()
                    .fill(color)
                    .frame(width: 54, height: 54)
                    .overlay { Circle().stroke(.primary.opacity(0.18), lineWidth: 0.5) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Color")
                        .font(.subheadline.weight(.semibold))
                    AccentHueStrip(hue: $hue) {
                        saturation = max(0.58, saturation)
                        brightness = max(0.62, brightness)
                        updateColor()
                    }
                    .frame(height: 38)

                    Text("Saturation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $saturation, in: 0...1)
                        .onChange(of: saturation) { _, _ in updateColor() }

                    Text("Lightness")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 0.25...1)
                        .onChange(of: brightness) { _, _ in updateColor() }
                }
                .padding(16)
                .hibiscusGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    onUseAutomatic()
                    dismiss()
                } label: {
                    HStack {
                        Label("Automatic Accent", systemImage: "wand.and.stars")
                        Spacer()
                        if isAutomatic { Image(systemName: "checkmark") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .hibiscusGlassButtonStyle()

                Spacer()
            }
            .padding(18)
            .navigationTitle("Accent Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func updateColor() {
        color = Color(
            uiColor: UIColor(
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                alpha: 1
            )
        )
    }
}

struct AccentHueStrip: View {
    @Binding var hue: Double
    let onChange: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(Capsule())

                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .overlay { Circle().stroke(.black.opacity(0.26), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.34), radius: 3, y: 1)
                    .offset(x: min(1, max(0, hue)) * max(0, proxy.size.width - 24))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                        onChange()
                    }
            )
        }
    }
}

private struct ComposerPageDots: View {
    let count: Int
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    guard selection != index else { return }
                    selection = index
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Circle()
                        .fill(index == selection ? Color.white : Color.white.opacity(0.38))
                        .frame(width: index == selection ? 7 : 5, height: index == selection ? 7 : 5)
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("Photo %lld", Int64(index + 1)))
                .accessibilityValue(L10n.string(index == selection ? "Selected" : "Not selected"))
            }
        }
        .frame(minWidth: 52)
        .frame(height: 28)
        .hibiscusGlass(in: Capsule())
        .animation(.snappy(duration: 0.18), value: selection)
        .frame(maxWidth: 380)
        .contentShape(Rectangle())
        .modifier(ComposerPageSwipeModifier(count: count, selection: $selection))
        .accessibilityLabel("Export photo selector")
        .accessibilityValue(L10n.format("Photo %lld of %lld", Int64(selection + 1), Int64(count)))
    }
}

private struct ComposerPageSwipeModifier: ViewModifier {
    let count: Int
    @Binding var selection: Int
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.simultaneousGesture(pagingGesture)
        } else {
            content
        }
    }

    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard count > 1,
                      abs(value.translation.width) > abs(value.translation.height),
                      abs(value.predictedEndTranslation.width) > 40 else { return }
                let direction = value.predictedEndTranslation.width < 0 ? 1 : -1
                let nextSelection = min(count - 1, max(0, selection + direction))
                guard nextSelection != selection else { return }
                selection = nextSelection
                UISelectionFeedbackGenerator().selectionChanged()
            }
    }
}

private struct PaletteComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [GradeSessionPhoto]
    let primaryActionShares: Bool
    let showsMark: Bool
    let onComplete: (PaletteComposition) -> Void

    @State private var currentIndex = 0
    @State private var previewImage: UIImage?
    @State private var candidates: [AccentColor] = []
    @State private var selectedIndices: Set<Int> = []
    @State private var showsHexCodes = false
    @State private var selectionMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                GeometryReader { proxy in
                    let cardSize = fittedCardSize(in: proxy.size)
                    paletteCard(size: cardSize)
                        .frame(width: cardSize.width, height: cardSize.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .modifier(ComposerPageSwipeModifier(count: photos.count, selection: $currentIndex))

                if photos.count > 1 {
                    ComposerPageDots(count: photos.count, selection: $currentIndex)
                }

                VStack(spacing: 11) {
                    HStack {
                        Text("Choose 1–5 colors")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(selectedIndices.count) selected")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(candidates.enumerated()), id: \.offset) { index, color in
                                Button {
                                    toggleColor(at: index)
                                } label: {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 42, height: 42)
                                        .overlay {
                                            Circle().stroke(.primary.opacity(0.20), lineWidth: 0.5)
                                            if selectedIndices.contains(index) {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(contrastingColor(for: color))
                                            }
                                        }
                                        .frame(width: 48, height: 48)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.format("Color %lld", Int64(index + 1)))
                                .accessibilityValue(L10n.string(selectedIndices.contains(index) ? "Selected" : "Not selected"))
                            }
                        }
                        .padding(.horizontal, 1)
                    }

                    Button {
                        showsHexCodes.toggle()
                    } label: {
                        HStack {
                            Text("Show hex codes")
                            Spacer()
                            Image(systemName: showsHexCodes ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(showsHexCodes ? Color.hibiscusAccent : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if let selectionMessage {
                        Text(selectionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if exportCount > 1 {
                        Text("Each photo keeps its own extracted colors.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .hibiscusGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: 420)

                Button {
                    let composition = PaletteComposition(
                        selectedIndices: selectedIndices.sorted(),
                        showsHexCodes: showsHexCodes,
                        showsMark: showsMark
                    )
                    onComplete(composition)
                    dismiss()
                } label: {
                    Label {
                        Text(LocalizedStringKey(primaryActionShares ? "Share" : "Export to Photos"))
                    } icon: {
                        Image(systemName: primaryActionShares ? "square.and.arrow.up" : "square.and.arrow.down")
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 420)
                .hibiscusGlassButtonStyle(tint: .white)
                .foregroundStyle(.black)
                .disabled(selectedIndices.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .navigationTitle("Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: currentPhoto?.id) {
            previewImage = nil
            guard let photoID = currentPhoto?.id, let sourceImage else { return }
            let settings = currentSettings
            let result = await Task.detached(priority: .userInitiated) {
                autoreleasepool { () -> (UIImage?, [AccentColor]) in
                    let rendered = ImageRenderer.gradeImage(sourceImage, settings: settings, maxDimension: 1800)
                    let analysisImage = rendered ?? sourceImage
                    return (rendered, PaletteAnalyzer.colors(from: analysisImage, count: 5))
                }
            }.value
            guard currentPhoto?.id == photoID else { return }
            previewImage = result.0
            candidates = result.1
            let availableSelection = selectedIndices.filter { $0 < result.1.count }
            selectedIndices = availableSelection.isEmpty
                ? Set(0..<min(5, result.1.count))
                : Set(availableSelection)
        }
    }

    private var currentPhoto: GradeSessionPhoto? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    private var sourceImage: UIImage? { currentPhoto?.image }
    private var currentSettings: GradeSettings { currentPhoto?.settings ?? GradeSettings() }
    private var exportCount: Int { photos.count }

    private func paletteCard(size: CGSize) -> some View {
        let image = previewImage ?? sourceImage
        let photoHeight = size.width * photoHeightRatio(for: image)
        let colorHeight = size.width * (150 / 1800)
        let brandHeight = showsMark ? size.width * (180 / 1800) : 0
        let selectedColors = selectedIndices.sorted().compactMap { index in
            candidates.indices.contains(index) ? candidates[index] : nil
        }
        let hexTextColor = Color(uiColor: HibiscusExportRenderer.paletteHexTextColor(for: selectedColors))

        return VStack(spacing: 0) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.secondary.opacity(0.16)
                }
            }
            .frame(width: size.width, height: photoHeight)

            HStack(spacing: 0) {
                ForEach(Array(selectedColors.enumerated()), id: \.offset) { _, color in
                    ZStack {
                        color.color
                        if showsHexCodes {
                            Text(hexString(for: color))
                                .font(.system(size: max(7, size.width * 0.016), weight: .semibold, design: .monospaced))
                                .foregroundStyle(hexTextColor)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                                .padding(.horizontal, 2)
                        }
                    }
                }
            }
            .frame(height: colorHeight)

            if showsMark {
                VStack(spacing: size.width * 0.006) {
                    HibiscusAppIcon()
                        .frame(width: size.width * 0.042, height: size.width * 0.042)
                    Text("Hibiscus")
                        .font(.system(size: size.width * 0.019, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.66))
                }
                .frame(width: size.width, height: brandHeight)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(red: 0.965, green: 0.958, blue: 0.938))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 12, y: 6)
    }

    private func fittedCardSize(in available: CGSize) -> CGSize {
        let footerHeight: CGFloat = showsMark ? 330 : 150
        let ratio = photoHeightRatio(for: previewImage ?? sourceImage) + (footerHeight / 1800)
        let aspect = 1 / ratio
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func photoHeightRatio(for image: UIImage?) -> CGFloat {
        guard let image else { return 0.75 }
        let ratio = image.size.width / max(1, image.size.height)
        return max(0.55, min(1.8, 1 / max(0.01, ratio)))
    }

    private func toggleColor(at index: Int) {
        if selectedIndices.contains(index) {
            guard selectedIndices.count > 1 else {
                selectionMessage = L10n.string("Keep at least one color.")
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            selectedIndices.remove(index)
        } else {
            guard selectedIndices.count < 5 else {
                selectionMessage = L10n.string("A Palette can contain up to five colors.")
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            selectedIndices.insert(index)
        }
        selectionMessage = nil
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func hexString(for color: AccentColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int(min(1, max(0, color.red)) * 255),
            Int(min(1, max(0, color.green)) * 255),
            Int(min(1, max(0, color.blue)) * 255)
        )
    }

    private func contrastingColor(for color: AccentColor) -> Color {
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.24 ? .black.opacity(0.82) : .white.opacity(0.92)
    }
}

private struct PolaroidComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let photos: [GradeSessionPhoto]
    let primaryActionShares: Bool
    let showsMetadata: Bool
    let showsMark: Bool
    let includesLocation: Bool
    let onComplete: (PolaroidComposition) -> Void

    @State private var currentIndex = 0
    @State private var previewImage: UIImage?
    @State private var drawing = PKDrawing()
    @State private var drawingCanvasSize: CGSize = .zero
    @State private var mode: PolaroidComposerMode = .crop
    @State private var cropScale = 1.0
    @State private var cropScaleStart = 1.0
    @State private var cropOffset = CGPoint.zero
    @State private var cropOffsetStart = CGPoint.zero
    @State private var hasPrinted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { proxy in
                    let cardSize = fittedCardSize(in: proxy.size)
                    polaroidCard(size: cardSize)
                        .frame(width: cardSize.width, height: cardSize.height)
                        .offset(y: hasPrinted ? 0 : -cardSize.height * 0.86)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if photos.count > 1 {
                    ComposerPageDots(count: photos.count, selection: $currentIndex)
                }

                Text(composerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                Button {
                    let composition = PolaroidComposition(
                        drawingData: drawing.dataRepresentation(),
                        drawingCanvasSize: drawingCanvasSize,
                        cropScale: cropScale,
                        cropOffset: cropOffset,
                        showsMetadata: showsMetadata,
                        showsMark: showsMark,
                        includesLocation: includesLocation
                    )
                    onComplete(composition)
                    dismiss()
                } label: {
                    Label {
                        Text(LocalizedStringKey(primaryActionShares ? "Share" : "Export to Photos"))
                    } icon: {
                        Image(systemName: primaryActionShares ? "square.and.arrow.up" : "square.and.arrow.down")
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 380)
                .hibiscusGlassButtonStyle(tint: .white)
                .foregroundStyle(.black)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .navigationTitle("Instant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        mode = .crop
                    } label: {
                        Image(systemName: "crop")
                    }
                    .tint(mode == .crop ? .primary : .secondary)
                    .accessibilityLabel("Adjust photo crop")

                    Button {
                        mode = mode == .draw ? .crop : .draw
                    } label: {
                        Image(systemName: mode == .draw ? "checkmark" : "pencil.tip")
                    }
                    .tint(mode == .draw ? .primary : .secondary)
                    .accessibilityLabel(L10n.string(mode == .draw ? "Finish drawing" : "Draw with PencilKit"))

                    if mode == .crop, cropScale != 1 || cropOffset != .zero {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                cropScale = 1
                                cropScaleStart = 1
                                cropOffset = .zero
                                cropOffsetStart = .zero
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .accessibilityLabel("Reset crop")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            guard !hasPrinted else { return }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) {
                hasPrinted = true
            }
        }
        .task(id: currentPhoto?.id) {
            previewImage = nil
            guard let photoID = currentPhoto?.id, let sourceImage else { return }
            let settings = currentSettings
            let rendered = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    ImageRenderer.gradeImage(sourceImage, settings: settings, maxDimension: 1800)
                }
            }.value
            guard currentPhoto?.id == photoID else { return }
            previewImage = rendered
        }
    }

    private var currentPhoto: GradeSessionPhoto? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    private var sourceImage: UIImage? { currentPhoto?.image }
    private var currentSettings: GradeSettings { currentPhoto?.settings ?? GradeSettings() }
    private var settings: GradeSettings { currentSettings }
    private var metadata: PhotoMetadata { currentPhoto?.metadata ?? PhotoMetadata() }
    private var exportCount: Int { photos.count }

    private func polaroidCard(size: CGSize) -> some View {
        let inset = size.width * 0.05
        let photoSize = size.width * 0.9
        return ZStack(alignment: .topLeading) {
            Color(red: 0.955, green: 0.947, blue: 0.918)

            Group {
                if let image = previewImage ?? sourceImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: photoSize, height: photoSize)
                        .scaleEffect(cropScale)
                        .offset(x: cropOffset.x * photoSize, y: cropOffset.y * photoSize)
                } else {
                    Color.secondary.opacity(0.16)
                }
            }
            .frame(width: photoSize, height: photoSize)
            .clipped()
            .offset(x: inset, y: inset)
            .contentShape(Rectangle())
            .allowsHitTesting(mode == .crop)
            .gesture(cropDragGesture(photoSize: photoSize))
            .simultaneousGesture(cropMagnificationGesture)

            if showsMetadata {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(polaroidMetadataLines, id: \.self) { line in
                        Text(line)
                    }
                }
                .font(.system(size: max(6, size.width * 0.012), weight: .medium, design: .monospaced))
                .foregroundStyle(.black.opacity(0.58))
                .frame(width: size.width * 0.61, alignment: .leading)
                .position(x: size.width * 0.36, y: size.height * 0.855)
                .allowsHitTesting(false)
            }

            if showsMark {
                VStack(spacing: size.width * 0.018) {
                    HibiscusAppIcon()
                        .frame(width: size.width * 0.073, height: size.width * 0.073)
                    Text("Hibiscus")
                        .font(.system(size: size.width * 0.027, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.66))
                }
                .position(x: showsMetadata ? size.width * 0.86 : size.width / 2, y: size.height * 0.865)
                .allowsHitTesting(false)
            }

            PencilCanvasView(drawing: $drawing, isActive: mode == .draw)
                .onAppear { drawingCanvasSize = size }
                .onChange(of: size) { _, newSize in drawingCanvasSize = newSize }
                .allowsHitTesting(mode == .draw)

            if photos.count > 1, mode != .draw {
                let pagingAreaTop = inset + photoSize
                Color.clear
                    .frame(width: size.width, height: max(1, size.height - pagingAreaTop))
                    .contentShape(Rectangle())
                    .offset(y: pagingAreaTop)
                    .modifier(ComposerPageSwipeModifier(count: photos.count, selection: $currentIndex))
                    .accessibilityLabel("Swipe between Instant photos")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
    }

    private func fittedCardSize(in available: CGSize) -> CGSize {
        let aspect = 1800.0 / 2320.0
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func cropDragGesture(photoSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let proposed = CGPoint(
                    x: cropOffsetStart.x + value.translation.width / max(1, photoSize),
                    y: cropOffsetStart.y + value.translation.height / max(1, photoSize)
                )
                cropOffset = clampedCropOffset(proposed, scale: cropScale)
            }
            .onEnded { _ in cropOffsetStart = cropOffset }
    }

    private var cropMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                cropScale = min(3, max(1, cropScaleStart * value))
                cropOffset = clampedCropOffset(cropOffset, scale: cropScale)
            }
            .onEnded { _ in
                cropScaleStart = cropScale
                cropOffsetStart = cropOffset
            }
    }

    private func clampedCropOffset(_ offset: CGPoint, scale: Double) -> CGPoint {
        guard let image = previewImage ?? sourceImage else { return .zero }
        let ratio = image.size.width / max(1, image.size.height)
        let baseWidth = max(1, ratio)
        let baseHeight = max(1, 1 / ratio)
        let maxX = max(0, (baseWidth * scale - 1) / 2)
        let maxY = max(0, (baseHeight * scale - 1) / 2)
        return CGPoint(
            x: min(maxX, max(-maxX, offset.x)),
            y: min(maxY, max(-maxY, offset.y))
        )
    }

    private var composerHint: String {
        switch mode {
        case .crop:
            L10n.string("Drag and pinch the photo to choose its crop.")
        case .draw:
            exportCount > 1
                ? L10n.format("Draw anywhere. The same drawing is added to all %lld cards.", Int64(exportCount))
                : L10n.string("Use the system PencilKit tools to draw anywhere on the card.")
        }
    }

    private var polaroidMetadataLines: [String] {
        var lines: [String] = []
        if let date = metadata.date {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(formatter.string(from: date).uppercased())
        }
        if includesLocation, let location = metadata.displayLocation { lines.append(location.uppercased()) }
        let camera = metadata.cameraCharacter.map { "\($0.symbol) \($0.name.uppercased()) · " } ?? ""
        lines.append("\(camera)\(settings.style.rawValue.uppercased())")
        return Array(lines.prefix(3))
    }

}

private enum PolaroidComposerMode {
    case crop
    case draw
}

private struct PencilCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.delegate = context.coordinator
        canvas.alwaysBounceHorizontal = false
        canvas.alwaysBounceVertical = false
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
        canvas.isUserInteractionEnabled = isActive
        context.coordinator.updateToolPicker(for: canvas, isActive: isActive)
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.updateToolPicker(for: canvas, isActive: false)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private var drawing: Binding<PKDrawing>
        private let toolPicker = PKToolPicker()
        private var isToolPickerActive = false

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }

        func updateToolPicker(for canvas: PKCanvasView, isActive: Bool) {
            guard isActive != isToolPickerActive else { return }
            isToolPickerActive = isActive
            if isActive {
                canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
                toolPicker.addObserver(canvas)
                toolPicker.setVisible(true, forFirstResponder: canvas)
                DispatchQueue.main.async { canvas.becomeFirstResponder() }
            } else {
                toolPicker.setVisible(false, forFirstResponder: canvas)
                toolPicker.removeObserver(canvas)
                canvas.resignFirstResponder()
            }
        }
    }
}

private struct HibiscusAppIcon: View {
    var body: some View {
        Group {
            if let icon = HibiscusBrand.appIcon() {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}
