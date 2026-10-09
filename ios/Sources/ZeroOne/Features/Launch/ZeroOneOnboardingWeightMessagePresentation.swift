import Foundation

/// Display projection only. Retained imported metadata cannot turn a failure,
/// stale reading or unknown diagnostic into a successful weight import.
enum ZeroOneOnboardingWeightMessagePresentation {
    static func message(
        _ actualMessage: String,
        importedBodyWeight: ImportedBodyWeight?,
        localization: AppLocalization
    ) -> String {
        guard let reading = importedBodyWeight else {
            return localization.string(actualMessage)
        }
        // Match the existing importer's exact success output before substituting.
        // It uses the device's Foundation locale. If that locale changes while
        // the message is visible, the conservative fallback keeps the source text.
        let sourceDate = reading.recordedAt.formatted(date: .abbreviated, time: .omitted)
        let sourceSuccess = "Filled from your Apple Health reading on \(sourceDate). Review it before saving."
        guard actualMessage == sourceSuccess else {
            return localization.string(actualMessage)
        }
        let displayDate = reading.recordedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(localization.locale)
        )
        return localization.format(
            "Filled from your Apple Health reading on %1$@. Review it before saving.",
            .text(displayDate)
        )
    }
}
