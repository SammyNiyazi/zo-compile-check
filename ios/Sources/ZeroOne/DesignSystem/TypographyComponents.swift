import SwiftUI

/// Explicit icon sizing keeps SF Symbols independent of the variable text face.
struct ZOIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZOSpace.s) {
            configuration.icon
                .font(.system(size: ZOIcon.row, weight: .medium))
                .imageScale(.medium)
                .frame(width: ZOIcon.row, height: ZOIcon.row)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
