//
//  DeletionSuccessSheet.swift
//  1pm Challenge 3
//

import SwiftUI

/// What was removed, kept in one value so the success sheet can present it with
/// `.sheet(item:)` and never show a stale total.
struct DeletionSummary: Identifiable {
    let id = UUID()
    let count: Int
    let bytes: Int64
    let isFiles: Bool

    var sizeText: String {
        StorageFormatter.compact(bytes)
    }

    var title: String {
        isFiles ? "Freed \(sizeText)" : "Cleaned up \(sizeText)"
    }

    var message: String {
        let items = count == 1 ? "1 item" : "\(count) items"

        if isFiles {
            return "\(items) removed from this iPhone. Your Home chart is already up to date."
        }

        return "\(items) moved to Recently Deleted. Empty it in Photos to reclaim the space now. Your Home chart is already up to date."
    }
}

/// The end of a delete: a clear result and one obvious way back to Home.
struct DeletionSuccessSheet: View {
    let summary: DeletionSummary
    let onBackHome: () -> Void
    let onKeepCleaning: () -> Void

    private let success = Color(hex: 0x16A34A)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(success.opacity(0.12))
                    .frame(width: 76, height: 76)

                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(success)
            }
            .padding(.top, 30)

            Text(summary.title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.top, 16)

            Text(summary.message)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 26)
                .padding(.top, 8)

            Spacer(minLength: 20)

            Button(action: onBackHome) {
                Text("Back to Home")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary)
                    )
            }
            .buttonStyle(.plain)

            Button("Keep cleaning", action: onKeepCleaning)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.top, 14)

            Spacer(minLength: 14)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(390)])
        .presentationCornerRadius(30)
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}
