import CoreImage
import MetalKit
import SwiftUI

nonisolated final class GradePreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let device: MTLDevice
    private let context: CIContext
    private let commandQueue: MTLCommandQueue
    private let colorSpace = ImageRenderer.gradeOutputColorSpace
    private var sourceImage: CIImage?
    private var settings = GradeSettings()
    private var renderVersion: UInt64 = 0
    private var submittedVersion: UInt64 = 0
    private var isRendering = false

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Hibiscus requires a Metal-capable iPhone.")
        }
        self.device = device
        self.context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: true,
            .workingColorSpace: ImageRenderer.gradeWorkingColorSpace,
            .outputColorSpace: ImageRenderer.gradeOutputColorSpace
        ])
        self.commandQueue = commandQueue
        super.init()
    }

    @MainActor
    func configure(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        (view.layer as? CAMetalLayer)?.colorspace = colorSpace
        view.clearColor = MTLClearColorMake(0.015, 0.015, 0.015, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
    }

    func load(_ image: UIImage, settings: GradeSettings) {
        guard let source = ImageRenderer.sourceCIImage(image) else { return }
        lock.lock()
        sourceImage = source
        self.settings = settings
        renderVersion &+= 1
        lock.unlock()
    }

    func update(settings: GradeSettings) {
        lock.lock()
        self.settings = settings
        renderVersion &+= 1
        lock.unlock()
    }

    func clear() {
        lock.lock()
        sourceImage = nil
        renderVersion &+= 1
        lock.unlock()
    }

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0,
              view.drawableSize.height > 0 else { return }

        lock.lock()
        guard !isRendering,
              renderVersion != submittedVersion,
              let source = sourceImage else {
            lock.unlock()
            return
        }
        let currentSettings = settings
        submittedVersion = renderVersion
        isRendering = true
        lock.unlock()

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            lock.lock()
            isRendering = false
            submittedVersion &-= 1
            lock.unlock()
            return
        }

        let target = CGRect(origin: .zero, size: view.drawableSize)
        // Preserve the entire photograph. Scale before building the grade graph so
        // filters work at display resolution without cropping the source ratio.
        let displaySource = aspectFit(source, into: target)
        let graded = ImageRenderer.gradeCIImage(displaySource, settings: currentSettings)
        let background = CIImage(color: CIColor(red: 0.075, green: 0.075, blue: 0.08))
            .cropped(to: target)
        let output = graded.composited(over: background)
        context.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isRendering = false
            self.lock.unlock()
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lock.lock()
        renderVersion &+= 1
        lock.unlock()
    }

    private func aspectFit(_ image: CIImage, into target: CGRect) -> CIImage {
        let source = image.extent
        let scale = min(target.width / source.width, target.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        let x = target.midX - width / 2
        let y = target.midY - height / 2
        return image
            .cropped(to: source)
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

struct GradeMetalPreview: UIViewRepresentable {
    let renderer: GradePreviewRenderer
    let isActive: Bool

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        renderer.configure(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.isPaused = !isActive
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        uiView.isPaused = true
        uiView.delegate = nil
    }
}
