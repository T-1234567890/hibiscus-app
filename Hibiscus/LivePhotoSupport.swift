@preconcurrency import AVFoundation
import CoreImage
import CoreLocation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct LivePhotoSource: @unchecked Sendable {
    let id: UUID
    let directoryURL: URL
    let stillURL: URL
    let motionURL: URL
    let assetIdentifier: String?
    let location: CLLocation?

    init(
        id: UUID = UUID(),
        directoryURL: URL,
        stillURL: URL,
        motionURL: URL,
        assetIdentifier: String?,
        location: CLLocation? = nil
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.stillURL = stillURL
        self.motionURL = motionURL
        self.assetIdentifier = assetIdentifier
        self.location = location
    }

    func removeOwnedResources() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

nonisolated struct ProcessedLivePhoto: @unchecked Sendable {
    let directoryURL: URL
    let stillURL: URL
    let motionURL: URL
    let location: CLLocation?

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

nonisolated enum LivePhotoImportLoader {
    static func copyResources(
        _ resources: [PHAssetResource], identifier: String? = nil, location: CLLocation? = nil
    ) async -> LivePhotoSource? {
        // Pick a matching representation pair; don't mix an edited key photo
        // with the original motion resource.
        let fullStill = resources.first(where: { $0.type == .fullSizePhoto })
        let fullMotion = resources.first(where: { $0.type == .fullSizePairedVideo })
        let useFullSize = fullStill != nil && fullMotion != nil
        let still = useFullSize ? fullStill : resources.first(where: { $0.type == .photo })
        let motion = useFullSize ? fullMotion : resources.first(where: { $0.type == .pairedVideo })
        guard let still, let motion else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HibiscusLivePhotoSources", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let stillExtension = URL(fileURLWithPath: still.originalFilename).pathExtension.nonEmpty ?? "heic"
        let motionExtension = URL(fileURLWithPath: motion.originalFilename).pathExtension.nonEmpty ?? "mov"
        let stillURL = directory.appendingPathComponent("photo.\(stillExtension)")
        let motionURL = directory.appendingPathComponent("motion.\(motionExtension)")

        let stillSucceeded = await write(still, to: stillURL)
        let motionSucceeded = await write(motion, to: motionURL)
        guard stillSucceeded, motionSucceeded else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return LivePhotoSource(
            directoryURL: directory,
            stillURL: stillURL,
            motionURL: motionURL,
            assetIdentifier: identifier,
            location: location
        )
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async -> Bool {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

nonisolated enum LivePhotoProcessor {
    static func process(
        _ source: LivePhotoSource,
        settings: GradeSettings,
        preview: Bool = false
    ) async -> ProcessedLivePhoto? {
        var livePhotoSettings = settings
        // Experimental Enhance is intentionally still-photo-only. Both the key
        // image and motion component use the same non-Enhance Grade transform.
        livePhotoSettings.enhance.isEnabled = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HibiscusLivePhotoExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let stillURL = directory.appendingPathComponent("Hibiscus-Live.heic")
        let motionURL = directory.appendingPathComponent("Hibiscus-Live.mov")

        guard renderStill(source.stillURL, to: stillURL, settings: livePhotoSettings, maxDimension: preview ? 1600 : nil),
              await renderMotion(
                  source.motionURL,
                  to: motionURL,
                  settings: livePhotoSettings,
                  presetName: preview ? AVAssetExportPresetMediumQuality : AVAssetExportPresetHighestQuality
              ),
              await isValidLivePhotoPair(stillURL: stillURL, motionURL: motionURL) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return ProcessedLivePhoto(
            directoryURL: directory,
            stillURL: stillURL,
            motionURL: motionURL,
            location: source.location
        )
    }

    static func processCameraCapture(
        photoData: Data,
        motionURL sourceMotionURL: URL,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment,
        aspectRatio: CGFloat,
        targetMegapixels: Int,
        location: CLLocation?
    ) async -> ProcessedLivePhoto? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HibiscusCameraLivePhotoExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let stillURL = directory.appendingPathComponent("Hibiscus-Camera-Live.heic")
        let motionURL = directory.appendingPathComponent("Hibiscus-Camera-Live.mov")
        guard renderCameraStill(
            photoData,
            to: stillURL,
            character: character,
            adjustment: adjustment,
            aspectRatio: aspectRatio,
            targetMegapixels: targetMegapixels
        ) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        let renderedMotion = await renderCameraMotion(
            sourceMotionURL,
            to: motionURL,
            character: character,
            adjustment: adjustment,
            aspectRatio: aspectRatio
        )
        if renderedMotion,
           await isValidLivePhotoPair(stillURL: stillURL, motionURL: motionURL) {
            return ProcessedLivePhoto(
                directoryURL: directory,
                stillURL: stillURL,
                motionURL: motionURL,
                location: location
            )
        }

        // Some hardware/OS combinations drop the Live Photo metadata track
        // while exporting a filtered movie. Preserve the processed key photo
        // and fall back to the original paired motion resource in that case.
        try? FileManager.default.removeItem(at: motionURL)
        if (try? FileManager.default.copyItem(at: sourceMotionURL, to: motionURL)) != nil,
           await isValidLivePhotoPair(stillURL: stillURL, motionURL: motionURL) {
            return ProcessedLivePhoto(
                directoryURL: directory,
                stillURL: stillURL,
                motionURL: motionURL,
                location: location
            )
        }

        // The native AVCapturePhotoOutput pair is the final lossless fallback.
        // It is preferable to returning a flattened still when a device cannot
        // preserve pairing metadata through the color-rendering export.
        try? FileManager.default.removeItem(at: stillURL)
        try? FileManager.default.removeItem(at: motionURL)
        do {
            try photoData.write(to: stillURL, options: .atomic)
            try FileManager.default.copyItem(at: sourceMotionURL, to: motionURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        guard await isValidLivePhotoPair(stillURL: stillURL, motionURL: motionURL) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return ProcessedLivePhoto(
            directoryURL: directory,
            stillURL: stillURL,
            motionURL: motionURL,
            location: location
        )
    }

    private static func isValidLivePhotoPair(stillURL: URL, motionURL: URL) async -> Bool {
        guard let placeholder = UIImage(contentsOfFile: stillURL.path) else { return false }
        return await withCheckedContinuation { continuation in
            var didFinish = false
            PHLivePhoto.request(
                withResourceFileURLs: [stillURL, motionURL],
                placeholderImage: placeholder,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit
            ) { livePhoto, info in
                guard !didFinish else { return }
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
                let error = info[PHLivePhotoInfoErrorKey] as? Error
                if error != nil || (!degraded && livePhoto == nil) {
                    didFinish = true
                    continuation.resume(returning: false)
                } else if livePhoto != nil, !degraded {
                    didFinish = true
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private static func renderStill(
        _ sourceURL: URL,
        to destinationURL: URL,
        settings: GradeSettings,
        maxDimension: CGFloat?
    ) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
              let image = UIImage(data: data),
              let rendered = ImageRenderer.gradeImage(
                  image,
                  settings: settings,
                  maxDimension: maxDimension
              )?.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                  destinationURL as CFURL,
                  UTType.heic.identifier as CFString,
                  1,
                  nil
              ) else { return false }
        let mutable = (properties as NSDictionary).mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        mutable[kCGImagePropertyOrientation] = 1
        mutable[kCGImageDestinationLossyCompressionQuality] = 0.96
        CGImageDestinationAddImage(destination, rendered, mutable)
        return CGImageDestinationFinalize(destination)
    }

    private static func renderCameraStill(
        _ data: Data,
        to destinationURL: URL,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment,
        aspectRatio: CGFloat,
        targetMegapixels: Int
    ) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let image = UIImage(data: data),
              let rendered = ImageRenderer.cameraImage(
                  image,
                  character: character,
                  adjustment: adjustment,
                  aspectRatio: aspectRatio,
                  targetMegapixels: targetMegapixels
              )?.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                  destinationURL as CFURL,
                  UTType.heic.identifier as CFString,
                  1,
                  nil
              ) else { return false }
        let mutable = (properties as NSDictionary).mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        mutable[kCGImagePropertyOrientation] = 1
        mutable[kCGImageDestinationLossyCompressionQuality] = 0.98
        CGImageDestinationAddImage(destination, rendered, mutable)
        return CGImageDestinationFinalize(destination)
    }

    private static func renderMotion(
        _ sourceURL: URL,
        to destinationURL: URL,
        settings: GradeSettings,
        presetName: String
    ) async -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: presetName) else {
            return false
        }
        export.outputURL = destinationURL
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        export.metadata = (try? await asset.load(.metadata)) ?? []
        export.videoComposition = AVVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let output = ImageRenderer.gradeCIImage(source, settings: settings).cropped(to: source.extent)
            request.finish(with: output, context: ImageRenderer.context)
        }
        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }
        return export.status == .completed
    }

    private static func renderCameraMotion(
        _ sourceURL: URL,
        to destinationURL: URL,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment,
        aspectRatio: CGFloat
    ) async -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }
        export.outputURL = destinationURL
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        export.metadata = (try? await asset.load(.metadata)) ?? []
        let composition = AVVideoComposition(asset: asset) { request in
            request.finish(
                with: ImageRenderer.cameraMotionCIImage(
                    request.sourceImage,
                    character: character,
                    adjustment: adjustment,
                    aspectRatio: aspectRatio,
                    inputExposureEV: 0
                ),
                context: nil
            )
        }
        if let mutable = composition as? AVMutableVideoComposition,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            mutable.renderSize = renderSize(
                for: naturalSize.applying(transform),
                portraitAspectRatio: aspectRatio
            )
        }
        export.videoComposition = composition
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        return export.status == .completed
    }

    private static func renderSize(for transformedSize: CGSize, portraitAspectRatio: CGFloat) -> CGSize {
        var width = abs(transformedSize.width)
        var height = abs(transformedSize.height)
        guard width > 0, height > 0 else { return CGSize(width: 1080, height: 1440) }
        let targetRatio = width > height ? 1 / portraitAspectRatio : portraitAspectRatio
        if width / height > targetRatio {
            width = height * targetRatio
        } else {
            height = width / targetRatio
        }
        return CGSize(
            width: max(2, floor(width / 2) * 2),
            height: max(2, floor(height / 2) * 2)
        )
    }
}

@MainActor
enum LivePhotoLibrarySaver {
    static func save(
        _ outputs: [ProcessedLivePhoto],
        cleanUpAfterSave: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        guard !outputs.isEmpty else {
            completion(false)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                if cleanUpAfterSave { outputs.forEach { $0.cleanUp() } }
                Task { @MainActor in completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                for output in outputs {
                    let request = PHAssetCreationRequest.forAsset()
                    request.location = output.location
                    request.addResource(with: .photo, fileURL: output.stillURL, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: output.motionURL, options: nil)
                }
            } completionHandler: { success, _ in
                if cleanUpAfterSave { outputs.forEach { $0.cleanUp() } }
                Task { @MainActor in completion(success) }
            }
        }
    }
}

@MainActor
enum LivePhotoPreviewFactory {
    static func make(from output: ProcessedLivePhoto, placeholder: UIImage) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            var didFinish = false
            PHLivePhoto.request(
                withResourceFileURLs: [output.stillURL, output.motionURL],
                placeholderImage: placeholder,
                targetSize: CGSize(width: 1280, height: 1280),
                contentMode: .aspectFit
            ) { livePhoto, info in
                guard !didFinish else { return }
                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
                let error = info[PHLivePhotoInfoErrorKey] as? Error
                if error != nil || (!isDegraded && livePhoto == nil) {
                    didFinish = true
                    continuation.resume(returning: nil)
                } else if let livePhoto, !isDegraded {
                    didFinish = true
                    continuation.resume(returning: livePhoto)
                }
            }
        }
    }
}

struct HibiscusLivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    var playbackID = 0
    let onPlaybackEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPlaybackEnded: onPlaybackEnded) }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView(frame: .zero)
        view.contentMode = UIView.ContentMode.scaleAspectFit
        view.clipsToBounds = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        let changedPhoto = view.livePhoto !== livePhoto
        let requestedReplay = context.coordinator.playbackID != playbackID
        guard changedPhoto || requestedReplay else { return }
        if changedPhoto { view.livePhoto = livePhoto }
        context.coordinator.playbackID = playbackID
        DispatchQueue.main.async {
            view.startPlayback(with: .full)
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        view.delegate = nil
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var onPlaybackEnded: () -> Void
        var playbackID = -1

        init(onPlaybackEnded: @escaping () -> Void) {
            self.onPlaybackEnded = onPlaybackEnded
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            onPlaybackEnded()
        }
    }
}

nonisolated private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
