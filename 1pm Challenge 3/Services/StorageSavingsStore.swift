//
//  StorageSavingsStore.swift
//  1pm Challenge 3
//

import Foundation
import Combine

/// Keeps a running total of the bytes the user has freed by deleting items,
/// so the starting page can show a lifetime "Storage saved" figure.
final class StorageSavingsStore: ObservableObject {
    static let shared = StorageSavingsStore()

    private static let key = "storageSavedBytes"

    @Published private(set) var savedBytes: Int64

    private init() {
        // Restore the lifetime total saved by earlier sessions. A missing or
        // corrupt value simply starts the running total at zero.
        savedBytes = (UserDefaults.standard.object(forKey: Self.key) as? NSNumber)?
            .int64Value ?? 0
    }

    /// Adds the bytes of successfully deleted items to the saved total. Each
    /// successful deletion adds to the previous value; nothing is ever reset.
    @MainActor
    func add(_ bytes: Int64) {
        guard bytes > 0 else { return }

        savedBytes += bytes
        UserDefaults.standard.set(NSNumber(value: savedBytes), forKey: Self.key)
    }

    /// "10 MB" for small values, automatically switching to "1.2 GB" once the
    /// total grows.
    var formattedSavings: String {
        StorageFormatter.compact(savedBytes)
    }
}
