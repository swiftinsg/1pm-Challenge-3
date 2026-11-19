//
//  ThumbnailService.swift
//  1pm Challenge 3
//

import Foundation
import Photos
import QuickLookThumbnailing
import UIKit

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

        let image = await withCheckedContinuation { continuation in
            let gate = ThumbnailGate(continuation)
            let options = PHImageRequestOptions()
            // iCloud-only photos should still show their picture.
            options.isNetworkAccessAllowed = true
            options.version = .current
            // A 256 px fast thumbnail is enough for every small preview and
            // arrives in a fraction of the time of a full-quality decode.
            options.deliveryMode = .fastFormat
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

        let image = await withCheckedContinuation { continuation in
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

        if let image {
            ThumbnailCache.store(image, forFile: url)
        }

        return image
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
