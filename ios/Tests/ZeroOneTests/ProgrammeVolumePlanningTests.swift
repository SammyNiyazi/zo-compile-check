import XCTest
@testable import ZeroOne

@MainActor
final class ProgrammeVolumePlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_024_000)
    private let planner = ProgrammeVolumePlanner()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var base: WorkoutProgramme { WorkoutProgrammeLibrary.programme(id: .zeroOneStart)! }

    func testCanonicalIdentitySurvivesRelaunchAndRandomOccurrenceIDs() throws {
        let first = programme([plan(sets: 3), plan(sets: 2)])
        let rebuilt = programme([plan(sets: 3), plan(sets: 2)])
        XCTAssertNotEqual(first.exercisePlans[0].id, rebuilt.exercisePlans[0].id)
        XCTAssertEqual(try ProgrammeVolumeSource.fingerprint(first), try ProgrammeVolumeSource.fingerprint(rebuilt))
        let revision = try revision(first)
        let relaunched = try JSONDecoder().decode(ProgrammeVolumeRevision.self, from: JSONEncoder().encode(revision))
        XCTAssertEqual(try ProgrammeVolumeSource.effective(rebuilt, revision: relaunched, at: now).exercisePlans.map(\.plannedSetCount), [2, 1])
    }

    func testIdentityBindsExplicitTargetAbsenceCuesGuardrailsAlternativesAndRepRange() throws {
        let original = plan(sets: 3)
        let baseline = try ProgrammeVolumeSource.fingerprint(programme([original]))
        for (key, value) in [("targetPrescription", nil), ("coachingCue", "Different cue" as Any?),
            ("painGuardrail", "Different guardrail" as Any?), ("unresolvedAlternativeNames", ["Other movement"] as Any?),
            ("targetReps", ["lowerBound": 9, "upperBound": 12] as Any?)] {
            let changed = try mutate(original, key: key, value: value)
            XCTAssertNotEqual(try ProgrammeVolumeSource.fingerprint(programme([changed])), baseline, key)
        }
    }

    func testOrderedRepeatedOccurrencesRemainDistinctAndEveryFieldIsPreserved() throws {
        let first = plan(sets: 3)
        let second = plan(sets: 1)
        let source = programme([first, second])
        let effective = try ProgrammeVolumeSource.effective(source, revision: revision(source), at: now)
        XCTAssertEqual(effective.exercisePlans.map(\.plannedSetCount), [2, 1])
        for (before, after) in zip(source.exercisePlans, effective.exercisePlans) {
            var expected = try object(before)
            expected["plannedSetCount"] = max(1, before.plannedSetCount - 1)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: object(after), options: [.sortedKeys]))
        }
        XCTAssertEqual(effective.rules, source.rules)
        XCTAssertEqual(effective.evidenceReferenceKeys, source.evidenceReferenceKeys)
        XCTAssertNotEqual(try ProgrammeVolumeSource.fingerprint(source), try ProgrammeVolumeSource.fingerprint(programme([second, first])))
    }

    func testSummaryKeepsPrimarySupportingConditioningAndUnknownSeparate() throws {
        let source = programme([plan(sets: 3), plan(id: ExerciseIDs.inclineWalk, sets: 2), plan(id: "UNKNOWN", sets: 4)])
        let summary = try ProgrammeVolumeSource.summary(source)
        XCTAssertEqual(summary.totalSetsPerRotation, 9)
        XCTAssertEqual(summary.rows.first { $0.muscle == "quadriceps" }?.primarySets, 3)
        XCTAssertEqual(summary.rows.first { $0.muscle == "abdominals" }?.supportingSets, 3)
        XCTAssertEqual(summary.rows.first { $0.muscle == "abdominals" }?.primarySets, 0)
        XCTAssertEqual(summary.conditioningSets, 2)
        XCTAssertEqual(summary.unclassifiedSets, 4)
    }

    func testWeeklyExposureUsesWholeRotationAndSelectedFrequency() throws {
        let source = programme([plan(sets: 3)], sessions: 3)
        let summary = try ProgrammeVolumeSource.summary(source)
        XCTAssertEqual(summary.totalSetsPerRotation, 9)
        XCTAssertEqual(summary.weeklyAverage(9, days: 2), 6)
        XCTAssertEqual(summary.weeklyAverage(9, days: 3), 9)
        XCTAssertEqual(summary.weeklyAverage(1, days: 2), 2.0 / 3.0, accuracy: 0.00001)
    }

    func testReductionIsSingleBoundedProposalAndMinimumOneCannotBeReduced() throws {
        let source = try context(programme([plan(sets: 3), plan(sets: 1)]))
        let offered = try planner.proposal(change: .ease, context: source, at: now, calendar: calendar)
        XCTAssertEqual(offered.before?.totalSetsPerRotation, 4)
        XCTAssertEqual(offered.after.totalSetsPerRotation, 3)
        XCTAssertThrowsError(try planner.proposal(change: .ease, context: context(source.programme, revision: revision(source.programme)), at: now, calendar: calendar))
        XCTAssertThrowsError(try planner.proposal(change: .ease, context: context(programme([plan(sets: 1)])), at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .noChange)
        }
    }

    func testRestoreRequiresExplicitPositiveRecoveryAndNeverExceedsAuthoredCounts() throws {
        let source = programme([plan(sets: 3)])
        let saved = try revision(source)
        let accepted = try planner.proposal(change: .restore, context: context(source, revision: saved, soreness: .none), at: now, calendar: calendar)
        XCTAssertEqual(accepted.before?.totalSetsPerRotation, 2)
        XCTAssertEqual(accepted.after.totalSetsPerRotation, 3)
        for source in [try context(source, revision: saved), try context(source, revision: saved, soreness: .none, pain: nil),
                      try context(source, revision: saved, soreness: .none, hungry: nil),
                      try context(source, revision: saved, soreness: .none, energy: .notReported)] {
            XCTAssertThrowsError(try planner.proposal(change: .restore, context: source, at: now, calendar: calendar))
        }
    }

    func testSourceAndOldPolicyRequireDistinctObsoleteReviewWithUnknownBefore() throws {
        let source = programme([plan(sets: 3)])
        let revisions = [try revision(source, baseline: String(repeating: "a", count: 64)), try revision(source, policy: "future-programme-sets-v0")]
        for saved in revisions {
            let context = try context(source, revision: saved, soreness: .none)
            XCTAssertThrowsError(try ProgrammeVolumeSource.effective(source, revision: saved, at: now))
            XCTAssertThrowsError(try planner.proposal(change: .restore, context: context, at: now, calendar: calendar))
            let proposed = try planner.proposal(change: .discardObsolete, context: context, at: now, calendar: calendar)
            XCTAssertNil(proposed.before)
            XCTAssertEqual(proposed.after.totalSetsPerRotation, 3)
            XCTAssertEqual(proposed.originalRevision, saved)
        }
        XCTAssertThrowsError(try planner.proposal(change: .discardObsolete,
            context: context(source, revision: revision(source), soreness: .none), at: now, calendar: calendar))
    }

    func testObsoleteRemovalStillRejectsConcernSymptomsAndActiveTraining() throws {
        let source = programme([plan(sets: 3)])
        let old = try revision(source, baseline: String(repeating: "a", count: 64))
        for context in [try context(source, revision: old), try context(source, revision: old, soreness: .none, pain: true),
                        try context(source, revision: old, soreness: .none, active: true)] {
            XCTAssertThrowsError(try planner.proposal(change: .discardObsolete, context: context, at: now, calendar: calendar))
        }
    }

    func testPainActiveUnknownAndResolvedRecoveryRejectReduction() throws {
        for context in [try context(base, pain: true), try context(base, active: true),
                        try context(base, soreness: .none), try context(base, hasReport: false)] {
            XCTAssertThrowsError(try planner.proposal(change: .ease, context: context, at: now, calendar: calendar))
        }
    }

    func testFutureRevisionRejectsAndFutureScheduleCannotCreateWeeklyAverage() throws {
        let source = programme([plan(sets: 3)])
        let future = try revision(source, at: now.addingTimeInterval(1))
        XCTAssertThrowsError(try ProgrammeVolumeSource.effective(source, revision: future, at: now))
        XCTAssertThrowsError(try planner.proposal(change: .restore, context: context(source, revision: future, soreness: .none), at: now, calendar: calendar))
        let futureSchedule = try WorkoutProgrammeSchedule(programme: source, weekdays: [2], confirmedAt: now.addingTimeInterval(1))
        let offered = try planner.proposal(change: .ease, context: context(source, schedule: futureSchedule), at: now, calendar: calendar)
        XCTAssertNil(offered.weeklyTrainingDays)
        XCTAssertEqual(offered.calendarEvidence, .observed(futureSchedule))
    }

    func testFreshAcceptanceBindsReportScheduleSourceAndOriginalRevision() throws {
        let source = programme([plan(sets: 3)], sessions: 3)
        let original = try context(source)
        let offered = try planner.proposal(change: .ease, context: original, at: now, calendar: calendar)
        let changed = programme([try mutate(source.exercisePlans[0], key: "coachingCue", value: "New cue")], sessions: 3)
        let schedule = try WorkoutProgrammeSchedule(programme: source, weekdays: [2, 5], confirmedAt: now)
        for context in [try context(changed), try context(source, schedule: schedule), try context(source, energy: .low),
                        try context(source, revision: revision(source))] {
            XCTAssertThrowsError(try planner.revalidated(offered, context: context, at: now, calendar: calendar))
        }
        XCTAssertEqual(try planner.revalidated(offered, context: original, at: now, calendar: calendar), offered)
    }

    func testExpiryClockRollbackDayAndTimeZoneInvalidateProposal() throws {
        let original = try context(base)
        let offered = try planner.proposal(change: .ease, context: original, at: now, calendar: calendar)
        for stamp in [now.addingTimeInterval(601), now.addingTimeInterval(-1), now.addingTimeInterval(86_400)] {
            XCTAssertThrowsError(try planner.revalidated(offered, context: original, at: stamp, calendar: calendar))
        }
        var changed = calendar; changed.timeZone = TimeZone(identifier: "Europe/Sofia")!
        XCTAssertThrowsError(try planner.revalidated(offered, context: original, at: now, calendar: changed))
        let midnight = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let beforeMidnight = try context(base, at: midnight.addingTimeInterval(-30))
        let crossesDay = try planner.proposal(change: .ease, context: beforeMidnight, at: midnight.addingTimeInterval(-30), calendar: calendar)
        XCTAssertThrowsError(try planner.revalidated(crossesDay, context: context(base, at: midnight), at: midnight, calendar: calendar))
    }

    func testTamperedOutputAndPolicyCannotBeAccepted() throws {
        let context = try context(base)
        let offered = try planner.proposal(change: .ease, context: context, at: now, calendar: calendar)
        for bad in [replacing(offered, policy: "old"), replacing(offered, after: offered.before!), replacing(offered, weeklyTrainingDays: 7)] {
            XCTAssertThrowsError(try planner.revalidated(bad, context: context, at: now, calendar: calendar))
        }
    }

    func testAcknowledgedUserDefaultsReductionRelaunchAndDuplicatePrevention() throws {
        let name = "01.volume." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsProgrammeVolumeStore(defaults: defaults, key: "volume")
        let repository = ProgrammeVolumeRepository(store: store)
        let context = try context(base)
        let offered = try planner.proposal(change: .ease, context: context, at: now, calendar: calendar)
        XCTAssertEqual(try store.load(), .empty)
        try repository.accept(offered, context: context, at: now, calendar: calendar)
        let saved = try store.load()
        XCTAssertEqual(saved.revisions.count, 1)
        let relaunched = ProgrammeVolumeRepository(store: store)
        XCTAssertTrue(relaunched.reload(at: now))
        XCTAssertEqual(try relaunched.effective(base).exercisePlans.map(\.plannedSetCount), base.exercisePlans.map { max(1, $0.plannedSetCount - 1) })
        XCTAssertThrowsError(try relaunched.accept(offered, context: context, at: now, calendar: calendar))
        XCTAssertEqual(try store.load(), saved)
    }

    func testFreshReadFailureMarksRepositoryUnavailableWithoutWriting() throws {
        let store = VolumeTestStore()
        let repository = ProgrammeVolumeRepository(store: store)
        let context = try context(base)
        let offered = try planner.proposal(change: .ease, context: context, at: now, calendar: calendar)
        store.failRead = true
        XCTAssertThrowsError(try repository.accept(offered, context: context, at: now, calendar: calendar))
        XCTAssertFalse(repository.isAvailable)
        XCTAssertThrowsError(try repository.effective(base))
        XCTAssertEqual(store.writes, 0)
    }

    func testFailedReadbackKeepsUnknownStateAndRetryCannotAccumulateReduction() throws {
        let store = VolumeTestStore()
        let repository = ProgrammeVolumeRepository(store: store)
        let context = try context(base)
        let offered = try planner.proposal(change: .ease, context: context, at: now, calendar: calendar)
        store.failAfterSave = true
        XCTAssertThrowsError(try repository.accept(offered, context: context, at: now, calendar: calendar)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .saveNotConfirmed)
        }
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(store.stored.revisions.count, 1)
        store.failRead = false; store.failAfterSave = false
        XCTAssertTrue(repository.reload(at: now))
        XCTAssertThrowsError(try repository.accept(offered, context: context, at: now, calendar: calendar))
        XCTAssertEqual(store.writes, 1)
    }

    func testCorruptDuplicateFutureAndWrongTypeStorageNeverBecomeEmpty() throws {
        let source = try revision(base)
        let invalid = [ProgrammeVolumeSnapshot(version: 2, revisions: []), .init(version: 1, revisions: [source, source]),
                       .init(version: 1, revisions: [try revision(base, at: now.addingTimeInterval(1))])]
        let store = VolumeTestStore()
        for snapshot in invalid {
            store.stored = snapshot
            let repository = ProgrammeVolumeRepository(store: store)
            XCTAssertFalse(repository.reload(at: now))
            XCTAssertThrowsError(try repository.effective(base))
            XCTAssertEqual(store.stored, snapshot)
        }
        let name = "01.volume.corrupt." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("wrong type", forKey: "volume")
        XCTAssertThrowsError(try UserDefaultsProgrammeVolumeStore(defaults: defaults, key: "volume").load())
        defaults.set(Data("bad JSON".utf8), forKey: "volume")
        XCTAssertThrowsError(try UserDefaultsProgrammeVolumeStore(defaults: defaults, key: "volume").load())
    }

    func testObsoleteRemovalAcknowledgementPreservesOtherProgrammeRevision() throws {
        let store = VolumeTestStore()
        let obsolete = try revision(base, baseline: String(repeating: "a", count: 64))
        let other = WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)!
        let retained = try revision(other)
        store.stored = .init(version: 1, revisions: [obsolete, retained])
        let repository = ProgrammeVolumeRepository(store: store)
        XCTAssertTrue(repository.reload(at: now))
        let context = try context(base, revision: obsolete, soreness: .none)
        let offered = try planner.proposal(change: .discardObsolete, context: context, at: now, calendar: calendar)
        try repository.accept(offered, context: context, at: now, calendar: calendar)
        XCTAssertEqual(store.stored.revisions, [retained])
        XCTAssertEqual(try repository.effective(base), base)
    }

    func testAcceptedRestorationSurvivesReloadAndOldProposalCannotRestoreAgain() throws {
        let store = VolumeTestStore()
        let saved = try revision(base)
        store.stored = .init(version: 1, revisions: [saved])
        let repository = ProgrammeVolumeRepository(store: store)
        XCTAssertTrue(repository.reload(at: now))
        let context = try context(base, revision: saved, soreness: .none)
        let offered = try planner.proposal(change: .restore, context: context, at: now, calendar: calendar)
        try repository.accept(offered, context: context, at: now, calendar: calendar)
        XCTAssertEqual(store.stored, .empty)
        let relaunched = ProgrammeVolumeRepository(store: store)
        XCTAssertEqual(try relaunched.effective(base), base)
        XCTAssertThrowsError(try relaunched.accept(offered, context: context, at: now, calendar: calendar))
        XCTAssertEqual(store.writes, 1)
    }

    func testExpiredAssessmentSupersededPolicyAndInvalidStoredFingerprintReject() throws {
        let original = try context(base)
        for assessment in [WellbeingAssessment(recommendations: original.assessment.recommendations,
                recordedTrainingDays: 0, reviewedNutritionDays: 0, hasCurrentRecoveryReport: true,
                hasConflictingSleep: false, evaluatedAt: now.addingTimeInterval(-601), timeZoneID: calendar.timeZone.identifier),
            WellbeingAssessment(recommendations: original.assessment.recommendations.map {
                .init(kind: $0.kind, demand: $0.demand, evidence: $0.evidence, policyVersion: "wellbeing-v0", sourceReferences: $0.sourceReferences)
            }, recordedTrainingDays: 0, reviewedNutritionDays: 0, hasCurrentRecoveryReport: true,
                hasConflictingSleep: false, evaluatedAt: now, timeZoneID: calendar.timeZone.identifier)] {
            let source = ProgrammeVolumeContext(programme: base, revision: nil, calendarEvidence: original.calendarEvidence,
                assessment: assessment, recovery: original.recovery, hasUnfinishedWorkout: false)
            XCTAssertThrowsError(try planner.proposal(change: .ease, context: source, at: now, calendar: calendar))
        }
        let invalid = try revision(base, baseline: "not-a-fingerprint")
        let source = try context(base, revision: invalid, soreness: .none)
        XCTAssertThrowsError(try planner.proposal(change: .discardObsolete, context: source, at: now, calendar: calendar))
        XCTAssertFalse(ProgrammeVolumeSnapshot(version: 1, revisions: [invalid]).isValid(at: now))
    }

    func testFutureFactoriesCopyAndBookedSessionUseEffectiveCountsWithoutRewritingPerformedWork() throws {
        let effective = try ProgrammeVolumeSource.effective(base, revision: revision(base), at: now)
        let recordedPlan = base.exercisePlans[0]
        let existing = WorkoutSession(title: "Already performed", programmeID: base.id,
            exercises: [WorkoutExercise(plan: recordedPlan, completedSets: [CompletedSet(load: Load(8), reps: 10,
                completedAt: now.addingTimeInterval(-60), isPerSide: recordedPlan.targetPrescription?.perSide,
                executionTarget: WorkingSetExecutionTarget(plan: recordedPlan))])])
        let encoded = try JSONEncoder().encode(existing)
        let booked = WorkoutAppointment(reference: .programme(base.id, sessionID: base.sessions[1].id), title: "Booked", startsAt: now, timeZoneIdentifier: calendar.timeZone.identifier)
        let bookedBytes = try JSONEncoder().encode(booked)
        let future = effective.makeSession(sessionID: base.sessions[1].id, progressionAllowed: false, asOf: now)
        XCTAssertEqual(future.exercises.map { $0.plan.plannedSetCount }, base.sessions[1].exercisePlans.map { max(1, $0.plannedSetCount - 1) })
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: VolumeSelectionStore(), scheduleStore: VolumeScheduleStore())
        coordinator.showDetail(for: base.id)
        XCTAssertEqual(coordinator.startSelectedProgramme(effectiveProgramme: effective, progressionAllowed: false, asOf: now)?.totalPlannedSetCount, effective.totalSetCount)
        let preview = effective.makeSession(progressionAllowed: false, asOf: now)
        let copy = try ProgrammeSessionCustomization.makeCopy(programme: effective, previewSession: preview, warmUpLength: .full)
        XCTAssertEqual(copy.items.map(\.sets), effective.exercisePlans.map(\.plannedSetCount))
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: encoded), existing)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutAppointment.self, from: bookedBytes), booked)
        XCTAssertEqual(existing.exercises[0].plan.plannedSetCount, recordedPlan.plannedSetCount)
        XCTAssertEqual(existing.completedSetCount, 1)
    }

    func testVerifiedUnscheduledPresetCanReviewAndSaveSetsWithoutInventingFrequency() throws {
        let calendarStore = VolumeScheduleStore()
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: VolumeSelectionStore(), scheduleStore: calendarStore)
        coordinator.showDetail(for: base.id)
        let evidence = coordinator.programmeVolumeCalendarEvidence(at: now)
        XCTAssertEqual(evidence, .absent)
        let source = try context(base, calendarEvidence: evidence)
        let offered = try planner.proposal(change: .ease, context: source, at: now, calendar: calendar)
        XCTAssertNil(offered.weeklyTrainingDays)
        XCTAssertGreaterThan(try XCTUnwrap(offered.before).totalSetsPerRotation, offered.after.totalSetsPerRotation)
        let volume = ProgrammeVolumeRepository(store: VolumeTestStore())
        try volume.accept(offered, context: source, at: now, calendar: calendar)
        XCTAssertNotNil(try volume.revision(for: base.id))
        XCTAssertNil(calendarStore.stored)
        XCTAssertEqual(calendarStore.writes, 0)
    }

    func testOtherProgrammeCalendarRemainsKnownButCannotProvideSelectedWeeklyFrequency() throws {
        let calendarStore = VolumeScheduleStore()
        let other = WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)!
        let saved = try WorkoutProgrammeSchedule(programme: other, weekdays: [2, 4], confirmedAt: now)
        calendarStore.stored = saved
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: VolumeSelectionStore(), scheduleStore: calendarStore)
        coordinator.showDetail(for: base.id)
        let evidence = coordinator.programmeVolumeCalendarEvidence(at: now)
        let offered = try planner.proposal(change: .ease, context: context(base, calendarEvidence: evidence), at: now, calendar: calendar)
        XCTAssertEqual(offered.calendarEvidence, .observed(saved))
        XCTAssertNil(offered.weeklyTrainingDays)
        XCTAssertTrue(coordinator.scheduleIsAvailable)
        XCTAssertEqual(calendarStore.stored, saved)
        XCTAssertEqual(calendarStore.writes, 0)
    }

    func testSessionCountChangeCanRepairObsoleteVolumeWhileInvalidScheduleIsKept() throws {
        let old = programme([plan(sets: 3)], sessions: 3)
        let updated = programme([plan(sets: 3)], sessions: 1)
        let savedSchedule = try WorkoutProgrammeSchedule(programme: old, weekdays: [2, 4, 6], confirmedAt: now)
        let calendarStore = VolumeScheduleStore(); calendarStore.stored = savedSchedule
        let coordinator = WorkoutProgrammeCoordinator(programmes: WorkoutProgrammeLibrary.all.map { $0.id == updated.id ? updated : $0 },
            selectionStore: VolumeSelectionStore(), scheduleStore: calendarStore)
        coordinator.showDetail(for: updated.id)
        XCTAssertFalse(coordinator.reloadSchedule(at: now))
        let observation = coordinator.programmeVolumeCalendarEvidence(at: now)
        XCTAssertEqual(observation, .observed(savedSchedule))
        let savedRevision = try revision(old)
        let source = try context(updated, revision: savedRevision, soreness: .none, calendarEvidence: observation)
        let offered = try planner.proposal(change: .discardObsolete, context: source, at: now, calendar: calendar)
        XCTAssertNil(offered.before)
        XCTAssertNil(offered.weeklyTrainingDays)
        XCTAssertEqual(offered.after.totalSetsPerRotation, 3)
        let store = VolumeTestStore(); store.stored = .init(version: 1, revisions: [savedRevision])
        let volume = ProgrammeVolumeRepository(store: store)
        XCTAssertTrue(volume.reload(at: now))
        try volume.accept(offered, context: source, at: now, calendar: calendar)
        XCTAssertEqual(try volume.effective(updated), updated)
        XCTAssertEqual(calendarStore.stored, savedSchedule)
        XCTAssertEqual(calendarStore.writes, 0)
        XCTAssertFalse(coordinator.scheduleIsAvailable)
    }

    func testUnreadableCalendarAllowsIndependentSetReviewWithoutClearingOrRepairingIt() throws {
        let calendarStore = VolumeScheduleStore()
        let saved = try WorkoutProgrammeSchedule(programme: base, weekdays: [2, 4], confirmedAt: now)
        calendarStore.stored = saved; calendarStore.failRead = true
        let coordinator = WorkoutProgrammeCoordinator(selectionStore: VolumeSelectionStore(), scheduleStore: calendarStore)
        let evidence = coordinator.programmeVolumeCalendarEvidence(at: now)
        XCTAssertEqual(evidence, .unavailable)
        let source = try context(base, calendarEvidence: evidence)
        let offered = try planner.proposal(change: .ease, context: source, at: now, calendar: calendar)
        XCTAssertNil(offered.weeklyTrainingDays)
        let volume = ProgrammeVolumeRepository(store: VolumeTestStore())
        try volume.accept(offered, context: source, at: now, calendar: calendar)
        XCTAssertEqual(calendarStore.stored, saved)
        XCTAssertEqual(calendarStore.writes, 0)
        XCTAssertFalse(coordinator.scheduleIsAvailable)
    }

    func testCalendarAvailabilityIdentityAndWeekdaysAreBoundAtAcceptance() throws {
        let first = try WorkoutProgrammeSchedule(programme: base, weekdays: [2, 4], confirmedAt: now)
        let changed = try WorkoutProgrammeSchedule(programme: base, weekdays: [3, 5], confirmedAt: now)
        let other = try WorkoutProgrammeSchedule(programme: WorkoutProgrammeLibrary.programme(id: .zeroOneBuild)!, weekdays: [2, 4], confirmedAt: now)
        let values: [ProgrammeVolumeCalendarEvidence] = [.absent, .unavailable, .observed(first), .observed(changed), .observed(other)]
        for before in values {
            let original = try context(base, calendarEvidence: before)
            let offered = try planner.proposal(change: .ease, context: original, at: now, calendar: calendar)
            for after in values where after != before {
                XCTAssertThrowsError(try planner.revalidated(offered, context: context(base, calendarEvidence: after), at: now, calendar: calendar)) {
                    XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
                }
            }
        }
    }

    func testUnchangedCalendarRecordBecomingTimeValidRequiresFreshExposureReview() throws {
        let schedule = try WorkoutProgrammeSchedule(programme: base, weekdays: [2, 4], confirmedAt: now.addingTimeInterval(1))
        let original = try context(base, schedule: schedule)
        let offered = try planner.proposal(change: .ease, context: original, at: now, calendar: calendar)
        XCTAssertNil(offered.weeklyTrainingDays)
        XCTAssertThrowsError(try planner.revalidated(offered, context: original, at: now.addingTimeInterval(2), calendar: calendar)) {
            XCTAssertEqual($0 as? ProgrammeVolumeError, .stale)
        }
    }

    private func plan(id: ExerciseID = ExerciseIDs.gobletSquat, sets: Int) -> ExercisePlan {
        .init(exerciseID: id, name: "Goblet Squat", targetLoad: Load(10), targetReps: RepRange(8, 12), plannedSetCount: sets,
            restSeconds: 120, previousPerformance: [.init(load: Load(8), reps: 10)], sourcePrescription: "8-12 reps",
            coachingCue: "Control the movement", painGuardrail: "Stop for pain", equipmentIdentifiers: ["dumbbell"],
            alternativeExerciseIDs: [ExerciseIDs.legPress], unresolvedAlternativeNames: ["Unresolved"],
            targetPrescription: .init(unit: .repetitions, lowerBound: 8, upperBound: 12))
    }
    private func programme(_ plans: [ExercisePlan], sessions: Int = 1) -> WorkoutProgramme {
        .init(id: base.id, title: base.title, summary: base.summary, durationMinutes: base.durationMinutes,
            equipmentContext: base.equipmentContext, experienceBand: base.experienceBand, goalSupport: base.goalSupport,
            schedule: base.schedule, durationWeeks: base.durationWeeks, rules: base.rules, evidenceReferenceKeys: base.evidenceReferenceKeys,
            sessions: (0..<sessions).map { .init(id: "session-\($0)", title: "Session \($0)", exercisePlans: plans) })
    }
    private func revision(_ source: WorkoutProgramme, baseline: String? = nil, policy: String = ProgrammeVolumePlanner.policyVersion,
                          at stamp: Date? = nil) throws -> ProgrammeVolumeRevision {
        .init(programmeID: source.id, baseline: try baseline ?? ProgrammeVolumeSource.fingerprint(source), policyVersion: policy, acceptedAt: stamp ?? now)
    }
    private func context(_ source: WorkoutProgramme, revision: ProgrammeVolumeRevision? = nil,
                         soreness: RecoverySoreness = .severe, pain: Bool? = false, hungry: Bool? = false,
                         energy: RecoveryEnergy = .usual, active: Bool = false, hasReport: Bool = true,
                         schedule: WorkoutProgrammeSchedule? = nil, calendarEvidence: ProgrammeVolumeCalendarEvidence? = nil,
                         at stamp: Date? = nil) throws -> ProgrammeVolumeContext {
        let stamp = stamp ?? now
        let report = RecoveryCheckIn(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            day: calendar.startOfDay(for: stamp), timeZoneID: calendar.timeZone.identifier, reportedAt: stamp,
            energy: energy, soreness: soreness, sleepHours: nil, hasNewOrWorseningPain: pain,
            feelsUnwell: false, feelsUnusuallyHungry: hungry, feelsThirsty: false)
        let assessment = WellbeingRecommendationEngine().assess(.init(asOf: stamp, calendar: calendar,
            strengthHistory: [], outdoorHistory: [], recoveryCheckIns: hasReport ? [report] : [], meals: [], nutritionReviews: [],
            chosenFoodGoal: nil, hydration: nil, healthSleep: nil))
        let days: Set<Int> = source.sessions.count == 1 ? [2] : [2, 4, 6]
        let evidence = try calendarEvidence ?? .observed(schedule ?? WorkoutProgrammeSchedule(programme: source, weekdays: days, confirmedAt: stamp))
        return .init(programme: source, revision: revision, calendarEvidence: evidence,
            assessment: assessment, recovery: hasReport ? report : nil, hasUnfinishedWorkout: active)
    }
    private func object(_ plan: ExercisePlan) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    }
    private func mutate(_ plan: ExercisePlan, key: String, value: Any?) throws -> ExercisePlan {
        var object = try object(plan); object[key] = value
        return try JSONDecoder().decode(ExercisePlan.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func replacing(_ proposal: ProgrammeVolumeProposal, policy: String? = nil, after: ProgrammeVolumeSummary? = nil,
                           weeklyTrainingDays: Int? = nil) -> ProgrammeVolumeProposal {
        .init(policyVersion: policy ?? proposal.policyVersion, change: proposal.change, baseline: proposal.baseline,
            originalRevision: proposal.originalRevision, calendarEvidence: proposal.calendarEvidence,
            weeklyTrainingDays: weeklyTrainingDays ?? proposal.weeklyTrainingDays, concerns: proposal.concerns,
            recovery: proposal.recovery, offeredAt: proposal.offeredAt, timeZoneID: proposal.timeZoneID,
            before: proposal.before, after: after ?? proposal.after)
    }
}

private final class VolumeTestStore: ProgrammeVolumePersisting {
    var stored = ProgrammeVolumeSnapshot.empty
    var failRead = false
    var failAfterSave = false
    private(set) var writes = 0
    func load() throws -> ProgrammeVolumeSnapshot {
        if failRead { throw ProgrammeVolumeError.unavailable }; return stored
    }
    func save(_ snapshot: ProgrammeVolumeSnapshot) throws {
        stored = snapshot; writes += 1
        if failAfterSave { failRead = true }
    }
}

private final class VolumeSelectionStore: WorkoutProgrammeSelectionPersisting {
    var selected: WorkoutProgrammeID?
    func loadSelectedID() -> WorkoutProgrammeID? { selected }
    func saveSelectedID(_ id: WorkoutProgrammeID) { selected = id }
}

private final class VolumeScheduleStore: WorkoutProgrammeSchedulePersisting {
    var stored: WorkoutProgrammeSchedule?
    var failRead = false
    private(set) var writes = 0
    func load() throws -> WorkoutProgrammeSchedule? {
        if failRead { throw WorkoutProgrammeScheduleError.unavailable }
        return stored
    }
    func save(_ schedule: WorkoutProgrammeSchedule) throws { stored = schedule; writes += 1 }
}
