//
//  DeletionStatusBanner.swift
//  1pm Challenge 3
//

import SwiftUI

/// Small floating popup shown while a bulk deletion runs. It mirrors the Live
/// Activity for devices without a Dynamic Island, and stays visible in the app
/// while the system activity takes over once the app is in the background.
struct DeletionStatusBanner: View {
    let progress: DeletionProgress

    private var accent: Color {
        if progress.isFinished {
            return progress.completed == 0
                ? Color(hex: 0xDC2626)
                : Color(hex: 0x16A34A)
        }
        return Color(hex: 0x7C5CFC)
    }

    private var title: String {
        if progress.isFinished {
            if progress.completed == 0 { return "Couldn’t delete items" }
            return progress.completed == 1
                ? "Deleted 1 item"
                : "Deleted \(progress.completed) items"
        }

        return progress.total == 1
            ? "Deleting 1 item…"
            : "Deleting \(progress.total) items…"
    }

    private var subtitle: String {
        if progress.isFinished {
            if progress.completed == 0 { return "Nothing was removed" }
            return "\(StorageFormatter.compact(progress.bytes)) saved"
        }

        if progress.completed > 0 {
            return "\(StorageFormatter.compact(progress.bytes)) · \(progress.completed) of \(progress.total)"
        }

        return "Removing from your library…"
    }

    private var fraction: Double {
        guard progress.total > 0 else { return 0 }
        return min(1, max(0, Double(progress.completed) / Double(progress.total)))
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 34, height: 34)

                if progress.isFinished {
                    Image(systemName: progress.completed == 0 ? "exclamationmark" : "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !progress.isFinished, progress.completed > 0 {
                Text("\(progress.completed)/\(progress.total)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(accent.opacity(0.18), lineWidth: 1)
                )
        )
        .overlay(alignment: .bottom) {
            if !progress.isFinished, progress.completed > 0 {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(accent.opacity(0.65))
                        .frame(width: proxy.size.width * fraction, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 1)
                .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }
}
