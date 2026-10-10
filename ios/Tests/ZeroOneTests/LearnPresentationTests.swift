import XCTest
@testable import ZeroOne

/// Pure facts behind proof 44's Learn home and lesson. Layout, VoiceOver and
/// rendering need native acceptance; these rules do not.
final class LearnPresentationTests: XCTestCase {
    // MARK: The lesson for the moment around a workout

    func testTheMomentIsTheExistingTodayRule() {
        XCTAssertEqual(LearnWorkoutMoment.current(hasPlannedWorkout: true, workoutCompleted: false, workoutInProgress: false),
                       .beforeWorkout)
        XCTAssertEqual(LearnWorkoutMoment.current(hasPlannedWorkout: true, workoutCompleted: true, workoutInProgress: false),
                       .afterWorkout, "A saved workout wins, as before")
        XCTAssertEqual(LearnWorkoutMoment.current(hasPlannedWorkout: false, workoutCompleted: true, workoutInProgress: false),
                       .afterWorkout)
        XCTAssertNil(LearnWorkoutMoment.current(hasPlannedWorkout: false, workoutCompleted: false, workoutInProgress: false),
                     "No workout state, no lesson for the moment")
        XCTAssertNil(LearnWorkoutMoment.current(hasPlannedWorkout: true, workoutCompleted: false, workoutInProgress: true),
                     "Never during a workout")
    }

    func testEachMomentNamesABundledLessonAndNoInventedDay() {
        XCTAssertEqual(LearnWorkoutMoment.beforeWorkout.lessonID, "warmup-basics")
        XCTAssertEqual(LearnWorkoutMoment.afterWorkout.lessonID, "progression-basics")
        for moment in [LearnWorkoutMoment.beforeWorkout, .afterWorkout] {
            XCTAssertNotNil(LearnCatalog.lesson(moment.lessonID))
            for weekday in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
                XCTAssertFalse(moment.eyebrow.contains(weekday), "No scheduled day is known here")
            }
        }
    }

    // MARK: Evidence

    func testNoEvidenceKindIsTurnedIntoACertaintyGrade() {
        // The lessons carry a source kind, not a graded strength.
        XCTAssertNil(LearnEvidenceMeter.filledSegments(for: .publicGuidance))
        XCTAssertNil(LearnEvidenceMeter.filledSegments(for: .researchSummary))
        XCTAssertNil(LearnEvidenceMeter.filledSegments(for: .how01Works))
        XCTAssertEqual(LearnEvidenceMeter.segmentCount, 4)
        for lesson in LearnCatalog.lessons {
            XCTAssertNil(LearnEvidenceMeter.filledSegments(for: lesson.evidence), lesson.id)
        }
    }

    func testUngradedEvidenceUsesWordsInsteadOfAZeroMeter() {
        for evidence in [LearnEvidence.publicGuidance, .researchSummary, .how01Works] {
            XCTAssertEqual(LearnEvidenceMeter.presentation(for: evidence), .ungraded)
        }
        for lesson in LearnCatalog.lessons {
            XCTAssertEqual(LearnEvidenceMeter.presentation(for: lesson.evidence), .ungraded, lesson.id)
        }
    }

    func testUngradedEvidenceIsExplicitInTheRowAccessibilityDescription() {
        for evidence in [LearnEvidence.publicGuidance, .researchSummary, .how01Works] {
            let description = LearnEvidenceMeter.accessibilityDescription(for: evidence, localization: .english)
            XCTAssertEqual(description, "Evidence strength not graded")
            XCTAssertFalse(description.contains("0"), "An unknown grade must not be announced as zero")
        }
    }

    // MARK: Filters

    func testFiltersKeepTheExistingSemantics() {
        let lessons = LearnCatalog.lessons
        let all = LearnLessonPresentation.lessons(lessons, topic: nil, savedOnly: false, savedIDs: [], search: "")
        XCTAssertEqual(all.map(\.id), lessons.map(\.id))

        let warmUp = LearnLessonPresentation.lessons(lessons, topic: .warmup, savedOnly: false, savedIDs: [], search: "")
        XCTAssertFalse(warmUp.isEmpty)
        XCTAssertTrue(warmUp.allSatisfy { $0.topic == .warmup })

        let saved = LearnLessonPresentation.lessons(lessons, topic: nil, savedOnly: true,
                                                    savedIDs: ["progression-basics"], search: "")
        XCTAssertEqual(saved.map(\.id), ["progression-basics"])
        XCTAssertTrue(LearnLessonPresentation.lessons(lessons, topic: nil, savedOnly: true, savedIDs: [], search: "").isEmpty)

        let searched = LearnLessonPresentation.lessons(lessons, topic: nil, savedOnly: false, savedIDs: [], search: "warm")
        XCTAssertTrue(searched.contains { $0.id == "warmup-basics" })
    }

    func testTheTopicLineIsTopicThenTime() {
        XCTAssertEqual(LearnLessonPresentation.topicLine(topic: "Warm-up", minutes: "2 min"), "Warm-up · 2 min")
    }
}
