//
//  ContentView.swift
//  1pm Challenge 3
//

import SwiftUI
import Photos
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = StorageStore()
    @ObservedObject private var library = DocumentLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var hasFinishedScan: Bool
    @AppStorage("hasCompletedTutorial") private var hasCompletedTutorial = false
    @State private var isShowingTutorial = false
    @State private var isChoosingFolder = false
    @State private var folderError: String?
    @State private var didPromptForFolder = false
    @State private var didAutoScan = false
    @State private var autoScanToken = 0

    init() {
        // Restore the last completed scan so a returning user lands on Home
        // immediately instead of watching the same scan again.
        _hasFinishedScan = State(initialValue: ScanCache.hasSnapshot())
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if hasFinishedScan {
                    home
                        .transition(.opacity)
                } else {
                    ScanLandingView(
                        autoScanToken: autoScanToken,
                        onScan: {
                            await store.refresh(requestAccess: true)
                        },
                        onFinished: {
                            path = NavigationPath()
                            // Swap to Home as soon as the scan completes;
                            // there is no tip carousel or minimum wait.
                            withAnimation(.easeOut(duration: 0.2)) {
                                hasFinishedScan = true
                            }
                        }
                    )
                    .transition(.opacity)
                }
            }
            .navigationDestination(for: StorageCategory.self) { category in
                destination(for: category)
            }
        }
        .tint(AppTheme.accent)
        .fullScreenCover(
            isPresented: $isShowingTutorial,
            onDismiss: handleTutorialDismissed
        ) {
            TutorialView {
                hasCompletedTutorial = true
                isShowingTutorial = false
            }
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
        .onAppear(perform: handleAppear)
        .task {
            // A previous run may have been terminated while a deletion Live
            // Activity was on screen; clear it instead of leaving it stale.
            DeletionActivityController.shared.endStaleActivities()

            // Cached values are already on screen. Refresh quietly if they
            // have gone stale.
            if hasFinishedScan {
                await store.refreshIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, hasFinishedScan else { return }
            Task { await store.refreshIfNeeded() }
        }
    }

    private var home: some View {
        HomeView(
            snapshot: store.snapshot,
            onSelectCategory: { category in
                path.append(category)
            },
            onRequestPhotoAccess: handlePhotoAccessRequest
        )
    }

    @ViewBuilder
    private func destination(for category: StorageCategory) -> some View {
        switch category {
        case .photos:
            OverviewPage(kind: .photos) {
                await store.refresh()
            }
        case .videos:
            OverviewPage(kind: .videos) {
                await store.refresh()
            }
        case .files:
            OverviewPage(kind: .files) {
                await store.refresh()
            }
        }
    }

    // MARK: - Launch

    private func handleAppear() {
        guard !hasCompletedTutorial else {
            promptForFolderIfNeeded()
            startAutoScanIfPossible()
            return
        }

        // Show the tour only on the very first launch. The flag is stored in
        // UserDefaults, so later launches skip straight to the landing page.
        isShowingTutorial = true
    }

    private func handleTutorialDismissed() {
        promptForFolderIfNeeded()
        startAutoScanIfPossible()
    }

    /// Asks for On My iPhone access once per launch when no folder has been
    /// granted. iOS does not allow an app to grant itself the Files root, so
    /// the system picker is the only way to open it in place.
    private func promptForFolderIfNeeded() {
        guard !didPromptForFolder, !library.hasFolderAccess else { return }

        didPromptForFolder = true

        // Let the first screen finish appearing before presenting the picker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isChoosingFolder = true
        }
    }

    private func startAutoScanIfPossible() {
        guard !hasFinishedScan,
              !didAutoScan,
              library.hasFolderAccess,
              !isShowingTutorial else {
            return
        }

        didAutoScan = true
        autoScanToken += 1
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
                    try library.addFolder(url)
                }

                if hasFinishedScan {
                    Task { await store.refresh() }
                } else {
                    startAutoScanIfPossible()
                }
            } catch {
                folderError = error.localizedDescription
            }
        }
    }

    private func handlePhotoAccessRequest() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        if status == .notDetermined {
            Task { await store.requestPhotoAccess() }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    ContentView()
}

@main
struct Challenge3App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
