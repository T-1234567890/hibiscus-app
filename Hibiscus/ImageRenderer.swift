import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

nonisolated enum ImageRenderer {
    static let gradeWorkingColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static let gradeOutputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [
        .cacheIntermediates: true,
        .workingColorSpace: gradeWorkingColorSpace,
        .outputColorSpace: gradeOutputColorSpace
    ])

    static func cameraPreview(
        _ image: CIImage,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment = .centered
    ) -> CIImage {
        cameraCIImage(image, character: character, adjustment: adjustment, includesTexture: false)
    }

    static func cameraCIImage(
        _ image: CIImage,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment,
        includesTexture: Bool
    ) -> CIImage {
        guard let character else { return image }
        let base = applyCamera(character, to: image, isPreview: !includesTexture)
        return applyCameraVariation(character, to: base, point: adjustment.point)
            .cropped(to: image.extent)
    }

    static func cameraMotionCIImage(
        _ image: CIImage,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment,
        aspectRatio: CGFloat,
        inputExposureEV: Double
    ) -> CIImage {
        var source = image
        if inputExposureEV != 0 { source = exposure(source, ev: inputExposureEV) }
        let orientedAspectRatio = source.extent.width > source.extent.height
            ? 1 / aspectRatio
            : aspectRatio
        let crop = centerCrop(source, to: orientedAspectRatio)
        let rendered = cameraCIImage(
            crop,
            character: character,
            adjustment: adjustment,
            includesTexture: false
        )
        return rendered.transformed(by: CGAffineTransform(
            translationX: -rendered.extent.minX,
            y: -rendered.extent.minY
        ))
    }

    static func cameraImage(
        _ image: UIImage,
        character: CameraCharacter?,
        adjustment: CameraCharacterAdjustment = .centered,
        aspectRatio: CGFloat,
        targetMegapixels: Int,
        inputExposureEV: Double = 0
    ) -> UIImage? {
        guard var source = normalizedCIImage(image) else { return nil }
        if inputExposureEV != 0 {
            source = exposure(source, ev: inputExposureEV)
        }
        let orientedAspectRatio = source.extent.width > source.extent.height
            ? 1 / aspectRatio
            : aspectRatio
        var input = centerCrop(source, to: orientedAspectRatio)
        let targetPixels = CGFloat(targetMegapixels) * 1_000_000
        let sourcePixels = input.extent.width * input.extent.height
        if targetPixels > 0, sourcePixels > targetPixels * 1.03 {
            let scale = sqrt(targetPixels / sourcePixels)
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return makeUIImage(
            from: cameraCIImage(input, character: character, adjustment: adjustment, includesTexture: true),
            scale: image.scale
        )
    }

    static func gradeImage(_ image: UIImage, settings: GradeSettings, maxDimension: CGFloat? = nil) -> UIImage? {
        guard var input = normalizedCIImage(image) else { return nil }
        if let maxDimension {
            let longest = max(input.extent.width, input.extent.height)
            if longest > maxDimension {
                let scale = maxDimension / longest
                input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }

        let output = gradeCIImage(input, settings: settings)
        return makeUIImage(from: output, scale: 1)
    }

    static func gradeCIImage(_ input: CIImage, settings: GradeSettings) -> CIImage {
        // Enhance is a neutral correction of the unfiltered source. Style and
        // Accent are deliberately built only after that source correction.
        let corrected = applyEnhance(to: input, adjustment: settings.enhance)
        let styled = applyGradeStyle(settings.style, to: corrected, point: settings.stylePoint)
        let mixedStyle = dissolve(corrected, styled, amount: settings.styleStrength)
        let accented = applyAccent(to: mixedStyle, accent: settings.accent, point: settings.accentPoint)
        return dissolve(mixedStyle, accented, amount: settings.accentStrength)
    }

    static func applyEnhance(to image: CIImage, adjustment: EnhanceAdjustment) -> CIImage {
        guard adjustment.isEnabled else { return image }
        var output = image
        if abs(adjustment.exposureEV) > 0.001 {
            output = exposure(output, ev: adjustment.exposureEV)
        }
        output = channelMix(
            output,
            red: (adjustment.redGain, 0, 0),
            green: (0, adjustment.greenGain, 0),
            blue: (0, 0, adjustment.blueGain)
        )
        output = highlightShadow(
            output,
            highlights: adjustment.highlightAmount,
            shadows: adjustment.shadowAmount
        )
        output = controls(output, saturation: 1, brightness: 0, contrast: adjustment.contrast)
        return output.cropped(to: image.extent)
    }

    static func enhancedSourceImage(
        _ image: UIImage,
        adjustment: EnhanceAdjustment,
        maxDimension: CGFloat = 2_048
    ) -> UIImage? {
        guard var input = normalizedCIImage(image) else { return nil }
        let longest = max(input.extent.width, input.extent.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return makeUIImage(from: applyEnhance(to: input, adjustment: adjustment), scale: 1)
    }

    /// Evaluates the same global color graph used by Grade over an RGB lattice.
    /// The lattice deliberately contains no photograph data, so the result can be
    /// serialized as a fixed 3D LUT without baking in spatial or analysis effects.
    static func gradeCubeSamples(settings: GradeSettings, dimension: Int) -> [SIMD3<Float>] {
        precondition(dimension > 1)
        let width = dimension * dimension
        let height = dimension
        let componentCount = width * height * 4
        let denominator = Float(dimension - 1)
        var inputPixels = [Float](repeating: 0, count: componentCount)

        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let pixel = (blue * width) + (green * dimension) + red
                    let component = pixel * 4
                    inputPixels[component] = Float(red) / denominator
                    inputPixels[component + 1] = Float(green) / denominator
                    inputPixels[component + 2] = Float(blue) / denominator
                    inputPixels[component + 3] = 1
                }
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        let inputData = inputPixels.withUnsafeBytes { Data($0) }
        let lattice = CIImage(
            bitmapData: inputData,
            bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        let output = gradeCIImage(lattice, settings: settings)
        var outputPixels = [Float](repeating: 0, count: componentCount)
        outputPixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                output,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: colorSpace
            )
        }

        return stride(from: 0, to: componentCount, by: 4).map { component in
            SIMD3(
                outputPixels[component],
                outputPixels[component + 1],
                outputPixels[component + 2]
            )
        }
    }

    static func sourceCIImage(_ image: UIImage) -> CIImage? {
        normalizedCIImage(image)
    }

    static func styleThumbnail(_ image: UIImage, style: GradeStyle) -> UIImage? {
        var settings = GradeSettings()
        settings.style = style
        settings.accentStrength = 0
        return gradeImage(image, settings: settings, maxDimension: 240)
    }

    static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        guard var input = normalizedCIImage(image) else { return nil }
        let longest = max(input.extent.width, input.extent.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return makeUIImage(from: input, scale: 1)
    }

    private static func applyCamera(_ character: CameraCharacter, to image: CIImage, isPreview: Bool) -> CIImage {
        var output = image
        switch character {
        case .alpha:
            // Clear is restrained, not bypassed: gently polish color, tonal
            // rolloff, and detail while Original remains the true no-look path.
            output = vibrance(output, amount: 0.035)
            output = controls(output, saturation: 1.005, brightness: 0, contrast: 1.035)
            output = highlightShadow(output, highlights: 0.86, shadows: 0.028)
            output = sharpen(output, amount: 0.13, radius: 0.85)
        case .beta:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5550, y: 3))
            output = controls(output, saturation: 0.95, brightness: 0, contrast: 0.965)
            output = highlightShadow(output, highlights: 0.80, shadows: 0.065)
            output = channelMix(output, red: (1.018, 0.006, -0.004), green: (0.002, 0.975, 0.010), blue: (-0.004, 0.008, 1.00))
            output = splitTone(
                output,
                shadow: CIColor(red: 0.36, green: 0.43, blue: 0.42),
                highlight: CIColor(red: 0.92, green: 0.72, blue: 0.55),
                amount: 0.052,
                placement: -0.08
            )
            if !isPreview {
                output = bloom(output, radius: 2.4, intensity: 0.024)
                output = addGrain(output, amount: 0.010, scale: 0.72)
            }
        case .gamma:
            output = temperature(output, neutral: CIVector(x: 6000, y: 0), target: CIVector(x: 6550, y: -3))
            output = controls(output, saturation: 1.06, brightness: 0, contrast: 1.095)
            output = highlightShadow(output, highlights: 0.97, shadows: -0.022)
            output = channelMix(output, red: (1.045, -0.014, 0), green: (-0.010, 0.995, 0.008), blue: (-0.012, 0.004, 1.065))
            output = sharpen(output, amount: 0.23, radius: 0.68)
        case .delta:
            output = controls(output, saturation: 1.025, brightness: 0, contrast: 1.14)
            output = highlightShadow(output, highlights: 0.88, shadows: -0.025)
            output = splitTone(
                output,
                shadow: CIColor(red: 0.25, green: 0.42, blue: 0.43),
                highlight: CIColor(red: 0.96, green: 0.69, blue: 0.47),
                amount: 0.095,
                placement: -0.10
            )
            output = channelMix(output, red: (1.04, 0.010, -0.004), green: (-0.008, 0.99, 0.014), blue: (0, -0.010, 0.99))
            output = sharpen(output, amount: 0.15, radius: 0.78)
            if !isPreview {
                output = bloom(output, radius: 2.5, intensity: 0.030)
                output = addGrain(output, amount: 0.016, scale: 0.94)
            }
        case .epsilon:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5650, y: 2))
            output = controls(output, saturation: 0.89, brightness: 0, contrast: 0.94)
            output = highlightShadow(output, highlights: 0.79, shadows: 0.13)
            output = channelMix(output, red: (1.018, 0.010, -0.004), green: (0.004, 0.995, 0), blue: (0.004, 0.004, 0.955))
            output = splitTone(
                output,
                shadow: CIColor(red: 0.48, green: 0.45, blue: 0.42),
                highlight: CIColor(red: 0.95, green: 0.78, blue: 0.63),
                amount: 0.045,
                placement: 0.16
            )
            output = sharpen(output, amount: 0.075, radius: 0.90)
            if !isPreview { output = addGrain(output, amount: 0.006, scale: 0.78) }
        case .zeta:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5750, y: 7))
            output = controls(output, saturation: 0.98, brightness: 0, contrast: 1.07)
            output = highlightShadow(output, highlights: 0.94, shadows: -0.008)
            output = channelMix(output, red: (1.015, 0.012, -0.006), green: (0.008, 1.025, -0.008), blue: (0.004, -0.006, 0.955))
            output = vignette(output, intensity: 0.20, radius: 1.50)
            output = sharpen(output, amount: 0.14, radius: 0.76)
            if !isPreview { output = addGrain(output, amount: 0.026, scale: 1.18) }
        case .eta:
            output = temperature(output, neutral: CIVector(x: 6100, y: 0), target: CIVector(x: 7000, y: -5))
            output = controls(output, saturation: 1.045, brightness: 0, contrast: 1.16)
            output = highlightShadow(output, highlights: 0.82, shadows: -0.035)
            output = channelMix(output, red: (1.01, -0.008, 0.012), green: (-0.010, 1.01, 0.014), blue: (-0.012, 0.010, 1.06))
            output = splitTone(
                output,
                shadow: CIColor(red: 0.12, green: 0.42, blue: 0.52),
                highlight: CIColor(red: 0.82, green: 0.30, blue: 0.62),
                amount: 0.078,
                placement: 0.10
            )
            output = sharpen(output, amount: 0.17, radius: 0.74)
            if !isPreview { output = addGrain(output, amount: 0.009, scale: 0.78, colored: true) }
        case .theta:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5750, y: -1))
            output = controls(output, saturation: 0.95, brightness: 0, contrast: 0.97)
            output = highlightShadow(output, highlights: 0.78, shadows: 0.055)
            output = channelMix(output, red: (1.012, 0.006, -0.006), green: (0.006, 0.982, 0.008), blue: (0.002, 0.004, 0.985))
            output = splitTone(
                output,
                shadow: CIColor(red: 0.42, green: 0.43, blue: 0.44),
                highlight: CIColor(red: 0.94, green: 0.72, blue: 0.63),
                amount: 0.032,
                placement: 0.20
            )
            output = sharpen(output, amount: 0.055, radius: 0.92)
        case .sigma:
            output = temperature(output, neutral: CIVector(x: 6100, y: 0), target: CIVector(x: 5750, y: 1))
            output = controls(output, saturation: 0.91, brightness: 0, contrast: 1.13)
            output = highlightShadow(output, highlights: 0.91, shadows: -0.025)
            output = channelMix(output, red: (1.025, 0.008, -0.005), green: (0.005, 0.955, 0.012), blue: (-0.006, 0.008, 1.025))
            output = splitTone(
                output,
                shadow: CIColor(red: 0.28, green: 0.35, blue: 0.42),
                highlight: CIColor(red: 0.78, green: 0.62, blue: 0.48),
                amount: 0.04,
                placement: -0.12
            )
            output = sharpen(output, amount: 0.22, radius: 0.80)
            if !isPreview { output = addGrain(output, amount: 0.018, scale: 0.92) }
        case .omega:
            output = blackAndWhite(output, red: 0.27, green: 0.64, blue: 0.09, tint: CIColor(red: 0.72, green: 0.70, blue: 0.67))
            output = controls(output, saturation: 0, brightness: 0, contrast: 1.14)
            output = highlightShadow(output, highlights: 0.81, shadows: -0.008)
            output = sharpen(output, amount: 0.10, radius: 0.86)
            if !isPreview { output = addGrain(output, amount: 0.016, scale: 0.90) }
        }
        return output.cropped(to: image.extent)
    }

    /// Character Pad variation is intentionally character-specific. The shared
    /// coordinates describe color interpretation and tonal openness, but each
    /// profile maps them through its own photographic relationships.
    private static func applyCameraVariation(
        _ character: CameraCharacter,
        to image: CIImage,
        point: CGPoint
    ) -> CIImage {
        let color = Double(point.x - 0.5) * 2
        let tone = Double(0.5 - point.y) * 2
        guard abs(color) > 0.001 || abs(tone) > 0.001 else { return image }
        var output = image

        switch character {
        case .alpha:
            output = vibrance(output, amount: color * 0.08)
            output = controls(output, saturation: 1 + color * 0.025, brightness: 0, contrast: 1 - tone * 0.035)
            output = highlightShadow(output, highlights: 0.97 - max(0, tone) * 0.025, shadows: tone * 0.045)
        case .beta:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6200 - color * 360, y: 1 + color * 2.5))
            output = splitTone(output, shadow: CIColor(red: 0.30, green: 0.42, blue: 0.40), highlight: CIColor(red: 0.94, green: 0.69, blue: 0.50), amount: abs(color) * 0.055, placement: -0.08)
            output = controls(output, saturation: 1, brightness: 0, contrast: 1 - tone * 0.055)
            output = highlightShadow(output, highlights: 0.96 - max(0, tone) * 0.055, shadows: tone * 0.055)
        case .gamma:
            output = channelMix(output, red: (1 + color * 0.035, -color * 0.012, 0), green: (0, 1, 0), blue: (-color * 0.012, 0, 1 + color * 0.050))
            output = controls(output, saturation: 1, brightness: 0, contrast: 1 + color * 0.025 - tone * 0.045)
            output = highlightShadow(output, highlights: 0.98 + min(0, tone) * 0.04, shadows: tone * 0.028)
        case .delta:
            output = splitTone(output, shadow: CIColor(red: 0.20, green: 0.39, blue: 0.42), highlight: CIColor(red: 0.98, green: 0.66, blue: 0.42), amount: 0.035 + color * 0.030, placement: -0.12)
            output = controls(output, saturation: 1 + color * 0.025, brightness: 0, contrast: 1 + color * 0.028 - tone * 0.060)
            output = highlightShadow(output, highlights: 0.97, shadows: tone * 0.035)
        case .epsilon:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6200 - color * 420, y: 1 + color))
            output = controls(output, saturation: 1 - color * 0.022, brightness: 0, contrast: 1 - tone * 0.060)
            output = highlightShadow(output, highlights: 0.94 - max(0, tone) * 0.040, shadows: 0.015 + tone * 0.070)
        case .zeta:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6200 - color * 260, y: color * 4.5))
            output = channelMix(output, red: (1, 0, 0), green: (color * 0.012, 1 + color * 0.025, 0), blue: (0, 0, 1 - color * 0.030))
            output = controls(output, saturation: 1, brightness: 0, contrast: 1 + color * 0.018 - tone * 0.050)
            output = highlightShadow(output, highlights: 0.98, shadows: tone * 0.040)
        case .eta:
            output = splitTone(output, shadow: CIColor(red: 0.08, green: 0.42, blue: 0.55), highlight: CIColor(red: 0.82, green: 0.23, blue: 0.65), amount: 0.045 + color * 0.045, placement: 0.08)
            output = channelMix(output, red: (1 + color * 0.018, 0, 0), green: (0, 1, 0), blue: (-color * 0.010, 0, 1 + color * 0.035))
            output = controls(output, saturation: 1, brightness: 0, contrast: 1 + color * 0.020 - tone * 0.060)
            output = highlightShadow(output, highlights: 0.94 - max(0, tone) * 0.030, shadows: tone * 0.025)
        case .theta:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6200 - color * 300, y: -color * 1.5))
            output = channelMix(output, red: (1 + color * 0.015, 0, -color * 0.008), green: (0, 1, 0), blue: (0, 0, 1 - color * 0.010))
            output = controls(output, saturation: 1 - max(0, color) * 0.018, brightness: 0, contrast: 1 - tone * 0.050)
            output = highlightShadow(output, highlights: 0.94 - max(0, tone) * 0.050, shadows: tone * 0.045)
        case .sigma:
            output = channelMix(output, red: (1 + color * 0.020, 0, 0), green: (0, 1 - color * 0.035, 0), blue: (-color * 0.008, 0, 1 + color * 0.018))
            output = splitTone(output, shadow: CIColor(red: 0.25, green: 0.34, blue: 0.43), highlight: CIColor(red: 0.80, green: 0.62, blue: 0.46), amount: abs(color) * 0.035, placement: -0.10)
            output = controls(output, saturation: 1, brightness: 0, contrast: 1 + color * 0.025 - tone * 0.065)
            output = highlightShadow(output, highlights: 0.97, shadows: tone * 0.035)
        case .omega:
            let red = 0.27 + color * 0.055
            let green = 0.64 - color * 0.035
            let blue = 0.09 - color * 0.020
            output = blackAndWhite(output, red: red, green: green, blue: blue, tint: CIColor(red: 0.72, green: 0.70, blue: 0.67))
            output = controls(output, saturation: 0, brightness: 0, contrast: 1 + color * 0.035 - tone * 0.075)
            output = highlightShadow(output, highlights: 0.96 - max(0, tone) * 0.040, shadows: tone * 0.045)
        }
        output = exposure(output, ev: tone * 0.12)
        return output.cropped(to: image.extent)
    }

    private static func applyGradeStyle(_ style: GradeStyle, to image: CIImage, point: CGPoint) -> CIImage {
        let color = Double(point.x - 0.5) * 2
        let tone = Double(0.5 - point.y) * 2
        var output = image

        switch style {
        case .pure:
            output = controls(output, saturation: 1.0 + color * 0.055, brightness: 0, contrast: 1.025 - tone * 0.018)
            output = vibrance(output, amount: 0.04 + color * 0.08)
            output = highlightShadow(output, highlights: 0.91, shadows: 0.015 + tone * 0.035)
        case .air:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6650 + color * 260, y: -2 - color))
            output = controls(output, saturation: 0.94 + color * 0.055, brightness: 0, contrast: 0.955 - tone * 0.025)
            output = highlightShadow(output, highlights: 0.86, shadows: 0.085 + tone * 0.045)
        case .glow:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5500 - color * 260, y: 3 + color * 1.5))
            output = controls(output, saturation: 0.98 + color * 0.05, brightness: 0, contrast: 0.985 - tone * 0.025)
            output = highlightShadow(output, highlights: 0.80 - color * 0.025, shadows: 0.045 + tone * 0.035)
            output = splitTone(output, shadow: CIColor(red: 0.42, green: 0.43, blue: 0.46), highlight: CIColor(red: 0.96, green: 0.78, blue: 0.60), amount: 0.045 + color * 0.025, placement: 0.22)
        case .soft:
            output = controls(output, saturation: 0.88 + color * 0.075, brightness: 0, contrast: 0.94 - tone * 0.025)
            output = highlightShadow(output, highlights: 0.84, shadows: 0.105 + tone * 0.045)
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6000 - color * 170, y: color * 1.5))
        case .rich:
            output = controls(output, saturation: 1.065 + color * 0.10, brightness: 0, contrast: 1.13 - tone * 0.035)
            output = vibrance(output, amount: 0.13 + color * 0.12)
            output = highlightShadow(output, highlights: 0.89, shadows: -0.025 + tone * 0.035)
        case .chrome:
            output = controls(output, saturation: 1.04 + color * 0.085, brightness: 0, contrast: 1.095 - tone * 0.03)
            output = channelMix(output, red: (1.035 + color * 0.025, -0.008, -0.004), green: (-0.006, 0.975 - color * 0.025, 0.006), blue: (-0.008, 0.004, 1.045 + color * 0.035))
            output = vibrance(output, amount: 0.11 + color * 0.11)
        case .fade:
            output = controls(output, saturation: 0.84 + color * 0.075, brightness: 0, contrast: 0.91 - tone * 0.025)
            output = highlightShadow(output, highlights: 0.82, shadows: 0.15 + tone * 0.045)
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5900 - color * 180, y: 1.5))
        case .ember:
            output = temperature(output, neutral: CIVector(x: 6300, y: 0), target: CIVector(x: 5550 - color * 320, y: 4 + color * 2))
            output = channelMix(output, red: (1.035 + color * 0.025, 0.008, -0.006), green: (0.004, 0.995, -0.004), blue: (0.002, -0.006, 0.965 - color * 0.018))
            output = controls(output, saturation: 1.0 + color * 0.075, brightness: 0, contrast: 1.04 - tone * 0.03)
            output = splitTone(output, shadow: CIColor(red: 0.40, green: 0.40, blue: 0.43), highlight: CIColor(red: 0.94, green: 0.58, blue: 0.34), amount: 0.055 + color * 0.03, placement: 0.18)
        case .blush:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 5800 - color * 180, y: -1.5 - color))
            output = channelMix(output, red: (1.022 + color * 0.018, 0.007, 0.002), green: (0.002, 0.988, 0.004), blue: (0.006, 0, 0.995))
            output = controls(output, saturation: 0.96 + color * 0.065, brightness: 0, contrast: 0.975 - tone * 0.025)
            output = splitTone(output, shadow: CIColor(red: 0.43, green: 0.42, blue: 0.46), highlight: CIColor(red: 0.94, green: 0.67, blue: 0.63), amount: 0.035 + color * 0.02, placement: 0.25)
        case .moss:
            output = temperature(output, neutral: CIVector(x: 6200, y: 0), target: CIVector(x: 6000 - color * 120, y: 2 + color * 2))
            output = channelMix(output, red: (0.99, 0.008, 0), green: (0.008, 1.015 + color * 0.025, -0.006), blue: (0.003, 0.004, 0.975 - color * 0.018))
            output = controls(output, saturation: 0.91 + color * 0.075, brightness: 0, contrast: 1.045 - tone * 0.03)
        case .tide:
            output = temperature(output, neutral: CIVector(x: 6100, y: 0), target: CIVector(x: 6550 + color * 260, y: -2 - color * 2))
            output = channelMix(output, red: (0.985 - color * 0.012, 0, 0.004), green: (0, 1.008, 0.006), blue: (-0.005, 0.006, 1.03 + color * 0.025))
            output = controls(output, saturation: 0.99 + color * 0.075, brightness: 0, contrast: 1.025 - tone * 0.03)
        case .dusk:
            output = splitTone(output, shadow: CIColor(red: 0.25, green: 0.27, blue: 0.48), highlight: CIColor(red: 0.90, green: 0.64, blue: 0.46), amount: 0.075 + color * 0.04, placement: -0.02)
            output = controls(output, saturation: 0.97 + color * 0.065, brightness: 0, contrast: 1.04 - tone * 0.03)
        case .cinema:
            output = splitTone(output, shadow: CIColor(red: 0.18, green: 0.38, blue: 0.40), highlight: CIColor(red: 0.88, green: 0.62, blue: 0.43), amount: 0.065 + color * 0.035, placement: -0.10)
            output = controls(output, saturation: 0.91 + color * 0.055, brightness: 0, contrast: 1.09 - tone * 0.03)
            output = highlightShadow(output, highlights: 0.88, shadows: -0.01 + tone * 0.03)
        case .neon:
            output = splitTone(output, shadow: CIColor(red: 0.06, green: 0.54, blue: 0.66), highlight: CIColor(red: 0.80, green: 0.18, blue: 0.63), amount: 0.11 + color * 0.055, placement: 0.06)
            output = controls(output, saturation: 1.08 + color * 0.13, brightness: 0, contrast: 1.10 - tone * 0.03)
            output = vibrance(output, amount: 0.18 + color * 0.12)
            output = highlightShadow(output, highlights: 0.86, shadows: -0.01 + tone * 0.025)
        case .silver:
            output = blackAndWhite(output, red: 0.23 + color * 0.035, green: 0.68 - color * 0.025, blue: 0.09 - color * 0.01, tint: CIColor(red: 0.72, green: 0.73, blue: 0.74))
            output = controls(output, saturation: 0, brightness: 0, contrast: 0.98 + color * 0.055 - tone * 0.025)
            output = highlightShadow(output, highlights: 0.83, shadows: 0.055 + tone * 0.04)
        case .ink:
            output = blackAndWhite(output, red: 0.31 + color * 0.045, green: 0.59 - color * 0.03, blue: 0.10 - color * 0.015, tint: CIColor(red: 0.62, green: 0.61, blue: 0.60))
            output = controls(output, saturation: 0, brightness: 0, contrast: 1.18 + color * 0.075 - tone * 0.03)
            output = highlightShadow(output, highlights: 0.87, shadows: -0.035 + tone * 0.035)
        }

        // The pad finish is intentionally bounded. Style-specific transforms above
        // carry most of the color movement; this stage adds continuous density and
        // openness without turning the corners into exposure/saturation extremes.
        if style == .silver || style == .ink {
            output = controls(output, saturation: 0, brightness: 0, contrast: 1 + color * 0.045 - tone * 0.045)
        } else {
            output = controls(output, saturation: 1 + color * 0.07, brightness: 0, contrast: 1 - tone * 0.055)
            output = vibrance(output, amount: color * 0.10)
        }
        output = highlightShadow(output, highlights: 0.96 - max(0, tone) * 0.035, shadows: tone * 0.055)
        output = exposure(output, ev: tone * 0.18)
        return output.cropped(to: image.extent)
    }

    private static func applyAccent(to image: CIImage, accent: AccentColor, point: CGPoint) -> CIImage {
        // Keep Accent tied to the analyzed color, but make the pad's cooler/warmer
        // and highlight/shadow movement visibly legible in the live preview.
        let hueShift = Double(point.x - 0.5) * 0.24
        let placement = Double(0.5 - point.y) * 1.0
        let adjusted = shiftedHue(accent, by: hueShift)
        let opposite = shiftedHue(
            AccentColor(red: adjusted.red, green: adjusted.green, blue: adjusted.blue),
            by: placement >= 0 ? -0.09 : 0.09
        )
        return splitTone(
            image,
            shadow: placement < 0 ? adjusted : opposite,
            highlight: placement >= 0 ? adjusted : opposite,
            amount: 0.88,
            placement: placement
        )
    }

    private static func controls(_ image: CIImage, saturation: Double, brightness: Double, contrast: Double) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast
        ])
    }

    private static func temperature(_ image: CIImage, neutral: CIVector, target: CIVector) -> CIImage {
        image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": neutral, "inputTargetNeutral": target])
    }

    private static func highlightShadow(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": highlights, "inputShadowAmount": shadows])
    }

    private static func vibrance(_ image: CIImage, amount: Double) -> CIImage {
        image.applyingFilter("CIVibrance", parameters: ["inputAmount": amount])
    }

    private static func exposure(_ image: CIImage, ev: Double) -> CIImage {
        image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }

    private static func sharpen(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: amount, kCIInputRadiusKey: radius])
    }

    private static func bloom(_ image: CIImage, radius: Double, intensity: Double) -> CIImage {
        image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: intensity]).cropped(to: image.extent)
    }

    private static func vignette(_ image: CIImage, intensity: Double, radius: Double) -> CIImage {
        image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: intensity, kCIInputRadiusKey: radius])
    }

    private static func monochrome(_ image: CIImage, color: CIColor, intensity: Double) -> CIImage {
        image.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: color, kCIInputIntensityKey: intensity])
    }

    private static func blackAndWhite(
        _ image: CIImage,
        red: Double,
        green: Double,
        blue: Double,
        tint: CIColor
    ) -> CIImage {
        let luminance = CIVector(x: red, y: green, z: blue, w: 0)
        let separated = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luminance,
            "inputGVector": luminance,
            "inputBVector": luminance,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        return monochrome(separated, color: tint, intensity: 0.08)
    }

    private static func channelMix(_ image: CIImage, red: (Double, Double, Double), green: (Double, Double, Double), blue: (Double, Double, Double)) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red.0, y: red.1, z: red.2, w: 0),
            "inputGVector": CIVector(x: green.0, y: green.1, z: green.2, w: 0),
            "inputBVector": CIVector(x: blue.0, y: blue.1, z: blue.2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private static func addGrain(_ image: CIImage, amount: Double, scale: Double, colored: Bool = false) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        var grain = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: image.extent)
        if !colored {
            grain = monochrome(grain, color: .white, intensity: 1)
        }
        grain = grain.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
            "inputBiasVector": CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 0)
        ])
        return grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: image.extent)
    }

    private static func splitTone(_ image: CIImage, shadow: CIColor, highlight: CIColor, amount: Double, placement: Double) -> CIImage {
        let extent = image.extent
        let shadowColor = CIImage(color: shadow).cropped(to: extent)
        let highlightColor = CIImage(color: highlight).cropped(to: extent)
        let pivot = max(-0.45, min(0.45, placement))
        let highlightMask = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: -pivot * 0.18,
            kCIInputContrastKey: 1.32
        ])
        let shadowMask = highlightMask.applyingFilter("CIColorInvert")
        let shadowed = shadowColor.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        let shadowBlend = shadowed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: shadowMask])
        let highlighted = highlightColor.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: shadowBlend])
        let toned = highlighted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: shadowBlend, kCIInputMaskImageKey: highlightMask]).cropped(to: extent)
        return dissolve(image, toned, amount: amount)
    }

    private static func dissolve(_ background: CIImage, _ foreground: CIImage, amount: Double) -> CIImage {
        let alpha = max(0, min(1, amount))
        guard alpha < 0.999 else { return foreground }
        let faded = foreground.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
        ])
        return faded.composited(over: background).cropped(to: background.extent)
    }

    private static func shiftedHue(_ accent: AccentColor, by shift: Double) -> CIColor {
        let uiColor = UIColor(red: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let wrapped = (hue + shift).truncatingRemainder(dividingBy: 1)
        // Keep vivid detected colors from becoming a synthetic global wash at high
        // Accent strength while preserving neutral warm/cool-gray accents.
        let safeSaturation = min(0.68, saturation * 0.86)
        let safeBrightness = min(0.78, max(0.32, brightness))
        let result = UIColor(
            hue: wrapped < 0 ? wrapped + 1 : wrapped,
            saturation: safeSaturation,
            brightness: safeBrightness,
            alpha: alpha
        )
        return CIColor(color: result)
    }

    private static func centerCrop(_ image: CIImage, to targetRatio: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, targetRatio > 0 else { return image }
        let sourceRatio = extent.width / extent.height
        var crop = extent
        if sourceRatio > targetRatio {
            crop.size.width = extent.height * targetRatio
            crop.origin.x = extent.midX - crop.width / 2
        } else {
            crop.size.height = extent.width / targetRatio
            crop.origin.y = extent.midY - crop.height / 2
        }
        return image.cropped(to: crop)
    }

    private static func normalizedCIImage(_ image: UIImage) -> CIImage? {
        if let cgImage = image.cgImage {
            return CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(image.imageOrientation.exifOrientation.rawValue))
        }
        return image.ciImage
    }

    private static func makeUIImage(from image: CIImage, scale: CGFloat) -> UIImage? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

nonisolated private extension UIImage.Orientation {
    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
