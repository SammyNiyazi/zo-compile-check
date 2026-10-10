import Foundation

/// Immutable raster and both permanent tokens, retained outside the view. Files
/// and native activity item supply check these same objects without actor/UI reads.
struct PhotoComparisonShareExportPermit: Sendable {
    let reviewedPNG: Data
    let rootLifetime: PhotoComparisonShareLifetime?
    let rootVersion: UUID?
    let localLifetime: PhotoComparisonShareLifetime?
    let ticket: UUID?

    func authorizedData(_ data: Data) throws -> Data {
        guard let rootVersion, let ticket, !reviewedPNG.isEmpty, data == reviewedPNG,
              rootLifetime?.allows(rootVersion) == true,
              localLifetime?.allows(ticket) == true else {
            throw PhotoComparisonShareError.unavailable
        }
        return reviewedPNG
    }
}
