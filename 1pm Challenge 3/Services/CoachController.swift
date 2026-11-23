//
//  CoachController.swift
//  1pm Challenge 3
//

import Combine
import Foundation

/// Where the instruction card sits relative to the spotlight.
enum CoachCardPlacement {
    case center
    case bottom
    case top
    case aboveTarget
    case belowTarget
    /// The card is drawn inline by the hosting view (used by the filter
    /// sheet) so it can never cover the controls being taught.
    case inline
}

/// The single, interactive walkthrough shown on the first launch.
///
/// Every step waits for the real control to be tapped, so the user learns the
/// app by using it. The overlay blocks everything that is not highlighted.
enum CoachStep: String, CaseIterable {
    case permissions
    case scan
    case homeChart
    case filterButton
    case filterOutdated
    case filterThreshold
    case filterCancel
    case categoryLegend
    case selectButton
    case selectItem
    case deleteButton
    case finish
}

extension CoachStep {
    var title: String {
        switch self {
        case .permissions:
            return "Enable scanning"
        case .scan:
            return "Start your first scan"
        case .homeChart:
            return "Explore your storage"
        case .filterButton:
            return "Filter your photos"
        case .filterOutdated:
            return "Choose outdated photos"
        case .filterThreshold:
            return "Set the age limit"
        case .filterCancel:
            return "Nothing filtered yet"
        case .categoryLegend:
            return "Open a category"
        case .selectButton:
            return "Select photos to remove"
        case .selectItem:
            return "Choose a photo"
        case .deleteButton:
            return "Delete and free space"
        case .finish:
            return "Tour complete"
        }
    }

    var message: String {
        switch self {
        case .permissions:
            return "Tap Allow on both prompts. Spacer reads only what is already on this iPhone — nothing is uploaded, and iCloud items are never downloaded."
        case .scan:
            return "Tap SCAN to measure the photos, videos and files already on this iPhone. Large libraries can take a while."
        case .homeChart:
            return "Tap the Photos slice on the ring or the Photos key above it to open every photo category."
        case .filterButton:
            return "Tap the filter button to choose exactly which photos to show."
        case .filterOutdated:
            return "Select Outdated Photos to surface photos you may no longer need."
        case .filterThreshold:
            return "Tap the age menu to try different thresholds. You decide what counts as outdated — change it as often as you like, then tap Continue."
        case .filterCancel:
            return "Tap Cancel to keep all photos for now. You can return to filters at any time."
        case .categoryLegend:
            return "Tap the Large slice on the ring or the Large key to see every photo in that category."
        case .selectButton:
            return "Tap Select to start choosing photos."
        case .selectItem:
            return "Tap the circle beside a photo to add it to your selection."
        case .deleteButton:
            return "Tap Delete to remove the selected photos. They stay in Recently Deleted for 30 days. Nothing is deleted during this tour."
        case .finish:
            return "You’re ready. Start with the categories that hold the most space and clean up at your own pace."
        }
    }

    var symbol: String {
        switch self {
        case .permissions:
            return "checkmark.shield.fill"
        case .scan:
            return "sparkles"
        case .homeChart:
            return "chart.pie.fill"
        case .filterButton:
            return "line.3.horizontal.decrease"
        case .filterOutdated:
            return "clock.arrow.circlepath"
        case .filterThreshold:
            return "calendar.badge.clock"
        case .filterCancel:
            return "arrow.uturn.backward"
        case .categoryLegend:
            return "photo.on.rectangle.angled"
        case .selectButton:
            return "checkmark.circle"
        case .selectItem:
            return "checkmark.circle.fill"
        case .deleteButton:
            return "trash.fill"
        case .finish:
            return "checkmark.seal.fill"
        }
    }

    var anchors: [CoachAnchor] {
        switch self {
        case .permissions:
            return [.permissionStack]
        case .scan:
            return [.scanButton]
        case .homeChart:
            return [.homePhotosLegend, .homePhotosSegment]
        case .filterButton:
            return [.filterButton]
        case .filterOutdated:
            return [.coachCard, .filterOutdatedRow]
        case .filterThreshold:
            return [.coachCard, .filterThresholdRow]
        case .filterCancel:
            return [.coachCard, .filterCancelButton]
        case .categoryLegend:
            return [.overviewLargeLegend, .overviewLargeSegment]
        case .selectButton:
            return [.detailSelectButton]
        case .selectItem:
            return [.detailFirstSelect]
        case .deleteButton:
            return [.detailDeleteButton]
        case .finish:
            return []
        }
    }

    var placement: CoachCardPlacement {
        switch self {
        case .permissions, .homeChart, .filterButton, .categoryLegend,
             .selectButton:
            return .bottom
        case .scan, .deleteButton:
            return .aboveTarget
        case .selectItem:
            return .belowTarget
        case .filterOutdated, .filterThreshold, .filterCancel:
            return .inline
        case .finish:
            return .center
        }
    }

    /// The filter sheet draws the card itself, above the filter list, so the
    /// instructions never sit on top of the controls.
    var showsInlineCard: Bool {
        placement == .inline
    }

    /// A step that lets the user experiment keeps an explicit Continue button.
    var showsContinueButton: Bool {
        self == .filterThreshold
    }

    /// Progress through the tour, used for the thin bar on the card.
    var progress: Double {
        guard let index = Self.allCases.firstIndex(of: self) else { return 0 }
        return Double(index + 1) / Double(Self.allCases.count)
    }

    var next: CoachStep? {
        switch self {
        case .permissions: return .scan
        case .scan: return .homeChart
        case .homeChart: return .filterButton
        case .filterButton: return .filterOutdated
        case .filterOutdated: return .filterThreshold
        case .filterThreshold: return .filterCancel
        case .filterCancel: return .categoryLegend
        case .categoryLegend: return .selectButton
        case .selectButton: return .selectItem
        case .selectItem: return .deleteButton
        case .deleteButton: return .finish
        case .finish: return nil
        }
    }
}

/// Owns the walkthrough state. Views advance it when the user performs the
/// highlighted action, so the tour always follows real navigation.
@MainActor
final class CoachController: ObservableObject {
    static let shared = CoachController()

    @Published private(set) var step: CoachStep?
    @Published private(set) var isRunning = false
    /// Incremented once when the tour finishes or is skipped, so the root
    /// view can record completion and return to Home.
    @Published private(set) var completionToken = 0

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        step = .permissions
    }

    /// Used when a returning user already has a completed scan.
    func startAtHome() {
        guard !isRunning else { return }
        isRunning = true
        step = .homeChart
    }

    func advance(from current: CoachStep, to next: CoachStep?) {
        guard step == current else { return }
        step = next
    }

    func advanceToNext() {
        guard let step else { return }
        self.step = step.next
    }

    /// Hides the overlay while the scan runs; the tour resumes on Home.
    func beginScanning() {
        guard step == .scan else { return }
        step = nil
    }

    func resumeAfterScan() {
        guard isRunning, step == nil else { return }
        step = .homeChart
    }

    func finish() {
        guard isRunning else { return }
        isRunning = false
        step = nil
        completionToken += 1
    }
}
