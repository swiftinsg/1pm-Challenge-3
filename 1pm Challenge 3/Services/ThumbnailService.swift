//
//  ThumbnailService.swift
//  1pm Challenge 3
//

import AVFoundation
import Foundation
import ImageIO
import Photos
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Shared, cost-limited memory cache for the small previews shown in category
/// headers, overview centres and item rows. Using one cache means a thumbnail
/// produced by the scan is reused instantly when the item list opens.
enum ThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 260
        // Roughly 48 MB of decoded pixels. NSCache evicts automatically under
        // memory pressure, so a large library can never grow this without end.
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func key(forAsset identifier: String) -> NSString {
        "a:\(identifier)" as NSString
    }

    static func key(forFile url: URL) -> NSString {
        "f:\(url.path)" as NSString
    }

    static func image(for item: OverviewItem) -> UIImage? {
        if let identifier = item.assetIdentifier {
            return shared.object(forKey: key(forAsset: identifier))
        }

        if let url = item.fileURL {
            return shared.object(forKey: key(forFile: url))
        }

        return nil
    }

    static func store(_ image: UIImage, forAsset identifier: String) {
        shared.setObject(
            image,
            forKey: key(forAsset: identifier),
            cost: cost(of: image)
        )
    }

    static func store(_ image: UIImage, forFile url: URL) {
        shared.setObject(
            image,
            forKey: key(forFile: url),
            cost: cost(of: image)
        )
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// Loads the small preview for one overview item. Rows, category headers and
/// the overview centre all request the same 256 px image, so the first load is
/// shared by every place that shows it.
enum ThumbnailLoader {
    static let pixelSize: CGFloat = 256

    static func image(for item: OverviewItem) async -> UIImage? {
        if let cached = ThumbnailCache.image(for: item) {
            return cached
        }

        if let identifier = item.assetIdentifier {
            return await photo(identifier: identifier)
        }

        if let url = item.fileURL {
            return await file(url: url)
        }

        return nil
    }

    static func photo(identifier: String) async -> UIImage? {
        let key = ThumbnailCache.key(forAsset: identifier)
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            return cached
        }

        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
        )
        guard let asset = assets.firstObject else { return nil }

        // The fast thumbnail request is cheapest, but some libraries (and the
        // iOS 27 simulator) answer it with "No resource found matching image
        // request spec". Falling back to the asset's image data or video
        // poster frame keeps every row showing the real item.
        var image = await requestedImage(for: asset)

        if image == nil {
            if asset.mediaType == .video {
                image = await videoPosterFrame(for: asset)
            } else {
                image = await imageThumbnailFromData(for: asset)
            }
        }

        if let image {
            ThumbnailCache.store(image, forAsset: identifier)
        }

        return image
    }

    static func file(url: URL) async -> UIImage? {
        let key = ThumbnailCache.key(forFile: url)
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            return cached
        }

        // Image files are decoded from their own contents first. Quick Look can
        // return a generic document icon for imported images, which makes the
        // row look empty even though the file contains a picture.
        var image: UIImage?
        if isImageFile(url) {
            image = downsampledImage(from: url)
        }
        if image == nil {
            image = await quickLookThumbnail(for: url)
        }

        if let image {
            ThumbnailCache.store(image, forFile: url)
        }

        return image
    }

    private static func quickLookThumbnail(for url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: pixelSize, height: pixelSize),
                scale: 1,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            ) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }

        return type.conforms(to: .image)
    }

    // MARK: - PhotoKit fallbacks

    private static func requestedImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let gate = ThumbnailGate(continuation)
            let options = PHImageRequestOptions()
            // iCloud-only photos should still show their picture.
            options.isNetworkAccessAllowed = true
            options.version = .current
            // High-quality delivery with fast resizing matches the request
            // that produced reliable row previews before the overview rework.
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixelSize, height: pixelSize),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                gate.finish(image)
            }
        }
    }

    private static func imageThumbnailFromData(for asset: PHAsset) async -> UIImage? {
        let data: Data? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }

        guard let data else { return nil }
        return downsampledImage(from: data)
    }

    private static func videoPosterFrame(for asset: PHAsset) async -> UIImage? {
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic

            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }

        guard let avAsset else { return nil }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)

        let duration = avAsset.duration.seconds
        let seconds = duration.isFinite ? min(max(duration * 0.1, 0), 1) : 0

        do {
            let (cgImage, _) = try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            )
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private static func downsampledImage(
        from data: Data,
        maxPixelSize: CGFloat = pixelSize
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }

        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func downsampledImage(
        from url: URL,
        maxPixelSize: CGFloat = pixelSize
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }

        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(
        from source: CGImageSource,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private final class ThumbnailGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var isFinished = false

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func finish(_ image: UIImage?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: image)
    }
}
