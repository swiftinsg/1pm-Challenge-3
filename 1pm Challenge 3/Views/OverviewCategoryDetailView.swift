//
//  OverviewCategoryDetailView.swift
//  1pm Challenge 3
//

import SwiftUI
import UIKit

/// Detail page for one overview category, or for a combined filter selection.
/// The item list, selection and deletion all live on this page, so choosing
/// "Select" no longer pushes a separate screen.
struct OverviewCategoryDetailView: View {
    let kind: StorageCategory
    let usage: OverviewUsage
    /// Optional overrides so this page can also present a combined filter
    /// selection (for example "Large and Duplicate Photos") instead of a single
    /// category.
    var displayTitle: String? = nil
    var displayColor: Color? = nil
    var displaySymbolName: String? = nil
    var onBack: (() -> Void)?
    var onGoHome: (() -> Void)?
    var onItemsDeleted: () async -> Void = {}

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var deletedIDs: Set<String> = []
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var previewRequest: ItemPreviewRequest?
    @State private var deletionProgress: DeletionProgress?
    @State private var deletionSummary: DeletionSummary?
    @State private var bannerDismissTask: Task<Void, Never>?

    private let destructiveColor = Color(hex: 0xDC2626)

    private var title: String {
        displayTitle ?? usage.category.title
    }

    private var tint: Color {
        displayColor ?? usage.category.color
    }

    private var symbolName: String {
        displaySymbolName ?? usage.category.symbolName
    }

    private var sortedItems: [OverviewItem] {
        usage.items.sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }

    /// Items that still exist after deletions, newest first.
    private var visibleItems: [OverviewItem] {
        sortedItems.filter { !deletedIDs.contains($0.id) }
    }

    private var selectedItems: [OverviewItem] {
        visibleItems.filter { selectedIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    /// The header keeps matching the list after items are removed, even while
    /// the full library rescan is still running in the background.
    private var remainingItemCount: Int {
        usage.items.reduce(0) { count, item in
            count + (deletedIDs.contains(item.id) ? 0 : 1)
        }
    }

    private var remainingBytes: Int64 {
        usage.items.reduce(Int64(0)) { total, item in
            total + (deletedIDs.contains(item.id) ? 0 : item.bytes)
        }
    }

    private var isAllSelected: Bool {
        !visibleItems.isEmpty && selectedIDs.count == visibleItems.count
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 6)
                        .padding(.bottom, isSelecting ? 18 : 24)

                    if isSelecting, !visibleItems.isEmpty {
                        selectionControls
                            .padding(.bottom, 12)
                    }

                    if visibleItems.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(visibleItems.enumerated()),
                                id: \.element.id
                            ) { index, item in
                                itemRow(item, index: index)

                                if item.id != visibleItems.last?.id {
                                    Rectangle()
                                        .fill(AppTheme.hairline)
                                        .frame(height: 0.5)
                                        .padding(.leading, 58)
                                }
                            }
                        }
                    }

                    Text(footerText)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                        .padding(.bottom, isSelecting ? 12 : 32)
                }
                .padding(.horizontal, 24)
            }
            .allowsHitTesting(!isDeleting)
        }
        .overlay(alignment: .bottom) {
            if let deletionProgress {
                DeletionStatusBanner(progress: deletionProgress)
                    .padding(.horizontal, 20)
                    .padding(.bottom, isSelecting ? 80 : 16)
                    .allowsHitTesting(false)
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting, !visibleItems.isEmpty {
                bottomBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .tint(.primary)
                    .accessibilityLabel("Back to \(kind.title) chart")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    if !isSelecting {
                        CoachController.shared.advance(
                            from: .selectButton,
                            to: .selectItem
                        )
                    }
                    toggleSelectionMode()
                }
                .font(.system(size: 15, weight: .semibold))
                .tint(.primary)
                .disabled(usage.items.isEmpty)
                .coachAnchor(.detailSelectButton)
                .accessibilityHint(isSelecting
                                   ? "Leaves selection mode"
                                   : "Choose items to delete")
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(deleteActionTitle, role: .destructive) {
                Task { await deleteSelectedItems() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected items from your iPhone. Photos and videos stay in Recently Deleted for 30 days.")
        }
        .alert(
            "Couldn’t delete items",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $deletionSummary) { summary in
            DeletionSuccessSheet(
                summary: summary,
                onBackHome: {
                    deletionSummary = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onGoHome?()
                    }
                },
                onKeepCleaning: {
                    deletionSummary = nil
                }
            )
        }
        .itemPreview(request: $previewRequest)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(StorageFormatter.compact(remainingBytes))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .tracking(-1)
                .monospacedDigit()
                .foregroundStyle(.primary)

            HStack(spacing: 7) {
                Text(remainingItemCount == 1 ? "1 item" : "\(remainingItemCount) items")
                Circle()
                    .fill(AppTheme.tertiaryText)
                    .frame(width: 3, height: 3)
                Text(kind.title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppTheme.secondaryText)
        }
    }

    // MARK: - List

    private func itemRow(_ item: OverviewItem, index: Int) -> some View {
        let isSelected = selectedIDs.contains(item.id)

        return HStack(spacing: 10) {
            Button {
                if isSelecting {
                    toggleSelection(item)
                } else {
                    previewRequest = ItemPreviewRequest(
                        items: visibleItems,
                        startIndex: index
                    )
                }
            } label: {
                HStack(spacing: 12) {
                    if isSelecting {
                        selectionIndicator(isSelected: isSelected, index: index)
                    }

                    OverviewItemThumbnail(
                        item: item,
                        tint: tint
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            if let date = item.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                            Text("·")
                            Text(item.formattedSize)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name), \(item.formattedSize)")
            .accessibilityValue(isSelecting
                                ? (isSelected ? "Selected" : "Not selected")
                                : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isSelecting
                               ? "Adds or removes this item from the selection"
                               : "Opens a preview")

            previewButton(for: item, index: index)
        }
        .padding(.vertical, 1)
    }

    private func previewButton(for item: OverviewItem, index: Int) -> some View {
        Button {
            previewRequest = ItemPreviewRequest(
                items: visibleItems,
                startIndex: index
            )
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(AppTheme.surface)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .accessibilityLabel("Preview \(item.name)")
        .accessibilityHint("Opens a preview of this item")
    }

    private func selectionIndicator(isSelected: Bool, index: Int) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? tint : .clear)
                .frame(width: 22, height: 22)

            Circle()
                .strokeBorder(
                    isSelected ? tint : Color.primary.opacity(0.18),
                    lineWidth: 1.5
                )
                .frame(width: 22, height: 22)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .coachAnchor(index == 0 ? .detailFirstSelect : nil)
        .accessibilityHidden(true)
    }

    // MARK: - Selection controls

    private var selectionControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedIDs.isEmpty ? "Tap items to select them" : selectedSummary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(headerSubtitle)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 0)

            Button {
                toggleSelectAll()
            } label: {
                Text(isAllSelected ? "Deselect All" : "Select All")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.surface)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surface)
        )
    }

    private var selectedSummary: String {
        let count = selectedIDs.count
        return count == 1 ? "1 item selected" : "\(count) items selected"
    }

    private var headerSubtitle: String {
        if !selectedIDs.isEmpty {
            return "\(StorageFormatter.compact(selectedBytes)) selected"
        }
        return "Tap an item to add it to your selection."
    }

    // MARK: - Delete bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            deleteButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 0.5)
        }
        .allowsHitTesting(!isDeleting)
    }

    private var deleteButton: some View {
        Button {
            // The tour explains deletion without actually removing anything.
            if CoachController.shared.step == .deleteButton {
                CoachController.shared.advance(from: .deleteButton, to: .finish)
            } else {
                showDeleteConfirmation = true
            }
        } label: {
            HStack(spacing: 8) {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }

                Text(deleteButtonTitle)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(selectedIDs.isEmpty ? AppTheme.secondaryText : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                Capsule(style: .continuous)
                    .fill(selectedIDs.isEmpty ? AppTheme.surface : destructiveColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedIDs.isEmpty || isDeleting)
        .coachAnchor(.detailDeleteButton)
        .accessibilityLabel(deleteButtonTitle)
        .accessibilityHint("Deletes the selected items")
    }

    private var deleteButtonTitle: String {
        if isDeleting { return "Deleting…" }
        guard !selectedIDs.isEmpty else { return "Select items to delete" }

        let count = selectedIDs.count
        let size = StorageFormatter.compact(selectedBytes)
        return "Delete \(count) \(count == 1 ? "item" : "items") · \(size)"
    }

    private var deleteConfirmationTitle: String {
        let count = selectedIDs.count
        return count == 1 ? "Delete 1 item?" : "Delete \(count) items?"
    }

    private var deleteActionTitle: String {
        let count = selectedIDs.count
        return "Delete \(count) \(count == 1 ? "Item" : "Items")"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)

            Text(emptyTitle)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Text(emptyMessage)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private var emptyTitle: String {
        deletedIDs.isEmpty ? "No items" : "All clean"
    }

    private var emptyMessage: String {
        deletedIDs.isEmpty
            ? "There are no items to manage in this category."
            : "There are no items left to delete in this category."
    }

    private var footerText: String {
        if isSelecting {
            return kind == .files
                ? "Deleted files can’t be recovered."
                : "Deleted photos and videos stay in Recently Deleted for 30 days."
        }
        return usage.items.isEmpty
            ? "There are no items to manage in this category."
            : "Tap an item to preview it. Use Select to remove items."
    }

    // MARK: - Actions

    private func toggleSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelecting.toggle()
            if !isSelecting {
                selectedIDs.removeAll()
            }
        }
    }

    private func toggleSelection(_ item: OverviewItem) {
        CoachController.shared.advance(from: .selectItem, to: .deleteButton)

        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        }
    }

    private func toggleSelectAll() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isAllSelected {
                selectedIDs.removeAll()
            } else {
                selectedIDs = Set(visibleItems.map(\.id))
            }
        }
    }

    @MainActor
    private func deleteSelectedItems() async {
        guard !selectedIDs.isEmpty, !isDeleting else { return }

        isDeleting = true
        defer { isDeleting = false }

        let items = selectedItems
        guard !items.isEmpty else { return }

        // One Live Activity for the whole selection, no matter how many items
        // are removed. The same progress drives the in-app popup.
        let started = DeletionProgress(
            completed: 0,
            total: items.count,
            bytes: 0,
            isFinished: false
        )
        DeletionActivityController.shared.start(totalItems: items.count)

        bannerDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            deletionProgress = started
        }

        let outcome = await ItemDeletion.delete(items) { completed, bytes in
            let update = DeletionProgress(
                completed: completed,
                total: items.count,
                bytes: bytes,
                isFinished: false
            )

            withAnimation(.easeOut(duration: 0.2)) {
                deletionProgress = update
            }
            DeletionActivityController.shared.update(update)
        }

        deletedIDs.formUnion(outcome.deletedIDs)
        selectedIDs.subtract(outcome.deletedIDs)

        let finished = DeletionProgress(
            completed: outcome.deletedIDs.count,
            total: items.count,
            bytes: outcome.deletedBytes,
            isFinished: true
        )
        DeletionActivityController.shared.finish(finished)

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            deletionProgress = finished
        }

        let summary = DeletionSummary(
            count: outcome.deletedIDs.count,
            bytes: outcome.deletedBytes,
            isFiles: kind == .files
        )

        bannerDismissTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.3)) {
                deletionProgress = nil
            }

            // Show the result only after the progress popup has had its
            // moment, so the two never compete for attention.
            if !outcome.deletedIDs.isEmpty {
                deletionSummary = summary
            }
        }

        if !outcome.deletedIDs.isEmpty {
            await onItemsDeleted()
        }

        if let message = outcome.message {
            errorMessage = message
        }
    }
}

// MARK: - Thumbnail

struct OverviewItemThumbnail: View {
    let item: OverviewItem
    let tint: Color

    @State private var image: UIImage?

    init(item: OverviewItem, tint: Color) {
        self.item = item
        self.tint = tint
        // Start from the shared cache so photos thumbnailed during the scan
        // appear immediately, with no placeholder-symbol flash.
        _image = State(initialValue: ThumbnailCache.image(for: item))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipped()
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    private var placeholderSymbol: String {
        if item.fileURL != nil { return "doc.fill" }
        return item.isVideo ? "video.fill" : "photo.fill"
    }

    private func loadThumbnail() async {
        if let cached = ThumbnailCache.image(for: item) {
            image = cached
            return
        }

        image = nil

        let loaded = await ThumbnailLoader.image(for: item)
        guard !Task.isCancelled, let loaded else { return }

        withAnimation(.easeOut(duration: 0.15)) {
            image = loaded
        }
    }
}
