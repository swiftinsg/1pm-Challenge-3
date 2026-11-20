//
//  DeletionActivityController.swift
//  1pm Challenge 3
//

import ActivityKit
import Foundation

/// One in-flight bulk deletion, used by the in-app popup and the Live Activity.
struct DeletionProgress: Equatable {
    var completed: Int
    var total: Int
    var bytes: Int64
    var isFinished: Bool
}

/// Starts a single Live Activity for a whole bulk deletion and keeps it in
/// step with the deletion. When Live Activities are unavailable (or the device
/// has no Dynamic Island) the app still shows the same popup on screen.
@MainActor
final class DeletionActivityController {
    static let shared = DeletionActivityController()

    private var activity: Activity<DeletionActivityAttributes>?

    private init() {}

    /// Starts one activity for the entire selection. Calling it again replaces
    /// any previous activity instead of stacking a second one.
    func start(totalItems: Int) {
        endActivityImmediately()

        guard totalItems > 0,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let state = DeletionActivityAttributes.ContentState(
            completed: 0,
            total: totalItems,
            bytes: 0,
            isFinished: false
        )

        do {
            activity = try Activity.request(
                attributes: DeletionActivityAttributes(startedAt: Date()),
                content: ActivityContent(state: state, staleDate: nil)
            )
        } catch {
            // Live Activities can be refused (for example in some managed
            // environments). The in-app banner still reports progress.
            activity = nil
        }
    }

    func update(_ progress: DeletionProgress) {
        guard let activity else { return }
        let state = contentState(for: progress)

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func finish(_ progress: DeletionProgress) {
        guard let activity else { return }
        let state = contentState(for: progress)

        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(4))
            )
        }

        self.activity = nil
    }

    /// Clears activities left behind by a previous launch.
    func endStaleActivities() {
        for activity in Activity<DeletionActivityAttributes>.activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil
    }

    private func endActivityImmediately() {
        if let activity {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil
    }

    private func contentState(
        for progress: DeletionProgress
    ) -> DeletionActivityAttributes.ContentState {
        DeletionActivityAttributes.ContentState(
            completed: progress.completed,
            total: progress.total,
            bytes: progress.bytes,
            isFinished: progress.isFinished
        )
    }
}
