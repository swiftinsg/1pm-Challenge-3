//
//  PermissionPromptView.swift
//  1pm Challenge 3
//

import SwiftUI

/// Two notification-style permission requests shown on the landing page.
/// Tapping Allow runs the real system prompt (Photos) or opens the system
/// folder picker (Files). iOS never lets an app grant Files access silently.
struct PermissionPromptView: View {
    let photosGranted: Bool
    let filesGranted: Bool
    let onAllowPhotos: () -> Void
    let onAllowFiles: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            banner(
                icon: "photo.on.rectangle.angled",
                tint: StorageCategory.photos.color,
                title: "Photos & Videos",
                message: "Spacer would like to read your photo library to measure the space it uses. Items stored only in iCloud are never downloaded.",
                isGranted: photosGranted,
                action: onAllowPhotos
            )

            banner(
                icon: "folder.fill",
                tint: StorageCategory.files.color,
                title: "Files on On My iPhone",
                message: "Allow Spacer to scan documents already stored on this iPhone. Files are read where they are and never copied. Choose your folders on the next screen.",
                isGranted: filesGranted,
                action: onAllowFiles
            )

            privacyNote
        }
    }

    // MARK: - Notification banner

    private func banner(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("SPACER")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(AppTheme.tertiaryText)

                    Spacer(minLength: 8)

                    Text("now")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(AppTheme.tertiaryText)
                }

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)

                Button(action: action) {
                    HStack(spacing: 5) {
                        if isGranted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(isGranted ? "Allowed" : "Allow")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(
                        isGranted
                            ? AppTheme.secondaryText
                            : Color(uiColor: .systemBackground)
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isGranted ? AppTheme.surface : Color.primary)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGranted)
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Privacy

    private var privacyNote: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Privacy comes first")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(AppTheme.secondaryText)

            Text("Everything is measured on this iPhone. Nothing leaves your device and iCloud items are never downloaded.")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(AppTheme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            Button("Not now", action: onNotNow)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 2)
        }
        .padding(.top, 2)
        .padding(.horizontal, 12)
    }
}

#Preview {
    ZStack {
        AppBackground()
        PermissionPromptView(
            photosGranted: false,
            filesGranted: false,
            onAllowPhotos: {},
            onAllowFiles: {},
            onNotNow: {}
        )
        .padding(22)
    }
}
