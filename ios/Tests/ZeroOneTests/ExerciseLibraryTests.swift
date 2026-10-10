import XCTest
@testable import ZeroOne

final class ExerciseLibraryTests: XCTestCase {
    func testSeedLibraryHasStableUniqueExercises() {
        XCTAssertEqual(ExerciseLibrary.all.count, 28)
        XCTAssertEqual(Set(ExerciseLibrary.all.map(\.id)).count, ExerciseLibrary.all.count)
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.shortCoachingCue.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.equipment.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.equipmentIdentifiers.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.primaryMuscleNames.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.painGuardrail.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.alternativeNames.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.evidenceReferenceKeys.isEmpty })
        XCTAssertTrue(ExerciseLibrary.all.allSatisfy { !$0.trainingGoalTags.isEmpty })
    }

    func testResolvedAlternativesAlwaysPointBackIntoTheCatalogue() {
        for exercise in ExerciseLibrary.all {
            for alternativeID in exercise.resolvedAlternativeIDs {
                XCTAssertNotNil(ExerciseLibrary.exercise(id: alternativeID))
            }
        }

        XCTAssertEqual(
            ExerciseLibrary.exercise(id: ExerciseIDs.gobletSquat)?.resolvedAlternativeIDs.first,
            ExerciseIDs.legPress
        )
    }

    func testVisualLevelsFallBackToAvailableArtwork() throws {
        let benchPress = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellBenchPress))

        XCTAssertEqual(benchPress.imageName(for: .hero), "ExerciseDumbbellBenchPress01")
        XCTAssertEqual(benchPress.imageName(for: .card), "ExerciseDumbbellBenchPress01")
        XCTAssertEqual(benchPress.imageName(for: .thumbnail), "ExerciseDumbbellBenchPress01")
    }

    func testVisualCatalogueCoversEveryCurrentExerciseExactlyOnce() {
        XCTAssertEqual(ExerciseVisualCatalog.all.count, 28)
        XCTAssertEqual(
            Set(ExerciseVisualCatalog.all.map(\.id)),
            Set(ExerciseLibrary.all.map(\.id))
        )
    }

    func testVisualCatalogueResolvesApprovedAssetsAndHonestFallbacks() throws {
        let benchPress = try XCTUnwrap(
            ExerciseVisualCatalog.entry(for: ExerciseIDs.barbellBenchPress)
        )
        let gobletSquat = try XCTUnwrap(
            ExerciseVisualCatalog.entry(for: ExerciseIDs.gobletSquat)
        )

        XCTAssertEqual(benchPress.status, .prototypeCandidate)
        XCTAssertEqual(benchPress.assets.resolvedName(for: .card), "ExerciseBarbellBenchPress01")
        XCTAssertNil(benchPress.fallbackLabel)

        XCTAssertEqual(gobletSquat.status, .prototypeCandidate)
        XCTAssertEqual(gobletSquat.assets.resolvedName(for: .hero), "ExerciseGobletSquat01")
        XCTAssertNil(gobletSquat.fallbackLabel)
    }

    func testStarterExerciseVisualPackResolvesMostUsedProgrammeExercises() {
        let expectedAssets: [ExerciseID: String] = [
            ExerciseIDs.barbellBenchPress: "ExerciseBarbellBenchPress01",
            ExerciseIDs.gobletSquat: "ExerciseGobletSquat01",
            ExerciseIDs.dumbbellBenchPress: "ExerciseDumbbellBenchPress01",
            ExerciseIDs.lyingLegCurl: "LyingLegCurlArtwork",
            ExerciseIDs.seatedCableRow: "SeatedCableRowArtwork",
            ExerciseIDs.romanianDeadlift: "RomanianDeadliftArtwork",
            ExerciseIDs.legPress: "LegPressArtwork",
            ExerciseIDs.latPulldown: "LatPulldownArtwork"
        ]

        for (exerciseID, assetName) in expectedAssets {
            let entry = ExerciseVisualCatalog.entry(for: exerciseID)
            let candidateIDs: Set<ExerciseID> = [
                ExerciseIDs.barbellBenchPress,
                ExerciseIDs.gobletSquat,
                ExerciseIDs.dumbbellBenchPress
            ]
            XCTAssertEqual(entry?.status, candidateIDs.contains(exerciseID) ? .prototypeCandidate : .approved)
            XCTAssertEqual(entry?.assets.resolvedName(for: .hero), assetName)
            XCTAssertEqual(entry?.assets.resolvedName(for: .card), assetName)
            XCTAssertEqual(entry?.assets.resolvedName(for: .thumbnail), assetName)
        }
    }

    func testArmProgrammeVisualsArePresentButNotFounderApproved() {
        let expected: [ExerciseID: String] = [
            ExerciseIDs.dumbbellCurl: "ExerciseDumbbellCurl01",
            ExerciseIDs.dumbbellHammerCurl: "ExerciseDumbbellHammerCurl01",
            ExerciseIDs.dumbbellInclineCurl: "ExerciseDumbbellInclineCurl01",
            ExerciseIDs.dumbbellOverheadTricepsExtension: "ExerciseDumbbellOverheadTricepsExtension01",
            ExerciseIDs.cableTricepsPressdown: "ExerciseCableRopePushdown01"
        ]

        for (exerciseID, assetName) in expected {
            let entry = ExerciseVisualCatalog.entry(for: exerciseID)
            XCTAssertEqual(entry?.status, .prototypeCandidate)
            XCTAssertEqual(entry?.assets.resolvedName(for: .hero), assetName)
        }
    }

    func testGuidanceMotionConfigurationCoversExactlyTheSixApprovedVisuals() {
        let expectedIDs: Set<ExerciseID> = [
            ExerciseIDs.dumbbellBenchPress,
            ExerciseIDs.lyingLegCurl,
            ExerciseIDs.seatedCableRow,
            ExerciseIDs.romanianDeadlift,
            ExerciseIDs.legPress,
            ExerciseIDs.latPulldown
        ]

        XCTAssertEqual(ExerciseGuidanceMotionCatalog.supportedExerciseIDs, expectedIDs)
        for exerciseID in expectedIDs {
            let configuration = ExerciseGuidanceMotionCatalog.configuration(for: exerciseID)
            XCTAssertEqual(configuration?.exerciseID, exerciseID)
            XCTAssertEqual(configuration?.point(at: 0), configuration?.start)
            XCTAssertEqual(configuration?.point(at: 1), configuration?.end)
        }
    }

    func testGuidanceMotionUsesHonestFallbackForUnrecognizedExercise() {
        XCTAssertNil(ExerciseGuidanceMotionCatalog.configuration(for: ExerciseIDs.barbellBenchPress))
        XCTAssertNil(ExerciseGuidanceMotionCatalog.configuration(for: ExerciseIDs.gobletSquat))
    }

    func testGuidanceMotionReduceMotionStartsInFinalStaticState() {
        XCTAssertEqual(ExerciseGuidanceMotionState.entryState(reduceMotion: true), .settled)
        XCTAssertEqual(ExerciseGuidanceMotionState.entryState(reduceMotion: false), .initial)
    }

    func testArtworkAvailabilityIsSemanticAndLevelAware() {
        let finishedArtwork = ExerciseArtwork(
            exerciseID: ExerciseIDs.dumbbellBenchPress,
            exerciseName: "Dumbbell Bench Press",
            level: .card
        )
        let unavailableArtwork = ExerciseArtwork(
            exerciseID: ExerciseIDs.chestSupportedRow,
            exerciseName: "Chest Supported Dumbbell Row",
            level: .card
        )

        XCTAssertTrue(finishedArtwork.isAvailable)
        XCTAssertFalse(unavailableArtwork.isAvailable)
        XCTAssertNil(finishedArtwork.fallbackLabel)
        XCTAssertEqual(unavailableArtwork.fallbackLabel, "VISUAL PENDING")
    }

    func testLegacyExercisePlanNamesResolveToStableIDs() {
        let exercise = ExercisePlan(
            name: "Barbell Bench Press",
            targetLoad: Load(80),
            targetReps: RepRange(6, 8),
            plannedSetCount: 3,
            restSeconds: 120,
            previousPerformance: []
        )

        XCTAssertEqual(exercise.exerciseID, ExerciseIDs.barbellBenchPress)
    }

    func testBundledSeedSchemaAndReferencesValidate() throws {
        let seed = try TrainingSeedLoader().load()

        XCTAssertEqual(seed.schemaVersion, "0.1.0")
        XCTAssertEqual(seed.exercises.count, 28)
        XCTAssertEqual(seed.programmeTemplates.count, 5)
        XCTAssertEqual(seed.evidenceRecords.count, 6)
        XCTAssertNoThrow(try TrainingSeedLoader().validate(seed))
    }
}
