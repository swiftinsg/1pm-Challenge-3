//
//  DocumentLibrary.swift
//  1pm Challenge 3
//

import Combine
import Foundation

/// One folder the user allowed the app to read. The security-scoped bookmark
/// keeps the grant alive across launches, so the folder is scanned in place and
/// its files are never copied into the app sandbox.
struct DocumentFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bookmark: Data

    init(id: UUID = UUID(), name: String, bookmark: Data) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
    }
}

/// Owns the app's visible folders.
///
/// The app can always read its own Documents folder. Anything else on
/// "On My iPhone" needs the system folder picker, because iOS does not let an
/// app grant itself the root of the Files app. The chosen folder is stored as a
/// security-scoped bookmark and reopened on every launch.
final class DocumentLibrary: ObservableObject {
    static let shared = DocumentLibrary()

    @Published private(set) var folders: [DocumentFolder] = []

    private let lock = NSLock()
    private var rootsStorage: [URL] = []

    private static let foldersKey = "documentLibrary.folders"

    private init() {
        restoreFolders()
    }

    /// True when the user has allowed at least one folder outside the sandbox.
    var hasFolderAccess: Bool {
        !folders.isEmpty
    }

    /// Every root that should be scanned, with duplicates and nested folders
    /// removed. The app's own Documents folder always comes first.
    var scanRoots: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return rootsStorage
    }

    func documentsDirectory() -> URL? {
        try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Adds a folder chosen in the system picker and keeps its security scope
    /// open for the rest of the session.
    @discardableResult
    func addFolder(_ url: URL) throws -> DocumentFolder {
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let folder = DocumentFolder(
            name: displayName(for: url),
            bookmark: bookmark
        )

        // Replace an existing grant for the same folder instead of stacking
        // duplicate roots.
        let standardizedPath = url.standardizedFileURL.path
        folders.removeAll { existing in
            var isStale = false
            guard let existingURL = try? URL(
                resolvingBookmarkData: existing.bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return false
            }

            return existingURL.standardizedFileURL.path == standardizedPath
        }
        folders.append(folder)

        persistFolders()
        rebuildRoots()
        ScanCache.invalidateOverview(for: .files)
        return folder
    }

    func removeFolder(_ folder: DocumentFolder) {
        folders.removeAll { $0.id == folder.id }
        persistFolders()
        rebuildRoots()
        ScanCache.invalidateOverview(for: .files)
    }

    func removeAllFolders() {
        folders.removeAll()
        persistFolders()
        rebuildRoots()
        ScanCache.invalidateOverview(for: .files)
    }

    // MARK: - Bookmarks

    private func restoreFolders() {
        guard let data = UserDefaults.standard.data(forKey: Self.foldersKey),
              let stored = try? JSONDecoder().decode([DocumentFolder].self, from: data) else {
            rebuildRoots()
            return
        }

        var restored: [DocumentFolder] = []

        for folder in stored {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: folder.bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }

            if isStale,
               let refreshed = try? url.bookmarkData(
                   options: [],
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                restored.append(
                    DocumentFolder(id: folder.id, name: folder.name, bookmark: refreshed)
                )
            } else {
                restored.append(folder)
            }
        }

        folders = restored
        if restored.count != stored.count {
            persistFolders()
        }
        rebuildRoots()
    }

    private func persistFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: Self.foldersKey)
    }

    private func rebuildRoots() {
        var candidates: [URL] = []

        if let documents = documentsDirectory() {
            candidates.append(documents)
        }

        for folder in folders {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: folder.bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }

            // The URL stored in scanRoots must itself have an active security
            // scope; resolving a bookmark returns a new URL object.
            _ = url.startAccessingSecurityScopedResource()
            candidates.append(url)
        }

        // Keep only top-level roots. A folder that is already covered by an
        // earlier root would otherwise be enumerated twice.
        var unique: [URL] = []
        for url in candidates {
            let candidate = url.standardizedFileURL
            let path = candidate.path

            if unique.contains(where: { $0.path == path }) { continue }
            if unique.contains(where: { path.hasPrefix($0.path + "/") }) { continue }

            unique.removeAll { $0.path.hasPrefix(path + "/") }
            unique.append(candidate)
        }

        lock.lock()
        rootsStorage = unique
        lock.unlock()
    }

    private func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
