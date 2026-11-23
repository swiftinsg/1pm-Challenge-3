//
//  StorageStore.swift
//  1pm Challenge 3
//

import Foundation
import Photos

/// Collects only measurements the app is actually allowed to make:
/// device capacity, this app's document files, and the user's photo library.
/// It never walks the whole filesystem and never invents missing values.
final class StorageStore: ObservableObject {
    @Published private(set) var snapshot: StorageSnapshot = .loading
    /// True while a scan is running, so Settings can show inline progress.
    @Published private(set) var isRefreshing = false
    private var lastRefresh: Date?
    private var lastAuthorizationStatus: PHAuthorizationStatus?

    init() {
        // Restore the last snapshot immediately so the landing page and Home
        // never wait for a full measurement just to show known values.
        if let cached = ScanCache.loadSnapshot() {
            snapshot = cached.snapshot
            lastRefresh = cached.updatedAt
            lastAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }

    @MainActor
    func refresh(requestAccess: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let capacity = Self.deviceCapacity()
        let fileBytes = await Self.appFileBytes()

        let authorization: PHAuthorizationStatus
        if requestAccess {
            authorization = await Self.photoAuthorizationStatus()
        } else {
            authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }

        // Access changed, so any cached photo/video list is no longer valid.
        if let lastAuthorizationStatus, lastAuthorizationStatus != authorization {
            ScanCache.invalidateOverview(for: .photos)
            ScanCache.invalidateOverview(for: .videos)
        }
        lastAuthorizationStatus = authorization

        let photos: CategoryUsage
        let videos: CategoryUsage

        switch authorization {
        case .authorized, .limited:
            // Only locally stored media is counted. The measurement never
            // requests an iCloud original, so it cannot trigger a download.
            let media = await OverviewScanner.measureLocalMedia()
            let isLimited = authorization == .limited

            photos = CategoryUsage(
                category: .photos,
                bytes: media.photos,
                quality: Self.quality(complete: media.photosComplete, isLimited: isLimited),
                note: Self.mediaNote(complete: media.photosComplete, isLimited: isLimited)
            )
            videos = CategoryUsage(
                category: .videos,
                bytes: media.videos,
                quality: Self.quality(complete: media.videosComplete, isLimited: isLimited),
                note: Self.mediaNote(complete: media.videosComplete, isLimited: isLimited)
            )

        case .denied, .restricted:
            let note = "Photo access is off. Allow access in Settings to measure your photo and video library."
            photos = CategoryUsage(category: .photos, bytes: 0, quality: .unavailable, note: note)
            videos = CategoryUsage(category: .videos, bytes: 0, quality: .unavailable, note: note)

        case .notDetermined:
            let note = "Photo access has not been granted yet."
            photos = CategoryUsage(category: .photos, bytes: 0, quality: .unavailable, note: note)
            videos = CategoryUsage(category: .videos, bytes: 0, quality: .unavailable, note: note)

        @unknown default:
            let note = "Photo access is unavailable on this device."
            photos = CategoryUsage(category: .photos, bytes: 0, quality: .unavailable, note: note)
            videos = CategoryUsage(category: .videos, bytes: 0, quality: .unavailable, note: note)
        }

        let files = CategoryUsage(
            category: .files,
            bytes: fileBytes,
            quality: .verified,
            note: Self.filesNote
        )

        let snapshot = StorageSnapshot(
            totalCapacity: capacity.total,
            usedCapacity: capacity.used,
            categories: [photos, videos, files],
            isLoaded: true,
            isPhotoAccessLimited: authorization == .limited
        )

        self.snapshot = snapshot
        lastRefresh = Date()
        ScanCache.saveSnapshot(snapshot, at: lastRefresh ?? Date())
    }

    /// Refreshes when access changed, on first launch, or after the values
    /// have gone stale. Returning from the app switcher does not trigger a
    /// needless full rescan.
    @MainActor
    func refreshIfNeeded() async {
        let currentAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let isStale = lastRefresh.map { Date().timeIntervalSince($0) > 900 } ?? true

        // Access can change while the app is closed. Drop cached category
        // lists when the snapshot no longer matches the current permission.
        if snapshot.isLoaded {
            let wasAvailable = snapshot.usage(for: .photos).quality != .unavailable
            let isAvailable = currentAuthorization == .authorized || currentAuthorization == .limited
            let wasLimited = snapshot.isPhotoAccessLimited
            let isLimited = currentAuthorization == .limited

            if wasAvailable != isAvailable || wasLimited != isLimited {
                ScanCache.invalidateOverview(for: .photos)
                ScanCache.invalidateOverview(for: .videos)
            }
        }

        guard !snapshot.isLoaded || currentAuthorization != lastAuthorizationStatus || isStale else {
            return
        }

        await refresh(requestAccess: false)
    }

    /// Asks for photo access if the user has never answered the system prompt.
    /// If access was already denied, the caller should send the user to Settings.
    @MainActor
    func requestPhotoAccess() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else {
            await refresh()
            return
        }

        _ = await Self.photoAuthorizationStatus()
        await refresh()
    }

    // MARK: - Photo library

    private static func photoAuthorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static var filesNote: String {
        let folders = DocumentLibrary.shared.folders
        if folders.isEmpty {
            return "Measured from files in On My iPhone › 1pm Challenge 3."
        }
        return "Measured from On My iPhone and \(folders.count) allowed folder\(folders.count == 1 ? "" : "s")."
    }

    private static func quality(complete: Bool, isLimited: Bool) -> MeasurementQuality {
        (isLimited || !complete) ? .estimated : .verified
    }

    private static func mediaNote(complete: Bool, isLimited: Bool) -> String? {
        if isLimited {
            return "Limited photo access. Only the items you allowed are measured, so this total may be incomplete."
        }
        if !complete {
            return "Some items could not be measured, so this total may be lower than the value in Settings."
        }
        return nil
    }

    // MARK: - Device and app files

    private static func deviceCapacity() -> (total: Int64?, used: Int64?) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]

        if let values = try? home.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity {
            // Prefer the capacity iOS reports for important usage: it includes
            // purgeable space, which is the figure Settings counts as free.
            // The plain available value is still used when that key is missing
            // or reports zero.
            let importantUsage = values.volumeAvailableCapacityForImportantUsage ?? 0
            let plainAvailable = Int64(values.volumeAvailableCapacity ?? 0)

            let available: Int64? = importantUsage > 0
                ? importantUsage
                : (plainAvailable > 0 ? plainAvailable : nil)

            return (
                Int64(total),
                available.map { max(0, Int64(total) - $0) }
            )
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = (attributes[.systemSize] as? NSNumber)?.int64Value {
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
            return (total, free.map { max(0, total - $0) })
        }

        return (nil, nil)
    }

    private static func appFileBytes() async -> Int64 {
        let roots = DocumentLibrary.shared.scanRoots
        return await Task.detached(priority: .utility) {
            measuredFileBytes(in: roots)
        }.value
    }

    /// Kept synchronous so the directory enumerator is never traversed from
    /// an async context. The caller runs it on a background task.
    private static func measuredFileBytes(in roots: [URL]) -> Int64 {
        let fileManager = FileManager.default

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        var total: Int64 = 0
        var seenPaths = Set<String>()

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }

                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else {
                    continue
                }

                let isCloudPlaceholder = values.isUbiquitousItem == true
                    && values.ubiquitousItemDownloadingStatus != .current

                let size: Int
                if isCloudPlaceholder {
                    size = values.fileSize ?? 0
                } else {
                    size = values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                }
                total += Int64(size)
            }
        }

        return total
    }
}
