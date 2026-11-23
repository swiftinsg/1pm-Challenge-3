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

    // MARK: - Home snapshot

    static func loadSnapshot() -> SnapshotEntry? {
        guard let url = fileURL(name: "snapshot.json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? decoder.decode(SnapshotEntry.self, from: data)
    }

    static func saveSnapshot(_ snapshot: StorageSnapshot, at date: Date = Date()) {
        let entry = SnapshotEntry(snapshot: snapshot, updatedAt: date)
        // The Home snapshot is tiny, so write it immediately. A force-quit
        // right after a scan must not lose the values the user just waited for.
        writeNow(entry, name: "snapshot.json")
    }

    static func hasSnapshot() -> Bool {
        loadSnapshot()?.snapshot.isLoaded == true
    }

    // MARK: - Category scan

    static func loadOverview(for kind: StorageCategory) -> OverviewEntry? {
        guard let url = fileURL(name: "overview-\(kind.rawValue).json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? decoder.decode(OverviewEntry.self, from: data)
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
        writeAsync(entry, name: "overview-\(kind.rawValue).json")
    }

    static func isFresh(_ date: Date, maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(date) < maxAge
    }

    /// Drops a category result so the next visit scans again. Used when the
    /// user grants a folder or changes photo access.
    static func invalidateOverview(for kind: StorageCategory) {
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
