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
    /// The landing page with the SCAN button is always the first screen of a
    /// new app launch, even when a previous scan is cached. The cached values
    /// are still restored by `StorageStore`, so the scan itself stays fast.
    @State private var hasFinishedScan = false
    @AppStorage("hasCompletedCoachTour") private var hasCompletedCoachTour = false
    @State private var isChoosingFolder = false
    @State private var showSettings = false
    @State private var folderError: String?
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// Held while the folder picker is open during the SCAN flow, so the scan
    /// starts only after the user has answered the Files request.
    @State private var folderRequestContinuation: CheckedContinuation<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if hasFinishedScan {
                    home
                        .transition(.opacity)
                } else {
                    ScanLandingView(
                        onScan: {
                            await scanWithAccessRequests()
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

            // Warm the in-memory cache while the landing page is on screen.
            // Category pages then open without waiting on a disk decode.
            ScanCache.preload()

            // The very first thing a new user sees: the system notification
            // prompt, over the SCAN landing page. Photos and Files are asked
            // for later, when SCAN is tapped.
            await NotificationService.requestOnFirstLaunch()

            // The permission is now answered, so arm the low-storage reminder
            // it exists for.
            NotificationService.updateLowStorageReminder(
                available: store.snapshot.availableCapacity,
                total: store.snapshot.totalCapacity
            )

            if hasFinishedScan {
                await store.refreshIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }

            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            // The big Home numbers must match the current device capacity as
            // soon as the app comes back.
            store.refreshCapacity()

            guard hasFinishedScan else { return }
            Task { await store.refreshIfNeeded() }
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
        // Coming back from a category page should not show yesterday's
        // capacity. This only re-reads the volume values; it does not rescan.
        .onAppear { store.refreshCapacity() }
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
        store.refreshCapacity()

        guard !hasCompletedCoachTour else { return }

        // First launch goes straight to the landing page with the interactive
        // walkthrough layered on top. There is no separate tutorial screen.
        if hasFinishedScan {
            coach.startAtHome()
        } else {
            coach.start()
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        // A scan started by SCAN may be waiting on this picker.
        defer { resumeFolderRequest() }

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
        }
    }

    private func handlePhotoAccessRequest() {
        if photoStatus == .notDetermined {
            requestPhotoAccessForScan()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Runs when the user taps SCAN. Access is requested here — not on the
    /// landing page — so the first launch only shows the notification prompt.
    @MainActor
    private func scanWithAccessRequests() async {
        // Photos: iOS shows its own alert the first time. A denied status is
        // not re-prompted; the scan simply measures what it is allowed to.
        await store.promptForPhotoAccess()
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        // Files: iOS only grants folder access through the system picker, so
        // it is presented now, before the measurement starts.
        if !library.hasFolderAccess {
            await withCheckedContinuation { continuation in
                folderRequestContinuation = continuation
                isChoosingFolder = true
            }
        }

        await store.refresh(requestAccess: false)
    }

    private func resumeFolderRequest() {
        folderRequestContinuation?.resume()
        folderRequestContinuation = nil
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
