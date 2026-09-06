import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var preferences: AppPreferences
    @EnvironmentObject private var languageManager: LanguageManager
    @EnvironmentObject private var remoteContent: RemoteContentManager
#if DEBUG && targetEnvironment(simulator)
    @EnvironmentObject private var simulatorDemoMode: SimulatorDemoMode
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    NavigationLink {
                        LanguageSelectionView()
                    } label: {
                        HStack {
                            Text("Language")
                            Spacer()
                            Text(languageManager.mode.titleKey)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

#if DEBUG && targetEnvironment(simulator)
                Section {
                    Toggle("Demo Camera", isOn: $simulatorDemoMode.isCameraEnabled)
                        .disabled(simulatorDemoMode.photos.isEmpty)

                    Picker("Camera Photo", selection: $simulatorDemoMode.selectedPhotoID) {
                        ForEach(simulatorDemoMode.photos) { photo in
                            Text(photo.displayName).tag(photo.id)
                        }
                    }
                    .disabled(simulatorDemoMode.photos.isEmpty)

                    NavigationLink {
                        SimulatorDemoPhotoSelectionView()
                    } label: {
                        HStack {
                            Text("Demo Photos")
                            Spacer()
                            Text("\(simulatorDemoMode.selectedGradePhotoIDs.count) selected")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        simulatorDemoMode.requestCurrentPhotoForGrade()
                    } label: {
                        Label("Import Current Demo Photo to Grade", systemImage: "photo.badge.plus")
                    }
                    .disabled(simulatorDemoMode.selectedPhoto == nil || simulatorDemoMode.isPreparingGradeImport)

                    NavigationLink {
                        CreateLUTView(simulatorDemoPhoto: simulatorDemoMode.selectedPhoto)
                    } label: {
                        Label("Import Current Demo Photo to Create LUT", systemImage: "cube.transparent")
                    }
                    .disabled(simulatorDemoMode.selectedPhoto == nil)
                } header: {
                    Text("Demo Mode")
                } footer: {
                    Text("DEBUG Simulator only. Demo photos remain local to this development build.")
                }
#endif

                Section("Camera") {
                    Toggle("Grid", isOn: $preferences.cameraGridEnabled)

                    Picker("Default Camera", selection: $preferences.defaultCamera) {
                        ForEach(DefaultCameraPreference.allCases) { option in
                            Text(LocalizedStringKey(option.displayName)).tag(option)
                        }
                    }

                    Picker("Default Live Photo", selection: $preferences.defaultLivePhoto) {
                        ForEach(DefaultLivePhotoPreference.allCases) { option in
                            Text(LocalizedStringKey(option.rawValue)).tag(option)
                        }
                    }

                    Picker("Default Aspect Ratio", selection: $preferences.defaultAspectRatio) {
                        ForEach(CameraAspectRatio.allCases) { ratio in
                            Text(ratio.rawValue).tag(ratio)
                        }
                    }

                    Toggle(isOn: $preferences.autoSaveCaptures) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto Save Captures")
                            Text("Automatically save photos after capture.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $preferences.saveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save Location")
                            Text("Attach location metadata to Camera captures.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Remember Exposure", isOn: $preferences.rememberExposure)
                }

                Section("Grade") {
                    Toggle("Long Press to Show Original", isOn: $preferences.longPressToShowOriginal)
                    Toggle("Remember Last Style", isOn: $preferences.rememberLastStyle)
                    Toggle("Auto Accent", isOn: $preferences.autoAccent)
                    Toggle("Reset Edits for New Photo", isOn: $preferences.resetEditsForNewPhoto)
                    Toggle(isOn: $preferences.experimentalEnhance) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Experimental Enhance")
                            Text("Experimental automatic photo correction.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Export") {
                    Toggle("Preserve Metadata", isOn: $preferences.preserveMetadata)
                    Toggle("Include Location", isOn: $preferences.includeLocation)
                    Toggle("Instant Metadata", isOn: $preferences.polaroidMetadata)
                    Toggle("Hibiscus Mark", isOn: $preferences.hibiscusMark)

                    NavigationLink {
                        CreateLUTView()
                    } label: {
                        Label("Create LUT", systemImage: "cube.transparent")
                            .foregroundStyle(.primary)
                    }
                }

                Section("More Apps") {
                    Toggle(isOn: $preferences.exploreMoreAfterExport) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Discovery Pop-up")
                            Text("Occasionally show more projects after exporting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        MoreAppsView {
                            preferences.recordExploreMoreEcosystemOpen()
                        }
                        .onAppear {
                            preferences.recordExploreMoreEcosystemOpen()
                        }
                    } label: {
                        SettingsRow(
                            title: "More Apps",
                            subtitle: "Explore more from 1234567890.dev"
                        )
                    }

                    if let discordURL = remoteContent.discordURL {
                        Button {
                            preferences.recordExploreMoreEcosystemOpen()
                            openURL(discordURL)
                        } label: {
                            SettingsRow(
                                title: "Discord",
                                subtitle: "Join the community",
                                showsExternalLinkIndicator: true
                            )
                        }
                        .buttonStyle(.plain)
                        .tint(.primary)
                    }
                }

                Section("About") {
                    HStack(spacing: 14) {
                        if let icon = HibiscusBrand.appIcon() {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 58, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hibiscus")
                                .font(.headline)
                            Text("Color by feel.")
                                .foregroundStyle(.secondary)
                            Text(versionText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    Button {
                        preferences.recordExploreMoreEcosystemOpen()
                        openURL(HibiscusLinks.repository)
                    } label: {
                        SettingsRow(
                            title: "Free & Open Source",
                            subtitle: "MPL-2.0 · View Source Code",
                            showsExternalLinkIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)

                    Button {
                        preferences.recordExploreMoreEcosystemOpen()
                        openURL(HibiscusLinks.openChromaIndex)
                    } label: {
                        SettingsRow(
                            title: "Open Chroma Index",
                            subtitle: "Support open digital color.",
                            showsExternalLinkIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)

                    Button {
                        openURL(HibiscusLinks.privacy)
                    } label: {
                        SettingsRow(
                            title: "Privacy",
                            subtitle: "View Privacy Policy",
                            showsExternalLinkIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)

                    Button {
                        openURL(HibiscusLinks.terms)
                    } label: {
                        SettingsRow(
                            title: "Terms of Service",
                            subtitle: "View Terms of Service",
                            showsExternalLinkIndicator: true
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                }
            }
            .navigationTitle("Settings")
            .tint(.hibiscusAccent)
            .task { remoteContent.refreshInBackground() }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.format("Version %@ (%@)", version, build)
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct SimulatorDemoPhotoSelectionView: View {
    @EnvironmentObject private var simulatorDemoMode: SimulatorDemoMode

    var body: some View {
        List {
            Section {
                ForEach(simulatorDemoMode.photos) { photo in
                    Button {
                        simulatorDemoMode.toggleGradeSelection(photo)
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if let thumbnail = simulatorDemoMode.thumbnail(for: photo) {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Text(photo.displayName)
                                .foregroundStyle(.primary)

                            Spacer()

                            if simulatorDemoMode.selectedGradePhotoIDs.contains(photo.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.hibiscusAccent)
                            } else {
                                Image(systemName: "circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Select up to \(SimulatorDemoMode.maximumGradePhotos) photos for one normal Grade session.")
            }

            Section {
                Button {
                    simulatorDemoMode.requestSelectedPhotosForGrade()
                } label: {
                    Label("Import Selected to Grade", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(
                    simulatorDemoMode.selectedGradePhotoIDs.isEmpty
                    || simulatorDemoMode.isPreparingGradeImport
                )
            }
        }
        .navigationTitle("Demo Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(simulatorDemoMode.selectedGradePhotoIDs.isEmpty ? "Select All" : "Clear") {
                    if simulatorDemoMode.selectedGradePhotoIDs.isEmpty {
                        simulatorDemoMode.selectAllForGrade()
                    } else {
                        simulatorDemoMode.clearGradeSelection()
                    }
                }
                .disabled(simulatorDemoMode.photos.isEmpty)
            }
        }
        .overlay {
            if simulatorDemoMode.isPreparingGradeImport {
                ProgressView("Preparing Grade")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .hibiscusGlass(in: Capsule())
            }
        }
        .alert(
            "Demo Mode",
            isPresented: Binding(
                get: { simulatorDemoMode.statusMessage != nil },
                set: { if !$0 { simulatorDemoMode.statusMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { simulatorDemoMode.statusMessage = nil }
        } message: {
            Text(simulatorDemoMode.statusMessage ?? "")
        }
    }
}
#endif

private struct LanguageSelectionView: View {
    @EnvironmentObject private var languageManager: LanguageManager

    var body: some View {
        List {
            ForEach(AppLanguageMode.allCases) { mode in
                Button {
                    languageManager.mode = mode
                } label: {
                    HStack {
                        Text(mode.titleKey)
                            .foregroundStyle(.primary)
                        Spacer()
                        if languageManager.mode == mode {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.hibiscusAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var showsExternalLinkIndicator = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if showsExternalLinkIndicator {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.76))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
