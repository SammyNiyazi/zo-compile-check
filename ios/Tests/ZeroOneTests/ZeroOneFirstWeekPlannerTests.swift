import XCTest
@testable import ZeroOne

final class ZeroOneFirstWeekPlannerTests: XCTestCase {
    private let bundledIDs = Set(MoveKitExercise.all.map(\.id))

    func testNoEquipmentPlanContainsOnlyBundledBodyweightMovements() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.none]
        profile.trainingExperience = .startingOut
        profile.preferredTrainingDays = [.monday, .wednesday, .friday]
        profile.preferredSessionMinutes = 45

        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs
        ))

        XCTAssertEqual(plan.trainingDays, [.monday, .wednesday, .friday])
        XCTAssertEqual(plan.workingSets, 2)
        XCTAssertEqual(plan.sessions.count, 2)
        XCTAssertTrue(plan.sessions.allSatisfy { $0.videoIDs.count == 5 })
        for videoID in plan.sessions.flatMap(\.videoIDs) {
            let movement = try XCTUnwrap(MoveKitExerciseCatalog.exercise(for: videoID))
            XCTAssertEqual(movement.equipment, "Bodyweight")
        }
    }

    func testSkippedSetupGetsAConservativePlayableStarter() throws {
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: ZeroOneUserProfile(), availableVideoIDs: bundledIDs
        ))
        XCTAssertEqual(plan.trainingDays, [.monday, .wednesday, .friday])
        XCTAssertEqual(plan.workingSets, 2)
        XCTAssertTrue(plan.sessions.flatMap(\.videoIDs).allSatisfy {
            MoveKitExerciseCatalog.exercise(for: $0)?.equipment == "Bodyweight"
        })
    }

    func testSelectedDaysAreNotSilentlyReplacedByARecommendedSubset() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.none]
        profile.trainingExperience = .returning
        profile.preferredTrainingDays = Set(ZeroOneTrainingDay.allCases)

        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs
        ))

        XCTAssertEqual(plan.availableDays.count, 7)
        XCTAssertEqual(plan.trainingDays, ZeroOneTrainingDay.allCases)
        XCTAssertEqual(plan.trainingDays, plan.availableDays)
        XCTAssertTrue(plan.reasons.first { $0.kind == .days }?.explanation.contains("each selected training day") == true)
    }

    func testNonDefaultDaysSurviveAlternativeGenerationAndSavedPlanRoundTrip() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = ZeroOneEquipmentItem.fullGym
        profile.trainingExperience = .experienced
        profile.preferredTrainingDays = [.tuesday, .thursday, .friday, .saturday, .sunday]
        let expected: [ZeroOneTrainingDay] = [.tuesday, .thursday, .friday, .saturday, .sunday]
        for alternative in 0...2 {
            let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
                for: profile, availableVideoIDs: bundledIDs, alternative: alternative
            ))
            let saved = ZeroOneSavedFirstWeekPlan(plan: plan, workoutIDs: [UUID(), UUID()], savedAt: .now)
            let restored = try JSONDecoder().decode(ZeroOneSavedFirstWeekPlan.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(restored.plan.trainingDays, expected)
            XCTAssertEqual(restored.plan.availableDays, expected)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)))
            XCTAssertEqual(restored.nextTrainingDay(on: monday, calendar: calendar), .tuesday)
            let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)))
            XCTAssertEqual(restored.nextTrainingDay(on: saturday, calendar: calendar), .saturday)
        }
    }

    func testFullGymAlternativeIsARealDifferentEquipmentPlan() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = ZeroOneEquipmentItem.fullGym
        profile.trainingExperience = .experienced
        profile.preferredSessionMinutes = 60

        let first = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs, alternative: 0
        ))
        let second = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs, alternative: 1
        ))

        XCTAssertEqual(first.sessions.first?.videoIDs.first, "barbell-squat")
        XCTAssertEqual(second.sessions.first?.videoIDs.first, "dumbbell-goblet-squat")
        XCTAssertEqual(first.trainingDays.count, 3)
        XCTAssertNotEqual(first.sessions, second.sessions)
    }

    func testMissingExerciseNeverProducesAPlan() {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.none]

        XCTAssertNil(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: ["bodyweight-squat", "push-up"]
        ))
    }

    func testConflictingSavedEquipmentFailsClosedToBodyweight() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.none, .barbell]

        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs
        ))

        XCTAssertEqual(plan.sessions.first?.videoIDs.first, "bodyweight-squat")
    }

    func testEachExclusiveEquipmentPathUsesOnlyThatKitOrBodyweight() throws {
        let choices: [(ZeroOneEquipmentItem, Set<String>)] = [
            (.barbell, ["Barbell", "Barbell and rack"]), (.dumbbells, ["Dumbbell"]),
            (.kettlebells, ["Kettlebell"]), (.machines, ["Machine"]),
            (.cables, ["Cable Machine"]), (.bands, ["Band"])
        ]
        for (choice, expectedEquipment) in choices {
            var profile = ZeroOneUserProfile()
            profile.availableEquipment = [choice]
            let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
                for: profile, availableVideoIDs: bundledIDs
            ))
            for videoID in plan.sessions.flatMap(\.videoIDs) {
                let movement = try XCTUnwrap(MoveKitExerciseCatalog.exercise(for: videoID))
                XCTAssertTrue(expectedEquipment.union(["Bodyweight"]).contains(movement.equipment),
                    "\(videoID) requires \(movement.equipment), not \(choice.title)")
            }
        }
    }

    func testProposalMaterializesEditableWorkoutsWithNoInventedStartingLoad() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.dumbbells]
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs
        ))
        let ids = [UUID(), UUID()]

        let workouts = try XCTUnwrap(plan.makeCustomWorkouts(ids: ids, weightUnit: .pounds))

        XCTAssertEqual(workouts.map(\.id), ids)
        XCTAssertTrue(workouts.allSatisfy(\.isValid))
        XCTAssertTrue(workouts.flatMap(\.items).allSatisfy { $0.targetLoad == 0 && $0.loadUnit == .pounds })
        XCTAssertNil(plan.makeCustomWorkouts(ids: [ids[0], ids[0]], weightUnit: .pounds))
    }

    func testSavedPlanOffersTheNextSelectedDayWithoutChangingTheSchedule() throws {
        var profile = ZeroOneUserProfile()
        profile.availableEquipment = [.none]
        profile.preferredTrainingDays = [.monday, .wednesday, .friday]
        let plan = try XCTUnwrap(ZeroOneFirstWeekPlanner.recommend(
            for: profile, availableVideoIDs: bundledIDs
        ))
        let ids = [UUID(), UUID()]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func day(_ month: Int, _ number: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: number)))
        }
        let saved = ZeroOneSavedFirstWeekPlan(plan: plan, workoutIDs: ids, savedAt: try day(9, 28))
        XCTAssertEqual(saved.nextWorkoutID(on: try day(9, 28), calendar: calendar), ids[0]) // Mon
        XCTAssertEqual(saved.nextWorkoutID(on: try day(9, 29), calendar: calendar), ids[1]) // Tue -> Wed
        XCTAssertEqual(saved.nextWorkoutID(on: try day(9, 30), calendar: calendar), ids[1]) // Wed
        XCTAssertEqual(saved.nextWorkoutID(on: try day(10, 2), calendar: calendar), ids[0]) // Fri
        XCTAssertEqual(saved.nextWorkoutID(on: try day(10, 3), calendar: calendar), ids[1]) // Sat -> next Mon

        let savedOnRestDay = ZeroOneSavedFirstWeekPlan(plan: plan, workoutIDs: ids, savedAt: try day(10, 3))
        XCTAssertEqual(savedOnRestDay.nextWorkoutID(on: try day(10, 3), calendar: calendar), ids[0])
        XCTAssertEqual(savedOnRestDay.nextWorkoutID(on: try day(10, 5), calendar: calendar), ids[0])
        XCTAssertEqual(savedOnRestDay.nextWorkoutID(on: try day(10, 7), calendar: calendar), ids[1])
    }
}
