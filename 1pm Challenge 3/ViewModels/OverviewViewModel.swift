//
//  OverviewViewModel.swift
//  1pm Challenge 3
//

import Foundation
import Photos

/// Owns one overview page's scan, filter selection and derived chart data.
/// The filter is read-only: it never changes or deletes any item.
@MainActor
final class OverviewViewModel: ObservableObject {
    let kind: StorageCategory

    @Published private(set) var usages: [OverviewUsage] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var accessState: PhotoAccessState
    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var skippedItems = 0
    @Published private(set) var hasScanned = false
    @Published private(set) var appliedFilters: Set<OverviewCategory> = []
    @Published private(set) var outdatedThreshold: OutdatedThreshold

    private var scannedItems: [OverviewItem] = []
    private var scanTask: Task<Void, Never>?
    private var lastScanDate: Date?

    private static let thresholdKey = "overview.outdatedThreshold"

    init(kind: StorageCategory) {
        self.kind = kind
        self.accessState = kind == .files ? .notApplicable : .notDetermined

        let stored = UserDefaults.standard.integer(forKey: Self.thresholdKey)
        self.outdatedThreshold = OutdatedThreshold(rawValue: stored) ?? .threeMonths

        // Restore the previous scan immediately. The page can draw its chart
        // and item counts before any PhotoKit or file work starts.
        if let cached = ScanCache.loadOverview(for: kind) {
            scannedItems = cached.items
            accessState = cached.accessState
            skippedItems = cached.skippedItems
            lastScanDate = cached.updatedAt
            hasScanned = true
            rebuildUsages()
        }
    }

    // MARK: - Derived chart data

    var allCategories: [OverviewCategory] {
        OverviewCategory.categories(for: kind)
    }

    var isFilterActive: Bool {
        !appliedFilters.isEmpty
    }

    /// An empty selection intentionally means "no filtering", per the brief.
    var selectedCategories: Set<OverviewCategory> {
        appliedFilters.isEmpty ? Set(allCategories) : appliedFilters
    }

    /// Chart sectors and legend entries. Zero-byte categories are excluded so
    /// the legend always matches what is actually drawn.
    var displayedUsages: [OverviewUsage] {
        let selected = selectedCategories
        return usages.filter {
            selected.contains($0.category) && $0.bytes > 0
        }
    }

    /// Every item in this category, including items that match none of the
    /// optional breakdowns. This is the same value Home shows for the category,
    /// so the two pages never disagree.
    var allItemsBytes: Int64 {
        scannedItems.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var filterSummary: String {
        guard isFilterActive else { return "All categories" }
        let count = displayedUsages.count
        return count == 1 ? "1 category" : "\(count) categories"
    }

    var needsPhotoPermission: Bool {
        hasScanned && accessState.needsPermission
    }

    var isEmptyState: Bool {
        hasScanned && !isScanning && !needsPhotoPermission && displayedUsages.isEmpty
    }

    var emptyTitle: String {
        "No storage used"
    }

    var emptyMessage: String {
        if selectedCategories.count == 1 {
            return "This category does not take up any storage on your device."
        }
        if isFilterActive {
            return "None of the selected categories take up any storage on your device."
        }

        switch kind {
        case .photos:
            return "There is no tracked photo storage to show on this device."
        case .videos:
            return "There is no tracked video storage to show on this device."
        case .files:
            return "There are no tracked files to show on this device."
        }
    }

    func usage(for category: OverviewCategory) -> OverviewUsage {
        usages.first { $0.category == category }
            ?? OverviewUsage(category: category, bytes: 0, items: [])
    }

    /// Detail page for a filtered set of categories. An item can match more
    /// than one category (for example a large, duplicate photo), so items are
    /// de-duplicated by id before the bytes are summed.
    func combinedUsage(for categories: Set<OverviewCategory>) -> OverviewUsage? {
        let ordered = allCategories.filter { categories.contains($0) }
        guard let primary = ordered.first else { return nil }

        var seen = Set<String>()
        var matching: [OverviewItem] = []

        for category in ordered {
            for item in usage(for: category).items where seen.insert(item.id).inserted {
                matching.append(item)
            }
        }

        let bytes = matching.reduce(Int64(0)) { $0 + $1.bytes }
        return OverviewUsage(category: primary, bytes: bytes, items: matching)
    }

    var outdatedCategory: OverviewCategory {
        OverviewCategory.outdatedCategory(for: kind)
    }

    // MARK: - Filtering

    func applyFilters(_ selection: Set<OverviewCategory>) {
        appliedFilters = selection.intersection(Set(allCategories))
    }

    func applyOutdatedThreshold(_ threshold: OutdatedThreshold) {
        guard threshold != outdatedThreshold else { return }
        outdatedThreshold = threshold
        UserDefaults.standard.set(threshold.rawValue, forKey: Self.thresholdKey)
        rebuildUsages()
    }

    func clearFilters() {
        appliedFilters.removeAll()
    }

    /// Category membership is derived from the item flags, so a photo can
    /// appear as a screenshot and as outdated at the same time.
    ///
    /// One pass over the scan result fills every category. The previous
    /// implementation filtered the whole library once per category, which made
    /// opening a large page do several full scans on the main thread.
    private func rebuildUsages() {
        let cutoff = outdatedThreshold.cutoff
        let categories = allCategories

        var itemsByCategory: [OverviewCategory: [OverviewItem]] = [:]
        itemsByCategory.reserveCapacity(categories.count)

        for category in categories {
            itemsByCategory[category] = []
        }

        var total: Int64 = 0

        for item in scannedItems {
            total += item.bytes

            for category in categories where category.matches(item, cutoff: cutoff) {
                itemsByCategory[category, default: []].append(item)
            }
        }

        usages = categories.map { category in
            let matching = itemsByCategory[category] ?? []
            return OverviewUsage(
                category: category,
                bytes: matching.reduce(Int64(0)) { $0 + $1.bytes },
                items: matching
            )
        }
        totalBytes = total
    }

    // MARK: - Scanning

    func scanIfNeeded() {
        guard !isScanning else { return }

        // A cached result is shown instantly. Only rescan when it is old
        // enough that the user may have changed the library.
        if hasScanned,
           let lastScanDate,
           ScanCache.isFresh(lastScanDate, maxAge: ScanCache.overviewMaxAge) {
            return
        }

        scan()
    }

    func rescan() {
        scan()
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// Requests photo access when the user has not answered yet. If access was
    /// already denied, the calling view sends the user to Settings instead.
    func requestPhotoAccessAndScan() async {
        guard kind == .photos || kind == .videos else {
            scan()
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        }

        scan()
    }

    private func scan() {
        scanTask?.cancel()

        let kind = self.kind
        isScanning = true
        progress = 0

        scanTask = Task { [weak self] in
            guard let self else { return }

            let result = await OverviewScanner.scan(kind: kind) { value in
                await self.updateProgress(value)
            }

            guard !Task.isCancelled else { return }

            self.scannedItems = result.items
            self.rebuildUsages()
            self.accessState = result.accessState
            self.skippedItems = result.skippedItems
            self.progress = 1
            self.hasScanned = true
            self.isScanning = false
            self.scanTask = nil
            self.lastScanDate = Date()
            ScanCache.saveOverview(result, for: kind, at: self.lastScanDate ?? Date())
        }
    }

    private func updateProgress(_ value: Double) {
        guard isScanning else { return }
        progress = min(max(value, 0), 1)
    }
}
