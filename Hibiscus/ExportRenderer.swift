import CoreGraphics
import ImageIO
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

nonisolated enum HibiscusExportFormat: String, CaseIterable, Identifiable, Sendable {
    case photo = "Photo"
    case polaroid = "Instant"
    case palette = "Palette"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .polaroid: "rectangle.portrait"
        case .palette: "swatchpalette"
        }
    }
}

nonisolated struct PolaroidComposition: Sendable {
    var drawingData: Data
    var drawingCanvasSize: CGSize
    var cropScale: Double
    var cropOffset: CGPoint
    var showsMetadata: Bool
    var showsMark: Bool
    var includesLocation: Bool

    static let empty = PolaroidComposition(
        drawingData: Data(),
        drawingCanvasSize: .zero,
        cropScale: 1,
        cropOffset: .zero,
        showsMetadata: false,
        showsMark: true,
        includesLocation: true
    )
}

nonisolated struct PaletteComposition: Sendable {
    var selectedIndices: [Int]
    var showsHexCodes: Bool
    var showsMark: Bool

    static let standard = PaletteComposition(
        selectedIndices: Array(0..<5),
        showsHexCodes: false,
        showsMark: true
    )
}

nonisolated enum PhotoMetadataExtractor {
    static func metadata(from data: Data) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoMetadata()
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let date = dateString.flatMap(parseDate)

        var location: String?
        var latitude: Double?
        var longitude: Double?
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitudeNumber = gps[kCGImagePropertyGPSLatitude] as? NSNumber,
           let longitudeNumber = gps[kCGImagePropertyGPSLongitude] as? NSNumber {
            let isSouth = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
            let isWest = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
            latitude = isSouth ? -latitudeNumber.doubleValue : latitudeNumber.doubleValue
            longitude = isWest ? -longitudeNumber.doubleValue : longitudeNumber.doubleValue
            let northSouth = (latitude ?? 0) >= 0 ? "N" : "S"
            let eastWest = (longitude ?? 0) >= 0 ? "E" : "W"
            location = String(
                format: "%.2f°%@ · %.2f°%@",
                abs(latitude ?? 0), northSouth, abs(longitude ?? 0), eastWest
            )
        }

        return PhotoMetadata(
            date: date,
            location: location,
            city: iptc?[kCGImagePropertyIPTCCity] as? String,
            cameraCharacter: nil,
            latitude: latitude,
            longitude: longitude,
            cameraMake: tiff?[kCGImagePropertyTIFFMake] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

nonisolated enum PaletteAnalyzer {
    static func colors(from image: UIImage, count: Int = 5) -> [AccentColor] {
        guard let sample = ImageRenderer.resizedImage(image, maxDimension: 72),
              let cgImage = sample.cgImage else { return [.warmGray, .coolGray] }

        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [.warmGray, .coolGray] }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        struct Bucket {
            var count = 0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var buckets: [Int: Bucket] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] > 180 else { continue }
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let key = (Int(red * 15) << 8) | (Int(green * 15) << 4) | Int(blue * 15)
            var bucket = buckets[key] ?? Bucket()
            bucket.count += 1
            bucket.red += red
            bucket.green += green
            bucket.blue += blue
            buckets[key] = bucket
        }

        let candidates = buckets.values.sorted { lhs, rhs in
            let lhsAverage = (lhs.red + lhs.green + lhs.blue) / Double(max(1, lhs.count))
            let rhsAverage = (rhs.red + rhs.green + rhs.blue) / Double(max(1, rhs.count))
            let lhsScore = Double(lhs.count) * (0.78 + 0.22 * lhsAverage)
            let rhsScore = Double(rhs.count) * (0.78 + 0.22 * rhsAverage)
            return lhsScore > rhsScore
        }

        var result: [AccentColor] = []
        for bucket in candidates {
            let divisor = Double(max(1, bucket.count))
            let candidate = AccentColor(
                red: bucket.red / divisor,
                green: bucket.green / divisor,
                blue: bucket.blue / divisor
            )
            guard result.allSatisfy({ colorDistance($0, candidate) > 0.13 }) else { continue }
            result.append(candidate)
            if result.count == count { break }
        }
        return result.isEmpty ? [.warmGray] : result
    }

    private static func colorDistance(_ lhs: AccentColor, _ rhs: AccentColor) -> Double {
        sqrt(pow(lhs.red - rhs.red, 2) + pow(lhs.green - rhs.green, 2) + pow(lhs.blue - rhs.blue, 2))
    }
}

nonisolated enum HibiscusExportRenderer {
    static func jpegData(
        for image: UIImage,
        metadata: PhotoMetadata,
        preservesMetadata: Bool,
        includesLocation: Bool
    ) -> Data? {
        guard preservesMetadata, let cgImage = image.cgImage else {
            return image.jpegData(compressionQuality: 0.96)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return image.jpegData(compressionQuality: 0.96) }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.96
        ]
        var tiff: [CFString: Any] = [:]
        if let make = metadata.cameraMake { tiff[kCGImagePropertyTIFFMake] = make }
        if let model = metadata.cameraModel { tiff[kCGImagePropertyTIFFModel] = model }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }

        var exif: [CFString: Any] = [:]
        if let date = metadata.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exif[kCGImagePropertyExifDateTimeOriginal] = formatter.string(from: date)
        }
        if let lens = metadata.lensModel { exif[kCGImagePropertyExifLensModel] = lens }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }

        if includesLocation, let latitude = metadata.latitude, let longitude = metadata.longitude {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W"
            ]
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func render(
        editedImage: UIImage,
        format: HibiscusExportFormat,
        settings: GradeSettings,
        metadata: PhotoMetadata,
        polaroidComposition: PolaroidComposition = .empty,
        paletteComposition: PaletteComposition = .standard
    ) -> UIImage {
        switch format {
        case .photo:
            editedImage
        case .polaroid:
            polaroid(
                image: editedImage,
                settings: settings,
                metadata: metadata,
                composition: polaroidComposition
            )
        case .palette:
            palette(image: editedImage, composition: paletteComposition)
        }
    }

    private static func polaroid(
        image: UIImage,
        settings: GradeSettings,
        metadata: PhotoMetadata,
        composition: PolaroidComposition
    ) -> UIImage {
        let canvas = CGSize(width: 1800, height: 2320)
        let photoRect = CGRect(x: 90, y: 90, width: 1620, height: 1620)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor(red: 0.955, green: 0.947, blue: 0.918, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            drawAspectFill(
                image,
                in: photoRect,
                scale: CGFloat(composition.cropScale),
                offset: composition.cropOffset
            )

            if composition.showsMetadata {
                drawPolaroidMetadata(
                    metadata,
                    settings: settings,
                    includesLocation: composition.includesLocation,
                    in: canvas,
                    context: context.cgContext
                )
            }

            if composition.showsMark {
                drawBrandMark(
                    centeredAt: CGPoint(
                        x: canvas.width * (composition.showsMetadata ? 0.86 : 0.5),
                        y: canvas.height * 0.865
                    ),
                    iconSize: canvas.width * 0.073,
                    spacing: canvas.width * 0.018,
                    fontSize: canvas.width * 0.027
                )
            }

            drawPencilDrawing(composition, in: canvas)
        }
    }

    private static func palette(image: UIImage, composition: PaletteComposition) -> UIImage {
        let width: CGFloat = 1800
        let ratio = image.size.width / max(1, image.size.height)
        let photoHeight = max(width * 0.55, min(width * 1.8, width / max(0.01, ratio)))
        let colorHeight: CGFloat = 150
        let brandHeight: CGFloat = composition.showsMark ? 180 : 0
        let footerHeight = colorHeight + brandHeight
        let canvas = CGSize(width: width, height: photoHeight + footerHeight)
        let candidates = PaletteAnalyzer.colors(from: image, count: 5)
        var colors = composition.selectedIndices
            .sorted()
            .compactMap { candidates.indices.contains($0) ? candidates[$0] : nil }
        if colors.isEmpty { colors = Array(candidates.prefix(1)) }
        let hexTextColor = paletteHexTextColor(for: colors)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor(red: 0.965, green: 0.958, blue: 0.938, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            drawAspectFit(image, in: CGRect(x: 0, y: 0, width: width, height: photoHeight))

            let blockWidth = width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                let uiColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
                uiColor.setFill()
                let blockRect = CGRect(
                    x: CGFloat(index) * blockWidth,
                    y: photoHeight,
                    width: blockWidth + 1,
                    height: colorHeight
                )
                context.cgContext.fill(blockRect)
                if composition.showsHexCodes {
                    let hex = hexString(for: color)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .semibold),
                        .foregroundColor: hexTextColor
                    ]
                    let textSize = hex.size(withAttributes: attributes)
                    hex.draw(
                        at: CGPoint(x: blockRect.midX - textSize.width / 2, y: blockRect.midY - textSize.height / 2),
                        withAttributes: attributes
                    )
                }
            }

            if composition.showsMark {
                let brandArea = CGRect(x: 0, y: photoHeight + colorHeight, width: width, height: brandHeight)
                drawBrandMark(
                    centeredAt: CGPoint(x: brandArea.midX, y: brandArea.midY),
                    iconSize: width * 0.042,
                    spacing: width * 0.006,
                    fontSize: width * 0.019
                )
            }
        }
    }

    private static func drawAspectFit(_ image: UIImage, in rect: CGRect) {
        let ratio = image.size.width / max(1, image.size.height)
        let targetRatio = rect.width / rect.height
        let drawRect: CGRect
        if ratio > targetRatio {
            let height = rect.width / ratio
            drawRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        } else {
            let width = rect.height * ratio
            drawRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        image.draw(in: drawRect)
    }

    private static func drawPolaroidMetadata(
        _ metadata: PhotoMetadata,
        settings: GradeSettings,
        includesLocation: Bool,
        in canvas: CGSize,
        context: CGContext
    ) {
        var lines: [String] = []
        if let date = metadata.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d yyyy · HH:mm"
            lines.append(formatter.string(from: date).uppercased())
        }
        if includesLocation, let location = metadata.displayLocation {
            lines.append(location.uppercased())
        }
        let camera = metadata.cameraCharacter.map { "\($0.symbol) \($0.name.uppercased()) · " } ?? ""
        lines.append("\(camera)\(settings.style.rawValue.uppercased())")

        context.saveGState()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 29, weight: .medium),
            .foregroundColor: UIColor(white: 0.22, alpha: 0.74),
            .paragraphStyle: paragraphStyle
        ]
        let text = lines.prefix(3).joined(separator: "\n") as NSString
        let textWidth = canvas.width * 0.61
        let measured = text.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        text.draw(
            in: CGRect(
                x: canvas.width * 0.36 - textWidth / 2,
                y: canvas.height * 0.855 - ceil(measured.height) / 2,
                width: textWidth,
                height: ceil(measured.height)
            ),
            withAttributes: attributes
        )
        context.restoreGState()
    }

    private static func hexString(for color: AccentColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int(min(1, max(0, color.red)) * 255),
            Int(min(1, max(0, color.green)) * 255),
            Int(min(1, max(0, color.blue)) * 255)
        )
    }

    static func paletteHexTextColor(for colors: [AccentColor]) -> UIColor {
        guard !colors.isEmpty else { return UIColor(white: 0.08, alpha: 0.84) }
        let averageLuminance = colors.reduce(0.0) { result, color in
            result + 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        } / Double(colors.count)
        return averageLuminance >= 0.42
            ? UIColor(white: 0.08, alpha: 0.84)
            : UIColor(white: 1, alpha: 0.92)
    }

    private static func drawAspectFill(
        _ image: UIImage,
        in rect: CGRect,
        scale: CGFloat = 1,
        offset: CGPoint = .zero
    ) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let sourceRatio = image.size.width / max(1, image.size.height)
        let targetRatio = rect.width / rect.height
        var drawRect = rect
        if sourceRatio > targetRatio {
            drawRect.size.width = rect.height * sourceRatio
            drawRect.origin.x = rect.midX - drawRect.width / 2
        } else {
            drawRect.size.height = rect.width / sourceRatio
            drawRect.origin.y = rect.midY - drawRect.height / 2
        }
        let safeScale = max(1, min(3, scale))
        drawRect = CGRect(
            x: rect.midX - drawRect.width * safeScale / 2 + offset.x * rect.width,
            y: rect.midY - drawRect.height * safeScale / 2 + offset.y * rect.height,
            width: drawRect.width * safeScale,
            height: drawRect.height * safeScale
        )
        context.saveGState()
        context.clip(to: rect)
        image.draw(in: drawRect)
        context.restoreGState()
    }

    private static func drawPencilDrawing(_ composition: PolaroidComposition, in canvas: CGSize) {
        guard !composition.drawingData.isEmpty,
              composition.drawingCanvasSize.width > 0,
              composition.drawingCanvasSize.height > 0,
              let drawing = try? PKDrawing(data: composition.drawingData) else { return }
        let scale = canvas.width / composition.drawingCanvasSize.width
        drawing.image(
            from: CGRect(origin: .zero, size: composition.drawingCanvasSize),
            scale: scale
        ).draw(in: CGRect(origin: .zero, size: canvas))
    }

    private static func drawAppIcon(in rect: CGRect) {
        guard let icon = HibiscusBrand.appIcon() else { return }
        icon.draw(in: rect)
    }

    private static func drawBrandMark(
        centeredAt center: CGPoint,
        iconSize: CGFloat,
        spacing: CGFloat,
        fontSize: CGFloat
    ) {
        let brand = "Hibiscus" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor(white: 0.17, alpha: 0.72)
        ]
        let brandSize = brand.size(withAttributes: attributes)
        let contentHeight = iconSize + spacing + brandSize.height
        let markRect = CGRect(
            x: center.x - iconSize / 2,
            y: center.y - contentHeight / 2,
            width: iconSize,
            height: iconSize
        )
        drawAppIcon(in: markRect)
        brand.draw(
            at: CGPoint(
                x: center.x - brandSize.width / 2,
                y: markRect.maxY + spacing
            ),
            withAttributes: attributes
        )
    }
}

nonisolated enum HibiscusBrand {
    static func appIcon() -> UIImage? {
        // App-icon renditions supplied by iOS are opaque square resources meant
        // to receive a system mask. Use the bundled transparent artwork for
        // exports so its complete rounded-square silhouette remains intact.
        if let image = UIImage(named: "HibiscusBrandIcon") { return image }

        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primaryIcon?["CFBundleIconFiles"] as? [String] ?? []
        for name in iconFiles.reversed() {
            if let image = UIImage(named: name) { return image }
            if let path = Bundle.main.path(forResource: name, ofType: nil),
               let image = UIImage(contentsOfFile: path) { return image }
        }
        return ["AppIcon", "AppIcon60x60", "AppIcon76x76"]
            .lazy
            .compactMap(UIImage.init(named:))
            .first
    }
}
