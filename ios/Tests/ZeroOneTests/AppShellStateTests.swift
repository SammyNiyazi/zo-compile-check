import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class AppShellStateTests: XCTestCase {
    func testTimedShareAndHistoryKeepSecondsAndDoNotInventRepRecords() {
        let timed = CompletedSet(load: Load(0), reps: 0, completedAt: .now,
                                 durationSeconds: 42, isPerSide: true)
        let repSet = CompletedSet(load: Load(0), reps: 20, completedAt: .now)
        XCTAssertEqual(SocialShareDraft.setText(timed, visibility: .exact), "42 sec per side")
        XCTAssertEqual(SocialShareDraft.setText(timed, visibility: .repsOnly), "42 sec per side")
        XCTAssertFalse(SocialShareAnalysis.isPersonalRecord(current: [timed], previous: [repSet]))
        XCTAssertNil(SocialShareAnalysis.change(current: [timed], previous: [repSet], visibility: .change))
        let row = WorkoutHistoryPresentation.ExerciseRow(
            id: 0, exerciseID: ExerciseID(rawValue: "front-plank"), name: "Front plank",
            plannedCount: 1, sets: [timed], showsUnit: false
        )
        XCTAssertEqual(row.text(for: timed), "42 sec per side")
        XCTAssertTrue(row.accessibilityLabel.contains("42 sec per side"))
    }
    #if DEBUG
    func testCompletedReviewProgrammePersistsSavedSetsAndCanPreviewShareCard() throws {
        let source = try XCTUnwrap(WorkoutProgrammeLibrary.programme(id: WorkoutProgrammeLibrary.recommendedID)?.makeSession())
        let completed = AppRootView.completedReviewSession(from: source)
        XCTAssertTrue(completed.isComplete)
        XCTAssertEqual(completed.completedSetCount, source.totalPlannedSetCount)
        let suite = "review-history-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsWorkoutHistoryStore(defaults: defaults)
        let history = WorkoutHistoryRepository(store: store)
        try history.record(completed)
        let reloaded = WorkoutHistoryRepository(store: store)
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(entry.completedSetCount, source.totalPlannedSetCount)
        XCTAssertEqual(entry.exercises?.reduce(0) { $0 + $1.completedSets.count }, source.totalPlannedSetCount)
        XCTAssertTrue(SocialShareDraft(workout: entry).canPreview)
    }
    #endif

    func testMultipleGoalsRetainOrderPrimaryAndLegacyProfiles() throws {
        let legacy = Data(#"{"version":1,"onboardingComplete":true,"trainingGoal":"buildStrength"}"#.utf8)
        var profile = try JSONDecoder().decode(ZeroOneUserProfile.self, from: legacy)
        XCTAssertEqual(profile.selectedTrainingGoals, [.buildStrength])
        profile.toggleTrainingGoal(.buildMuscle)
        profile.toggleTrainingGoal(.sportPerformance)
        XCTAssertEqual(profile.selectedTrainingGoals, [.buildStrength, .buildMuscle, .sportPerformance])
        XCTAssertEqual(profile.trainingGoal, .buildStrength)
        XCTAssertTrue(profile.isCompatible)
        let restored = try JSONDecoder().decode(ZeroOneUserProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
        profile.toggleTrainingGoal(.buildStrength)
        XCTAssertEqual(profile.trainingGoal, .buildMuscle)
        profile.toggleTrainingGoal(.notSure)
        XCTAssertEqual(profile.selectedTrainingGoals, [.notSure])
        profile.toggleTrainingGoal(.moveBetter)
        XCTAssertEqual(profile.selectedTrainingGoals, [.moveBetter])
        profile.toggleTrainingGoal(.moveBetter)
        XCTAssertNil(profile.trainingGoal)
        XCTAssertTrue(profile.selectedTrainingGoals.isEmpty)
        XCTAssertTrue(profile.isCompatible)
    }

    func testSocialShareUsesOnlySelectedSavedSetsAndProtectsHiddenLoads() throws {
        let previous = try socialHistoryEntry(load: 60, reps: [8, 7], at: 1_000)
        let current = try socialHistoryEntry(load: 65, reps: [8, 8], at: 2_000)
        var draft = SocialShareDraft(workout: current)

        XCTAssertEqual(draft.selectedSetIDs.count, 2)
        let exact = draft.preview(history: [current, previous])
        XCTAssertEqual(exact.blocks.first?.sets.count, 2)
        XCTAssertTrue(exact.headline.contains("65 kg"))
        XCTAssertTrue(exact.chips.contains("Personal record"))
        XCTAssertTrue(exact.chips.contains("+5 kg vs last time"))

        let removedSetID = try XCTUnwrap(current.exercises?.first?.completedSets.last?.id)
        draft.toggleSet(removedSetID)
        XCTAssertEqual(draft.preview(history: [current, previous]).blocks.first?.sets.count, 1)
        XCTAssertFalse(draft.preview(history: [current, previous]).chips.contains("Personal record"))

        draft.visibility = .repsOnly
        let hidden = draft.preview(history: [current, previous])
        XCTAssertFalse(hidden.headline.contains("kg"))
        XCTAssertFalse(hidden.chips.joined().contains("kg"))
        XCTAssertEqual(
            SocialShareDraft.setText(try XCTUnwrap(hidden.blocks.first?.sets.first), visibility: .repsOnly),
            "8 reps"
        )
        draft.headlineOverride = "Bench 65 kg"
        XCTAssertTrue(draft.warnsAboutTypedLoad)
        draft.headlineOverride = ""
        draft.note = "A good day at 65 kg"
        XCTAssertTrue(draft.warnsAboutTypedLoad)
    }

    func testSocialShareNoHistoryNeverInventsPRAndMixedUnitsDoNotCompare() throws {
        let current = try socialHistoryEntry(load: 65, reps: [8, 8], at: 2_000)
        let alone = SocialShareDraft(workout: current).preview(history: [current])
        XCTAssertTrue(alone.chips.isEmpty)

        let pounds = try socialHistoryEntry(load: 100, reps: [8, 8], unit: .pounds, at: 1_000)
        let withMixedUnits = SocialShareDraft(workout: current).preview(history: [current, pounds])
        XCTAssertFalse(withMixedUnits.chips.contains(where: { $0.contains("vs last time") }))

        let olderBest = try socialHistoryEntry(load: 70, reps: [8, 8], at: 500)
        let recent = try socialHistoryEntry(load: 60, reps: [8, 8], at: 1_000)
        let withOlderBest = SocialShareDraft(workout: current).preview(
            history: [current, recent, olderBest]
        )
        XCTAssertFalse(withOlderBest.chips.contains("Personal record"))
    }

    func testSocialComparisonShowsRepTradeoffAlongsideLoadChange() {
        let previous = CompletedSet(load: Load(60), reps: 10, completedAt: .now)
        let current = CompletedSet(load: Load(65), reps: 8, completedAt: .now)

        XCTAssertEqual(
            SocialShareAnalysis.change(current: [current], previous: [previous], visibility: .change),
            "+5 kg, -2 reps vs last time"
        )
        XCTAssertEqual(
            SocialShareAnalysis.change(current: [current], previous: [previous], visibility: .repsOnly),
            "-2 reps vs last time"
        )
        XCTAssertFalse(SocialShareAnalysis.isPersonalRecord(current: [current], previous: [previous]))
    }

    func testSharePagesPreserveEverySelectedSetAndWholeExercisePRScope() throws {
        let entry = try socialHistoryEntry(load: 65, reps: Array(repeating: 8, count: 8) + [10], at: 2_000)
        let draft = SocialShareDraft(workout: entry)
        let source = draft.preview(history: [entry])
        let preview = SocialSharePreview(
            workoutTitle: source.workoutTitle, completedAt: source.completedAt,
            headline: source.headline, note: "", visibility: .exact,
            chips: ["Personal record"], blocks: source.blocks
        )
        let pages = SocialShareCardPage.make(preview: preview, headlineOverride: "")
        let exported = pages.compactMap(\.block).flatMap(\.sets)
        XCTAssertEqual(exported.map(\.id), source.blocks.flatMap(\.sets).map(\.id))
        XCTAssertTrue(pages.compactMap(\.block).allSatisfy { $0.sets.count <= 8 })
        XCTAssertTrue(pages.filter { $0.block != nil }.allSatisfy { $0.chips.isEmpty })
        XCTAssertTrue(pages.compactMap(\.text).joined().contains("9 selected saved sets"))
        XCTAssertTrue(pages.compactMap(\.text).joined().contains("Personal record"))
    }

    func testLongShareTextContinuesWithoutDroppingWordsOrUnicode() throws {
        let entry = try socialHistoryEntry(load: 65, reps: [8, 8], at: 2_000)
        var draft = SocialShareDraft(workout: entry)
        draft.visibility = .repsOnly
        draft.headlineOverride = "A good session 💪"
        draft.note = String(repeating: "Steady training, голям напредък. ", count: 80)
        let preview = draft.preview(history: [entry])
        let pages = SocialShareCardPage.make(preview: preview, headlineOverride: draft.headlineOverride)
        XCTAssertGreaterThan(pages.filter { $0.text != nil }.count, 1)
        XCTAssertEqual(pages.compactMap(\.text).joined(), draft.headlineOverride + "\n\n" + preview.note)
        XCTAssertFalse(pages.map { $0.accessibilityDescription(visibility: .repsOnly) }.joined().contains("65 kg"))
    }

    func testClaudeCardExportsAt1080By1350InEveryCardColour() throws {
        let entry = try socialHistoryEntry(load: 65, reps: [8, 8, 8, 8], at: 2_000)
        let preview = SocialShareDraft(workout: entry).preview(history: [entry])
        let page = try XCTUnwrap(SocialShareCardPage.make(preview: preview, headlineOverride: "").first)
        for style in SocialShareCardStyle.allCases {
            let renderer = ImageRenderer(content: SocialShareCard(
                page: page, completedAt: entry.completedAt, visibility: .exact, style: style
            ))
            renderer.scale = 3
            let pixels = try XCTUnwrap(renderer.uiImage?.cgImage)
            XCTAssertEqual(pixels.width, 1080)
            XCTAssertEqual(pixels.height, 1350)
        }
    }

    func testPinkExportsEveryPageWithRecordedSetsAndActualPinkCanvas() throws {
        let entry = try socialHistoryEntry(load: 65, reps: Array(repeating: 8, count: 9), at: 2000)
        var draft = SocialShareDraft(workout: entry)
        draft.note = String(repeating: "Saved work 💪. ", count: 80)
        let preview = draft.preview(history: [entry])
        let pages = SocialShareCardPage.make(preview: preview, headlineOverride: "")
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(pages.compactMap(\.block).flatMap(\.sets), preview.blocks.flatMap(\.sets))
        XCTAssertEqual(pages.compactMap(\.text).joined(), preview.note)
        XCTAssertTrue(SocialShareCardStyle.allCases.contains(.pink))
        for page in pages {
            let renderer = ImageRenderer(content: SocialShareCard(page: page,
                completedAt: entry.completedAt, visibility: .exact, style: .pink))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            XCTAssertEqual(image.width, 1080)
            XCTAssertEqual(image.height, 1350)
            // Bottom centre is canvas inside the rounded card, clear of all content.
            let sample = try XCTUnwrap(image.cropping(to: CGRect(x: 540, y: 1335, width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertEqual(Double(pixel[0]), 255, accuracy: 2)
            XCTAssertEqual(Double(pixel[1]), 154, accuracy: 2)
            XCTAssertEqual(Double(pixel[2]), 213, accuracy: 2)
            XCTAssertEqual(pixel[3], 255)
        }
    }

    private func socialHistoryEntry(
        load: Double,
        reps: [Int],
        unit: LoadUnit = .kilograms,
        at time: TimeInterval
    ) throws -> WorkoutHistoryEntry {
        let plan = ExercisePlan(
            exerciseID: ExerciseIDs.barbellBenchPress,
            name: "Barbell Bench Press",
            targetLoad: Load(load, unit: unit),
            targetReps: RepRange(6, 8),
            plannedSetCount: reps.count,
            restSeconds: 0,
            previousPerformance: []
        )
        var session = WorkoutSession(title: "Upper Body Strength", exercises: [WorkoutExercise(plan: plan)])
        for (index, count) in reps.enumerated() {
            _ = try session.completeCurrentSet(
                load: Load(load, unit: unit),
                reps: count,
                at: Date(timeIntervalSince1970: time + Double(index))
            )
        }
        return WorkoutHistoryEntry(session: session)
    }

    func testLockedShellDestinationOrder() {
        XCTAssertEqual(AppTab.allCases, [.today, .workout, .social, .diets])
    }

    func testDemoStateDefaultsEveryDestinationToInitial() {
        let state = ZeroOneDemoState.initial

        for destination in AppTab.allCases {
            XCTAssertEqual(state.state(for: destination), .initial)
        }
    }

    func testInjectedStoreLoadsAndPersistsDestinationState() {
        let store = InMemoryDemoStateStore(
            initial: ZeroOneDemoState(social: .empty, diets: .unavailable)
        )
        let model = ZeroOneDemoStateModel(store: store)

        XCTAssertEqual(model.state(for: .social), .empty)
        XCTAssertEqual(model.state(for: .diets), .unavailable)

        model.set(.initial, for: .social)

        XCTAssertEqual(store.savedState?.social, .initial)
        XCTAssertEqual(model.state(for: .social), .initial)
    }

    func testUserDefaultsStoreRoundTripsWithoutSharedAppState() throws {
        let suiteName = "AppShellStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsZeroOneDemoStateStore(defaults: defaults, key: "state")
        let expected = ZeroOneDemoState(today: .empty, workout: .unavailable, social: .initial, diets: .empty)

        store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testUserProfilePersistsAndRestoresAcrossRepositoryInstances() {
        let store = InMemoryUserProfileStore()
        let first = ZeroOneUserProfileRepository(store: store)

        first.update {
            $0.trainingGoal = .buildStrength
            $0.trainingExperience = .someExperience
            $0.weeklyAvailability = .threeDays
            $0.equipmentAccess = .fullGym
            $0.trainingConstraint = .variableSchedule
        }
        first.completeOnboarding()

        let restored = ZeroOneUserProfileRepository(store: store)
        XCTAssertEqual(restored.profile, first.profile)
        XCTAssertEqual(restored.rootRoute, .appShell)
    }

    func testNotSureSelectionsAreExplicitPersistedSkipStates() {
        let store = InMemoryUserProfileStore()
        let repository = ZeroOneUserProfileRepository(store: store)

        repository.update {
            $0.trainingGoal = .notSure
            $0.trainingExperience = .notSure
            $0.weeklyAvailability = .notSure
            $0.equipmentAccess = .notSure
            $0.trainingConstraint = .notSure
        }
        repository.completeOnboarding()

        XCTAssertEqual(store.savedProfile?.trainingGoal, .notSure)
        XCTAssertEqual(store.savedProfile?.trainingConstraint, .notSure)
        XCTAssertTrue(store.savedProfile?.onboardingComplete == true)
    }

    func testOptionalTrainingConstraintCanRemainUnsetAfterFirstRun() {
        let store = InMemoryUserProfileStore()
        let repository = ZeroOneUserProfileRepository(store: store)

        repository.update {
            $0.trainingGoal = .buildMuscle
            $0.trainingExperience = .someExperience
            $0.weeklyAvailability = .threeDays
            $0.equipmentAccess = .fullGym
        }
        repository.completeOnboarding()

        XCTAssertNil(store.savedProfile?.trainingConstraint)
        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertEqual(ZeroOneUserProfileRepository(store: store).rootRoute, .appShell)
    }

    func testSkippingFirstRunCanReachAppWithoutFabricatedAnswers() {
        let store = InMemoryUserProfileStore()
        let repository = ZeroOneUserProfileRepository(store: store)

        repository.update { $0.onboardingWasSkipped = true }
        repository.completeOnboarding()

        XCTAssertEqual(repository.rootRoute, .appShell)
        XCTAssertNil(store.savedProfile?.trainingGoal)
        XCTAssertNil(store.savedProfile?.trainingExperience)
        XCTAssertNil(store.savedProfile?.weeklyAvailability)
        XCTAssertNil(store.savedProfile?.equipmentAccess)
        XCTAssertEqual(store.savedProfile?.onboardingWasSkipped, true)
    }

    func testProfileSavedBeforeSkipFlagStillDecodes() throws {
        let legacy = Data("""
            {"version":1,"onboardingComplete":true,"trainingGoal":"buildStrength"}
            """.utf8)

        let profile = try JSONDecoder().decode(ZeroOneUserProfile.self, from: legacy)

        XCTAssertNil(profile.onboardingWasSkipped)
        XCTAssertNil(profile.availableEquipment)
        XCTAssertNil(profile.preferredTrainingDays)
        XCTAssertNil(profile.preferredWeightUnit)
        XCTAssertEqual(profile.trainingGoal, .buildStrength)
    }

    func testProfileEditPersistsWithoutResettingCompletion() {
        var completed = ZeroOneUserProfile()
        completed.onboardingComplete = true
        completed.trainingGoal = .buildMuscle
        let store = InMemoryUserProfileStore(initial: completed)
        let repository = ZeroOneUserProfileRepository(store: store)

        repository.update { $0.weeklyAvailability = .fourDays }

        XCTAssertEqual(store.savedProfile?.weeklyAvailability, .fourDays)
        XCTAssertEqual(store.savedProfile?.trainingGoal, .buildMuscle)
        XCTAssertTrue(store.savedProfile?.onboardingComplete == true)
    }

    func testDetailedOnboardingAnswersRoundTripWithoutLosingLegacyAnswers() throws {
        var profile = ZeroOneUserProfile()
        profile.trainingGoal = .sportPerformance
        profile.trainingSport = .volleyball
        profile.trainingExperience = .returning
        profile.availableEquipment = [.dumbbells, .bands]
        profile.equipmentAccess = .notSure
        profile.preferredTrainingDays = [.monday, .wednesday, .friday]
        profile.weeklyAvailability = .threeDays
        profile.preferredSessionMinutes = 45
        profile.preferredWeightUnit = .kilograms
        profile.preferredDistanceUnit = .kilometers

        let decoded = try JSONDecoder().decode(ZeroOneUserProfile.self, from: JSONEncoder().encode(profile))

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.availableEquipment, [.dumbbells, .bands])
        XCTAssertEqual(decoded.preferredTrainingDays, [.monday, .wednesday, .friday])
        XCTAssertEqual(decoded.trainingSport, .volleyball)
    }

    func testSavedFirstWeekPlanRoundTripsWithStableWorkoutReferences() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.none]
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: Set(MoveKitExercise.all.map(\.id))
        ))
        let ids = [UUID(), UUID()]
        profile.savedFirstWeekPlan = ZeroOneSavedFirstWeekPlan(plan: plan, workoutIDs: ids, savedAt: .now)
        let store = InMemoryUserProfileStore()
        let repository = ZeroOneUserProfileRepository(store: store)
        XCTAssertTrue(repository.updateVerified { $0 = profile })

        let restored = ZeroOneUserProfileRepository(store: store)
        XCTAssertEqual(restored.profile.savedFirstWeekPlan?.workoutIDs, ids)
        XCTAssertEqual(try JSONDecoder().decode(ZeroOneUserProfile.self,
                        from: JSONEncoder().encode(restored.profile)), profile)
    }

    func testVerifiedProfileUpdateDoesNotExposeUnpersistedPlan() {
        let repository = ZeroOneUserProfileRepository(store: RejectingUserProfileStore())
        XCTAssertFalse(repository.updateVerified { $0.onboardingComplete = true })
        XCTAssertEqual(repository.rootRoute, .onboarding)
    }

    func testRootRouteRequiresCompletedCompatibleProfile() {
        let selector = ZeroOneRootRouteSelector()
        var profile = ZeroOneUserProfile()

        XCTAssertEqual(selector.route(for: profile), .onboarding)

        profile.onboardingComplete = true
        XCTAssertEqual(selector.route(for: profile), .appShell)

        profile.version = ZeroOneUserProfile.currentVersion + 1
        XCTAssertEqual(selector.route(for: profile), .onboarding)
    }

    func testCorruptProfileDataRecoversToFreshOnboarding() throws {
        let suiteName = "UserProfileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "profile"
        defaults.set(Data("broken".utf8), forKey: key)
        let store = UserDefaultsZeroOneUserProfileStore(defaults: defaults, key: key)

        let repository = ZeroOneUserProfileRepository(store: store)

        XCTAssertEqual(repository.profile, ZeroOneUserProfile())
        XCTAssertEqual(repository.rootRoute, .onboarding)
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testUnreadableProfileIsBackedUpAndSetupCanSaveAgain() throws {
        let suiteName = "UserProfileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "profile"
        let broken = Data("broken".utf8)
        defaults.set(broken, forKey: key)

        let repository = ZeroOneUserProfileRepository(store: UserDefaultsZeroOneUserProfileStore(defaults: defaults, key: key))

        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(key + ".unreadableBackup.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.first?.value as? Data, broken)
        XCTAssertTrue(repository.isAvailable)
        XCTAssertTrue(repository.update { $0.onboardingComplete = true })
        XCTAssertEqual(repository.rootRoute, .appShell)
    }
}

private final class InMemoryDemoStateStore: ZeroOneDemoStatePersisting {
    private let initial: ZeroOneDemoState?
    private(set) var savedState: ZeroOneDemoState?

    init(initial: ZeroOneDemoState? = nil) {
        self.initial = initial
    }

    func load() -> ZeroOneDemoState? {
        initial
    }

    func save(_ state: ZeroOneDemoState) {
        savedState = state
    }
}

private final class InMemoryUserProfileStore: ZeroOneUserProfilePersisting {
    private let initial: ZeroOneUserProfile?
    private(set) var savedProfile: ZeroOneUserProfile?

    init(initial: ZeroOneUserProfile? = nil) {
        self.initial = initial
        savedProfile = initial
    }

    func load() -> ZeroOneUserProfile? {
        savedProfile ?? initial
    }

    func save(_ profile: ZeroOneUserProfile) {
        savedProfile = profile
    }

    func clear() {
        savedProfile = nil
    }
}

private struct RejectingUserProfileStore: ZeroOneUserProfilePersisting {
    func load() -> ZeroOneUserProfile? { ZeroOneUserProfile() }
    func save(_ profile: ZeroOneUserProfile) { }
    func clear() { }
}
