import PhotosUI
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// The system picker is the only photo-selection interface.
struct GradePhotoImportSheet: UIViewControllerRepresentable {
    let limit: Int
    let completion: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = limit
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([PHPickerResult]) -> Void
        init(completion: @escaping ([PHPickerResult]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            completion(results)
        }
    }
}

nonisolated enum GradePickerResourceLoader {
    static func load(_ provider: NSItemProvider) async -> GradeImportItem? {
        var liveSource: LivePhotoSource?
        let data: Data?
        if provider.canLoadObject(ofClass: PHLivePhoto.self) {
            let live: PHLivePhoto? = await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: PHLivePhoto.self) { object, _ in
                    continuation.resume(returning: object as? PHLivePhoto)
                }
            }
            guard let live,
                  let source = await LivePhotoImportLoader.copyResources(PHAssetResource.assetResources(for: live)) else {
                // Never silently flatten an item the user selected as a Live Photo.
                return nil
            }
            liveSource = source
            data = try? Data(contentsOf: source.stillURL, options: .mappedIfSafe)
        } else {
            data = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }
        guard let data, let image = AccentAnalyzer.downsample(data, maxDimension: 4096) else {
            liveSource?.removeOwnedResources()
            return nil
        }
        let metadata = PhotoMetadataExtractor.metadata(from: data)
        if let source = liveSource, let latitude = metadata.latitude, let longitude = metadata.longitude {
            liveSource = LivePhotoSource(
                id: source.id, directoryURL: source.directoryURL,
                stillURL: source.stillURL, motionURL: source.motionURL, assetIdentifier: source.assetIdentifier,
                location: CLLocation(latitude: latitude, longitude: longitude)
            )
        }
        return GradeImportItem(
            image: image,
            thumbnail: AccentAnalyzer.downsample(data, maxDimension: 384) ?? image,
            metadata: metadata,
            livePhoto: liveSource
        )
    }
}
