import CryptoKit
import Foundation

enum ProgrammeVolumeChange: String, CaseIterable {
    case ease, restore, discardObsolete
    var titleKey: String {
        switch self {
        case .ease: "Fewer sets in future programme sessions"
        case .restore: "Return to the authored set counts"
        case .discardObsolete: "Review removal of an obsolete set adjustment"
        }
    }
}

enum ProgrammeVolumeError: Error, Equatable {
    case unavailable, active, symptoms, noConcern, noChange, stale, sourceChanged, saveNotConfirmed
    var messageKey: String {
        switch self {
        case .unavailable: "Current programme volume and recovery records could not be verified. Reopen this review."
        case .active: "Finish or leave active training before changing future programme sets."
        case .symptoms: "Review reported pain or illness before changing future programme sets."
        case .noConcern: "The current check-in does not support this programme option. Your saved plan is kept."
        case .noChange: "This programme has no supported set-count change for that option."
        case .stale: "The programme, saved change, schedule or check-in changed. Review a fresh option."
        case .saveNotConfirmed: "The saved programme may have changed, but storage could not confirm it. Close and reopen this review before trying again."
        case .sourceChanged: "The authored programme changed. Review the saved set adjustment before starting it."
        }
    }
}

/// A single accepted reduction per programme, rather than an accumulating delta.
/// Positions disambiguate repeated exercises; runtime occurrence UUIDs are excluded.
struct ProgrammeVolumeRevision: Codable, Equatable {
    let programmeID: WorkoutProgrammeID
    let baseline: String
    let policyVersion: String
    let acceptedAt: Date
    var isValid: Bool {
        !policyVersion.isEmpty && policyVersion.count <= 100 && baseline.count == 64
            && baseline.allSatisfy { $0.isHexDigit }
            && acceptedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

struct ProgrammeVolumeRow: Equatable {
    let muscle: String
    let primarySets: Int
    let supportingSets: Int
}

struct ProgrammeVolumeSummary: Equatable {
    let sessionCount: Int
    let totalSetsPerRotation: Int
    let rows: [ProgrammeVolumeRow]
    let unclassifiedSets: Int
    let conditioningSets: Int
    /// Long-run average across the full rotation, not a dated workout forecast.
    func weeklyAverage(_ sets: Int, days: Int) -> Double {
        Double(sets) * Double(days) / Double(sessionCount)
    }
}

enum ProgrammeVolumeSource {
    private struct Occurrence: Encodable {
        let exercise: ExerciseID
        let name: String
        let load: Load
        let target: WorkingSetPrescription?
        let reps: RepRange
        let sets: Int
        let rest: Double
        let source: String?
        let equipment: [String]
        let alternatives: [ExerciseID]
        let unresolvedAlternatives: [String]
        let coachingCue: String?
        let painGuardrail: String?
    }
    private struct Session: Encodable { let id: String; let title: String; let occurrences: [Occurrence] }
    private struct Baseline: Encodable { let programme: WorkoutProgrammeID; let duration: Int; let sessions: [Session] }

    static func sessionFingerprint(programmeID: WorkoutProgrammeID, session: WorkoutProgrammeSession) throws -> String {
        guard !session.id.isEmpty, (1...50).contains(session.exercisePlans.count), session.exercisePlans.allSatisfy({
            (1...100).contains($0.plannedSetCount) && $0.prescription.isValid && $0.targetLoad.value.isFinite
                && $0.targetLoad.value >= 0 && $0.restSeconds.isFinite && (0...3_600).contains($0.restSeconds)
        }) else { throw ProgrammeVolumeError.unavailable }
        let value = Baseline(programme: programmeID, duration: 0, sessions: [.init(id: session.id, title: session.title,
            occurrences: session.exercisePlans.map {
                .init(exercise: $0.exerciseID, name: $0.name, load: $0.targetLoad, target: $0.targetPrescription, reps: $0.targetReps,
                    sets: $0.plannedSetCount, rest: $0.restSeconds, source: $0.sourcePrescription,
                    equipment: $0.equipmentIdentifiers, alternatives: $0.alternativeExerciseIDs,
                    unresolvedAlternatives: $0.unresolvedAlternativeNames, coachingCue: $0.coachingCue, painGuardrail: $0.painGuardrail)
            })])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ programme: WorkoutProgramme) throws -> String {
        guard !programme.sessions.isEmpty, programme.sessions.count <= 30,
              Set(programme.sessions.map(\.id)).count == programme.sessions.count,
              programme.sessions.allSatisfy({ !$0.exercisePlans.isEmpty && $0.exercisePlans.count <= 50
                  && $0.exercisePlans.allSatisfy { (1 ... 100).contains($0.plannedSetCount)
                      && $0.targetReps.lowerBound > 0 && $0.targetReps.upperBound >= $0.targetReps.lowerBound
                      && $0.targetReps.upperBound <= 86_400
                      && $0.prescription.isValid && $0.restSeconds.isFinite && (0 ... 3_600).contains($0.restSeconds)
                      && $0.targetLoad.value.isFinite && $0.targetLoad.value >= 0 } }) else {
            throw ProgrammeVolumeError.unavailable
        }
        let value = Baseline(programme: programme.id, duration: programme.durationMinutes,
            sessions: programme.sessions.map { .init(id: $0.id, title: $0.title, occurrences: $0.exercisePlans.map {
                .init(exercise: $0.exerciseID, name: $0.name, load: $0.targetLoad, target: $0.targetPrescription, reps: $0.targetReps,
                    sets: $0.plannedSetCount, rest: $0.restSeconds, source: $0.sourcePrescription,
                    equipment: $0.equipmentIdentifiers, alternatives: $0.alternativeExerciseIDs,
                    unresolvedAlternatives: $0.unresolvedAlternativeNames, coachingCue: $0.coachingCue, painGuardrail: $0.painGuardrail)
            }) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func effective(_ programme: WorkoutProgramme, revision: ProgrammeVolumeRevision?, at now: Date = .now) throws -> WorkoutProgramme {
        let baseline = try fingerprint(programme)
        guard let revision else { return programme }
        guard now.timeIntervalSinceReferenceDate.isFinite, revision.isValid, revision.acceptedAt <= now else {
            throw ProgrammeVolumeError.unavailable
        }
        guard revision.policyVersion == ProgrammeVolumePlanner.policyVersion,
              revision.programmeID == programme.id, revision.baseline == baseline else {
            throw ProgrammeVolumeError.sourceChanged
        }
        return .init(id: programme.id, title: programme.title, summary: programme.summary,
            durationMinutes: programme.durationMinutes, equipmentContext: programme.equipmentContext,
            experienceBand: programme.experienceBand, goalSupport: programme.goalSupport, schedule: programme.schedule,
            durationWeeks: programme.durationWeeks, rules: programme.rules, evidenceReferenceKeys: programme.evidenceReferenceKeys,
            sessions: programme.sessions.map { .init(id: $0.id, title: $0.title,
                exercisePlans: $0.exercisePlans.map { $0.withPlannedSets(max(1, $0.plannedSetCount - 1)) }) },
            authoredSourceFingerprint: programme.authoredSourceFingerprint ?? baseline)
    }

    static func summary(_ programme: WorkoutProgramme) throws -> ProgrammeVolumeSummary {
        _ = try fingerprint(programme)
        var primary: [String: Int] = [:]; var supporting: [String: Int] = [:]
        var unknown = 0; var conditioning = 0; var total = 0
        for plan in programme.sessions.flatMap(\.exercisePlans) {
            total += plan.plannedSetCount
            guard let definition = ExerciseLibrary.exercise(id: plan.exerciseID) else {
                unknown += plan.plannedSetCount; continue
            }
            if definition.movementPattern == .lowImpactConditioning { conditioning += plan.plannedSetCount; continue }
            guard !definition.primaryMuscleNames.isEmpty else { unknown += plan.plannedSetCount; continue }
            let major = Set(definition.primaryMuscleNames)
            for name in major { primary[name, default: 0] += plan.plannedSetCount }
            for name in Set(definition.secondaryMuscleNames).subtracting(major) { supporting[name, default: 0] += plan.plannedSetCount }
        }
        let rows = Set(primary.keys).union(supporting.keys).sorted().map {
            ProgrammeVolumeRow(muscle: $0, primarySets: primary[$0, default: 0], supportingSets: supporting[$0, default: 0])
        }
        return .init(sessionCount: programme.sessions.count, totalSetsPerRotation: total, rows: rows, unclassifiedSets: unknown, conditioningSets: conditioning)
    }
}

extension ExercisePlan {
    func withPlannedSets(_ count: Int) -> ExercisePlan {
        .init(id: id, exerciseID: exerciseID, name: name, targetLoad: targetLoad, targetReps: targetReps,
            plannedSetCount: count, restSeconds: restSeconds, previousPerformance: previousPerformance,
            sourcePrescription: sourcePrescription, coachingCue: coachingCue, painGuardrail: painGuardrail,
            equipmentIdentifiers: equipmentIdentifiers, alternativeExerciseIDs: alternativeExerciseIDs,
            unresolvedAlternativeNames: unresolvedAlternativeNames, targetPrescription: targetPrescription)
    }
}

/// Calendar evidence is optional context for weekly averages, never authority to
/// alter a schedule. Keep readable but invalid/other-programme records exact.
enum ProgrammeVolumeCalendarEvidence: Equatable {
    case absent
    case observed(WorkoutProgrammeSchedule)
    case unavailable

    func weeklyDays(for programme: WorkoutProgramme, at now: Date) -> Int? {
        guard case let .observed(schedule) = self,
              now.timeIntervalSinceReferenceDate.isFinite,
              schedule.isValid(for: programme), schedule.confirmedAt <= now else { return nil }
        return schedule.weekdays.count
    }
}

struct ProgrammeVolumeContext {
    let programme: WorkoutProgramme
    let revision: ProgrammeVolumeRevision?
    let calendarEvidence: ProgrammeVolumeCalendarEvidence
    let assessment: WellbeingAssessment
    let recovery: RecoveryCheckIn?
    let hasUnfinishedWorkout: Bool
    // Live host supplies a fresh source projection; older independent fixtures
    // may omit it. This is not authority to apply richer planning changes.
    var planningObservation: ProgrammePlanningObservation? = nil
}

struct ProgrammeVolumeProposal: Equatable {
    let policyVersion: String
    let change: ProgrammeVolumeChange
    let baseline: String
    let originalRevision: ProgrammeVolumeRevision?
    let calendarEvidence: ProgrammeVolumeCalendarEvidence
    let weeklyTrainingDays: Int?
    let concerns: [WellbeingRecommendation]
    var energyTargetSource: String? = nil
    var planningSource: String? = nil
    let recovery: RecoveryCheckIn
    let offeredAt: Date
    let timeZoneID: String
    /// Nil only for explicit obsolete-source removal: old counts cannot be reconstructed.
    let before: ProgrammeVolumeSummary?
    let after: ProgrammeVolumeSummary
}

struct ProgrammeVolumePlanner {
    static let policyVersion = "future-programme-sets-v1"
    func proposal(change: ProgrammeVolumeChange, context: ProgrammeVolumeContext, at now: Date,
                  calendar: Calendar = .current) throws -> ProgrammeVolumeProposal {
        guard !context.hasUnfinishedWorkout else { throw ProgrammeVolumeError.active }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              context.revision.map({ $0.isValid && $0.programmeID == context.programme.id && $0.acceptedAt <= now }) ?? true,
              context.assessment.isCurrent(at: now, calendar: calendar), context.assessment.hasCurrentRecoveryReport,
              context.assessment.unavailableSources.isEmpty,
              context.assessment.energyTargetReview?.hasBoundSource ?? true,
              context.assessment.recommendations.allSatisfy({ $0.policyVersion == WellbeingRecommendationEngine.policyVersion }),
              let recovery = context.recovery, recovery.isCurrent(at: now, calendar: calendar) else { throw ProgrammeVolumeError.unavailable }
        guard !context.assessment.recommendations.contains(where: { $0.kind == .symptoms || $0.demand == .pauseForSymptoms }),
              recovery.hasNewOrWorseningPain != true, recovery.feelsUnwell != true else { throw ProgrammeVolumeError.symptoms }
        let baseline = try ProgrammeVolumeSource.fingerprint(context.programme)
        let concerns = context.assessment.recommendations.filter { $0.demand == .easeTraining && ($0.kind == .recovery || $0.kind == .fuelling) }
        let before: WorkoutProgramme?
        let after: WorkoutProgramme
        switch change {
        case .ease:
            guard !concerns.isEmpty else { throw ProgrammeVolumeError.noConcern }
            guard context.revision == nil else { throw ProgrammeVolumeError.noChange }
            before = context.programme
            after = try ProgrammeVolumeSource.effective(context.programme, revision: .init(programmeID: context.programme.id, baseline: baseline,
                policyVersion: Self.policyVersion, acceptedAt: now), at: now)
        case .restore, .discardObsolete:
            guard let revision = context.revision else { throw ProgrammeVolumeError.noChange }
            guard !context.assessment.holdsAutomaticProgression, concerns.isEmpty,
                  recovery.hasNewOrWorseningPain == false, recovery.feelsUnwell == false,
                  recovery.feelsUnusuallyHungry == false, recovery.energy == .usual || recovery.energy == .high,
                  recovery.soreness == .none || recovery.soreness == .mild else { throw ProgrammeVolumeError.noConcern }
            if change == .discardObsolete {
                guard revision.baseline != baseline || revision.policyVersion != Self.policyVersion else { throw ProgrammeVolumeError.noChange }
                before = nil
            } else {
                before = try ProgrammeVolumeSource.effective(context.programme, revision: revision, at: now)
            }
            after = context.programme
        }
        let prior = try before.map { try ProgrammeVolumeSource.summary($0) }; let next = try ProgrammeVolumeSource.summary(after)
        guard prior == nil || prior?.totalSetsPerRotation != next.totalSetsPerRotation else { throw ProgrammeVolumeError.noChange }
        return .init(policyVersion: Self.policyVersion, change: change, baseline: baseline, originalRevision: context.revision,
            calendarEvidence: context.calendarEvidence, weeklyTrainingDays: context.calendarEvidence.weeklyDays(for: context.programme, at: now),
            concerns: concerns, energyTargetSource: context.assessment.energyTargetReview?.sourceFingerprint,
            planningSource: context.planningObservation?.sourceFingerprint,
            recovery: recovery, offeredAt: now, timeZoneID: calendar.timeZone.identifier, before: prior, after: next)
    }
    func revalidated(_ presented: ProgrammeVolumeProposal, context: ProgrammeVolumeContext, at now: Date,
                     calendar: Calendar = .current) throws -> ProgrammeVolumeProposal {
        guard presented.policyVersion == Self.policyVersion, presented.offeredAt.timeIntervalSinceReferenceDate.isFinite, presented.offeredAt <= now,
              now.timeIntervalSince(presented.offeredAt) <= 600, presented.timeZoneID == calendar.timeZone.identifier,
              calendar.isDate(presented.offeredAt, inSameDayAs: now) else { throw ProgrammeVolumeError.stale }
        let fresh = try proposal(change: presented.change, context: context, at: now, calendar: calendar)
        guard fresh.baseline == presented.baseline, fresh.originalRevision == presented.originalRevision,
              fresh.calendarEvidence == presented.calendarEvidence, fresh.weeklyTrainingDays == presented.weeklyTrainingDays,
              fresh.concerns == presented.concerns, fresh.recovery == presented.recovery,
              fresh.energyTargetSource == presented.energyTargetSource,
              fresh.planningSource == presented.planningSource,
              fresh.before == presented.before, fresh.after == presented.after else { throw ProgrammeVolumeError.stale }
        return fresh
    }
}
