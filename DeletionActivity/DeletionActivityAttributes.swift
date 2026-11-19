//
//  DeletionActivityAttributes.swift
//  DeletionActivity
//

import ActivityKit
import Foundation

/// Mirrors the app's attributes type so ActivityKit can render the same
/// activity in the widget extension.
struct DeletionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var completed: Int
        var total: Int
        var bytes: Int64
        var isFinished: Bool
    }

    var startedAt: Date
}
