//
//  CategoryPreviewThumbnail.swift
//  1pm Challenge 3
//

import SwiftUI
import UIKit

/// A small circular preview of the newest item in a category. It replaces the
/// generic SF Symbol with the real photo, video frame or document preview.
///
/// The cached image is read synchronously, so returning to a page shows the
/// preview instantly instead of flashing the placeholder symbol first.
struct CategoryPreviewThumbnail: View {
    let item: OverviewItem?
    let tint: Color
    let symbolName: String
    var size: CGFloat = 82

    @State private var image: UIImage?
    @State private var imageItemID: String?

    init(
        item: OverviewItem?,
        tint: Color,
        symbolName: String,
        size: CGFloat = 82
    ) {
        self.item = item
        self.tint = tint
        self.symbolName = symbolName
        self.size = size

        // Read the shared cache up front so revisiting a page draws the real
        // preview on the first frame, without a placeholder flash.
        if let item, let cached = ThumbnailCache.image(for: item) {
            _image = State(initialValue: cached)
            _imageItemID = State(initialValue: item.id)
        }
    }

    /// Only show an image that belongs to the item currently being described.
    /// This avoids a stale preview for a moment after a deletion changes the
    /// newest item on the page.
    private var displayedImage: UIImage? {
        imageItemID == item?.id ? image : nil
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(displayedImage == nil ? tint.opacity(0.12) : Color.clear)

            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: max(13, size * 0.38), weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(tint.opacity(0.2), lineWidth: 1)
        }
        .task(id: item?.id) {
            await load()
        }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let item else {
            image = nil
            imageItemID = nil
            return
        }

        // A scan or an already-visible row usually filled the cache, so this
        // path costs nothing and never shows the placeholder.
        if let cached = ThumbnailCache.image(for: item) {
            image = cached
            imageItemID = item.id
            return
        }

        let loaded = await ThumbnailLoader.image(for: item)
        guard !Task.isCancelled, let loaded else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            image = loaded
            imageItemID = item.id
        }
    }
}
