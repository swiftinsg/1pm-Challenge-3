//
//  TutorialView.swift
//  1pm Challenge 3
//

import SwiftUI

/// A short first-launch tour of the app. The caller presents this once and
/// records completion, so returning users go straight to the scan landing page.
struct TutorialView: View {
    let onFinish: () -> Void

    @State private var pageIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages = TutorialPage.all

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                skipBar

                TabView(selection: $pageIndex) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        TutorialPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityValue("Page \(pageIndex + 1) of \(pages.count)")

                pageIndicator
                    .padding(.bottom, 22)

                actionButton
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Chrome

    private var skipBar: some View {
        HStack {
            Spacer()

            Button("Skip", action: finish)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppTheme.surface)
                )
                .accessibilityLabel("Skip tutorial")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(height: 44)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        index == pageIndex
                            ? Color.primary
                            : Color.primary.opacity(0.16)
                    )
                    .frame(width: index == pageIndex ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: pageIndex)
        .accessibilityHidden(true)
    }

    private var actionButton: some View {
        Button {
            if pageIndex < pages.count - 1 {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                    pageIndex += 1
                }
            } else {
                finish()
            }
        } label: {
            Text(isLastPage ? "Get Started" : "Continue")
                .font(.system(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLastPage ? "Get started" : "Continue to next page")
    }

    private var isLastPage: Bool {
        pageIndex == pages.count - 1
    }

    private func finish() {
        onFinish()
    }
}

// MARK: - Page

private struct TutorialPageView: View {
    let page: TutorialPage

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            TutorialIllustration(art: page.art)
                .padding(.bottom, 28)
                .accessibilityHidden(true)

            Text(page.title)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(page.message)
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 12)
                .frame(maxWidth: 330)

            Spacer(minLength: 16)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Illustrations

private struct TutorialIllustration: View {
    let art: TutorialArt

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.surface)
                .frame(width: 208, height: 208)

            Circle()
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
                .frame(width: 208, height: 208)

            artwork
        }
        .frame(width: 220, height: 220)
    }

    @ViewBuilder
    private var artwork: some View {
        switch art {
        case .scan:
            scanArt
        case .chart:
            chartArt
        case .filter:
            filterArt
        case .delete:
            deleteArt
        case .files:
            filesArt
        }
    }

    private var scanArt: some View {
        BroomIcon()
            .frame(width: 24, height: 24)
            .scaleEffect(3.6)
            .foregroundStyle(.primary)
    }

    private var chartArt: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.chartTrack, lineWidth: 20)

            segment(from: 0.00, to: 0.46, color: StorageCategory.photos.color)
            segment(from: 0.48, to: 0.78, color: StorageCategory.videos.color)
            segment(from: 0.80, to: 0.97, color: StorageCategory.files.color)

            VStack(spacing: 2) {
                Text("128 GB")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .tracking(-0.4)
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Text("tracked")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.tertiaryText)
            }
        }
        .frame(width: 152, height: 152)
    }

    private var filterArt: some View {
        VStack(spacing: 14) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(StorageCategory.photos.color)

            HStack(spacing: 5) {
                filterChip("Large")
                filterChip("Outdated")
                filterChip("Duplicates")
            }
        }
    }

    private var deleteArt: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Color(hex: 0xDC2626))

            Text("12.4 GB saved")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color(hex: 0x16A34A))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(hex: 0x16A34A, opacity: 0.12))
                )
        }
    }

    private var filesArt: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(StorageCategory.files.color)

            Text("On My iPhone")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppTheme.surface)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(AppTheme.hairline, lineWidth: 1)
                        )
                )
        }
    }

    private func segment(from: CGFloat, to: CGFloat, color: Color) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: 20, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }

    private func filterChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.surface)
            )
    }
}

// MARK: - Model

private struct TutorialPage: Identifiable {
    let id: Int
    let art: TutorialArt
    let title: String
    let message: String

    static let all: [TutorialPage] = [
        TutorialPage(
            id: 0,
            art: .scan,
            title: "Welcome to Spacer",
            message: "Tap SCAN and Spacer measures the photos, videos and files on this iPhone. Everything stays on your device."
        ),
        TutorialPage(
            id: 1,
            art: .chart,
            title: "See what's taking space",
            message: "Your storage is split into Photos, Videos and Files on this chart. Tap a slice or a category above it to explore."
        ),
        TutorialPage(
            id: 2,
            art: .filter,
            title: "Find the clutter",
            message: "Filter any category to surface Large, Outdated, Duplicate or Screenshot items. You decide what counts as outdated."
        ),
        TutorialPage(
            id: 3,
            art: .delete,
            title: "Preview, then delete",
            message: "Tap an item to preview it. Use Select to choose several, then delete them in one go. Freed space adds to Storage saved."
        ),
        TutorialPage(
            id: 4,
            art: .files,
            title: "Measure your files",
            message: "On the Files page, tap Add files from On My iPhone to include documents in your scan. They're measured alongside your media."
        )
    ]
}

private enum TutorialArt {
    case scan
    case chart
    case filter
    case delete
    case files
}

#Preview {
    TutorialView(onFinish: {})
}
