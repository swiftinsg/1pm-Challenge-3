//
//  DeletionActivityWidget.swift
//  DeletionActivity
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DeletionActivityBundle: WidgetBundle {
    var body: some Widget {
        DeletionActivityWidget()
    }
}

struct DeletionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeletionActivityAttributes.self) { context in
            LockScreenDeletionView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusSymbol(for: context.state)
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(counterText(for: context.state))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(for: context.state))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(subtitle(for: context.state))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.isFinished {
                        ProgressView(
                            value: Double(context.state.completed),
                            total: Double(max(context.state.total, 1))
                        )
                        .tint(brandColor)
                        .padding(.top, 2)
                    }
                }
            } compactLeading: {
                statusSymbol(for: context.state)
                    .font(.system(size: 14, weight: .semibold))
            } compactTrailing: {
                Text(counterText(for: context.state))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                statusSymbol(for: context.state)
                    .font(.system(size: 14, weight: .semibold))
            }
            .keylineTint(brandColor)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenDeletionView: View {
    let state: DeletionActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(lockScreenSymbolColor.opacity(0.22))
                        .frame(width: 40, height: 40)

                    if state.isFinished {
                        Image(systemName: symbolName(for: state))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(symbolColor(for: state))
                    } else {
                        ProgressView()
                            .tint(lockScreenSymbolColor)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: state))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(subtitle(for: state))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(counterText(for: state))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            if !state.isFinished {
                ProgressView(
                    value: Double(state.completed),
                    total: Double(max(state.total, 1))
                )
                .tint(brandColor)
            }
        }
        .padding(16)
    }
}

// MARK: - Shared presentation

private let brandColor = Color(
    red: 124 / 255,
    green: 92 / 255,
    blue: 252 / 255
)

private var lockScreenSymbolColor: Color {
    brandColor
}

private func statusSymbol(
    for state: DeletionActivityAttributes.ContentState
) -> some View {
    Image(systemName: symbolName(for: state))
        .foregroundStyle(symbolColor(for: state))
}

private func symbolName(
    for state: DeletionActivityAttributes.ContentState
) -> String {
    if state.isFinished {
        return state.completed == 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }
    return "trash.fill"
}

private func symbolColor(
    for state: DeletionActivityAttributes.ContentState
) -> Color {
    if state.isFinished {
        return state.completed == 0 ? .red : .green
    }
    return brandColor
}

private func title(
    for state: DeletionActivityAttributes.ContentState
) -> String {
    if state.isFinished {
        if state.completed == 0 { return "Couldn’t delete items" }
        return state.completed == 1 ? "Deleted 1 item" : "Deleted \(state.completed) items"
    }

    return state.total == 1 ? "Deleting 1 item…" : "Deleting \(state.total) items…"
}

private func subtitle(
    for state: DeletionActivityAttributes.ContentState
) -> String {
    if state.isFinished {
        if state.completed == 0 { return "Nothing was removed" }
        return "\(sizeText(state.bytes)) saved"
    }

    if state.completed > 0 {
        return "\(sizeText(state.bytes)) · \(state.completed) of \(state.total)"
    }

    return "Keep this screen open"
}

private func counterText(
    for state: DeletionActivityAttributes.ContentState
) -> String {
    if state.isFinished {
        return state.completed == 1 ? "1" : "\(state.completed)"
    }
    return "\(state.completed)/\(state.total)"
}

private func sizeText(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 MB" }

    let gigabytes = Double(bytes) / 1_000_000_000
    if gigabytes >= 1 {
        return formattedSize(gigabytes, unit: "GB")
    }

    let megabytes = Double(bytes) / 1_000_000
    return formattedSize(max(0.1, megabytes), unit: "MB")
}

private func formattedSize(_ value: Double, unit: String) -> String {
    let rounded = value >= 10
        ? value.rounded()
        : (value * 10).rounded() / 10

    if rounded == rounded.rounded() {
        return "\(Int(rounded)) \(unit)"
    }

    return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), rounded, unit)
}
