//
//  HomeView.swift
//  1pm Challenge 3
//

import SwiftUI

struct HomeView: View {
    let snapshot: StorageSnapshot
    let onSelectCategory: (StorageCategory) -> Void
    let onRequestPhotoAccess: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            AppBackground()

            GeometryReader { proxy in
                let diameter = chartDiameter(for: proxy.size)

                VStack(spacing: 0) {
                    header

                    StorageLegendView(
                        usages: snapshot.categories,
                        isLoading: !snapshot.isLoaded,
                        onSelect: onSelectCategory,
                        anchors: [.photos: .homePhotosLegend]
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 14)

                    Spacer(minLength: 12)

                    DonutChartView(
                        snapshot: snapshot,
                        diameter: diameter,
                        onSelectCategory: onSelectCategory,
                        anchors: [.photos: .homePhotosSegment]
                    )

                    StorageCapacityBar(
                        used: snapshot.usedCapacity,
                        total: snapshot.totalCapacity
                    )
                    .padding(.horizontal, 34)
                    .padding(.top, 26)

                    Text("Only the categories above are shown — not all storage on this iPhone.\nItems in more than one category are counted once.")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 40)
                        .padding(.top, 12)

                    if snapshot.photosAccessNeedsAttention {
                        Button {
                            onRequestPhotoAccess()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(snapshot.isPhotoAccessLimited ? "Allow full access" : "Allow photo access")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppTheme.surface)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 16)
                    }

                    Spacer(minLength: 24)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("This iPhone")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Storage at a glance")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            Spacer(minLength: 0)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(AppTheme.surface)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(AppTheme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .coachAnchor(.homeSettingsButton)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private func chartDiameter(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 260 }

        let widthLimit = size.width - 64
        let heightLimit = size.height * 0.52
        return min(widthLimit, heightLimit, 360)
    }
}
