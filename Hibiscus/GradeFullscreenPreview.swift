import SwiftUI

struct GradeFullscreenPreview: View {
    let source: UIImage
    let settings: GradeSettings
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderer = GradePreviewRenderer()
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.48, dampingFraction: 0.8)))
    private var tilt = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let photoSize = fittedPhotoSize(in: proxy.size)
            ZStack {
                Color(white: 0.075).ignoresSafeArea().onTapGesture(perform: dismiss)
                photoPanel(size: photoSize)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : -tilt.height * 16), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : tilt.width * 22), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .offset(x: reduceMotion ? 0 : tilt.width * 7,
                            y: reduceMotion ? 0 : tilt.height * 7)
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .named("gradeFullscreen"))
                            .updating($tilt) { value, state, _ in
                                // A soft limit keeps the photo facing the user.
                                // GestureState also springs home on cancellation.
                                state = CGSize(
                                    width: tanh(value.translation.width / max(1, photoSize.width * 0.45)),
                                    height: tanh(value.translation.height / max(1, photoSize.height * 0.4))
                                )
                            }
                    )
                    .onTapGesture(perform: dismiss)
                    .accessibilityLabel("Fullscreen photo preview")
                    .accessibilityAction(.escape, dismiss)

                VStack {
                    HStack {
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .hibiscusGlass(in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                    Spacer()
                }
                .padding(16)
            }
            .coordinateSpace(name: "gradeFullscreen")
        }
        .background(Color(white: 0.075).ignoresSafeArea())
        .onAppear { renderer.load(source, settings: settings) }
        .onChange(of: settings) { _, value in renderer.update(settings: value) }
        .onDisappear { renderer.clear() }
    }

    private func photoPanel(size: CGSize) -> some View {
        let outline = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // Only the solid panel edge is layered. The photograph remains a single
        // live Metal surface, with no snapshot or extra image rendering passes.
        let edgeX = reduceMotion ? 0 : -sin(tilt.width * 22 * .pi / 180)
        let edgeY = reduceMotion ? 0 : -sin(tilt.height * 16 * .pi / 180)

        return ZStack {
            outline
                .fill(Color(white: 0.12))
                .offset(x: edgeX * 8, y: edgeY * 8)
                .shadow(color: .black.opacity(0.55), radius: 20,
                        x: reduceMotion ? 0 : -tilt.width * 10,
                        y: reduceMotion ? 10 : 14 - tilt.height * 6)

            ForEach((1...8).reversed(), id: \.self) { depth in
                outline
                    .fill(LinearGradient(
                        colors: [Color(white: 0.42), Color(white: 0.2), Color(white: 0.13)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .offset(x: edgeX * CGFloat(depth), y: edgeY * CGFloat(depth))
            }

            GradeMetalPreview(renderer: renderer, isActive: true)
                .clipShape(outline)
                .overlay {
                    outline.strokeBorder(.white.opacity(0.18), lineWidth: 0.65)
                        .allowsHitTesting(false)
                }
        }
        .frame(width: size.width, height: size.height)
    }

    private func fittedPhotoSize(in available: CGSize) -> CGSize {
        let ratio = source.size.width / max(1, source.size.height)
        let width = max(1, available.width * 0.82)
        let height = max(1, available.height * 0.72)
        if width / height > ratio {
            return CGSize(width: height * ratio, height: height)
        }
        return CGSize(width: width, height: width / ratio)
    }
}
