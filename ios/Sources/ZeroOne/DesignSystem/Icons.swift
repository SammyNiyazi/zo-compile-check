import SwiftUI

/// SF Symbols use the generated medium-weight sizes. The custom jogging glyph
/// uses the unchanged final study SVG, preserved as a vector template asset.
struct ZOAppIcon: View {
    let name: String
    let size: CGFloat

    init(_ name: String, size: CGFloat = ZOIcon.row) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if name == "01.jog" {
            Image(name)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .zoIcon(size)
        }
    }
}
