import Foundation

enum ExerciseVisualApprovalStatus: String, Codable, Sendable {
    case approved
    case prototypeCandidate
    case pending
}

struct ExerciseVisualAssets: Equatable, Codable, Sendable {
    let hero: String?
    let card: String?
    let thumbnail: String?

    static let pending = ExerciseVisualAssets(hero: nil, card: nil, thumbnail: nil)

    func resolvedName(for level: ExerciseVisualLevel) -> String? {
        switch level {
        case .hero:
            hero ?? card ?? thumbnail
        case .card:
            card ?? hero ?? thumbnail
        case .thumbnail:
            thumbnail ?? card ?? hero
        }
    }
}

struct ExerciseVisualCatalogEntry: Identifiable, Equatable, Sendable {
    static let pendingLabel = "VISUAL PENDING"

    let id: ExerciseID
    let status: ExerciseVisualApprovalStatus
    let assets: ExerciseVisualAssets

    var fallbackLabel: String? {
        status == .pending ? Self.pendingLabel : nil
    }

    static func approved(
        _ id: ExerciseID,
        hero: String? = nil,
        card: String? = nil,
        thumbnail: String? = nil
    ) -> ExerciseVisualCatalogEntry {
        ExerciseVisualCatalogEntry(
            id: id,
            status: .approved,
            assets: ExerciseVisualAssets(hero: hero, card: card, thumbnail: thumbnail)
        )
    }

    static func pending(_ id: ExerciseID) -> ExerciseVisualCatalogEntry {
        ExerciseVisualCatalogEntry(id: id, status: .pending, assets: .pending)
    }

    static func prototypeCandidate(_ id: ExerciseID, hero: String) -> ExerciseVisualCatalogEntry {
        ExerciseVisualCatalogEntry(
            id: id,
            status: .prototypeCandidate,
            assets: ExerciseVisualAssets(hero: hero, card: nil, thumbnail: nil)
        )
    }
}

enum ExerciseVisualCatalog {
    static let all: [ExerciseVisualCatalogEntry] = [
        .pending(ExerciseIDs.barbellBackSquat),
        .prototypeCandidate(ExerciseIDs.gobletSquat, hero: "ExerciseGobletSquat01"),
        .approved(ExerciseIDs.legPress, hero: "LegPressArtwork"),
        .approved(ExerciseIDs.romanianDeadlift, hero: "RomanianDeadliftArtwork"),
        .approved(ExerciseIDs.lyingLegCurl, hero: "LyingLegCurlArtwork"),
        .pending(ExerciseIDs.legExtension),
        .pending(ExerciseIDs.standingCalfRaise),
        .prototypeCandidate(ExerciseIDs.barbellBenchPress, hero: "ExerciseBarbellBenchPress01"),
        .prototypeCandidate(ExerciseIDs.dumbbellBenchPress, hero: "ExerciseDumbbellBenchPress01"),
        .pending(ExerciseIDs.inclineDumbbellPress),
        .approved(ExerciseIDs.latPulldown, hero: "LatPulldownArtwork"),
        .approved(ExerciseIDs.seatedCableRow, hero: "SeatedCableRowArtwork"),
        .pending(ExerciseIDs.chestSupportedRow),
        .pending(ExerciseIDs.facePull),
        .pending(ExerciseIDs.overheadPress),
        .pending(ExerciseIDs.cableLateralRaise),
        .prototypeCandidate(ExerciseIDs.dumbbellCurl, hero: "ExerciseDumbbellCurl01"),
        .prototypeCandidate(ExerciseIDs.dumbbellHammerCurl, hero: "ExerciseDumbbellHammerCurl01"),
        .prototypeCandidate(ExerciseIDs.dumbbellInclineCurl, hero: "ExerciseDumbbellInclineCurl01"),
        .prototypeCandidate(ExerciseIDs.dumbbellOverheadTricepsExtension, hero: "ExerciseDumbbellOverheadTricepsExtension01"),
        .prototypeCandidate(ExerciseIDs.cableTricepsPressdown, hero: "ExerciseCableRopePushdown01"),
        .pending(ExerciseIDs.plank),
        .pending(ExerciseIDs.deadBug),
        .pending(ExerciseIDs.splitSquat),
        .pending(ExerciseIDs.hipThrust),
        .pending(ExerciseIDs.assistedPullUp),
        .pending(ExerciseIDs.pushUp),
        .pending(ExerciseIDs.inclineWalk)
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func entry(for exerciseID: ExerciseID) -> ExerciseVisualCatalogEntry? {
        byID[exerciseID]
    }
}
