import CoreText
import Foundation

enum ZeroOneFontRegistrar {
    private static let fontNames = [
        "InstrumentSans-Regular",
        "InstrumentSans-Medium",
        "InstrumentSans-SemiBold",
        "InstrumentSans-Bold"
    ]

    static func registerBundledFonts(bundle: Bundle = .main) {
        for fontName in fontNames {
            guard let url = bundle.url(forResource: fontName, withExtension: "ttf") else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
