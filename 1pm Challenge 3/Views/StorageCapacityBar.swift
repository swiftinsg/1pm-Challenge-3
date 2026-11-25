//
//  StorageCapacityBar.swift
//  1pm Challenge 3
//

import SwiftUI

/// A thin horizontal bar under the donut. The filled part is used space and
/// the remaining grey track is the space still available on the device. Both
/// values come from the real volume capacity reported by iOS.
struct StorageCapacityBar: View {
    let used: Int64?
    let total: Int64?

    private var usedFraction: Double {
        guard let used, let total, total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }

    private var availableText: String {
        guard let used, let total else { return "—" }
        return StorageFormatter.capacity(max(0, total - used))
    }

    private var usedText: String {
        guard let used else { return "—" }
        return StorageFormatter.capacity(used) + " used"
    }

    /// Both numbers the user needs to make sense of the chart: the capacity
    /// printed on the box and the smaller, formatted space iOS actually gives
    /// apps. A 128 GB iPhone therefore reads "iPhone 128 GB · 114.6 GB usable".
    private var deviceText: String? {
        guard let total else { return nil }
        let usable = StorageFormatter.capacity(total)
        guard let advertised = DeviceStorage.advertisedCapacity(forUsable: total) else {
            return "\(usable) usable"
        }
        return "iPhone \(StorageFormatter.capacity(advertised)) · \(usable) usable"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)

                Spacer(minLength: 8)

                Text(availableText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppTheme.dynamic(light: 0xE3E3E8, dark: 0x2A2A2E))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.86), Color.primary.opacity(0.5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * usedFraction)
                }
            }
            .frame(height: 9)

            if let deviceText {
                Text(deviceText)
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .animation(.easeInOut(duration: 0.9), value: usedFraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage availability")
        .accessibilityValue("\(usedText), \(availableText) available. \(deviceText ?? "")")
    }
}
