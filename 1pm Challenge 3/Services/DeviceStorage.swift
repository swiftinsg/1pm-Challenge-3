//
//  DeviceStorage.swift
//  1pm Challenge 3
//

import Foundation

/// The one place the app reads the iPhone's storage capacity.
///
/// These are the same volume figures iOS uses for Settings › General ›
/// iPhone Storage:
///
/// * `volumeTotalCapacity` is the advertised capacity of the device.
/// * `volumeAvailableCapacityForImportantUsage` is the space iOS reports as
///   free, including purgeable space.
///
/// Reading the values fresh every time (rather than storing a copy) keeps the
/// big Home numbers in step with Settings after apps download or delete data.
enum DeviceStorage {
    struct Capacity: Equatable {
        var total: Int64?
        var available: Int64?

        var used: Int64? {
            guard let total, let available else { return nil }
            return max(0, total - available)
        }
    }

    static func current() -> Capacity {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]

        if let values = try? home.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity {
            let totalBytes = Int64(total)
            let importantUsage = values.volumeAvailableCapacityForImportantUsage ?? 0
            let plainAvailable = Int64(values.volumeAvailableCapacity ?? 0)

            // Important-usage capacity is what Settings treats as free because
            // it can include purgeable space. Fall back to the plain available
            // value only when that key is missing or reports zero.
            let available: Int64? = importantUsage > 0
                ? importantUsage
                : (plainAvailable > 0 ? plainAvailable : nil)

            return Capacity(total: totalBytes, available: available)
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ),
           let total = (attributes[.systemSize] as? NSNumber)?.int64Value {
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
            return Capacity(total: total, available: free)
        }

        return Capacity(total: nil, available: nil)
    }

    /// The storage tiers Apple prints on the box, in decimal gigabytes.
    private static let advertisedTiersGB: [Int64] = [
        16, 32, 64, 128, 256, 512, 1000, 2000
    ]

    /// Maps the usable data volume up to the capacity Apple advertises.
    ///
    /// iOS only exposes the formatted volume, so a 128 GB iPhone reports about
    /// 114.6 GB. The smallest advertised tier at or above that usable size is
    /// the number on the box, which is what Settings › About shows.
    static func advertisedCapacity(forUsable usable: Int64?) -> Int64? {
        guard let usable, usable > 0 else { return nil }

        let usableGB = Double(usable) / 1_000_000_000
        for tier in advertisedTiersGB where usableGB <= Double(tier) + 0.5 {
            return tier * 1_000_000_000
        }
        return nil
    }
}
