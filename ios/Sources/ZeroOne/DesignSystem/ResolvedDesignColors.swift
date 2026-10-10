import SwiftUI
import UIKit

extension ZOColor {
    /// CSS color-mix(in srgb, first weight%, second), with opaque token inputs.
    /// Keep fractional channels: rounding to an 8-bit hex changes the reference colour.
    static func mixedSRGB(_ first: UInt32, weight: Double, with second: UInt32) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let a = Double((first >> shift) & 0xFF) / 255
            let b = Double((second >> shift) & 0xFF) / 255
            return a * weight + b * (1 - weight)
        }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }

    /// Resolve generated roles against the app or widget's chosen appearance,
    /// which may differ from the host's trait collection.
    static func resolved(_ color: Color, in scheme: ColorScheme) -> Color {
        Color(uiColor: UIColor(color).resolvedColor(with:
            UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        ))
    }
}
