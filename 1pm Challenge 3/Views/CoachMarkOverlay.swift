//
//  CoachMarkOverlay.swift
//  1pm Challenge 3
//

import SwiftUI
import UIKit

/// Every control the walkthrough can spotlight.
enum CoachAnchor: Hashable {
    case permissionStack
    case scanButton
    case homePhotosLegend
    case homePhotosSegment
    case filterButton
    case filterOutdatedRow
    case filterThresholdRow
    case filterCancelButton
    case overviewLargeLegend
    case overviewLargeSegment
    case detailSelectButton
    case detailFirstSelect
    case detailDeleteButton
    case coachCard
}

/// A donut segment in window coordinates. The spotlight follows the real arc
/// so a large category is highlighted for its full size.
struct CoachArcSpotlight: Equatable {
    var center: CGPoint
    var radius: CGFloat
    var thickness: CGFloat
    var startDegrees: Double
    var endDegrees: Double

    func path(padding: CGFloat = 4) -> Path {
        let outer = radius + thickness / 2 + padding
        let inner = max(1, radius - thickness / 2 - padding)
        let start = Angle.degrees(startDegrees - 0.45)
        let end = Angle.degrees(endDegrees + 0.45)

        var path = Path()
        path.addArc(
            center: center,
            radius: outer,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: inner,
            startAngle: end,
            endAngle: start,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

/// A spotlight is either a rectangle or a full donut segment.
enum CoachSpotlight {
    case rect(CGRect)
    case arc(CoachArcSpotlight)

    var bounds: CGRect {
        switch self {
        case .rect(let rect):
            return rect
        case .arc(let arc):
            let outer = arc.radius + arc.thickness / 2 + 4
            return CGRect(
                x: arc.center.x - outer,
                y: arc.center.y - outer,
                width: outer * 2,
                height: outer * 2
            )
        }
    }
}

struct CoachAnchorKey: PreferenceKey {
    static let defaultValue: [CoachAnchor: CGRect] = [:]

    static func reduce(
        value: inout [CoachAnchor: CGRect],
        nextValue: () -> [CoachAnchor: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct CoachArcKey: PreferenceKey {
    static let defaultValue: [CoachAnchor: CoachArcSpotlight] = [:]

    static func reduce(
        value: inout [CoachAnchor: CoachArcSpotlight],
        nextValue: () -> [CoachAnchor: CoachArcSpotlight]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct CoachAnchorModifier: ViewModifier {
    let anchor: CoachAnchor?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let anchor {
            content.background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CoachAnchorKey.self,
                        value: [anchor: proxy.frame(in: .global)]
                    )
                }
            )
        } else {
            content
        }
    }
}

extension View {
    /// Reports this view's frame so the walkthrough can spotlight it.
    func coachAnchor(_ anchor: CoachAnchor?) -> some View {
        modifier(CoachAnchorModifier(anchor: anchor))
    }

    /// Adds the dimmed, spotlight tour layer on top of this view. Pass
    /// `showsCard: false` when the view draws the instruction card itself.
    func coachOverlay(showsCard: Bool = true) -> some View {
        modifier(CoachOverlayModifier(showsCard: showsCard))
    }
}

// MARK: - Host

private struct CoachOverlayModifier: ViewModifier {
    let showsCard: Bool

    @ObservedObject private var coach = CoachController.shared
    @State private var anchors: [CoachAnchor: CGRect] = [:]
    @State private var arcs: [CoachAnchor: CoachArcSpotlight] = [:]

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(CoachAnchorKey.self) { anchors = $0 }
            .onPreferenceChange(CoachArcKey.self) { arcs = $0 }
            .overlay {
                if coach.step != nil {
                    CoachOverlay(
                        controller: coach,
                        anchors: anchors,
                        arcs: arcs,
                        showsCard: showsCard
                    )
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: coach.step)
    }
}

// MARK: - Overlay

private struct CoachOverlay: View {
    @ObservedObject var controller: CoachController
    let anchors: [CoachAnchor: CGRect]
    let arcs: [CoachAnchor: CoachArcSpotlight]
    let showsCard: Bool

    var body: some View {
        GeometryReader { proxy in
            // Anchors are reported in window coordinates. Convert them into
            // this overlay's space so the same code works at the root and
            // inside a sheet.
            let origin = proxy.frame(in: .global).origin
            let size = proxy.size

            if let step = controller.step {
                let spotlights = spotlights(for: step, in: size)
                    .map { local($0, origin: origin) }

                ZStack(alignment: .topLeading) {
                    let shape = CoachDimShape(spotlights: spotlights)
                    shape
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: false))
                        .contentShape(shape)
                        .onTapGesture {}

                    ForEach(Array(spotlights.enumerated()), id: \.offset) { _, spot in
                        outline(for: spot)
                            .allowsHitTesting(false)
                    }

                    if showsCard {
                        card(for: step, size: size, spotlights: spotlights)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    // MARK: Spotlight geometry

    private func spotlights(for step: CoachStep, in size: CGSize) -> [CoachSpotlight] {
        var result: [CoachSpotlight] = []

        for anchor in step.anchors {
            if let arc = arcs[anchor] {
                result.append(.arc(arc))
            } else if let frame = anchors[anchor], frame.width > 1, frame.height > 1 {
                result.append(.rect(frame.insetBy(dx: -4, dy: -4)))
            } else if let fallback = fallbackFrame(for: anchor, in: size) {
                result.append(.rect(fallback))
            }
        }

        return result
    }

    private func local(_ spotlight: CoachSpotlight, origin: CGPoint) -> CoachSpotlight {
        switch spotlight {
        case .rect(let rect):
            return .rect(rect.offsetBy(dx: -origin.x, dy: -origin.y))
        case .arc(var arc):
            arc.center = CGPoint(
                x: arc.center.x - origin.x,
                y: arc.center.y - origin.y
            )
            return .arc(arc)
        }
    }

    /// Toolbar items live in their own hosting view, so their frames are not
    /// always reported. These frames match the real button positions.
    private func fallbackFrame(for anchor: CoachAnchor, in size: CGSize) -> CGRect? {
        switch anchor {
        case .filterButton, .detailSelectButton:
            let top = windowSafeAreaTop
            return CGRect(x: size.width - 60, y: top, width: 44, height: 44)
        case .filterCancelButton:
            return CGRect(x: 12, y: 0, width: 64, height: 44)
        default:
            return nil
        }
    }

    private var windowSafeAreaTop: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets.top ?? 47
    }

    @ViewBuilder
    private func outline(for spotlight: CoachSpotlight) -> some View {
        switch spotlight {
        case .rect(let rect):
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.92), lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .shadow(color: .black.opacity(0.35), radius: 6)
        case .arc(let arc):
            arc.path()
                .stroke(Color.white.opacity(0.92), lineWidth: 2.5)
                .shadow(color: .black.opacity(0.35), radius: 6)
        }
    }

    // MARK: Card

    @ViewBuilder
    private func card(for step: CoachStep, size: CGSize, spotlights: [CoachSpotlight]) -> some View {
        let card = CoachInstructionCard(
            step: step,
            showsContinue: step.showsContinueButton || spotlights.isEmpty,
            onSkip: { controller.finish() },
            onContinue: { controller.advanceToNext() },
            onFinish: { controller.finish() }
        )
        .padding(.horizontal, 20)

        Group {
            switch step.placement {
            case .center, .inline:
                VStack {
                    Spacer(minLength: 0)
                    card
                    Spacer(minLength: 0)
                }

            case .bottom:
                VStack {
                    Spacer(minLength: 0)
                    card
                        .padding(.bottom, 46)
                }

            case .top:
                VStack {
                    card
                        .padding(.top, 58)
                    Spacer(minLength: 0)
                }

            case .aboveTarget:
                VStack {
                    Spacer(minLength: 0)
                    card
                        .padding(.bottom, paddingAboveTarget(spotlights.first, in: size))
                }

            case .belowTarget:
                VStack {
                    card
                    Spacer(minLength: 0)
                }
                .padding(.top, paddingBelowTarget(spotlights.first, in: size))
            }
        }
        // Fill the overlay so the tightly sized card stays centred instead of
        // being pinned to the top-left corner.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paddingAboveTarget(_ spotlight: CoachSpotlight?, in size: CGSize) -> CGFloat {
        guard let spotlight else { return 46 }
        let top = spotlight.bounds.minY
        let padding = size.height - top + 18
        return min(padding, max(46, size.height - 260))
    }

    private func paddingBelowTarget(_ spotlight: CoachSpotlight?, in size: CGSize) -> CGFloat {
        guard let spotlight else { return 46 }
        return min(spotlight.bounds.maxY + 18, size.height - 240)
    }
}

// MARK: - Dim shape

private struct CoachDimShape: Shape {
    var spotlights: [CoachSpotlight]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for spotlight in spotlights {
            switch spotlight {
            case .rect(let hole):
                path = path.subtracting(
                    Path(roundedRect: hole, cornerRadius: 12, style: .continuous)
                )
            case .arc(let arc):
                path = path.subtracting(arc.path())
            }
        }
        return path
    }
}

// MARK: - Instruction card

/// A vertical stack that hugs its content instead of stretching across the
/// screen. The instruction card uses it so the box wraps tightly around the
/// text, and the button inside matches the text width.
private struct HuggingVStack: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let widest = subviews.reduce(CGFloat.zero) { widest, subview in
            max(widest, subview.sizeThatFits(.unspecified).width)
        }
        let limit = min(maxWidth, proposal.width ?? maxWidth)
        let width = min(max(widest, 1), limit)

        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            if index > 0 { height += spacing }
            height += subview
                .sizeThatFits(ProposedViewSize(width: width, height: nil))
                .height
        }

        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index > 0 { y += spacing }

            let size = subview.sizeThatFits(
                ProposedViewSize(width: bounds.width, height: nil)
            )
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: size.height)
            )
            y += size.height
        }
    }
}

/// The instruction card. It is drawn by the overlay for most steps, and
/// inline by the filter sheet so it always sits above the filter list.
struct CoachInstructionCard: View {
    let step: CoachStep
    let showsContinue: Bool
    let onSkip: () -> Void
    let onContinue: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HuggingVStack(spacing: 0, maxWidth: 300) {
            progressBar

            VStack(alignment: .leading, spacing: 10) {
                header
                message

                if step == .finish {
                    primaryButton("Go to Home", action: onFinish)
                        .padding(.top, 2)
                } else if showsContinue {
                    primaryButton("Continue", action: onContinue)
                        .padding(.top, 2)
                } else {
                    hint
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 1)
        )
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.hairline)

                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: max(4, proxy.size.width * step.progress))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: step.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(AppTheme.accent)
                )

            Text(step.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if step != .finish {
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityLabel("Skip the tour")
            }
        }
    }

    private var message: some View {
        Text(step.message)
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(AppTheme.secondaryText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Tap the highlighted area to continue")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(AppTheme.tertiaryText)
        .padding(.top, 1)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                )
        }
        .buttonStyle(.plain)
    }
}
