import XCTest
import AVFoundation
import UIKit
@testable import ZeroOne

final class MoveKitExerciseTests: XCTestCase {
    @MainActor
    func testProgrammeLegPressUsesBundledPosterWithoutRemappingWorkoutIdentity() throws {
        let match = try XCTUnwrap(MoveKitExerciseCatalog.programmePoster(for: ExerciseIDs.legPress))
        XCTAssertEqual(match.exercise.id, "machine-leg-press")
        XCTAssertEqual(match.relationship, .variation("Machine leg-press variation"))
        XCTAssertNotNil(match.exercise.bundledPosterImage)
        XCTAssertEqual(MoveKitExerciseCatalog.workoutExerciseID(for: "machine-leg-press"),
                       ExerciseID(rawValue: "MOV-machine-leg-press"))
    }

    @MainActor
    func testSilentPlaybackOnlyRepairsTheDefaultAudioCategory() throws {
        let session = TestWorkoutAudioSession()
        let controller = WorkoutAudioSessionController(session: session)
        try controller.prepareForSilentPlayback()
        XCTAssertEqual(session.category, .ambient)
        XCTAssertEqual(session.categoryChanges, 1)
        XCTAssertTrue(session.activations.isEmpty)
        for category in [AVAudioSession.Category.ambient, .playback, .playAndRecord, .record, .multiRoute] {
            session.category = category
            try controller.prepareForSilentPlayback()
            XCTAssertEqual(session.category, category)
        }
        XCTAssertEqual(session.categoryChanges, 1)
    }

    @MainActor
    func testCaptureRestoresMusicProfileAndIdleStopsDoNothing() throws {
        let session = TestWorkoutAudioSession()
        session.category = .playback
        session.mode = .moviePlayback
        session.routeSharingPolicy = .longFormAudio
        session.categoryOptions = [.mixWithOthers]
        let controller = WorkoutAudioSessionController(session: session)
        try controller.endCapture()
        XCTAssertEqual(session.categoryChanges, 0)
        XCTAssertTrue(session.activations.isEmpty)
        try controller.beginCapture()
        let idleController = WorkoutAudioSessionController(session: session)
        try idleController.endCapture()
        XCTAssertEqual(session.activations, [true], "An idle service cannot release another service's capture")
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
        try controller.prepareForSilentPlayback()
        XCTAssertEqual(session.category, .playAndRecord)
        try controller.endCapture()
        try controller.endCapture()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .moviePlayback)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio)
        XCTAssertEqual(session.categoryOptions, [.mixWithOthers])
        XCTAssertEqual(session.activations, [true, false])
        XCTAssertEqual(session.categoryChanges, 2)
    }

    @MainActor
    func testAudioFailuresDoNotLeaveAnActivatedCaptureOrReplaceAnotherOwner() throws {
        let session = TestWorkoutAudioSession()
        let controller = WorkoutAudioSessionController(session: session)
        session.rejectCategory = true
        XCTAssertThrowsError(try controller.prepareForSilentPlayback())
        XCTAssertThrowsError(try controller.beginCapture())
        try controller.endCapture()
        XCTAssertTrue(session.activations.isEmpty)
        session.rejectCategory = false
        session.rejectActivation = true
        XCTAssertThrowsError(try controller.beginCapture())
        XCTAssertEqual(session.category, .soloAmbient)
        XCTAssertTrue(session.activations.isEmpty)
        session.rejectActivation = false
        try controller.beginCapture()
        session.category = .playback
        try controller.endCapture()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.activations, [true], "Must not deactivate a newer owner")
    }

    @MainActor
    func testFailedRestorationCanBeRetriedWithoutDeactivatingTwice() throws {
        let session = TestWorkoutAudioSession()
        let controller = WorkoutAudioSessionController(session: session)
        try controller.prepareForSilentPlayback()
        try controller.beginCapture()
        session.rejectCategory = true
        XCTAssertThrowsError(try controller.endCapture())
        session.rejectCategory = false
        try controller.endCapture()
        XCTAssertEqual(session.category, .ambient)
        XCTAssertEqual(session.activations, [true, false])
    }

    func testCompleteLicensedCatalogIsAvailableWithoutDroppingExercises() {
        XCTAssertEqual(MoveKitExercise.all.count, 412)
        XCTAssertEqual(Set(MoveKitExercise.all.map(\.id)).count, 412)
        XCTAssertTrue(MoveKitExercise.all.allSatisfy { !$0.name.isEmpty })
    }

    func testEveryLicensedExerciseIsReachableThroughBothFilterRows() {
        let allIDs = Set(MoveKitExercise.all.map(\.id))
        let byMuscle = Set(MoveKitExerciseCatalog.muscleFilters.flatMap { muscle in
            MoveKitExerciseCatalog.filter(query: "", muscle: muscle, equipment: nil).map(\.id)
        })
        let byEquipment = Set(MoveKitExerciseCatalog.equipmentFilters.flatMap { equipment in
            MoveKitExerciseCatalog.filter(query: "", muscle: nil, equipment: equipment).map(\.id)
        })
        XCTAssertEqual(byMuscle, allIDs, "Every exercise needs a visible muscle filter")
        XCTAssertEqual(byEquipment, allIDs, "Every exercise needs a visible equipment filter")
    }

    func testEveryCatalogExerciseCanReceiveAnIndependentWorkoutIdentity() {
        for exercise in MoveKitExercise.all {
            XCTAssertNotNil(MoveKitExerciseCatalog.workoutExerciseID(for: exercise.id), exercise.id)
        }
        XCTAssertEqual(
            MoveKitExerciseCatalog.workoutExerciseID(for: "dumbbell-curl"),
            ExerciseIDs.dumbbellCurl
        )
        XCTAssertEqual(
            MoveKitExerciseCatalog.workoutExerciseID(for: "dumbbell-goblet-squat"),
            ExerciseID(rawValue: "MOV-dumbbell-goblet-squat")
        )
        XCTAssertNil(MoveKitExerciseCatalog.workoutExerciseID(for: "not-in-the-library"))
    }

    func testExerciseVideoAutoplayHonorsSystemAndReduceMotionPreferences() {
        XCTAssertTrue(ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: false, systemAutoplayEnabled: true, userRequestedPlayback: false
        ))
        XCTAssertFalse(ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: false, systemAutoplayEnabled: false, userRequestedPlayback: false
        ))
        XCTAssertFalse(ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: true, systemAutoplayEnabled: true, userRequestedPlayback: false
        ))
        XCTAssertFalse(ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: true, systemAutoplayEnabled: false, userRequestedPlayback: false
        ))
    }

    func testManualPlayRemainsAvailableWhenAutoplayIsDisabled() {
        XCTAssertTrue(ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: false, systemAutoplayEnabled: false, userRequestedPlayback: true
        ))
        XCTAssertTrue(ExerciseVideoPlaybackPolicy.showsVideo(
            reduceMotion: true, systemAutoplayEnabled: false, userRequestedPlayback: true
        ))
    }

    func testExerciseVideoPausesWhileCoveredWithoutLosingManualPlaybackChoice() {
        let active = ExerciseVideoPlaybackPolicy.shouldPlay(
            reduceMotion: true, systemAutoplayEnabled: false, userRequestedPlayback: true,
            isPlaying: true, didFail: false, sceneActive: true, isVisible: true, playbackAllowed: true
        )
        let covered = ExerciseVideoPlaybackPolicy.shouldPlay(
            reduceMotion: true, systemAutoplayEnabled: false, userRequestedPlayback: true,
            isPlaying: true, didFail: false, sceneActive: true, isVisible: true, playbackAllowed: false
        )
        XCTAssertTrue(active)
        XCTAssertFalse(covered)
        XCTAssertFalse(ExerciseVideoPlaybackPolicy.shouldPlay(
            reduceMotion: false, systemAutoplayEnabled: true, userRequestedPlayback: false,
            isPlaying: true, didFail: false, sceneActive: false, isVisible: true, playbackAllowed: true
        ))
    }

    func testRetainedHiddenVideoCannotResumeFromForegroundOrPreferenceChanges() {
        for reduceMotion in [false, true] {
            for autoplay in [false, true] {
                for manualPlay in [false, true] {
                    XCTAssertFalse(ExerciseVideoPlaybackPolicy.shouldPlay(
                        reduceMotion: reduceMotion, systemAutoplayEnabled: autoplay,
                        userRequestedPlayback: manualPlay, isPlaying: true, didFail: false,
                        sceneActive: true, isVisible: false, playbackAllowed: true
                    ))
                }
            }
        }
        // Returning to the screen can resume a previously explicit play choice,
        // but never overrides a user pause, host cover, background state or failure.
        XCTAssertTrue(ExerciseVideoPlaybackPolicy.shouldPlay(
            reduceMotion: true, systemAutoplayEnabled: false, userRequestedPlayback: true,
            isPlaying: true, didFail: false, sceneActive: true, isVisible: true, playbackAllowed: true
        ))
        for state in [(false, false, true, true), (true, true, true, true),
                      (true, false, false, true), (true, false, true, false)] {
            XCTAssertFalse(ExerciseVideoPlaybackPolicy.shouldPlay(
                reduceMotion: true, systemAutoplayEnabled: false, userRequestedPlayback: true,
                isPlaying: state.0, didFail: state.1, sceneActive: state.2,
                isVisible: true, playbackAllowed: state.3
            ))
        }
    }

    func testSubstitutionChoicesRequireAuthoredAlternativeAndExactBundledDemo() throws {
        let curl = try XCTUnwrap(ExerciseLibrary.exercise(id: ExerciseIDs.dumbbellHammerCurl))
        let plan = ExercisePlan(
            exerciseID: curl.id, name: curl.name, targetLoad: Load(12),
            targetReps: RepRange(8, 12), plannedSetCount: 2, restSeconds: 90,
            previousPerformance: [],
            alternativeExerciseIDs: [ExerciseIDs.dumbbellCurl, ExerciseID(rawValue: "EX-FACE-PULL")]
        )

        XCTAssertEqual(MoveKitExerciseCatalog.substitutes(for: plan).map(\.id), [ExerciseIDs.dumbbellCurl])
    }

    func testExerciseLibrarySearchUsesAllWordsAcrossNameMuscleAndEquipment() {
        let results = MoveKitExerciseCatalog.search("dumbbell biceps")
        XCTAssertTrue(results.contains(where: { $0.id == "dumbbell-curl" }))
        XCTAssertFalse(results.contains(where: { $0.id == "barbell-bench-press" }))
        XCTAssertEqual(MoveKitExerciseCatalog.search("  ").count, MoveKitExercise.all.count)
        XCTAssertTrue(MoveKitExerciseCatalog.search("exercise-that-is-not-bundled").isEmpty)
    }

    func testLargeLibrarySearchKeepsAliasesAndRanksExactNamesFirst() {
        XCTAssertEqual(MoveKitExerciseCatalog.search("dumbbell curl").first?.id, "dumbbell-curl")
        XCTAssertTrue(MoveKitExerciseCatalog.search("rdl").contains {
            $0.id == "barbell-romanian-deadlift"
        })
        XCTAssertTrue(MoveKitExerciseCatalog.search("ohp").contains {
            $0.id == "barbell-overhead-press"
        })
        XCTAssertTrue(MoveKitExerciseCatalog.search("pullup").contains {
            $0.id == "wide-grip-pull-up"
        })
        XCTAssertTrue(MoveKitExerciseCatalog.search("abs").contains {
            $0.id == "abdominals-stretch-variation-three"
        })
    }

    func testExerciseLibraryFiltersUseSuppliedMuscleAndEquipmentMetadata() {
        let bicepsWithDumbbells = MoveKitExerciseCatalog.filter(
            query: "",
            muscle: "Biceps",
            equipment: "Dumbbell"
        )
        XCTAssertTrue(bicepsWithDumbbells.contains(where: { $0.id == "dumbbell-curl" }))
        XCTAssertFalse(bicepsWithDumbbells.contains(where: { $0.id == "barbell-bench-press" }))

        let shoulderBand = MoveKitExerciseCatalog.filter(
            query: "face pull",
            muscle: "Shoulders",
            equipment: "Band"
        )
        XCTAssertEqual(shoulderBand.map(\.id), ["band-high-face-pull"])
    }

    func testEveryBundledDemoHasBrowsableMetadata() {
        for exercise in MoveKitExercise.all {
            XCTAssertNotEqual(exercise.equipment, "Not supplied", exercise.id)
            XCTAssertNotEqual(exercise.muscleFocus, "Not supplied", exercise.id)
        }
    }

    func testExactClipUsesExactRelationship() throws {
        let match = try XCTUnwrap(
            MoveKitExerciseCatalog.match(for: ExerciseID(exerciseName: "Barbell Bent Over Row"))
        )

        XCTAssertEqual(match.exercise.id, "barbell-bent-over-row")
        XCTAssertEqual(match.relationship, .exact)
    }

    func testRelatedClipIsClearlyMarkedAsVariation() throws {
        let match = try XCTUnwrap(
            MoveKitExerciseCatalog.match(for: ExerciseID(rawValue: "EX-FACE-PULL"))
        )

        XCTAssertEqual(match.exercise.id, "band-high-face-pull")
        XCTAssertEqual(match.relationship, .variation("Band face-pull variation"))
    }

    func testWorkoutMediaMatchesExactMovementsAndLabelsGobletVariation() throws {
        let dumbbellBench = try XCTUnwrap(
            MoveKitExerciseCatalog.match(for: ExerciseID(rawValue: "EX-DUMBBELL-BENCH-PRESS"))
        )
        XCTAssertEqual(dumbbellBench.exercise.id, "dumbbell-bench-press")
        XCTAssertEqual(dumbbellBench.relationship, .exact)

        let barbellBench = try XCTUnwrap(
            MoveKitExerciseCatalog.match(for: ExerciseID(rawValue: "EX-BARBELL-BENCH-PRESS"))
        )
        XCTAssertEqual(barbellBench.exercise.id, "barbell-bench-press")
        XCTAssertEqual(barbellBench.relationship, .exact)

        let gobletSquat = try XCTUnwrap(
            MoveKitExerciseCatalog.match(for: ExerciseID(rawValue: "EX-GOBLET-SQUAT"))
        )
        XCTAssertEqual(gobletSquat.exercise.id, "dumbbell-goblet-squat")
        XCTAssertEqual(gobletSquat.relationship, .variation("Dumbbell goblet-squat variation"))
    }

    func testLibraryHistoryLinkUsesOnlyExactSeedExerciseIdentity() {
        XCTAssertEqual(
            MoveKitExerciseCatalog.exactSeedExerciseID(for: "dumbbell-curl"),
            ExerciseIDs.dumbbellCurl
        )
        XCTAssertEqual(
            MoveKitExerciseCatalog.exactSeedExerciseID(for: "barbell-bench-press"),
            ExerciseIDs.barbellBenchPress
        )
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "lying-leg-curl"), ExerciseIDs.lyingLegCurl)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "barbell-squat"), ExerciseIDs.barbellBackSquat)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "machine-leg-extension"), ExerciseIDs.legExtension)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "dumbbell-incline-bench-press"), ExerciseIDs.inclineDumbbellPress)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "machine-assisted-pull-up"), ExerciseIDs.assistedPullUp)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "lat-pulldown"), ExerciseIDs.latPulldown)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "chest-supported-dumbbell-row"), ExerciseIDs.chestSupportedRow)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "barbell-hip-thrust"), ExerciseIDs.hipThrust)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "push-up"), ExerciseIDs.pushUp)
        XCTAssertEqual(MoveKitExerciseCatalog.exactSeedExerciseID(for: "incline-treadmill-walk"), ExerciseIDs.inclineWalk)
        XCTAssertNil(MoveKitExerciseCatalog.exactSeedExerciseID(for: "dumbbell-goblet-squat"))
        XCTAssertNil(MoveKitExerciseCatalog.exactSeedExerciseID(for: "cable-rope-pushdown"))
        XCTAssertNil(MoveKitExerciseCatalog.exactSeedExerciseID(for: "barbell-romanian-deadlift"))
        XCTAssertNil(MoveKitExerciseCatalog.exactSeedExerciseID(for: "cable-low-single-arm-lateral-raise"))
        XCTAssertNil(MoveKitExerciseCatalog.exactSeedExerciseID(for: "dumbbell-goblet-split-squat"))
        XCTAssertNil(MoveKitExerciseCatalog.exactSeedExerciseID(for: "not-bundled"))
    }

    func testUnrelatedExerciseDoesNotInventVideoMatch() {
        XCTAssertNil(
            MoveKitExerciseCatalog.match(for: ExerciseIDs.seatedCableRow)
        )
    }

    func testBroaderSeedExercisesKeepEquipmentSpecificClipsAsVariations() throws {
        let rdl = try XCTUnwrap(MoveKitExerciseCatalog.match(for: ExerciseIDs.romanianDeadlift))
        XCTAssertEqual(rdl.exercise.id, "barbell-romanian-deadlift")
        XCTAssertEqual(rdl.relationship, .variation("Barbell Romanian deadlift variation"))

        let lateralRaise = try XCTUnwrap(MoveKitExerciseCatalog.match(for: ExerciseIDs.cableLateralRaise))
        XCTAssertEqual(lateralRaise.exercise.id, "cable-low-single-arm-lateral-raise")
        XCTAssertEqual(lateralRaise.relationship, .variation("Single-arm low-cable variation"))

        let splitSquat = try XCTUnwrap(MoveKitExerciseCatalog.match(for: ExerciseIDs.splitSquat))
        XCTAssertEqual(splitSquat.exercise.id, "dumbbell-goblet-split-squat")
        XCTAssertEqual(splitSquat.relationship, .variation("Goblet-loaded split-squat variation"))
    }

    func testArmProgrammeClipsUseExactMovementsOrExplicitVariation() throws {
        let exactMatches: [String: String] = [
            "EX-DUMBBELL-CURL": "dumbbell-curl",
            "EX-DUMBBELL-HAMMER-CURL": "dumbbell-hammer-curl",
            "EX-DUMBBELL-INCLINE-CURL": "dumbbell-incline-curl",
            "EX-DUMBBELL-OVERHEAD-TRICEPS-EXTENSION": "dumbbell-seated-overhead-tricep-extension"
        ]

        for (exerciseID, clipID) in exactMatches {
            let match = try XCTUnwrap(MoveKitExerciseCatalog.match(for: ExerciseID(rawValue: exerciseID)))
            XCTAssertEqual(match.exercise.id, clipID)
            XCTAssertEqual(match.relationship, .exact)
        }

        let cable = try XCTUnwrap(
            MoveKitExerciseCatalog.match(for: ExerciseID(rawValue: "EX-CABLE-TRICEPS-PRESSDOWN"))
        )
        XCTAssertEqual(cable.exercise.id, "cable-rope-pushdown")
        XCTAssertEqual(cable.relationship, .variation("Rope-handle pressdown variation"))
    }

    func testEveryDemoClipAndPosterIsBundledForOfflinePlayback() {
        for exercise in MoveKitExercise.all {
            XCTAssertNotNil(Bundle.main.url(forResource: exercise.videoResource, withExtension: "mp4"))
            XCTAssertTrue(
                UIImage(named: exercise.posterResource) != nil
                    || Bundle.main.url(forResource: exercise.posterResource, withExtension: "jpg") != nil
            )
        }
    }

    func testNewExactMovementsHaveOfflineDemonstrations() throws {
        let expected: [(ExerciseID, String)] = [
            (ExerciseIDs.barbellBackSquat, "barbell-squat"),
            (ExerciseIDs.legExtension, "machine-leg-extension"),
            (ExerciseIDs.inclineDumbbellPress, "dumbbell-incline-bench-press"),
            (ExerciseIDs.assistedPullUp, "machine-assisted-pull-up"),
            (ExerciseIDs.lyingLegCurl, "lying-leg-curl"),
            (ExerciseIDs.latPulldown, "lat-pulldown"),
            (ExerciseIDs.chestSupportedRow, "chest-supported-dumbbell-row"),
            (ExerciseIDs.hipThrust, "barbell-hip-thrust"),
            (ExerciseIDs.pushUp, "push-up"),
            (ExerciseIDs.inclineWalk, "incline-treadmill-walk")
        ]
        for (exerciseID, videoID) in expected {
            let match = try XCTUnwrap(MoveKitExerciseCatalog.match(for: exerciseID))
            XCTAssertEqual(match.relationship, .exact)
            XCTAssertEqual(match.exercise.id, videoID)
            XCTAssertNotNil(Bundle.main.url(forResource: videoID, withExtension: "mp4"))
            XCTAssertNotNil(Bundle.main.url(forResource: videoID, withExtension: "jpg"))
        }
    }

    func testEveryArmProgrammeExerciseHasAnOfflineVideoAndPoster() throws {
        for programmeID in [WorkoutProgrammeID.arms, .biceps] {
            let programme = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: programmeID))
            for session in programme.sessions {
                for plan in session.exercisePlans {
                    let match = try XCTUnwrap(
                        MoveKitExerciseCatalog.match(for: plan.exerciseID),
                        "Missing video mapping for \(plan.exerciseID.rawValue) in \(programmeID.rawValue)"
                    )
                    XCTAssertNotNil(
                        Bundle.main.url(forResource: match.exercise.videoResource, withExtension: "mp4"),
                        "Missing bundled video for \(match.exercise.id)"
                    )
                    XCTAssertNotNil(
                        UIImage(named: match.exercise.posterResource),
                        "Missing bundled poster for \(match.exercise.id)"
                    )
                }
            }
        }
    }

    @MainActor
    func testFailedPlaybackCanResetAndLoadBundledClip() async throws {
        let playback = InlineExercisePlayback()
        defer { playback.reset() }

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        playback.play(url: missingURL)

        let failureDeadline = Date().addingTimeInterval(5)
        while !playback.didFail && Date() < failureDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(playback.didFail, "A missing video must trigger the poster fallback")
        XCTAssertFalse(playback.isReady)

        playback.reset()
        XCTAssertFalse(playback.didFail, "Manual retry starts from a clean playback state")

        let validURL = try XCTUnwrap(Bundle.main.url(forResource: "dumbbell-curl", withExtension: "mp4"))
        playback.play(url: validURL)

        let readyDeadline = Date().addingTimeInterval(5)
        while !playback.isReady && !playback.didFail && Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(playback.isReady, "A bundled clip should become ready after retry")
        XCTAssertFalse(playback.didFail)

        playback.play(url: validURL, rate: 0.5)
        XCTAssertEqual(playback.player.defaultRate, 0.5)
        playback.pause()
        XCTAssertEqual(playback.player.defaultRate, 0.5, "Pausing must preserve the selected review speed")
        playback.play(url: validURL, rate: 1)
        XCTAssertEqual(playback.player.defaultRate, 1)
    }
}

@MainActor
private final class TestWorkoutAudioSession: WorkoutAudioSession {
    var category: AVAudioSession.Category = .soloAmbient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var routeSharingPolicy: AVAudioSession.RouteSharingPolicy = .default
    var categoryChanges = 0
    var activations: [Bool] = []
    var rejectCategory = false
    var rejectActivation = false

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     policy: AVAudioSession.RouteSharingPolicy,
                     options: AVAudioSession.CategoryOptions) throws {
        if rejectCategory { throw NSError(domain: "AudioTest", code: 1) }
        self.category = category
        self.mode = mode
        routeSharingPolicy = policy
        categoryOptions = options.contains(.duckOthers) ? options.union(.mixWithOthers) : options
        categoryChanges += 1
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active && rejectActivation { throw NSError(domain: "AudioTest", code: 2) }
        activations.append(active)
    }
}
