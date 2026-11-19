//
//  ItemPreview.swift
//  1pm Challenge 3
//

import AVKit
import Foundation
import Photos
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One request to preview an item inside a list. Every tap creates a new
/// request, so tapping the same row twice still reopens the preview.
struct ItemPreviewRequest: Identifiable {
    let id = UUID()
    let items: [OverviewItem]
    let startIndex: Int
}

/// The files Quick Look should show.
struct PreparedPreview {
    var urls: [URL]
    var startIndex: Int
}

/// Builds what Quick Look needs for a tap.
///
/// Files that already live on disk are previewed in place. Photos from the
/// library have no file URL, so only the tapped photo is written to a small
/// on-disk cache; Quick Look then presents it with its usual zoom, share and
/// swipe controls. Videos skip file export entirely and stream through Apple's
/// AVKit player, which opens immediately even for large files.
enum ItemPreviewResolver {
    static func prepare(_ request: ItemPreviewRequest) async throws -> PreparedPreview {
        let items = request.items

        guard items.indices.contains(request.startIndex) else {
            throw ItemPreviewError.missingItem
        }

        let target = items[request.startIndex]

        // Files already live on disk, so the whole category can swipe through
        // in one Quick Look session.
        let diskURLs = items
            .compactMap(\.fileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if let targetURL = target.fileURL,
           let index = diskURLs.firstIndex(of: targetURL) {
            return PreparedPreview(urls: diskURLs, startIndex: index)
        }

        // Library photos have no URL, so keep a cached copy Quick Look can
        // open. Re-opening the same photo skips the export completely.
        guard let identifier = target.assetIdentifier else {
            throw ItemPreviewError.missingItem
        }

        let url = try await AssetPhotoExporter.export(identifier: identifier)
        return PreparedPreview(urls: [url], startIndex: 0)
    }
}

// MARK: - Photo library export

private enum AssetPhotoExporter {
    static func export(identifier: String) async throws -> URL {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
        )

        guard let asset = assets.firstObject else {
            throw ItemPreviewError.missingItem
        }

        let directory = try cacheDirectory()

        if let cached = cachedPreview(for: identifier, in: directory) {
            return cached
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none

        let (data, dataUTI) = try await requestImageData(for: asset, options: options)

        let fileExtension = dataUTI
            .flatMap { UTType($0)?.preferredFilenameExtension }
            ?? "jpg"

        let destination = directory.appendingPathComponent(
            "\(key(for: identifier)).\(fileExtension)"
        )

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ItemPreviewError.missingPreview
        }

        trimCache(in: directory)
        return destination
    }

    private static func requestImageData(
        for asset: PHAsset,
        options: PHImageRequestOptions
    ) async throws -> (Data, String?) {
        try await withCheckedThrowingContinuation { continuation in
            let gate = PreviewDataGate(continuation)

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, dataUTI, _, _ in
                if let data {
                    gate.finish(.success((data, dataUTI)))
                } else {
                    gate.finish(.failure(ItemPreviewError.missingPreview))
                }
            }
        }
    }

    // MARK: Cache

    private static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        let directory = base.appendingPathComponent("ItemPreviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory
    }

    private static func cachedPreview(for identifier: String, in directory: URL) -> URL? {
        let name = key(for: identifier)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return files.first {
            $0.deletingPathExtension().lastPathComponent == name
        }
    }

    private static func key(for identifier: String) -> String {
        identifier.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        .reduce(into: "") { $0.append($1) }
    }

    /// Photo previews are disposable, so old copies are swept away whenever a
    /// new one is written.
    private static func trimCache(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        for file in files {
            let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast

            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Errors

private enum ItemPreviewError: LocalizedError {
    case missingItem
    case missingFile
    case missingPreview

    var errorDescription: String? {
        switch self {
        case .missingItem:
            return "This item is no longer available."
        case .missingFile:
            return "This file couldn’t be found on this iPhone."
        case .missingPreview:
            return "This item can’t be previewed right now."
        }
    }
}

// MARK: - SwiftUI integration

extension View {
    /// Adds previewing to any page that lists overview items.
    func itemPreview(request: Binding<ItemPreviewRequest?>) -> some View {
        modifier(ItemPreviewModifier(request: request))
    }
}

private struct ItemPreviewModifier: ViewModifier {
    @Binding var request: ItemPreviewRequest?

    @State private var urls: [URL] = []
    @State private var selection: URL?
    @State private var videoPreview: OverviewItem?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($selection, in: urls)
            .fullScreenCover(item: $videoPreview) { item in
                LibraryVideoPreviewView(item: item)
            }
            .overlay {
                if isPreparing {
                    preparingOverlay
                        .transition(.opacity)
                }
            }
            .alert(
                "Couldn’t preview item",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task(id: request?.id) {
                guard let request else { return }
                await prepare(request)
            }
            .onChange(of: selection) { _, newValue in
                // Quick Look clears its selection when it is dismissed.
                if newValue == nil {
                    urls = []
                }
            }
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.secondaryText)

                Text("Preparing preview…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @MainActor
    private func prepare(_ request: ItemPreviewRequest) async {
        urls = []
        selection = nil

        guard request.items.indices.contains(request.startIndex) else {
            errorMessage = ItemPreviewError.missingItem.localizedDescription
            return
        }

        let target = request.items[request.startIndex]

        // Videos use Apple's player so even a multi-gigabyte clip starts
        // playing without being copied anywhere first.
        if target.assetIdentifier != nil, target.isVideo {
            videoPreview = target
            return
        }

        isPreparing = true
        defer { isPreparing = false }

        do {
            let prepared = try await ItemPreviewResolver.prepare(request)

            guard !Task.isCancelled else { return }

            urls = prepared.urls
            selection = prepared.urls[prepared.startIndex]
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Video preview

/// Apple's AVKit player, streamed straight from the photo library.
private struct LibraryVideoPreviewView: View {
    let item: OverviewItem

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if errorMessage == nil {
                ProgressView()
                    .tint(.white)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(24)
            }

            closeButton
        }
        .statusBarHidden()
        .task { await load() }
        .onDisappear {
            player?.pause()
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close preview")
                .padding(.top, 8)
                .padding(.trailing, 16)
            }

            Spacer()
        }
    }

    private func load() async {
        guard let identifier = item.assetIdentifier else {
            errorMessage = "This item is no longer available."
            return
        }

        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
        )

        guard let asset = fetch.firstObject else {
            errorMessage = "This item is no longer available."
            return
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        do {
            let playerItem = try await requestPlayerItem(
                for: asset,
                options: options
            )

            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            player.play()
        } catch {
            errorMessage = "This video couldn’t be loaded."
        }
    }

    private func requestPlayerItem(
        for asset: PHAsset,
        options: PHVideoRequestOptions
    ) async throws -> AVPlayerItem {
        try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestPlayerItem(
                forVideo: asset,
                options: options
            ) { playerItem, _ in
                if let playerItem {
                    continuation.resume(returning: playerItem)
                } else {
                    continuation.resume(throwing: ItemPreviewError.missingPreview)
                }
            }
        }
    }
}

// MARK: - Async gate

/// PhotoKit can call its result handler more than once; this makes sure the
/// continuation only finishes on the first result.
private final class PreviewDataGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, String?), Error>?
    private var isFinished = false

    init(_ continuation: CheckedContinuation<(Data, String?), Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<(Data, String?), Error>) {
        lock.lock()

        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}
