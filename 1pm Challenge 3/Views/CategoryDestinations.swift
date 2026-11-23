//
//  CategoryDestinations.swift
//  1pm Challenge 3
//

import SwiftUI
import UniformTypeIdentifiers

struct PhotosDetailView: View {
    let usage: CategoryUsage

    var body: some View {
        CategoryDetailView(usage: usage)
    }
}

struct VideosDetailView: View {
    let usage: CategoryUsage

    var body: some View {
        CategoryDetailView(usage: usage)
    }
}

struct FilesDetailView: View {
    let usage: CategoryUsage
    let onLibraryChanged: () async -> Void

    @State private var isChoosingFolder = false
    @State private var folderError: String?

    var body: some View {
        CategoryDetailView(usage: usage) {
            isChoosingFolder = true
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            handleFolderSelection(result)
        }
        .alert(
            "Couldn’t access that folder",
            isPresented: Binding(
                get: { folderError != nil },
                set: { if !$0 { folderError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                folderError = error.localizedDescription
            }

        case .success(let urls):
            guard !urls.isEmpty else { return }

            do {
                for url in urls {
                    try DocumentLibrary.shared.addFolder(url)
                }
                Task { await onLibraryChanged() }
            } catch {
                folderError = error.localizedDescription
            }
        }
    }
}
