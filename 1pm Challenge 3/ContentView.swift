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
    @ObservedObject private var coach = CoachController.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var hasFinishedScan: Bool
    @AppStorage("hasCompletedCoachTour") private var hasCompletedCoachTour = false
    @State private var isChoosingFolder = false
    @State private var showSettings = false
    @State private var folderError: String?
    @State private var didAutoScan = false
    @State private var autoScanToken = 0
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    init() {
        // Restore the last completed scan so a returning user lands on Home
        // immediately instead of watching the same scan again.
        _hasFinishedScan = State(initialValue: ScanCache.hasSnapshot())
    }

    private var photosGranted: Bool {
        photoStatus == .authorized || photoStatus == .limited
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
                        photosGranted: photosGranted,
                        filesGranted: library.hasFolderAccess,
                        onAllowPhotos: requestPhotoAccessForScan,
                        onAllowFiles: { isChoosingFolder = true },
                        onSkipPermissions: {
                            coach.advance(from: .permissions, to: .scan)
                        },
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
        .coachOverlay()
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                store: store,
                onReplayTour: {
                    path = NavigationPath()
                    if hasFinishedScan {
                        coach.startAtHome()
                    } else {
                        coach.start()
                    }
                },
                onRequestPhotoAccess: requestPhotoAccessForScan
            )
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
            guard phase == .active else { return }

            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            advancePermissionStepIfReady()

            guard hasFinishedScan else { return }
            Task { await store.refreshIfNeeded() }
        }
        .onChange(of: photoStatus) { _, _ in
            advancePermissionStepIfReady()
        }
        .onChange(of: library.folders) { _, _ in
            advancePermissionStepIfReady()
        }
        .onChange(of: hasFinishedScan) { _, finished in
            guard finished else { return }
            coach.resumeAfterScan()
        }
        .onChange(of: path.count) { _, count in
            guard count > 0 else { return }
            coach.advance(from: .homeChart, to: .filterButton)
        }
        .onChange(of: coach.completionToken) { _, _ in
            hasCompletedCoachTour = true
            path = NavigationPath()
        }
    }

    private var home: some View {
        HomeView(
            snapshot: store.snapshot,
            onSelectCategory: { category in
                path.append(category)
            },
            onRequestPhotoAccess: handlePhotoAccessRequest,
            onOpenSettings: { showSettings = true }
        )
    }

    @ViewBuilder
    private func destination(for category: StorageCategory) -> some View {
        switch category {
        case .photos:
            OverviewPage(
                kind: .photos,
                onGoHome: { path = NavigationPath() }
            ) {
                await store.refresh()
            }
        case .videos:
            OverviewPage(
                kind: .videos,
                onGoHome: { path = NavigationPath() }
            ) {
                await store.refresh()
            }
        case .files:
            OverviewPage(
                kind: .files,
                onGoHome: { path = NavigationPath() }
            ) {
                await store.refresh()
            }
        }
    }

    // MARK: - Launch

    private func handleAppear() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard !hasCompletedCoachTour else {
            startAutoScanIfPossible()
            return
        }

        // First launch goes straight to the landing page with the interactive
        // walkthrough layered on top. There is no separate tutorial screen.
        if hasFinishedScan {
            coach.startAtHome()
        } else {
            coach.start()
        }

        advancePermissionStepIfReady()
    }

    /// Starts a scan automatically only after the tour is done and a folder is
    /// already allowed. During the tour the user taps SCAN themselves.
    private func startAutoScanIfPossible() {
        guard !hasFinishedScan,
              !didAutoScan,
              library.hasFolderAccess,
              !coach.isRunning else {
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

    private func requestPhotoAccessForScan() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        // iOS only shows the system prompt once. After a denial the user has
        // to turn access back on in Settings.
        if status == .denied || status == .restricted {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }

        Task {
            await store.requestPhotoAccess()
            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            advancePermissionStepIfReady()
        }
    }

    private func handlePhotoAccessRequest() {
        if photoStatus == .notDetermined {
            requestPhotoAccessForScan()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Both permissions are in, so the tour moves to the SCAN button.
    private func advancePermissionStepIfReady() {
        guard coach.step == .permissions,
              photosGranted,
              library.hasFolderAccess else {
            return
        }

        coach.advance(from: .permissions, to: .scan)
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
