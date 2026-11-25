//
//  ScanCache.swift
//  1pm Challenge 3
//

import Foundation

/// Small on-disk cache for scan results.
///
/// Restoring the last snapshot makes the landing page and Home appear
/// immediately on launch. A fresh scan still replaces it in the background.
enum ScanCache {
    struct SnapshotEntry: Codable {
        var snapshot: StorageSnapshot
        var updatedAt: Date
    }

    struct OverviewEntry: Codable {
        var items: [OverviewItem]
        var accessState: PhotoAccessState
        var skippedItems: Int
        var updatedAt: Date
    }

    /// A cached Home snapshot is reused for this long before a background
    /// refresh. Category pages use a slightly shorter window.
    static let snapshotMaxAge: TimeInterval = 60 * 60 * 6
    static let overviewMaxAge: TimeInterval = 60 * 5

    private static let directoryName = "ScanCache"
    private static let writeQueue = DispatchQueue(
        label: "ScanCache.write",
        qos: .utility
    )

    // Decoding a large category list can take long enough to block a page
    // transition. Once a file has been read it stays here, so opening a page
    // is an in-memory lookup instead of another disk decode.
    private static let memoryLock = NSLock()
    private static var memorySnapshot: SnapshotEntry?
    private static var memoryOverviews: [StorageCategory: OverviewEntry] = [:]

    // MARK: - Home snapshot

    static func loadSnapshot() -> SnapshotEntry? {
        memoryLock.lock()
        let cached = memorySnapshot
        memoryLock.unlock()
        if let cached { return cached }

        guard let url = fileURL(name: "snapshot.json"),
              let data = try? Data(contentsOf: url),
              let entry = try? decoder.decode(SnapshotEntry.self, from: data) else {
            return nil
        }

        memoryLock.lock()
        // A scan may have finished while this file was being decoded. Never
        // let the older on-disk copy replace the newer in-memory result.
        if memorySnapshot == nil {
            memorySnapshot = entry
        }
        let result = memorySnapshot ?? entry
        memoryLock.unlock()
        return result
    }

    static func saveSnapshot(_ snapshot: StorageSnapshot, at date: Date = Date()) {
        let entry = SnapshotEntry(snapshot: snapshot, updatedAt: date)

        memoryLock.lock()
        memorySnapshot = entry
        memoryLock.unlock()

        // The Home snapshot is tiny, so write it immediately. A force-quit
        // right after a scan must not lose the values the user just waited for.
        writeNow(entry, name: "snapshot.json")
    }

    static func hasSnapshot() -> Bool {
        loadSnapshot()?.snapshot.isLoaded == true
    }

    // MARK: - Category scan

    static func loadOverview(for kind: StorageCategory) -> OverviewEntry? {
        memoryLock.lock()
        let cached = memoryOverviews[kind]
        memoryLock.unlock()
        if let cached { return cached }

        guard let url = fileURL(name: "overview-\(kind.rawValue).json"),
              let data = try? Data(contentsOf: url),
              let entry = try? decoder.decode(OverviewEntry.self, from: data) else {
            return nil
        }

        memoryLock.lock()
        // Keep a result saved while the file was being decoded.
        if memoryOverviews[kind] == nil {
            memoryOverviews[kind] = entry
        }
        let result = memoryOverviews[kind] ?? entry
        memoryLock.unlock()
        return result
    }

    static func saveOverview(
        _ result: OverviewScanResult,
        for kind: StorageCategory,
        at date: Date = Date()
    ) {
        let entry = OverviewEntry(
            items: result.items,
            accessState: result.accessState,
            skippedItems: result.skippedItems,
            updatedAt: date
        )

        memoryLock.lock()
        memoryOverviews[kind] = entry
        memoryLock.unlock()

        writeAsync(entry, name: "overview-\(kind.rawValue).json")
    }

    /// Reads every cached page once, off the main thread. The landing page is
    /// on screen for at least a moment on every launch, which is the ideal
    /// time to have all category data ready in memory.
    static func preload() {
        // Use a separate queue so a large read never delays a cache write.
        DispatchQueue.global(qos: .utility).async {
            _ = loadSnapshot()
            for kind in StorageCategory.allCases {
                _ = loadOverview(for: kind)
            }
        }
    }

    static func isFresh(_ date: Date, maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(date) < maxAge
    }

    /// Drops a category result so the next visit scans again. Used when the
    /// user grants a folder or changes photo access.
    static func invalidateOverview(for kind: StorageCategory) {
        memoryLock.lock()
        memoryOverviews[kind] = nil
        memoryLock.unlock()

        guard let url = fileURL(name: "overview-\(kind.rawValue).json") else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Files

    private static func directory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func fileURL(name: String) -> URL? {
        directory()?.appendingPathComponent(name)
    }

    private static func writeNow<T: Encodable>(_ value: T, name: String) {
        guard let url = fileURL(name: name),
              let data = try? encoder.encode(value) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    private static func writeAsync<T: Encodable>(_ value: T, name: String) {
        // Encoding a large category list can take long enough to drop frames.
        // Keep the main thread free and let the cache land a moment later.
        writeQueue.async {
            writeNow(value, name: name)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
