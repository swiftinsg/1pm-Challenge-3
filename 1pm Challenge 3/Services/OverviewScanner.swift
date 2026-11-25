//
//  OverviewScanner.swift
//  1pm Challenge 3
//

import CryptoKit
import Foundation
import Photos
import Vision

/// Reads the real photo library and the allowed folders. Each item is measured
/// once and carries flags, so the view model can place it in several categories
/// without re-reading the item. All work happens off the main thread and checks
/// `Task.isCancelled` between items.
///
/// iCloud-only photos and videos are skipped entirely. Every PhotoKit request
/// used here has `isNetworkAccessAllowed = false`, so a scan can never download
/// an original from iCloud.
enum OverviewScanner {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    /// PhotoKit and file metadata reads spend most of their time waiting, so a
    /// few more workers than CPU cores finishes large libraries noticeably
    /// sooner without starving the UI.
    private static var mediaWorkerCount: Int {
        max(4, min(8, ProcessInfo.processInfo.activeProcessorCount * 2))
    }

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

        return await scanVideos(assets: assets, access: access, progress: progress)
    }

    // MARK: - Photos

    private struct PhotoMeasurement {
        var bytes: Int64
        var digest: String
        var name: String
        var isScreenshot: Bool
    }

    private struct PhotoScanEntry {
        var item: OverviewItem
        var digest: String
    }

    /// Measures metadata and analyses a small local thumbnail in one pass.
    /// Earlier versions requested a thumbnail during the scan and then again
    /// for analysis, which doubled PhotoKit work on large libraries.
    private static func scanPhotos(
        assets: [PHAsset],
        access: PhotoAccessState,
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        let total = assets.count
        var entries = [PhotoScanEntry?](repeating: nil, count: total)
        var skippedItems = 0
        var completed = 0

        let workerCount = Self.mediaWorkerCount

        await withTaskGroup(of: (Int, PhotoScanEntry?).self) { group in
            var nextIndex = 0

            func submitNext() {
                while nextIndex < total {
                    let index = nextIndex
                    nextIndex += 1
                    let asset = assets[index]

                    group.addTask {
                        (index, await scanPhoto(asset))
                    }
                    return
                }
            }

            for _ in 0..<workerCount {
                submitNext()
            }

            while let (index, entry) = await group.next() {
                entries[index] = entry
                if entry == nil { skippedItems += 1 }
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

        var items: [OverviewItem] = []
        items.reserveCapacity(total)
        var seenDigests = Set<String>()

        for entry in entries.compactMap({ $0 }) {
            var item = entry.item
            item.isDuplicate = !seenDigests.insert(entry.digest).inserted
            items.append(item)
        }

        return OverviewScanResult(
            items: items,
            accessState: access,
            skippedItems: skippedItems
        )
    }

    private static func scanPhoto(_ asset: PHAsset) async -> PhotoScanEntry? {
        // Cloud-only photos are not part of the scan at all. Home usually
        // fills this cache first, so most items skip the extra request.
        if MediaAvailability.shared.status(for: asset.localIdentifier) == false {
            return nil
        }

        guard let measured = await measurePhotoMetadata(asset) else {
            return nil
        }

        let thumbnail = await localThumbnail(for: asset)

        if thumbnail.isInCloud {
            MediaAvailability.shared.set(false, for: asset.localIdentifier)
            return nil
        }

        MediaAvailability.shared.set(true, for: asset.localIdentifier)

        var item = OverviewItem(
            id: asset.localIdentifier,
            name: measured.name,
            bytes: measured.bytes,
            date: asset.creationDate,
            assetIdentifier: asset.localIdentifier,
            fileURL: nil,
            isVideo: false,
            isScreenshot: measured.isScreenshot,
            isDuplicate: false
        )

        if let image = thumbnail.image {
            item.hasQRCode = containsQRCode(image)
            item.isBlurry = isBlurry(image)
        }

        return PhotoScanEntry(item: item, digest: measured.digest)
    }

    private static func measurePhotoMetadata(_ asset: PHAsset) async -> PhotoMeasurement? {
        guard let resource = AssetSizeMeasurement.primaryResource(for: asset) else {
            return nil
        }

        // PhotoKit exposes the resource's size without transferring the image,
        // including for iCloud-optimised libraries. Only fall back to counting
        // bytes when that value is unavailable.
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
        // that metadata avoids hashing every original.
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

    private struct LocalThumbnail {
        var image: CGImage?
        var isInCloud: Bool
    }

    /// Returns a small, already-decoded thumbnail. Network access is disabled,
    /// so an iCloud-only photo is reported as such instead of downloaded.
    private static func localThumbnail(for asset: PHAsset) async -> LocalThumbnail {
        let result = await localImage(
            for: asset,
            targetSize: CGSize(width: 256, height: 256),
            storeThumbnail: true
        )
        return LocalThumbnail(image: result.image, isInCloud: result.isInCloud)
    }

    /// Requests an image without network access. A nil result with
    /// `isInCloud` means the asset exists only in iCloud, so it is skipped
    /// instead of downloaded.
    private static func localImage(
        for asset: PHAsset,
        targetSize: CGSize,
        storeThumbnail: Bool
    ) async -> LocalImageResult {
        await withCheckedContinuation { continuation in
            let gate = LocalImageGate(continuation)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.version = .current

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // Keep the thumbnail the scan already decoded. The category
                // pages then show real previews instantly instead of loading
                // the same image again (and flashing a placeholder).
                if let image, storeThumbnail {
                    ThumbnailCache.store(
                        image,
                        forAsset: asset.localIdentifier
                    )
                }

                let isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false

                if let cgImage = image?.cgImage {
                    gate.finish(LocalImageResult(image: cgImage, isInCloud: isInCloud))
                    return
                }

                if isInCloud {
                    gate.finish(LocalImageResult(image: nil, isInCloud: true))
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                let wasCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                let failed = info?[PHImageErrorKey] != nil

                if !isDegraded || wasCancelled || failed {
                    gate.finish(LocalImageResult(image: nil, isInCloud: false))
                }
            }
        }
    }

    // MARK: - Videos

    private struct VideoMeasurement {
        var bytes: Int64
        var digest: String
        var name: String
        var isScreenRecording: Bool
    }

    private struct VideoScanEntry {
        var item: OverviewItem
        var digest: String
    }

    private static func scanVideos(
        assets: [PHAsset],
        access: PhotoAccessState,
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        let total = assets.count
        var entries = [VideoScanEntry?](repeating: nil, count: total)
        var skippedItems = 0
        var completed = 0

        let workerCount = Self.mediaWorkerCount

        await withTaskGroup(of: (Int, VideoScanEntry?).self) { group in
            var nextIndex = 0

            func submitNext() {
                while nextIndex < total {
                    let index = nextIndex
                    nextIndex += 1
                    let asset = assets[index]

                    group.addTask {
                        (index, await scanVideo(asset))
                    }
                    return
                }
            }

            for _ in 0..<workerCount {
                submitNext()
            }

            while let (index, entry) = await group.next() {
                entries[index] = entry
                if entry == nil { skippedItems += 1 }
                completed += 1

                if completed % 4 == 0 || completed == total {
                    await progress(Double(completed) / Double(total))
                }

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                submitNext()
            }
        }

        var items: [OverviewItem] = []
        items.reserveCapacity(total)
        var seenDigests = Set<String>()

        for entry in entries.compactMap({ $0 }) {
            var item = entry.item
            item.isDuplicate = !seenDigests.insert(entry.digest).inserted
            items.append(item)
        }

        return OverviewScanResult(
            items: items,
            accessState: access,
            skippedItems: skippedItems
        )
    }

    private static func scanVideo(_ asset: PHAsset) async -> VideoScanEntry? {
        guard await isVideoAvailableLocally(asset) else {
            return nil
        }

        guard let measured = measureVideoMetadata(asset) else {
            return nil
        }

        let item = OverviewItem(
            id: asset.localIdentifier,
            name: measured.name,
            bytes: measured.bytes,
            date: asset.creationDate,
            assetIdentifier: asset.localIdentifier,
            fileURL: nil,
            isVideo: true,
            isDuplicate: false,
            isScreenRecording: measured.isScreenRecording
        )

        return VideoScanEntry(item: item, digest: measured.digest)
    }

    private static func measureVideoMetadata(_ asset: PHAsset) -> VideoMeasurement? {
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

    /// True when the video's file is on this iPhone. `requestAVAsset` with
    /// network access off reports a cloud-only video instead of downloading it.
    private static func isVideoAvailableLocally(_ asset: PHAsset) async -> Bool {
        if let cached = MediaAvailability.shared.status(for: asset.localIdentifier) {
            return cached
        }

        let available: Bool = await withCheckedContinuation { continuation in
            let gate = VideoAvailabilityGate(continuation)
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat

            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, info in
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                gate.finish(avAsset != nil && !isInCloud)
            }
        }

        MediaAvailability.shared.set(available, for: asset.localIdentifier)
        return available
    }

    // MARK: - Local media measurement for Home

    struct LocalMediaTotals: Sendable {
        var photos: Int64 = 0
        var videos: Int64 = 0
        var photosComplete = true
        var videosComplete = true
    }

    /// Measures only the photos and videos that are already on this iPhone.
    /// This keeps the Home legend in agreement with the category pages, which
    /// also skip cloud-only items.
    static func measureLocalMedia() async -> LocalMediaTotals {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false

        let photoAssets = PHAsset.fetchAssets(with: .image, options: options)
        let videoAssets = PHAsset.fetchAssets(with: .video, options: options)

        async let photos = measureLocalPhotos(photoAssets)
        async let videos = measureLocalVideos(videoAssets)
        let (photoTotals, videoTotals) = await (photos, videos)

        return LocalMediaTotals(
            photos: photoTotals.bytes,
            videos: videoTotals.bytes,
            photosComplete: photoTotals.complete,
            videosComplete: videoTotals.complete
        )
    }

    private struct MediaBucket: Sendable {
        var bytes: Int64 = 0
        var complete = true
    }

    private static func measureLocalPhotos(_ fetch: PHFetchResult<PHAsset>) async -> MediaBucket {
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        return await withTaskGroup(of: (Int64?, Bool).self) { group in
            let workerCount = Self.mediaWorkerCount
            var nextIndex = 0
            var bucket = MediaBucket()

            func submitNext() {
                while nextIndex < assets.count {
                    let index = nextIndex
                    nextIndex += 1
                    let asset = assets[index]

                    group.addTask {
                        guard await isPhotoAvailableLocally(asset) else {
                            return (nil, true)
                        }
                        return (AssetSizeMeasurement.measure(asset)?.bytes, false)
                    }
                    return
                }
            }

            for _ in 0..<workerCount { submitNext() }

            while let (bytes, wasSkipped) = await group.next() {
                if wasSkipped {
                    // Cloud-only items are intentionally not counted.
                } else if let bytes {
                    bucket.bytes += bytes
                } else {
                    bucket.complete = false
                }

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                submitNext()
            }

            return bucket
        }
    }

    private static func measureLocalVideos(_ fetch: PHFetchResult<PHAsset>) async -> MediaBucket {
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        return await withTaskGroup(of: (Int64?, Bool).self) { group in
            let workerCount = Self.mediaWorkerCount
            var nextIndex = 0
            var bucket = MediaBucket()

            func submitNext() {
                while nextIndex < assets.count {
                    let index = nextIndex
                    nextIndex += 1
                    let asset = assets[index]

                    group.addTask {
                        guard await isVideoAvailableLocally(asset) else {
                            return (nil, true)
                        }
                        return (AssetSizeMeasurement.measure(asset)?.bytes, false)
                    }
                    return
                }
            }

            for _ in 0..<workerCount { submitNext() }

            while let (bytes, wasSkipped) = await group.next() {
                if wasSkipped {
                    // Cloud-only items are intentionally not counted.
                } else if let bytes {
                    bucket.bytes += bytes
                } else {
                    bucket.complete = false
                }

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                submitNext()
            }

            return bucket
        }
    }

    private static func isPhotoAvailableLocally(_ asset: PHAsset) async -> Bool {
        if let cached = MediaAvailability.shared.status(for: asset.localIdentifier) {
            return cached
        }

        // A tiny local thumbnail is the cheapest reliable availability check:
        // it never touches the network, and iCloud-only assets report it.
        let result = await localImage(
            for: asset,
            targetSize: CGSize(width: 64, height: 64),
            storeThumbnail: false
        )

        let available = !result.isInCloud
        MediaAvailability.shared.set(available, for: asset.localIdentifier)
        return available
    }

    // MARK: - Files

    private struct FileEntry: Sendable {
        var url: URL
        var bytes: Int64
        var date: Date?
        var isCloudPlaceholder: Bool
        var isDownload: Bool
    }

    private struct ScannedFile: Sendable {
        var item: OverviewItem
        var digest: String?
    }

    private static func scanFiles(
        progress: @escaping ProgressHandler
    ) async -> OverviewScanResult {
        let roots = DocumentLibrary.shared.scanRoots

        guard !roots.isEmpty else {
            return .empty(accessState: .notApplicable)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        // Metadata is read once while enumerating instead of once per item.
        let entries = collectFileEntries(in: roots, keys: keys)

        guard !entries.isEmpty else {
            return .empty(accessState: .notApplicable)
        }

        let total = entries.count
        var scanned = [ScannedFile?](repeating: nil, count: total)
        var completed = 0
        let workerCount = Self.mediaWorkerCount

        await withTaskGroup(of: (Int, ScannedFile).self) { group in
            var nextIndex = 0

            func submitNext() {
                while nextIndex < total {
                    let index = nextIndex
                    nextIndex += 1
                    let entry = entries[index]

                    group.addTask {
                        (index, scanFile(entry))
                    }
                    return
                }
            }

            for _ in 0..<workerCount {
                submitNext()
            }

            while let (index, file) = await group.next() {
                scanned[index] = file
                completed += 1

                if completed % 16 == 0 || completed == total {
                    await progress(Double(completed) / Double(total))
                }

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                submitNext()
            }
        }

        var items: [OverviewItem] = []
        items.reserveCapacity(total)
        var seenDigests = Set<String>()

        for file in scanned.compactMap({ $0 }) {
            var item = file.item
            if let digest = file.digest {
                item.isDuplicate = !seenDigests.insert(digest).inserted
            }
            items.append(item)
        }

        return OverviewScanResult(
            items: items,
            accessState: .notApplicable,
            skippedItems: 0
        )
    }

    private static func collectFileEntries(
        in roots: [URL],
        keys: Set<URLResourceKey>
    ) -> [FileEntry] {
        var entries: [FileEntry] = []
        var seenPaths = Set<String>()

        for root in roots {
            if Task.isCancelled { break }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                if Task.isCancelled { return entries }

                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else {
                    continue
                }

                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }

                let isCloudPlaceholder = values.isUbiquitousItem == true
                    && values.ubiquitousItemDownloadingStatus != .current

                // A placeholder has no allocated blocks yet, so its logical
                // file size is the useful value. Local files use the allocated
                // size, which matches the space they actually occupy.
                let bytes: Int64
                if isCloudPlaceholder {
                    bytes = Int64(values.fileSize ?? 0)
                } else {
                    bytes = Int64(
                        values.totalFileAllocatedSize
                            ?? values.fileAllocatedSize
                            ?? values.fileSize
                            ?? 0
                    )
                }

                let isDownload = url.pathComponents
                    .dropLast()
                    .contains { $0.caseInsensitiveCompare("Downloads") == .orderedSame }

                entries.append(
                    FileEntry(
                        url: url,
                        bytes: bytes,
                        date: values.contentModificationDate,
                        isCloudPlaceholder: isCloudPlaceholder,
                        isDownload: isDownload
                    )
                )
            }
        }

        return entries
    }

    private static func scanFile(_ entry: FileEntry) -> ScannedFile {
        // iCloud Drive placeholders keep their size but are never opened, so
        // the scan cannot download them.
        let digest = entry.isCloudPlaceholder
            ? nil
            : fileDigest(entry.url, size: entry.bytes)

        let item = OverviewItem(
            id: entry.url.path,
            name: entry.url.lastPathComponent,
            bytes: entry.bytes,
            date: entry.date,
            assetIdentifier: nil,
            fileURL: entry.url,
            isVideo: false,
            isDuplicate: false,
            isDownload: entry.isDownload
        )

        return ScannedFile(item: item, digest: digest)
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

    /// Builds a duplicate fingerprint from the file's size plus its first and
    /// last 32 KB. Hashing every whole file made large folders take minutes;
    /// this keeps the scan fast while still comparing real file contents.
    private static func fileDigest(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = size > 0 ? size : Int64((try? handle.seekToEnd()) ?? 0)
        let sampleSize = 32 * 1024

        var hasher = SHA256()
        withUnsafeBytes(of: fileSize.bigEndian) { buffer in
            hasher.update(data: Data(buffer))
        }

        if let head = try? handle.read(
            upToCount: min(Int(fileSize), sampleSize)
        ), !head.isEmpty {
            hasher.update(data: head)
        }

        if fileSize > Int64(sampleSize * 2) {
            try? handle.seek(toOffset: UInt64(fileSize - Int64(sampleSize)))
            if let tail = try? handle.read(upToCount: sampleSize), !tail.isEmpty {
                hasher.update(data: tail)
            }
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

// MARK: - Local availability cache

/// Remembers which assets are already on this iPhone. Home and the category
/// pages share the result, so a library is only checked once per session.
private final class MediaAvailability: @unchecked Sendable {
    static let shared = MediaAvailability()

    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func status(for identifier: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return values[identifier]
    }

    func set(_ available: Bool, for identifier: String) {
        lock.lock()
        values[identifier] = available
        lock.unlock()
    }
}

// MARK: - Small thread-safe helpers

private struct LocalImageResult {
    var image: CGImage?
    var isInCloud: Bool
}

private final class LocalImageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalImageResult, Never>?

    init(_ continuation: CheckedContinuation<LocalImageResult, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: LocalImageResult) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
    }
}

private final class VideoAvailabilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var isFinished = false

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ available: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: available)
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
