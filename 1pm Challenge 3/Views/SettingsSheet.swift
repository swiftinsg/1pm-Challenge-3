//
//  SettingsSheet.swift
//  1pm Challenge 3
//

import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything that is not part of the main cleaning flow lives here: rescanning,
/// replaying the walkthrough, managing the allowed folders and checking access.
/// It is presented as a sheet so Home keeps the full-screen chart.
struct SettingsSheet: View {
    @ObservedObject var store: StorageStore
    @ObservedObject private var library = DocumentLibrary.shared
    @ObservedObject private var coach = CoachController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let onReplayTour: () -> Void
    let onRequestPhotoAccess: () -> Void

    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isChoosingFolder = false
    @State private var folderError: String?
    @State private var lastScanFinished: Date?
    @AppStorage(NotificationService.alertsEnabledKey) private var lowStorageAlertsEnabled = true

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    // During the tour the instruction card sits above the
                    // storage card, so the two never overlap.
                    if let step = coach.step, step.showsInlineCard {
                        CoachInstructionCard(
                            step: step,
                            showsContinue: step.showsContinueButton,
                            onSkip: { coach.finish() },
                            onContinue: {
                                coach.advance(from: step, to: step.next)
                                dismiss()
                            },
                            onFinish: { coach.finish() }
                        )
                        .coachAnchor(.coachCard)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .transition(.opacity)
                    }

                    ScrollView {
                        VStack(spacing: 20) {
                            storageSection
                            scanSection
                            alertsSection
                            walkthroughSection
                            foldersSection
                            accessSection
                            privacyFooter
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if coach.step == .settingsStorage {
                            coach.advance(from: .settingsStorage, to: .homeChart)
                        }
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .tint(.primary)
                }
            }
        }
        .coachOverlay(showsCard: false)
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
        .onAppear {
            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            store.refreshCapacity()

            // Opening Settings during the tour moves on to the storage
            // explanation, so the sheet shows its inline instruction card.
            if coach.step == .settingsButton {
                coach.advance(from: .settingsButton, to: .settingsStorage)
            }
        }
        .onDisappear {
            // A swipe-down closes the sheet without tapping Done. Keep the
            // tour moving instead of leaving it stuck on the settings step.
            if coach.step == .settingsStorage {
                coach.advance(from: .settingsStorage, to: .homeChart)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            store.refreshCapacity()
        }
    }

    // MARK: - Storage

    /// The same values Home uses for its big numbers. Both pages read the
    /// single `StorageStore` snapshot, so they can never disagree.
    private var storageSection: some View {
        SettingsCard(title: "Storage") {
            SettingsValueRow(
                symbol: "iphone",
                title: "iPhone total",
                value: formattedCapacity(store.snapshot.advertisedCapacity)
            )

            separator

            SettingsValueRow(
                symbol: "internaldrive",
                title: "Usable capacity",
                value: formattedCapacity(store.snapshot.totalCapacity)
            )

            separator

            SettingsValueRow(
                symbol: "internaldrive.fill",
                title: "Used",
                value: formattedCapacity(store.snapshot.usedCapacity)
            )

            separator

            SettingsValueRow(
                symbol: "checkmark.circle",
                title: "Available",
                value: formattedCapacity(store.snapshot.availableCapacity)
            )
        }
        .coachAnchor(.settingsStorageCard)
    }

    private func formattedCapacity(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return StorageFormatter.capacity(bytes)
    }

    // MARK: - Scan

    private var scanSection: some View {
        SettingsCard(title: "Scan") {
            SettingsRow(
                symbol: "arrow.clockwise",
                title: "Rescan now",
                subtitle: scanSubtitle,
                isBusy: store.isRefreshing
            ) {
                rescan()
            }
        }
    }

    private var scanSubtitle: String {
        if store.isRefreshing {
            return "Scanning this iPhone…"
        }

        if let lastScanFinished,
           Date().timeIntervalSince(lastScanFinished) < 90 {
            return "Updated just now."
        }

        return "Update your chart with what’s on this iPhone right now."
    }

    // MARK: - Alerts

    /// The only notification the app sends: a single low-storage reminder.
    /// Giving it a visible switch keeps the permission honest and reversible.
    private var alertsSection: some View {
        SettingsCard(title: "Alerts") {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(AppTheme.surface)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Low storage alerts")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("A reminder when this iPhone is nearly full.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: $lowStorageAlertsEnabled)
                    .labelsHidden()
                    .tint(AppTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .onChange(of: lowStorageAlertsEnabled) { _, enabled in
            if enabled {
                NotificationService.updateLowStorageReminder(
                    available: store.snapshot.availableCapacity,
                    total: store.snapshot.totalCapacity
                )
            } else {
                NotificationService.cancelLowStorageReminder()
            }
        }
    }

    // MARK: - Walkthrough

    private var walkthroughSection: some View {
        SettingsCard(title: "Walkthrough") {
            SettingsRow(
                symbol: "sparkles",
                title: "Replay the tour",
                subtitle: "Walk through the chart, filters and clean-up again."
            ) {
                replayTour()
            }
        }
    }

    // MARK: - Folders

    private var foldersSection: some View {
        SettingsCard(title: "Files on this iPhone") {
            if library.folders.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(AppTheme.surface)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("No folders allowed yet")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("iOS only lets the app read folders you choose in the Files picker.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                separator
            } else {
                ForEach(Array(library.folders.enumerated()), id: \.element.id) { index, folder in
                    folderRow(folder)

                    if index < library.folders.count - 1 {
                        separator
                    }
                }

                separator
            }

            SettingsRow(
                symbol: "folder.badge.plus",
                title: "Add folders",
                subtitle: "Pick folders in Files › On My iPhone."
            ) {
                isChoosingFolder = true
            }
        }
    }

    private func folderRow(_ folder: DocumentFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StorageCategory.files.color)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(StorageCategory.files.color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Allowed to read")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 8)

            Button {
                removeFolder(folder)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(AppTheme.surface)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop reading \(folder.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var separator: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    // MARK: - Access

    private var accessSection: some View {
        SettingsCard(title: "Access") {
            SettingsRow(
                symbol: "photo.on.rectangle.angled",
                title: "Photos & videos",
                subtitle: photoAccessSubtitle,
                tint: StorageCategory.photos.color
            ) {
                handlePhotoAccess()
            }
        }
    }

    private var photoAccessSubtitle: String {
        switch photoStatus {
        case .authorized:
            return "Full access. Only items already on this iPhone are measured."
        case .limited:
            return "Limited access. Only the items you allowed are measured."
        case .denied, .restricted:
            return "Not allowed. Tap to open Settings."
        case .notDetermined:
            return "Not requested yet. Tap to allow."
        @unknown default:
            return "Photo access is unavailable on this device."
        }
    }

    // MARK: - Privacy

    private var privacyFooter: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.tertiaryText)

            Text("Everything is measured on this iPhone. Nothing is uploaded, and iCloud items are never downloaded.")
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("Version \(appVersion)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version ?? "1.0"
    }

    // MARK: - Actions

    private func rescan() {
        guard !store.isRefreshing else { return }

        Task {
            // Never trigger a permission prompt from Settings; access is
            // already handled by the Access row.
            await store.refresh(requestAccess: false)
            lastScanFinished = Date()
        }
    }

    private func replayTour() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            onReplayTour()
        }
    }

    private func removeFolder(_ folder: DocumentFolder) {
        withAnimation(.easeInOut(duration: 0.2)) {
            library.removeFolder(folder)
        }

        Task {
            await store.refresh(requestAccess: false)
            lastScanFinished = Date()
        }
    }

    private func handlePhotoAccess() {
        if photoStatus == .notDetermined {
            onRequestPhotoAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            }
            return
        }

        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
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
                rescan()
            } catch {
                folderError = error.localizedDescription
            }
        }
    }
}

// MARK: - Building blocks

private struct SettingsCard<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.leading, 6)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
        }
    }
}

private struct SettingsValueRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(AppTheme.surface)
                )

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var tint: Color = .primary
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(tint.opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.secondaryText)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}
