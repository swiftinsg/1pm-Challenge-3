//
//  DeletionActivityAttributes.swift
//  1pm Challenge 3
//

import ActivityKit
import Foundation

/// Shared with the widget extension so the Dynamic Island and the in-app
/// banner describe the same bulk deletion.
struct DeletionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var completed: Int
        var total: Int
        var bytes: Int64
        var isFinished: Bool
    }

    var startedAt: Date
}
