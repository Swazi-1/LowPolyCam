import AVFoundation
import UIKit
import Photos
import ImageIO

// MARK: - Photo capture processor

/// Handles a single AVCapturePhotoOutput capture, decoding the delivered
/// image and downscaling it to the requested megapixel target while
/// preserving orientation and capture metadata.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    private let targetMegapixels: Double
    private let willCapture: () -> Void
    private let completion: (UIImage?, Data?, [String: Any]?, String?) -> Void

    init(targetMegapixels: Double,
         willCapture: @escaping () -> Void,
         completion: @escaping (UIImage?, Data?, [String: Any]?, String?) -> Void) {
        self.targetMegapixels = targetMegapixels
        self.willCapture = willCapture
        self.completion = completion
    }

    /// Fires right as the sensor captures the frame — this is when we play
    /// our shutter sound / trigger our screen-flash overlay, so they land
    /// exactly on the real capture moment instead of on button-tap.
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            completion(nil, nil, nil, error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(nil, nil, nil, "Could not read photo data")
            return
        }
        // If no downscale is needed, keep the camera's original bytes
        // (no second HEIC encode — that is why we looked worse than stock
        // Camera but sometimes larger).
        let resized = Self.resize(image, toMegapixels: targetMegapixels)
        let scaled: UIImage
        let passThrough: Data?
        if let cg = image.cgImage, let rcg = resized.cgImage,
           cg.width == rcg.width && cg.height == rcg.height {
            scaled = image
            passThrough = data
        } else {
            scaled = resized
            passThrough = nil
        }
        completion(scaled, passThrough, photo.metadata, nil)
    }

    /// Downscales while keeping aspect ratio and orientation. Never upscales.
    private static func resize(_ image: UIImage, toMegapixels targetMP: Double) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let currentPixels = Double(cg.width * cg.height)
        let targetPixels = targetMP * 1_000_000
        guard targetPixels > 0, currentPixels > targetPixels * 1.02 else { return image }

        let scale = (targetPixels / currentPixels).squareRoot()
        let newWidth = max(1, Int((Double(cg.width) * scale).rounded()))
        let newHeight = max(1, Int((Double(cg.height) * scale).rounded()))

        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        var bitmapInfo = cg.bitmapInfo.rawValue
        bitmapInfo = (bitmapInfo & ~CGBitmapInfo.alphaInfoMask.rawValue) | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(data: nil,
                                       width: newWidth,
                                       height: newHeight,
                                       bitsPerComponent: 8,
                                       bytesPerRow: 0,
                                       space: colorSpace,
                                       bitmapInfo: bitmapInfo) else { return image }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaledCG = context.makeImage() else { return image }
        return UIImage(cgImage: scaledCG, scale: 1, orientation: image.imageOrientation)
    }
}

// MARK: - Photo encoding & metadata

/// Static helpers for encoding stills and attaching capture metadata.
/// Kept separate from the live camera session so Photo mode logic stays isolated.
enum PhotoEncoder {

    /// Encodes as HEIC (what the native Camera app uses) at near-lossless
    /// quality, preserving the image's orientation plus the original EXIF
    /// (ISO, shutter, aperture, focal length, device model, etc.).
    static func encodeHEIC(_ image: UIImage, metadata: [String: Any]?) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        var properties = metadataMatchingDimensions(metadata, cgImage: cgImage)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.97
        properties[kCGImagePropertyOrientation as String] = image.imageOrientation.cgImagePropertyOrientation.rawValue
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// JPEG fallback path that still carries the original capture metadata.
    static func encodeJPEG(_ image: UIImage, metadata: [String: Any]?) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        var properties = metadataMatchingDimensions(metadata, cgImage: cgImage)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.97
        properties[kCGImagePropertyOrientation as String] = image.imageOrientation.cgImagePropertyOrientation.rawValue
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Copies capture metadata but corrects pixel-dimension fields to match
    /// the (possibly downscaled) output image.
    static func metadataMatchingDimensions(_ metadata: [String: Any]?, cgImage: CGImage) -> [String: Any] {
        var properties = metadata ?? [:]
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        properties[kCGImagePropertyPixelWidth as String] = cgImage.width
        properties[kCGImagePropertyPixelHeight as String] = cgImage.height
        return properties
    }
}
