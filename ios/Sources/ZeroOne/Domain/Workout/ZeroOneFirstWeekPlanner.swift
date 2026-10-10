import Foundation
import CryptoKit

enum ZeroOneFirstWeekReasonKind: String, Codable, CaseIterable, Sendable {
    case goal, experience, days, equipment, sessionLength, limitations

    var title: String {
        switch self {
        case .goal: "Goal"
        case .experience: "Experience"
        case .days: "Days"
        case .equipment: "Equipment"
        case .sessionLength: "Session length"
        case .limitations: "Movement exclusions"
        }
    }
}

struct ZeroOneFirstWeekReason: Codable, Equatable, Sendable {
    let kind: ZeroOneFirstWeekReasonKind
    let answer: String
    let explanation: String
}

struct ZeroOneFirstWeekSession: Codable, Equatable, Sendable {
    let name: String
    let videoIDs: [String]
}

struct ZeroOneFirstWeekSelectionReport: Codable, Equatable, Sendable {
    let policyVersion: String
    let alternative: Int
    let selections: [StarterExerciseSelection]

    var issues: [StarterSelectionIssue] {
        selections.flatMap(\.issues).reduce(into: []) { result, issue in
            if !result.contains(issue) { result.append(issue) }
        }
    }
}

enum ZeroOneFirstWeekRecommendation: Equatable, Sendable {
    case plan(ZeroOneFirstWeekPlan)
    case needsMovementReview
    case catalogueOrConstraintsIncomplete
    case timeNeedsReview

    var plan: ZeroOneFirstWeekPlan? {
        if case let .plan(value) = self { return value }
        return nil
    }

    var messageKey: String {
        switch self {
        case .plan: "Review your starter sessions."
        case .needsMovementReview: "Choose the movements to exclude before 01 makes a draft. These exclusions do not assess an injury."
        case .catalogueOrConstraintsIncomplete: "There are not enough supported exercises for these answers. Review equipment and movement exclusions; 01 will not invent a substitute."
        case .timeNeedsReview: "This draft needs more time while keeping its rest periods. Review session length or create a shorter session."
        }
    }
}

/// A local, rule-based proposal. Saving it as real workouts is a separate,
/// acknowledged action; merely viewing this value never changes training data.
struct ZeroOneFirstWeekPlan: Codable, Equatable, Sendable {
    let title: String
    let focus: String
    let availableDays: [ZeroOneTrainingDay]
    let trainingDays: [ZeroOneTrainingDay]
    let preferredMinutes: Int
    let sessions: [ZeroOneFirstWeekSession]
    var reasons: [ZeroOneFirstWeekReason]
    var workingSets: Int
    let targetReps: Int
    let restSeconds: Int
    /// Optional for older saved plans. Never synthesize a current selection review.
    var selectionReport: ZeroOneFirstWeekSelectionReport? = nil

    func makeCustomWorkouts(ids: [UUID], weightUnit: LoadUnit) -> [CustomWorkout]? {
        guard ids.count == sessions.count, Set(ids).count == ids.count else { return nil }
        return zip(ids, sessions).map { pair in
            let id = pair.0
            let session = pair.1
            return CustomWorkout(
                id: id,
                name: session.name,
                items: session.videoIDs.enumerated().map { index, videoID in
                    CustomWorkoutItem(
                        id: stableOccurrenceID(workoutID: id, index: index, videoID: videoID),
                        videoID: videoID,
                        sets: workingSets,
                        reps: targetReps,
                        restSeconds: restSeconds,
                        targetLoad: 0,
                        loadUnit: weightUnit,
                        perSide: selectionReport == nil ? nil
                            : StarterExerciseSelector.catalogue.first { $0.videoID == videoID }?.perSide
                    )
                }
            )
        }
    }

    var maximumEstimatedMinutes: Int? {
        guard let workouts = makeCustomWorkouts(ids: sessions.map { _ in UUID() }, weightUnit: .kilograms) else { return nil }
        let estimates = workouts.compactMap { workout -> Int? in
            guard let session = workout.makeSession(), let estimate = WorkoutTimeEstimator().estimate(for: session) else { return nil }
            return estimate.maximumMinutes
        }
        return estimates.count == sessions.count ? estimates.max() : nil
    }

    private func stableOccurrenceID(workoutID: UUID, index: Int, videoID: String) -> UUID {
        // Same acknowledged workout and ordered movement yields the same occurrence
        // on a retry. Different workouts never share an occurrence identity.
        var bytes = Array(SHA256.hash(data: Data("01-starter-occurrence-v1|\(workoutID.uuidString)|\(index)|\(videoID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct ZeroOneSavedFirstWeekPlan: Codable, Equatable, Sendable {
    let plan: ZeroOneFirstWeekPlan
    let workoutIDs: [UUID]
    let savedAt: Date

    /// On a rest day the next scheduled session is offered without pretending
    /// that today was one of the days selected during onboarding.
    func nextWorkoutID(on date: Date, calendar: Calendar = .current) -> UUID? {
        guard workoutIDs.count == plan.sessions.count,
              !workoutIDs.isEmpty, !plan.trainingDays.isEmpty else { return nil }
        guard let nextIndex = nextTrainingDayIndex(on: date, calendar: calendar) else { return nil }
        let firstIndex = nextTrainingDayIndex(on: savedAt, calendar: calendar) ?? 0
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        guard let firstWeek = mondayCalendar.dateInterval(of: .weekOfYear, for: savedAt)?.start,
              let currentWeek = mondayCalendar.dateInterval(of: .weekOfYear, for: date)?.start else {
            return workoutIDs[nextIndex % workoutIDs.count]
        }
        let elapsedWeeks = (mondayCalendar.dateComponents([.day], from: firstWeek, to: currentWeek).day ?? 0) / 7
        let savedWeekday = (calendar.component(.weekday, from: savedAt) + 5) % 7
        let currentWeekday = (calendar.component(.weekday, from: date) + 5) % 7
        let firstWeekOffset = plan.trainingDays[firstIndex].rawValue < savedWeekday ? 1 : 0
        let nextWeekOffset = plan.trainingDays[nextIndex].rawValue < currentWeekday ? 1 : 0
        let ordinal = max(0, (elapsedWeeks + nextWeekOffset - firstWeekOffset) * plan.trainingDays.count
            + nextIndex - firstIndex)
        return workoutIDs[ordinal % workoutIDs.count]
    }

    func nextTrainingDay(on date: Date, calendar: Calendar = .current) -> ZeroOneTrainingDay? {
        guard let index = nextTrainingDayIndex(on: date, calendar: calendar) else { return nil }
        return plan.trainingDays[index]
    }

    private func nextTrainingDayIndex(on date: Date, calendar: Calendar) -> Int? {
        guard !plan.trainingDays.isEmpty else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        let today = (weekday + 5) % 7 // Calendar: Sunday=1; plan: Monday=0.
        return plan.trainingDays.firstIndex { $0.rawValue >= today } ?? 0
    }
}

enum ZeroOneFirstWeekPlanner {
    /// The authored movement IDs are checked against the bundled video catalog
    /// before a proposal is shown. A missing clip never becomes an invisible
    /// exercise or an invented demonstration.
    static func recommend(
        for profile: ZeroOneUserProfile,
        availableVideoIDs: Set<String>,
        alternative: Int = 0
    ) -> ZeroOneFirstWeekPlan? {
        assess(for: profile, availableVideoIDs: availableVideoIDs, alternative: alternative).plan
    }

    static func assess(
        for profile: ZeroOneUserProfile,
        availableVideoIDs: Set<String>, alternative: Int = 0
    ) -> ZeroOneFirstWeekRecommendation {
        let preferences = profile.starterSelectionPreferences ?? StarterSelectionPreferences()
        if profile.trainingConstraint == .movementSensitivity,
           preferences.blockedGroups.isEmpty, preferences.blockedExerciseIDs.isEmpty { return .needsMovementReview }
        let equipment = profile.availableEquipment ?? [.none]
        let modalities = matchingModalities(equipment)
        let start = ((alternative % modalities.count) + modalities.count) % modalities.count
        let order = Array(modalities[start...]) + Array(modalities[..<start])
        let preferredMinutes = [30, 45, 60, 75].contains(profile.preferredSessionMinutes ?? 45)
            ? (profile.preferredSessionMinutes ?? 45) : 45
        let exerciseCount = preferredMinutes <= 30 ? 4 : preferredMinutes <= 45 ? 5 : 6
        let novice = profile.trainingExperience == nil || profile.trainingExperience == .notSure
            || profile.trainingExperience == .startingOut || profile.trainingExperience == .returning

        var selections: [StarterExerciseSelection] = []
        for modality in order {
            let proposed = modality.sessions(for: novice).compactMap { session in
                StarterExerciseSelector.select(preferred: session, profile: profile,
                    availableVideoIDs: availableVideoIDs, count: exerciseCount)
            }
            if proposed.count == 2 { selections = proposed; break }
        }
        guard selections.count == 2 else { return .catalogueOrConstraintsIncomplete }

        let requested = (profile.preferredTrainingDays.flatMap { $0.isEmpty ? nil : $0 }
            ?? Set([.monday, .wednesday, .friday]))
            .sorted { $0.rawValue < $1.rawValue }
        // These are the person's selected training days. Do not silently replace
        // them with a smaller, spread-out schedule when making the first draft.
        let trainingDays = requested
        let sessions = selections.enumerated().map { index, selection in
            ZeroOneFirstWeekSession(
                name: "Foundation \(index == 0 ? "A" : "B")",
                videoIDs: selection.videoIDs
            )
        }
        let goal = profile.trainingGoal
        let focus: String
        switch goal {
        case .buildStrength: focus = "Strength foundation"
        case .buildMuscle: focus = "Muscle foundation"
        case .generalFitness: focus = "General fitness"
        case .sportPerformance: focus = "Athletic foundation"
        case .moveBetter: focus = "Movement foundation"
        case .manageBodyWeight: focus = "Strength foundation"
        case .notSure, nil: focus = "Foundations"
        }
        let sets = novice || preferredMinutes <= 30 ? 2 : (preferredMinutes >= 75 ? 4 : 3)
        let reps = goal == .buildStrength && !novice ? 8 : 10
        // Time preference changes volume, never shortens recovery between sets.
        let rest = 120
        let equipmentWasSet = profile.availableEquipment?.isEmpty == false
        let equipmentAnswer = equipmentWasSet ? (profile.equipmentDescription ?? "Not set") : "Not set"
        let daysAnswer = profile.preferredTrainingDays?.isEmpty != false
            ? "Suggested Monday, Wednesday, Friday"
            : requested.map(\.shortTitle).joined(separator: ", ")

        let hasAdjacentDays = trainingDays.contains { day in
            trainingDays.contains { $0.rawValue == (day.rawValue + 1) % 7 }
        }
        if hasAdjacentDays {
            selections = selections.map { .init(videoIDs: $0.videoIDs, exerciseIDs: $0.exerciseIDs,
                groups: $0.groups, issues: $0.issues + [.closeTrainingDays]) }
        }
        var plan = ZeroOneFirstWeekPlan(
            title: "Starter sessions",
            focus: focus,
            availableDays: requested,
            trainingDays: trainingDays,
            preferredMinutes: preferredMinutes,
            sessions: sessions,
            reasons: [
                ZeroOneFirstWeekReason(kind: .goal, answer: goal?.title ?? "Not set",
                    explanation: goal == .sportPerformance
                        ? "A general strength base to begin with, not a sport-specific programme."
                        : goal == .manageBodyWeight
                        ? "Strength to begin with. No scale target or calorie prescription is inferred."
                        : "Sets the emphasis of this first week; adjust after real sessions."),
                ZeroOneFirstWeekReason(kind: .experience, answer: profile.trainingExperience?.title ?? "Not set",
                    explanation: novice ? "Starts with two working sets and room to learn the movements."
                        : "Starts with \(sets) working sets; use your own comfortable loads."),
                ZeroOneFirstWeekReason(kind: .days, answer: daysAnswer,
                    explanation: "One session on each selected training day. You can change these days before saving."),
                ZeroOneFirstWeekReason(kind: .equipment, answer: equipmentAnswer,
                    explanation: equipmentWasSet
                        ? "Every exercise in this draft has a bundled demonstration and fits the selected kit."
                        : "Equipment was not set, so this first draft uses bodyweight movements with bundled demonstrations."),
                ZeroOneFirstWeekReason(kind: .sessionLength, answer: "\(preferredMinutes) min available",
                    explanation: "Volume follows your time preference; rest stays at two minutes. Review the estimate before starting."),
                ZeroOneFirstWeekReason(kind: .limitations, answer: preferences.blockedGroups.isEmpty
                    && preferences.blockedExerciseIDs.isEmpty ? "No exclusions reported" : "Reported exclusions applied",
                    explanation: "Reported movement and exercise exclusions are checked before preferences. No injury assessment is inferred.")
            ],
            workingSets: sets,
            targetReps: reps,
            restSeconds: rest,
            selectionReport: .init(policyVersion: StarterExerciseSelector.policyVersion,
                alternative: alternative, selections: selections)
        )
        while plan.workingSets > 2, (plan.maximumEstimatedMinutes ?? Int.max) > preferredMinutes {
            plan.workingSets -= 1
        }
        if !novice, let index = plan.reasons.firstIndex(where: { $0.kind == .experience }) {
            plan.reasons[index] = .init(kind: .experience, answer: profile.trainingExperience?.title ?? "Not set",
                explanation: "Starts with \(plan.workingSets) working sets; use your own comfortable loads.")
        }
        guard let maximumMinutes = plan.maximumEstimatedMinutes, maximumMinutes <= preferredMinutes else { return .timeNeedsReview }
        return .plan(plan)
    }

    static func isCurrent(_ plan: ZeroOneFirstWeekPlan, for profile: ZeroOneUserProfile,
                          availableVideoIDs: Set<String>) -> Bool {
        guard let report = plan.selectionReport, report.policyVersion == StarterExerciseSelector.policyVersion,
              let current = recommend(for: profile, availableVideoIDs: availableVideoIDs,
                  alternative: report.alternative) else { return false }
        return current == plan
    }

    private static func matchingModalities(_ equipment: Set<ZeroOneEquipmentItem>) -> [Modality] {
        if equipment.contains(.none) { return [.bodyweight] }
        var matches: [Modality] = []
        if equipment.contains(.barbell) { matches.append(.barbell) }
        if equipment.contains(.dumbbells) { matches.append(.dumbbells) }
        if equipment.contains(.kettlebells) { matches.append(.kettlebells) }
        if equipment.contains(.machines) { matches.append(.machines) }
        if equipment.contains(.cables) { matches.append(.cables) }
        if equipment.contains(.bands) { matches.append(.bands) }
        matches.append(.bodyweight)
        return matches
    }

    private enum Modality {
        case barbell, dumbbells, kettlebells, machines, cables, bands, bodyweight

        func sessions(for novice: Bool) -> [[String]] {
            switch self {
            case .barbell:
                return [
                    ["barbell-squat", "barbell-floor-press", "barbell-bent-over-row", "barbell-romanian-deadlift", "bird-dog", "bodyweight-reverse-lunge"],
                    ["bodyweight-reverse-lunge", "barbell-overhead-press", "barbell-bent-over-row-overhand", "glute-bridge", "barbell-floor-press", "dead-bug"]
                ]
            case .dumbbells:
                return [
                    ["dumbbell-goblet-squat", "floor-press", "dumbbell-single-arm-row", "dumbbell-deadlift", "bird-dog", "bodyweight-reverse-lunge"],
                    ["dumbbell-front-squat", "push-up", "dumbbell-row-unilateral", "kickstand-dumbbell-romanian-deadlift", "glute-bridge", "dead-bug"]
                ]
            case .kettlebells:
                return [
                    ["kettlebell-goblet-squat", "push-up", "kettlebell-row", "kettlebell-romanian-deadlift", "bird-dog", "bodyweight-reverse-lunge"],
                    ["bodyweight-reverse-lunge", "push-up", "kettlebell-single-arm-row", "kettlebell-sumo-deadlift", "glute-bridge", "dead-bug"]
                ]
            case .machines:
                return [
                    ["machine-leg-press", "machine-chest-press", "machine-neutral-row", "seated-leg-curl", "bird-dog", "bodyweight-reverse-lunge"],
                    ["bodyweight-reverse-lunge", "machine-chest-press", "machine-plate-loaded-t-bar-row", "glute-bridge", "machine-leg-press", "dead-bug"]
                ]
            case .cables:
                return [
                    ["bodyweight-squat", "cable-chest-press", "cable-row-bar-standing-row", "glute-bridge", "bird-dog", "bodyweight-reverse-lunge"],
                    ["bodyweight-reverse-lunge", "cable-standing-single-arm-chest-press", "cable-single-arm-neutral-grip-row", "frog-pump", "bodyweight-squat", "dead-bug"]
                ]
            case .bands:
                return [
                    ["band-squat", "push-up", "band-row", "band-romanian-deadlift", "bird-dog", "bodyweight-reverse-lunge"],
                    ["bodyweight-reverse-lunge", "band-overhead-press", "band-row", "glute-bridge", "band-leg-curl", "dead-bug"]
                ]
            case .bodyweight:
                return [
                    ["bodyweight-squat", "push-up", "glute-bridge", "bird-dog", "bodyweight-reverse-lunge", "dead-bug"],
                    ["bodyweight-reverse-lunge", novice ? "bodyweight-knee-push-ups" : "diamond-push-ups", "frog-pump", "dead-bug", "bodyweight-squat", "bird-dog"]
                ]
            }
        }
    }
}
