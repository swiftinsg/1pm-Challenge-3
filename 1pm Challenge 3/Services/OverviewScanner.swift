//
//  OverviewScanner.swift
//  1pm Challenge 3
//

import CryptoKit
import Foundation
import Photos
import Vision

/// Reads the real photo library and the app's visible folders. Each item is
/// measured once and carries flags, so the view model can place it in several
/// categories without re-reading the item. All work happens off the main
/// thread and checks `Task.isCancelled` between items.
enum OverviewScanner {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    static func scan(
        kind: StorageCategory,
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        switch kind {
        case .photos, .videos:
            return await scanMedia(kind: kind, progress: progress)
        case .files:
            return await scanFiles(progress: progress)
        }
    }

    // MARK: - Photos and videos

    private static func scanMedia(
        kind: StorageCategory,
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        let access = accessState(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))

        guard access == .authorized || access == .limited else {
            return .empty(accessState: access)
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false

        let fetch = PHAsset.fetchAssets(
            with: kind == .photos ? .image : .video,
            options: options
        )

        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        guard !assets.isEmpty else {
            return .empty(accessState: access)
        }

        if kind == .photos {
            return await scanPhotos(assets: assets, access: access, progress: progress)
        }

        var items: [OverviewItem] = []
        items.reserveCapacity(assets.count)
        var seenDigests = Set<String>()
        var skippedItems = 0

        for (index, asset) in assets.enumerated() {
            if Task.isCancelled { break }

            guard let measured = await measureVideo(asset) else {
                skippedItems += 1
                await report(index: index, total: assets.count, progress: progress)
                continue
            }

            let isDuplicate = !seenDigests.insert(measured.digest).inserted

            items.append(
                OverviewItem(
                    id: asset.localIdentifier,
                    name: measured.name,
                    bytes: measured.bytes,
                    date: asset.creationDate,
                    assetIdentifier: asset.localIdentifier,
                    fileURL: nil,
                    isVideo: true,
                    isDuplicate: isDuplicate,
                    isScreenRecording: measured.isScreenRecording
                )
            )

            await report(index: index, total: assets.count, progress: progress)
        }

        return OverviewScanResult(
            items: items,
            accessState: access,
            skippedItems: skippedItems
        )
    }

    // MARK: - Photos

    /// Photos are measured in two passes:
    ///
    /// 1. Cheap metadata (size, filename, dimensions) for every asset. This is
    ///    fast even for very large libraries.
    /// 2. QR/blur analysis on small, locally available thumbnails, run several
    ///    at a time.
    ///
    /// Earlier versions streamed and hashed each original image (and downloaded
    /// iCloud originals) just to fill the same fields, which made a large
    /// library take minutes.
    private static func scanPhotos(
        assets: [PHAsset],
        access: PhotoAccessState,
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        var items: [OverviewItem] = []
        items.reserveCapacity(assets.count)
        var assetsByID: [String: PHAsset] = [:]
        assetsByID.reserveCapacity(assets.count)
        var seenDigests = Set<String>()
        var skippedItems = 0

        for asset in assets {
            if Task.isCancelled { break }

            guard let measured = await measurePhotoMetadata(asset) else {
                skippedItems += 1
                continue
            }

            let isDuplicate = !seenDigests.insert(measured.digest).inserted
            assetsByID[asset.localIdentifier] = asset

            items.append(
                OverviewItem(
                    id: asset.localIdentifier,
                    name: measured.name,
                    bytes: measured.bytes,
                    date: asset.creationDate,
                    assetIdentifier: asset.localIdentifier,
                    fileURL: nil,
                    isVideo: false,
                    isScreenshot: measured.isScreenshot,
                    isDuplicate: isDuplicate
                )
            )
        }

        guard !Task.isCancelled else {
            return OverviewScanResult(
                items: items,
                accessState: access,
                skippedItems: skippedItems
            )
        }

        let flags = await analyzePhotos(
            items: items,
            assetsByID: assetsByID,
            progress: progress
        )

        for index in items.indices {
            guard let flag = flags[items[index].id] else { continue }
            items[index].hasQRCode = flag.hasQRCode
            items[index].isBlurry = flag.isBlurry
        }

        return OverviewScanResult(
            items: items,
            accessState: access,
            skippedItems: skippedItems
        )
    }

    private struct PhotoFlags: Sendable {
        var hasQRCode: Bool
        var isBlurry: Bool
    }

    private struct PhotoMeasurement {
        var bytes: Int64
        var digest: String
        var name: String
        var isScreenshot: Bool
    }

    private static func measurePhotoMetadata(_ asset: PHAsset) async -> PhotoMeasurement? {
        guard let resource = AssetSizeMeasurement.primaryResource(for: asset) else {
            return nil
        }

        // PhotoKit exposes the resource's size without transferring the image,
        // including for iCloud-optimised libraries. Only fall back to counting
        // bytes when that value is unavailable. The shared measurement also
        // includes Live Photo motion and edit data, so it matches Home exactly.
        var bytes = AssetSizeMeasurement.measure(asset)?.bytes

        if bytes == nil,
           let counted = await loadResourceData(
               resource,
               allowNetwork: false,
               keepData: false
           ), counted.bytes > 0 {
            bytes = counted.bytes
        }

        guard let bytes, bytes > 0 else { return nil }

        let name = resource.originalFilename

        // True copies share a size, pixel geometry and filename. Comparing
        // that metadata avoids hashing every original, which was the single
        // slowest part of the old scan.
        let fingerprint = "\(bytes)|\(asset.pixelWidth)x\(asset.pixelHeight)|\(name)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return PhotoMeasurement(
            bytes: bytes,
            digest: digest,
            name: name,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }

    /// Runs QR and blur detection with a small worker pool so a large library
    /// uses several cores instead of analysing one photo at a time.
    private static func analyzePhotos(
        items: [OverviewItem],
        assetsByID: [String: PHAsset],
        progress: @escaping ProgressHandler
    ) async -> [String: PhotoFlags] {
        let total = items.count
        guard total > 0 else { return [:] }

        var flags: [String: PhotoFlags] = [:]
        flags.reserveCapacity(total)

        let workerCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var completed = 0

        await withTaskGroup(of: (String, PhotoFlags).self) { group in
            var nextIndex = 0

            func submitNext() {
                while nextIndex < items.count {
                    let item = items[nextIndex]
                    nextIndex += 1

                    guard let asset = assetsByID[item.id] else { continue }

                    group.addTask {
                        (item.id, await analyzePhoto(asset))
                    }
                    return
                }
            }

            for _ in 0..<workerCount {
                submitNext()
            }

            while let (id, flag) = await group.next() {
                flags[id] = flag
                completed += 1

                if completed % 8 == 0 || completed == total {
                    await progress(Double(completed) / Double(total))
                }

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                submitNext()
            }
        }

        return flags
    }

    private static func analyzePhoto(_ asset: PHAsset) async -> PhotoFlags {
        guard let image = await thumbnail(for: asset) else {
            return PhotoFlags(hasQRCode: false, isBlurry: false)
        }

        return PhotoFlags(
            hasQRCode: containsQRCode(image),
            isBlurry: isBlurry(image)
        )
    }

    /// Returns a small, already-decoded thumbnail. Network access is disabled,
    /// so an iCloud-only photo is skipped instead of downloading the original.
    private static func thumbnail(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let gate = ImageRequestGate(continuation)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.version = .current

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // Keep the thumbnail the scan already decoded. The category
                // pages then show real previews instantly instead of loading
                // the same image again (and flashing a placeholder).
                if let image {
                    ThumbnailCache.store(
                        image,
                        forAsset: asset.localIdentifier
                    )
                }

                if let cgImage = image?.cgImage {
                    gate.resume(cgImage)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                let wasCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                let failed = info?[PHImageErrorKey] != nil

                if !isDegraded || wasCancelled || failed {
                    gate.resume(nil)
                }
            }
        }
    }

    private struct VideoMeasurement {
        var bytes: Int64
        var digest: String
        var name: String
        var isScreenRecording: Bool
    }

    private static func measureVideo(_ asset: PHAsset) async -> VideoMeasurement? {
        // Use the exact same measurement as Home and the Photos list, so the
        // Videos page total always matches the Videos legend on Home.
        guard let measurement = AssetSizeMeasurement.measure(asset) else {
            return nil
        }

        let bytes = measurement.bytes

        // Comparing the same stable metadata for both measurement paths keeps
        // duplicate detection consistent without reading every video twice.
        let durationMilliseconds = Int((asset.duration * 1000).rounded())
        let fingerprint = "\(bytes)|\(durationMilliseconds)|\(asset.pixelWidth)x\(asset.pixelHeight)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return VideoMeasurement(
            bytes: bytes,
            digest: digest,
            name: measurement.name,
            isScreenRecording: asset.mediaSubtypes.contains(.videoScreenRecording)
        )
    }

    private static func report(
        index: Int,
        total: Int,
        progress: @escaping ProgressHandler
    ) async {
        guard total > 0 else { return }
        guard index % 8 == 0 || index == total - 1 else { return }
        await progress(Double(index + 1) / Double(total))
    }

    // MARK: - Files

    private static func collectFileURLs(
        in documents: URL,
        keys: Set<URLResourceKey>
    ) -> [URL] {
        var urls: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: documents,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return urls
        }

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            urls.append(url)
        }

        return urls
    }

    private static func scanFiles(
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        guard let documents = try? DocumentLibrary.documentsDirectory() else {
            return .empty(accessState: .notApplicable)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        let urls = collectFileURLs(in: documents, keys: keys)

        guard !urls.isEmpty else {
            return .empty(accessState: .notApplicable)
        }

        var items: [OverviewItem] = []
        items.reserveCapacity(urls.count)
        var seenDigests = Set<String>()

        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }

            guard let values = try? url.resourceValues(forKeys: keys) else {
                continue
            }

            let bytes = Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
            let date = values.contentModificationDate
            let digest = fileDigest(url)
            let isDuplicate = digest.map { seenDigests.contains($0) } ?? false
            if let digest { seenDigests.insert(digest) }

            let isDownload = url.pathComponents
                .dropLast()
                .contains { $0.caseInsensitiveCompare("Downloads") == .orderedSame }

            items.append(
                OverviewItem(
                    id: url.path,
                    name: url.lastPathComponent,
                    bytes: bytes,
                    date: date,
                    assetIdentifier: nil,
                    fileURL: url,
                    isVideo: false,
                    isDuplicate: isDuplicate,
                    isDownload: isDownload
                )
            )

            if index % 10 == 0 || index == urls.count - 1 {
                await progress(Double(index + 1) / Double(urls.count))
            }
        }

        return OverviewScanResult(
            items: items,
            accessState: .notApplicable,
            skippedItems: 0
        )
    }

    private static func accessState(from status: PHAuthorizationStatus) -> PhotoAccessState {
        switch status {
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    // MARK: - Image analysis

    private static func containsQRCode(_ image: CGImage) -> Bool {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        do {
            try VNImageRequestHandler(
                cgImage: image,
                orientation: .up
            ).perform([request])
        } catch {
            return false
        }

        return !(request.results?.isEmpty ?? true)
    }

    /// Vision does not expose a public sharpness score, so this uses a
    /// conservative normalised gradient measure. A low average difference
    /// between neighbouring pixels indicates an image with almost no detail.
    private static func isBlurry(_ image: CGImage) -> Bool {
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height)

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }

        guard didDraw else { return false }

        var total = 0.0
        for y in 0..<height {
            for x in 1..<width {
                total += abs(
                    Double(pixels[y * width + x])
                        - Double(pixels[y * width + x - 1])
                )
            }
        }
        for y in 1..<height {
            for x in 0..<width {
                total += abs(
                    Double(pixels[y * width + x])
                        - Double(pixels[(y - 1) * width + x])
                )
            }
        }

        let sampleCount = Double((width - 1) * height + (height - 1) * width)
        let averageGradient = total / sampleCount / 255
        return averageGradient < 0.018
    }

    // MARK: - File hashing

    private static func fileDigest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            if Task.isCancelled { return nil }

            guard let chunk = try? handle.read(upToCount: 1 << 20),
                  !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Streaming PhotoKit data

    private static func loadResourceData(
        _ resource: PHAssetResource,
        allowNetwork: Bool,
        keepData: Bool
    ) async -> (bytes: Int64, digest: String, data: Data?)? {
        let collector = StreamingCollector(keepData: keepData)
        let gate = ResourceDataGate()

        let succeeded = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.setContinuation(continuation)

                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = allowNetwork

                let requestID = PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { chunk in
                        collector.append(chunk)
                    },
                    completionHandler: { error in
                        gate.finish(success: error == nil)
                    }
                )

                gate.setRequestID(requestID)
            }
        } onCancel: {
            gate.cancel()
        }

        guard succeeded else { return nil }
        return collector.result()
    }
}

// MARK: - Small thread-safe helpers

private final class ImageRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?

    init(_ continuation: CheckedContinuation<CGImage?, Never>) {
        self.continuation = continuation
    }

    func resume(_ image: CGImage?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: image)
    }
}

private final class ResourceDataGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var isCancelled = false
    private var isFinished = false

    func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let cancelNow = isCancelled
        lock.unlock()

        if cancelNow {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let id = requestID
        lock.unlock()

        if let id {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    func finish(success: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: success)
    }
}

private final class StreamingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let keepData: Bool
    private var hasher = SHA256()
    private var data = Data()
    private var byteCount: Int64 = 0

    init(keepData: Bool) {
        self.keepData = keepData
    }

    func append(_ chunk: Data) {
        lock.lock()
        byteCount += Int64(chunk.count)
        hasher.update(data: chunk)
        if keepData {
            data.append(chunk)
        }
        lock.unlock()
    }

    func result() -> (bytes: Int64, digest: String, data: Data?) {
        lock.lock()
        let bytes = byteCount
        let keptData = keepData ? data : nil
        let copy = hasher
        let digest = copy.finalize()
        lock.unlock()

        return (
            bytes,
            digest.map { String(format: "%02x", $0) }.joined(),
            keptData
        )
    }
}
