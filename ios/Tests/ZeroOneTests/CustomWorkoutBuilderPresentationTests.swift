import XCTest
@testable import ZeroOne

/// Pure builder presentation rules: target shifting, drag reordering, rest choices,
/// row copy and Undo placement. Layout and gesture feel need native acceptance.
@MainActor
final class CustomWorkoutBuilderPresentationTests: XCTestCase {
    // MARK: One visible target, shifted as a whole

    func testShiftingARangeKeepsItsWidthAndStopsAtEitherEdge() {
        let reps = CustomWorkoutTargetRange(lower: 8, upper: 10)
        XCTAssertEqual(reps.shifted(by: 1, within: 1 ... 50), CustomWorkoutTargetRange(lower: 9, upper: 11))
        XCTAssertEqual(reps.shifted(by: -1, within: 1 ... 50), CustomWorkoutTargetRange(lower: 7, upper: 9))

        let atTop = CustomWorkoutTargetRange(lower: 48, upper: 50)
        XCTAssertNil(atTop.shifted(by: 1, within: 1 ... 50), "A range must not narrow or clamp at the upper edge")
        let atBottom = CustomWorkoutTargetRange(lower: 1, upper: 3)
        XCTAssertNil(atBottom.shifted(by: -1, within: 1 ... 50), "A range must not narrow or clamp at the lower edge")
    }

    func testShiftingAScalarKeepsItScalar() {
        let scalar = CustomWorkoutTargetRange(lower: 12, upper: nil)
        XCTAssertEqual(scalar.shifted(by: 1, within: 1 ... 50), CustomWorkoutTargetRange(lower: 13, upper: nil))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 50, upper: nil).shifted(by: 1, within: 1 ... 50))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 1, upper: nil).shifted(by: -1, within: 1 ... 50))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 86_400, upper: nil).shifted(by: 1, within: 1 ... 86_400))
    }

    func testPreciseEditorOnlyAcceptsAValidRangeAndEqualBoundsBecomeScalar() {
        XCTAssertEqual(CustomWorkoutTargetRange.validated(lower: 6, upper: 12, within: 1 ... 50),
                       CustomWorkoutTargetRange(lower: 6, upper: 12))
        XCTAssertEqual(CustomWorkoutTargetRange.validated(lower: 8, upper: 8, within: 1 ... 50),
                       CustomWorkoutTargetRange(lower: 8, upper: nil))
        XCTAssertNil(CustomWorkoutTargetRange.validated(lower: 10, upper: 8, within: 1 ... 50))
        XCTAssertNil(CustomWorkoutTargetRange.validated(lower: 0, upper: 8, within: 1 ... 50))
        XCTAssertNil(CustomWorkoutTargetRange.validated(lower: 8, upper: 51, within: 1 ... 50))
    }

    func testApplyingATargetChangesOnlyThatTargetsFields() throws {
        let original = CustomWorkoutItem(videoID: "push-up", sets: 4, reps: 8, restSeconds: 45, targetLoad: 12.5,
                                         loadUnit: .pounds, perSide: true, repUpperBound: 10)
        var reps = original
        CustomWorkoutTargetRange(lower: 9, upper: 11).apply(to: &reps)
        XCTAssertEqual(reps.reps, 9)
        XCTAssertEqual(reps.repUpperBound, 11)
        XCTAssertNil(reps.durationSeconds)
        XCTAssertEqual(reps.id, original.id)
        XCTAssertEqual(reps.sets, 4)
        XCTAssertEqual(reps.restSeconds, 45)
        XCTAssertEqual(reps.targetLoad, 12.5)
        XCTAssertEqual(reps.loadUnit, .pounds)
        XCTAssertEqual(reps.perSide, true)
        XCTAssertTrue(reps.isStructurallyValid)

        var timed = CustomWorkoutItem(videoID: "push-up", durationSeconds: 30, durationUpperBound: 45)
        XCTAssertEqual(CustomWorkoutTargetRange.current(for: timed), CustomWorkoutTargetRange(lower: 30, upper: 45))
        XCTAssertEqual(CustomWorkoutTargetRange.bounds(for: timed), 1 ... 86_400)
        let shifted = try XCTUnwrap(CustomWorkoutTargetRange.current(for: timed)
            .shifted(by: 1, within: CustomWorkoutTargetRange.bounds(for: timed)))
        shifted.apply(to: &timed)
        XCTAssertEqual(timed.durationSeconds, 31)
        XCTAssertEqual(timed.durationUpperBound, 46)
        XCTAssertEqual(timed.reps, 10, "Timed edits leave the stored repetition fields alone")
        XCTAssertTrue(timed.isStructurallyValid)
    }

    func testPreciseEditorHighestChoicesNeverInvertForAnOutOfBoundsStoredValue() {
        XCTAssertEqual(CustomWorkoutTargetRange.upperChoices(lower: 8, within: 1 ... 50), 8 ... 50)
        XCTAssertEqual(CustomWorkoutTargetRange.upperChoices(lower: 50, within: 1 ... 50), 50 ... 50)
        // An older draft can hold a value the builder never offered; the editor must not trap on it.
        XCTAssertEqual(CustomWorkoutTargetRange.upperChoices(lower: 60, within: 1 ... 50), 50 ... 50)
        XCTAssertEqual(CustomWorkoutTargetRange.upperChoices(lower: 0, within: 1 ... 50), 1 ... 50)
        XCTAssertNil(CustomWorkoutTargetRange.validated(lower: 60, upper: 50, within: 1 ... 50),
                     "Apply stays unavailable until the lowest value is back inside the bounds")
    }

    func testExtremeOrInvertedStoredTargetsAreRefusedWithoutTrappingOrRewriting() {
        let reps = 1 ... 50
        let seconds = 1 ... 86_400
        // An older draft is decoded without validation; evaluating either step must be safe.
        for range in [CustomWorkoutTargetRange(lower: .max, upper: nil), CustomWorkoutTargetRange(lower: .min, upper: nil),
                      CustomWorkoutTargetRange(lower: 8, upper: .max), CustomWorkoutTargetRange(lower: .min, upper: 10),
                      CustomWorkoutTargetRange(lower: .max, upper: .max), CustomWorkoutTargetRange(lower: .min, upper: .min),
                      CustomWorkoutTargetRange(lower: 10, upper: 8), CustomWorkoutTargetRange(lower: 0, upper: nil)] {
            XCTAssertFalse(range.isValid(within: reps))
            XCTAssertNil(range.shifted(by: 1, within: reps))
            XCTAssertNil(range.shifted(by: -1, within: reps))
            XCTAssertNil(range.shifted(by: 1, within: seconds))
            XCTAssertNil(range.shifted(by: -1, within: seconds))
        }
        // A huge step from a valid target reports overflow instead of trapping.
        XCTAssertNil(CustomWorkoutTargetRange(lower: 8, upper: 10).shifted(by: .max, within: reps))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 8, upper: nil).shifted(by: .min, within: reps))

        // Refusing a step never changes the stored item.
        var item = CustomWorkoutItem(videoID: "push-up", reps: .max, repUpperBound: .max)
        let stored = item
        if let step = CustomWorkoutTargetRange.current(for: item).shifted(by: 1, within: CustomWorkoutTargetRange.bounds(for: item)) {
            step.apply(to: &item)
        }
        XCTAssertEqual(item, stored)
    }

    func testValidTargetsStillStepAtTheirEdges() {
        XCTAssertTrue(CustomWorkoutTargetRange(lower: 1, upper: 50).isValid(within: 1 ... 50))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 1, upper: 50).shifted(by: 1, within: 1 ... 50))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 1, upper: 50).shifted(by: -1, within: 1 ... 50))
        XCTAssertEqual(CustomWorkoutTargetRange(lower: 49, upper: nil).shifted(by: 1, within: 1 ... 50),
                       CustomWorkoutTargetRange(lower: 50, upper: nil))
        XCTAssertEqual(CustomWorkoutTargetRange(lower: 2, upper: nil).shifted(by: -1, within: 1 ... 50),
                       CustomWorkoutTargetRange(lower: 1, upper: nil))
        XCTAssertEqual(CustomWorkoutTargetRange(lower: 86_398, upper: 86_399).shifted(by: 1, within: 1 ... 86_400),
                       CustomWorkoutTargetRange(lower: 86_399, upper: 86_400))
        XCTAssertNil(CustomWorkoutTargetRange(lower: 86_399, upper: 86_400).shifted(by: 1, within: 1 ... 86_400))
    }

    func testTheSetsBadgeIsLeftOutWhenAnUnvalidatedTotalWouldOverflow() {
        let items = [CustomWorkoutItem(videoID: "push-up", sets: 3), CustomWorkoutItem(videoID: "lat-pulldown", sets: 4)]
        XCTAssertEqual(CustomWorkoutBuilderPresentation.totalSets(items), 7)
        XCTAssertEqual(CustomWorkoutBuilderPresentation.totalSets([]), 0)
        XCTAssertNil(CustomWorkoutBuilderPresentation.totalSets(
            [CustomWorkoutItem(videoID: "push-up", sets: .max), CustomWorkoutItem(videoID: "lat-pulldown", sets: 1)]))
        XCTAssertNil(CustomWorkoutBuilderPresentation.totalSets(
            [CustomWorkoutItem(videoID: "push-up", sets: .min), CustomWorkoutItem(videoID: "lat-pulldown", sets: -1)]))
    }

    // MARK: Adding and replacing from the picker

    func testPickedExercisesAreAddedInSelectionOrderAndTheFirstOneOpens() throws {
        let existing = CustomWorkoutItem(videoID: "push-up", sets: 4, reps: 6)
        let picks = try ["lat-pulldown", "dumbbell-bench-press"].map { try XCTUnwrap(MoveKitExerciseCatalog.exercise(for: $0)) }
        let outcome = CustomWorkoutBuilderPresentation.applyingPicked(picks, replacing: nil, to: [existing])
        XCTAssertEqual(outcome.items.count, 3)
        XCTAssertEqual(outcome.items[0], existing, "Existing rows are untouched")
        XCTAssertEqual(outcome.items.dropFirst().map(\.videoID), ["lat-pulldown", "dumbbell-bench-press"])
        XCTAssertEqual(outcome.openItemID, outcome.items[1].id, "The first addition opens for editing, as before the redesign")
        XCTAssertEqual(Set(outcome.items.map(\.id)).count, 3)

        let nothing = CustomWorkoutBuilderPresentation.applyingPicked([], replacing: nil, to: [existing])
        XCTAssertEqual(nothing.items, [existing])
        XCTAssertNil(nothing.openItemID)
    }

    func testAReplacementKeepsTheRowIdentityAndPositionAndOpensThatRow() throws {
        let first = CustomWorkoutItem(videoID: "push-up")
        let target = CustomWorkoutItem(videoID: "dumbbell-bench-press", sets: 4, reps: 8, restSeconds: 120, repUpperBound: 10)
        let last = CustomWorkoutItem(videoID: "lat-pulldown")
        let replacement = try XCTUnwrap(MoveKitExerciseCatalog.exercise(for: "barbell-bench-press"))
        let outcome = CustomWorkoutBuilderPresentation.applyingPicked([replacement], replacing: target.id, to: [first, target, last])
        XCTAssertEqual(outcome.items.map(\.id), [first.id, target.id, last.id])
        XCTAssertEqual(outcome.items[1], target.replacing(with: replacement), "The existing replace policy decides what carries over")
        XCTAssertEqual(outcome.items[1].videoID, "barbell-bench-press")
        XCTAssertEqual(outcome.openItemID, target.id)
    }

    func testAReplacementWhoseRowIsGoneIsAddedInsteadAsBefore() throws {
        let kept = CustomWorkoutItem(videoID: "push-up")
        let replacement = try XCTUnwrap(MoveKitExerciseCatalog.exercise(for: "lat-pulldown"))
        let outcome = CustomWorkoutBuilderPresentation.applyingPicked([replacement], replacing: UUID(), to: [kept])
        XCTAssertEqual(outcome.items.count, 2)
        XCTAssertEqual(outcome.items[0], kept)
        XCTAssertEqual(outcome.items[1].videoID, "lat-pulldown")
        XCTAssertEqual(outcome.openItemID, outcome.items[1].id)
    }

    // MARK: Drag reordering

    func testTargetIndexFollowsTheLiftedRowsCentre() {
        let heights: [CGFloat] = [72, 72, 72, 72, 72]
        let step: CGFloat = 80
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 1, translation: 0), 1)
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 1, translation: 30), 1)
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 1, translation: step), 1,
                       "Swaps only once the lifted centre passes the neighbour's centre")
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 1, translation: step + 1), 2)
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 3, translation: -2 * step - 1), 1)
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 0, translation: 10_000), 4)
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 4, translation: -10_000), 0)
    }

    func testTargetIndexUsesMeasuredHeightsForTallRows() {
        // A tall second row (large text) must be passed by its own centre, not a fixed row height.
        let heights: [CGFloat] = [72, 200, 72]
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 0, translation: 90), 0)
        XCTAssertEqual(CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 0, translation: 150), 1)
        XCTAssertEqual(CustomWorkoutReorder.origin(of: 2, heights: heights, spacing: 8), 288)
    }

    func testDropReordersTheSameItemsWithoutChangingIdentity() throws {
        let items = ["dumbbell-bench-press", "dumbbell-incline-bench-press", "push-up"].map { CustomWorkoutItem(videoID: $0) }
        let order = CustomWorkoutReorder.moved(items.map(\.id), from: 2, to: 0)
        let reordered = try XCTUnwrap(CustomWorkoutReorder.reordered(items, by: order))
        XCTAssertEqual(reordered.map(\.id), [items[2].id, items[0].id, items[1].id])
        XCTAssertEqual(Set(reordered.map(\.id)), Set(items.map(\.id)))
        XCTAssertEqual(reordered.first, items[2], "Every field of a moved row stays the same")

        XCTAssertEqual(CustomWorkoutReorder.moved(items.map(\.id), from: 1, to: 1), items.map(\.id))
        XCTAssertEqual(CustomWorkoutReorder.moved(items.map(\.id), from: 7, to: 0), items.map(\.id))
    }

    func testAStalePreviewOrderIsRefusedRatherThanApplied() {
        let items = ["push-up", "lat-pulldown"].map { CustomWorkoutItem(videoID: $0) }
        let stranger = CustomWorkoutItem(videoID: "push-up")
        XCTAssertNil(CustomWorkoutReorder.reordered(items, by: [items[0].id]))
        XCTAssertNil(CustomWorkoutReorder.reordered(items, by: [items[0].id, stranger.id]))
        XCTAssertNil(CustomWorkoutReorder.reordered(items, by: [items[0].id, items[0].id]))
    }

    // MARK: Rest choices and copy

    func testEdgeScrollUsesTheVisibleViewportAndRampsInBothDirections() {
        // Screen space starts at 0; the actual viewport starts below the top bar.
        let viewport = CGRect(x: 20, y: 150, width: 350, height: 500)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 400), viewport: viewport), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 182), viewport: viewport), -130)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 150), viewport: viewport), -260)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 618), viewport: viewport), 130)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 650), viewport: viewport), 260)
    }

    func testEdgeScrollStopsAwayFromTheViewportAndHandlesShortOrMissingGeometry() {
        let viewport = CGRect(x: 20, y: 150, width: 350, height: 500)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 40), viewport: viewport), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 500, y: 640), viewport: viewport), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 800), viewport: viewport), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: .zero, viewport: .zero), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: .zero, viewport: .null), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: CGFloat.nan, y: 150), viewport: viewport), 0)
        // A keyboard-sized viewport retains a neutral middle; edge bands never overlap.
        let short = CGRect(x: 0, y: 100, width: 300, height: 80)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 140), viewport: short), 0)
        XCTAssertEqual(CustomWorkoutEdgeScroll.velocity(finger: CGPoint(x: 100, y: 110), viewport: short), -130)
    }

    func testEdgeScrollClampsToActualContentAndAdjustedInsets() {
        // Offset bounds are -70 ... 1,330, including the measured top bar and bottom dock.
        XCTAssertEqual(CustomWorkoutEdgeScroll.nextOffset(current: -68, contentHeight: 1_800, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: -260, elapsed: 1.0 / 60), -70)
        XCTAssertNil(CustomWorkoutEdgeScroll.nextOffset(current: -70, contentHeight: 1_800, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: -260, elapsed: 1.0 / 60))
        XCTAssertEqual(CustomWorkoutEdgeScroll.nextOffset(current: 1_328, contentHeight: 1_800, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 260, elapsed: 1.0 / 60), 1_330)
        XCTAssertNil(CustomWorkoutEdgeScroll.nextOffset(current: 1_330, contentHeight: 1_800, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 260, elapsed: 1.0 / 60))
        // A short list has no scroll range, even with nonzero safe-area insets.
        XCTAssertNil(CustomWorkoutEdgeScroll.nextOffset(current: -70, contentHeight: 200, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 260, elapsed: 1.0 / 60))
    }

    func testEdgeScrollCanReverseImmediatelyAtEitherBoundary() throws {
        let down = try XCTUnwrap(CustomWorkoutEdgeScroll.nextOffset(current: -70, contentHeight: 1_800, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 260, elapsed: 1.0 / 60))
        XCTAssertGreaterThan(down, -70)
        let up = try XCTUnwrap(CustomWorkoutEdgeScroll.nextOffset(current: 1_330, contentHeight: 1_800, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: -260, elapsed: 1.0 / 60))
        XCTAssertLessThan(up, 1_330)
    }

    func testEdgeScrollCapsDelayedFramesAndIgnoresInvalidTimeOrZeroVelocity() throws {
        let next = try XCTUnwrap(CustomWorkoutEdgeScroll.nextOffset(current: 300, contentHeight: 3_000, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 50_000, elapsed: 5))
        XCTAssertEqual(next - 300, 260.0 / 30.0, accuracy: 0.0001,
                       "A delayed display frame must never jump rows by catching up elapsed time")
        for elapsed in [0.0, -1.0, .infinity, .nan] {
            XCTAssertNil(CustomWorkoutEdgeScroll.nextOffset(current: 300, contentHeight: 3_000, viewportHeight: 600,
                topInset: 70, bottomInset: 130, velocity: 260, elapsed: elapsed))
        }
        XCTAssertNil(CustomWorkoutEdgeScroll.nextOffset(current: 300, contentHeight: 3_000, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 0, elapsed: 1.0 / 60))
        XCTAssertNil(CustomWorkoutEdgeScroll.nextOffset(current: .nan, contentHeight: 3_000, viewportHeight: 600,
            topInset: 70, bottomInset: 130, velocity: 260, elapsed: 1.0 / 60))
    }

    func testStationaryFingerCanReachOffscreenRowsWithoutChangingItemsUntilDrop() throws {
        let items = (0 ..< 12).map { index in
            CustomWorkoutItem(videoID: "push-up", sets: 1 + index % 4, reps: 5 + index)
        }
        let original = items
        let heights: [CGFloat] = Array(repeating: 72, count: items.count)
        let initialOffset: CGFloat = 120
        var actualOffset = initialOffset
        let fingerTranslation: CGFloat = 200
        var target = 0
        for _ in 0 ..< 180 {
            actualOffset = CustomWorkoutEdgeScroll.nextOffset(current: actualOffset,
                contentHeight: 1_400, viewportHeight: 500, topInset: 60, bottomInset: 100,
                velocity: 260, elapsed: 1.0 / 60) ?? actualOffset
            let contentTranslation = fingerTranslation + actualOffset - initialOffset
            target = CustomWorkoutReorder.targetIndex(heights: heights, spacing: 8, source: 0,
                                                       translation: contentTranslation)
            // Viewport position stays attached to the stationary finger while content moves.
            XCTAssertEqual(contentTranslation - (actualOffset - initialOffset), fingerTranslation, accuracy: 0.0001)
        }
        XCTAssertEqual(target, 11, "The same held drag reaches beyond the initially visible rows")
        XCTAssertEqual(items, original, "All scrolling and preview calculations leave the source untouched")
        let order = CustomWorkoutReorder.moved(items.map(\.id), from: 0, to: target)
        let dropped = try XCTUnwrap(CustomWorkoutReorder.reordered(items, by: order))
        XCTAssertEqual(dropped, Array(original.dropFirst()) + [original[0]], "Drop preserves every item field and UUID")
    }

    func testRestChipsKeepAStoredValueOutsideThePresets() {
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restChipValues(current: 120), [60, 90, 120, 180])
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restChipValues(current: 45), [60, 90, 120, 180, 45])
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restChipValues(current: 0), [60, 90, 120, 180, 0])
        XCTAssertEqual(CustomWorkoutBuilderPresentation.moreRestValues(current: 75), [0, 30, 45, 60, 75, 90, 120, 180, 300, 600])
        XCTAssertEqual(CustomWorkoutBuilderPresentation.moreRestValues(current: 90), [0, 30, 45, 60, 90, 120, 180, 300, 600])
    }

    func testRestClock() {
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restClock(60), "1:00")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restClock(90), "1:30")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restClock(45), "0:45")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restClock(65), "1:05")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restClock(600), "10:00")
    }

    func testRowCaptionMatchesTheFinalCopy() {
        let english = AppLocalization.english
        XCTAssertEqual(CustomWorkoutBuilderPresentation.rowCaption(
            CustomWorkoutItem(videoID: "dumbbell-bench-press", sets: 3, reps: 8, restSeconds: 120, repUpperBound: 10),
            localization: english), "3 × 8 to 10 · rest 2:00")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.rowCaption(
            CustomWorkoutItem(videoID: "push-up", sets: 2, reps: 12, restSeconds: 90), localization: english),
            "2 × 12 · rest 1:30")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.rowCaption(
            CustomWorkoutItem(videoID: "push-up", sets: 3, restSeconds: 45, durationSeconds: 30, perSide: true,
                              durationUpperBound: 45), localization: english),
            "3 × 30 to 45 sec per side · rest 0:45")
        XCTAssertEqual(CustomWorkoutBuilderPresentation.rowCaption(
            CustomWorkoutItem(videoID: "push-up", sets: 1, reps: 5, restSeconds: 0), localization: english),
            "1 × 5 · no timed rest")
    }

    func testRowReadsAsTheVoiceOverSentence() {
        let item = CustomWorkoutItem(videoID: "dumbbell-bench-press", sets: 3, reps: 8, restSeconds: 120, repUpperBound: 10)
        XCTAssertEqual(CustomWorkoutBuilderPresentation.rowAccessibilityLabel(item, localization: .english),
                       "Dumbbell bench press, 3 sets of 8 to 10, rest 2 minutes")
    }

    // MARK: Undo and the time estimate

    func testUndoRestoresAtTheOriginalPositionClampedToTheCurrentList() {
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restoredIndex(3, count: 4), 3)
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restoredIndex(3, count: 1), 1)
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restoredIndex(0, count: 0), 0)
        XCTAssertEqual(CustomWorkoutBuilderPresentation.restoredIndex(-1, count: 2), 0)
        XCTAssertEqual(CustomWorkoutBuilderPresentation.undoSeconds, 5)
    }

    func testTimeBadgeUsesTheExistingEstimatorAndIsAbsentForAnInvalidDraft() throws {
        let workout = CustomWorkout(name: "Push day", items: [
            CustomWorkoutItem(videoID: "dumbbell-bench-press", sets: 3, reps: 8, restSeconds: 120, repUpperBound: 10),
            CustomWorkoutItem(videoID: "push-up", sets: 2, reps: 12, restSeconds: 90)
        ])
        let before = workout
        let estimate = try XCTUnwrap(CustomWorkoutBuilderPresentation.estimate(for: workout, warmUp: .short))
        let session = try XCTUnwrap(workout.makeSession(warmUpLengthOverride: .short, progressionAllowed: false))
        XCTAssertEqual(estimate, WorkoutTimeEstimator().estimate(for: session))
        XCTAssertGreaterThan(estimate.maximumMinutes, 0)
        XCTAssertEqual(workout, before, "Estimating never changes the draft")
        XCTAssertNil(CustomWorkoutBuilderPresentation.estimate(for: CustomWorkout(name: "Empty"), warmUp: .full))
    }
}
