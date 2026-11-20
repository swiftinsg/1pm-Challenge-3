//
//  ContentView.swift
//  1pm Challenge 3
//

import SwiftUI
import Photos
import UIKit

struct ContentView: View {
    @StateObject private var store = StorageStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var hasFinishedScan = false
    @AppStorage("hasCompletedTutorial") private var hasCompletedTutorial = false
    @State private var isShowingTutorial = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if hasFinishedScan {
                    home
                        .transition(.opacity)
                } else {
                    ScanLandingView(
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
        .fullScreenCover(isPresented: $isShowingTutorial) {
            TutorialView {
                hasCompletedTutorial = true
                isShowingTutorial = false
            }
        }
        .onAppear {
            // Show the tour only on the very first launch. The flag is stored
            // in UserDefaults, so later launches skip straight to the landing
            // page.
            guard !hasCompletedTutorial else { return }
            isShowingTutorial = true
        }
        .task {
            // A previous run may have been terminated while a deletion Live
            // Activity was on screen; clear it instead of leaving it stale.
            DeletionActivityController.shared.endStaleActivities()
        }
        .onChange(of: scenePhase) { _, phase in
            // Only refresh once the user has scanned; the landing page waits
            // for the SCAN button instead of measuring on launch.
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
