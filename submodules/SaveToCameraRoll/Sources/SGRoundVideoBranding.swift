import Foundation
import UIKit
import AVFoundation
import CoreImage

// Zenlygram — a saved round video message ("krujok") is exported as a square video: the circle filling a dark
// square, the animated Zenlygram logo in the bottom-left corner and "ZENLYGRAM" along the circle's bottom-right edge.
enum SGRoundVideoBranding {
    static let renderSize = CGSize(width: 1080.0, height: 1080.0)
    static let circleDiameter: CGFloat = 1080.0

    // The logo animation: a sprite sheet of 90 frames (3 s at 30 fps), 10 per row, each 110×133 px, drawn with its
    // top-left corner at `logoOrigin` (y-down render space).
    private static let logoFrameSize = CGSize(width: 110.0, height: 133.0)
    private static let logoFrameCount = 90
    private static let logoFramesPerRow = 10
    private static let logoFrameRate: Double = 30.0
    private static let logoOrigin = CGPoint(x: 49.0, y: 911.0)

    /// Renders `inputURL` (the square round-video file) into `outputURL` (mp4). Completes with false on any failure;
    /// the caller then saves the original file.
    static func export(inputURL: URL, outputURL: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: inputURL)
        guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first else {
            completion(false)
            return
        }
        let duration = asset.duration
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(false)
            return
        }
        do {
            try videoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            videoTrack.preferredTransform = sourceVideoTrack.preferredTransform
            if let sourceAudioTrack = asset.tracks(withMediaType: .audio).first, let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            }
        } catch {
            completion(false)
            return
        }

        let bounds = CGRect(origin: .zero, size: renderSize)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let circleRect = CGRect(x: center.x - circleDiameter / 2.0, y: center.y - circleDiameter / 2.0, width: circleDiameter, height: circleDiameter)
        guard let layers = staticLayers(circleRect: circleRect) else {
            completion(false)
            return
        }

        // Every frame: the background with the wordmark, the video in the circle, then the current logo frame.
        // Core Image is y-up; the static layers were drawn y-down, which CIImage(cgImage:) already accounts for.
        let videoComposition = AVMutableVideoComposition(asset: composition, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage
            let sourceExtent = source.extent
            let shortSide = min(sourceExtent.width, sourceExtent.height)
            guard shortSide > 0.0 else {
                request.finish(with: NSError(domain: "SGRoundVideoBranding", code: 1))
                return
            }
            let scale = circleDiameter / shortSide
            let video = source
                .transformed(by: CGAffineTransform(translationX: -sourceExtent.midX, y: -sourceExtent.midY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))

            var image = video.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: layers.background,
                kCIInputMaskImageKey: layers.circleMask
            ])
            if !layers.logoFrames.isEmpty {
                let index = Int(request.compositionTime.seconds * logoFrameRate) % layers.logoFrames.count
                image = layers.logoFrames[max(0, index)].composited(over: image)
            }
            request.finish(with: image.cropped(to: bounds), context: nil)
        })
        videoComposition.renderSize = renderSize
        let frameRate = sourceVideoTrack.nominalFrameRate > 0.0 ? sourceVideoTrack.nominalFrameRate : 30.0
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(60.0, frameRate.rounded())))

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(false)
            return
        }
        let _ = try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.exportAsynchronously {
            completion(session.status == .completed)
        }
    }

    private struct StaticLayers {
        let background: CIImage
        let circleMask: CIImage
        /// Each logo frame already placed in the render space.
        let logoFrames: [CIImage]
    }

    /// Everything drawn once: the dark background with the wordmark, the circle mask and the logo frames.
    private static func staticLayers(circleRect: CGRect) -> StaticLayers? {
        let bounds = CGRect(origin: .zero, size: renderSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)

        let background = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let colors = [UIColor(white: 0.17, alpha: 1.0).cgColor, UIColor(white: 0.03, alpha: 1.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY), end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
            }
            drawArcWordmark(in: context, center: CGPoint(x: circleRect.midX, y: circleRect.midY))
        }
        let circleMask = renderer.image { rendererContext in
            rendererContext.cgContext.setFillColor(UIColor.white.cgColor)
            rendererContext.cgContext.fillEllipse(in: circleRect)
        }
        guard let backgroundImage = background.cgImage, let maskImage = circleMask.cgImage else {
            return nil
        }

        var logoFrames: [CIImage] = []
        if let sheet = UIImage(named: "ZenlygramRoundVideoLogoAnimation")?.cgImage {
            let placement = CGAffineTransform(translationX: logoOrigin.x, y: renderSize.height - logoOrigin.y - logoFrameSize.height)
            for index in 0 ..< logoFrameCount {
                let cell = CGRect(
                    x: CGFloat(index % logoFramesPerRow) * logoFrameSize.width,
                    y: CGFloat(index / logoFramesPerRow) * logoFrameSize.height,
                    width: logoFrameSize.width,
                    height: logoFrameSize.height
                )
                guard let frame = sheet.cropping(to: cell) else {
                    logoFrames = []
                    break
                }
                logoFrames.append(CIImage(cgImage: frame).transformed(by: placement))
            }
        }

        return StaticLayers(
            background: CIImage(cgImage: backgroundImage),
            circleMask: CIImage(cgImage: maskImage),
            logoFrames: logoFrames
        )
    }

    /// "ZENLYGRAM", widely spaced, glyph by glyph along an arc just outside the circle, centred a little below the
    /// bottom-right diagonal, reading counter-clockwise with the glyphs upright towards the circle.
    private static func drawArcWordmark(in context: CGContext, center: CGPoint) {
        let font = UIFont.systemFont(ofSize: 27.0, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let text = "ZENLYGRAM"
        let tracking: CGFloat = 15.0
        let glyphWidths = text.map { (String($0) as NSString).size(withAttributes: attributes).width }
        let baselineRadius: CGFloat = 573.0
        // Arc length is measured on the glyphs' middle line, which lies inside the baseline here.
        let middleRadius = baselineRadius - font.capHeight / 2.0
        let runLength = glyphWidths.reduce(0.0, +) + tracking * CGFloat(glyphWidths.count - 1)
        var angle = -44.8 * CGFloat.pi / 180.0 - runLength / middleRadius / 2.0

        for (character, width) in zip(text, glyphWidths) {
            let theta = angle + width / middleRadius / 2.0
            let point = CGPoint(x: center.x + baselineRadius * cos(theta), y: center.y - baselineRadius * sin(theta))
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.rotate(by: -(CGFloat.pi / 2.0 + theta))
            (String(character) as NSString).draw(at: CGPoint(x: -width / 2.0, y: -font.ascender), withAttributes: attributes)
            context.restoreGState()
            angle += (width + tracking) / middleRadius
        }
    }
}
