import Foundation

/// Evidence-informed principles with explicit, conservative product heuristics.
/// This engine cannot diagnose overtraining, REDs, dehydration or deficiencies,
/// estimate total energy expenditure, or prescribe a calorie deficit.
struct WellbeingRecommendationEngine {
    static let policyVersion = "wellbeing-v7"

    func assess(_ context: WellbeingContext) -> WellbeingAssessment {
        let now = context.asOf
        let calendar = context.calendar
        guard now.timeIntervalSinceReferenceDate.isFinite else { return empty }
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: today) else { return empty }
        var unavailableSources = Set<WellbeingUnavailableSource>()
        if context.strengthHistory == nil { unavailableSources.insert(.strengthHistory) }
        if context.outdoorHistory == nil { unavailableSources.insert(.outdoorHistory) }
        if context.meals == nil { unavailableSources.insert(.foodLog) }
        if !context.recoverySourceAvailable { unavailableSources.insert(.recovery) }
        let reports = validReports(context.recoverySourceAvailable ? context.recoveryCheckIns : [],
            at: now, calendar: calendar, since: windowStart)
        let current = reports.first { $0.isCurrent(at: now, calendar: calendar) }
        let workload = TrainingWorkloadEvidence.assess(strength: context.strengthHistory, outdoor: context.outdoorHistory,
            at: now, calendar: calendar)
        let trainingDays = workload?.recordedTrainingDays ?? []
        let decliningPerformance = workload?.hasRepeatedComparableDecline == true
        let recentDays = (0 ... 3).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let busyDays = recentDays.filter { trainingDays.contains($0) }.count >= 3
        let fatiguedReports = reports.filter { $0.energy == .low && calendar.dateComponents([.day], from: $0.day, to: today).day.map { $0 <= 2 } == true }
        let sleep = resolvedSleep(current: current, health: context.healthSleep, at: now, calendar: calendar)
        var recommendations: [WellbeingRecommendation] = []

        if let current, current.hasNewOrWorseningPain == true || current.feelsUnwell == true {
            var evidence: [WellbeingEvidenceKind] = []
            if current.hasNewOrWorseningPain == true { evidence.append(.reportedPain) }
            if current.feelsUnwell == true { evidence.append(.reportedIllness) }
            recommendations.append(make(.symptoms, demand: .pauseForSymptoms, evidence: evidence, sources: ["RT-2026", "REC-2013"]))
        } else if let current {
            var evidence: [WellbeingEvidenceKind] = []
            if current.energy == .low { evidence.append(.reportedFatigue) }
            if current.soreness == .moderate || current.soreness == .severe { evidence.append(.reportedSoreness) }
            if busyDays { evidence.append(.consecutiveTrainingDays) }
            if sleep.hours.map({ $0 < 6 }) == true { evidence.append(.shortSleep) }
            if decliningPerformance { evidence.append(.repeatedComparablePerformanceDecline) }
            // Severe soreness is a direct reason to reduce demand. Other
            // signals require a current symptom plus a corroborating pattern.
            let concerning = current.soreness == .severe
                || (current.energy == .low && (fatiguedReports.count >= 2 || busyDays || current.soreness == .moderate || decliningPerformance))
                || (current.soreness == .moderate && busyDays)
            if concerning {
                recommendations.append(make(.recovery, demand: .easeTraining, evidence: evidence, sources: ["REC-2013", "REC-2016", "LOAD-2017"]))
            } else if !evidence.isEmpty {
                recommendations.append(make(.recovery, demand: .checkIn, evidence: evidence, sources: ["REC-2013", "REC-2016", "LOAD-2017"]))
            }
        } else if busyDays || decliningPerformance {
            var evidence: [WellbeingEvidenceKind] = []
            if busyDays { evidence.append(.consecutiveTrainingDays) }
            if decliningPerformance { evidence.append(.repeatedComparablePerformanceDecline) }
            recommendations.append(make(.recovery, demand: .checkIn, evidence: evidence, sources: ["REC-2013", "LOAD-2017"]))
        }

        let guidance = context.recoverySourceAvailable ? context.nutritionGuidance : nil
        let reviews = context.recoverySourceAvailable ? validNutritionReviews(context, since: windowStart) : []
        let completeDays = reviews.filter { $0.coverage == .complete }
        let targetReview = NutritionEnergyTargetReview.assess(reviews: completeDays,
            guidance: guidance, at: now)
        if let meals = context.meals {
            let lowFuelDays = completeDays.filter { review in
                guard trainingDays.contains(review.day), let goal = review.reportedCalorieGoal,
                      (500 ... 10_000).contains(goal),
                      NutritionEnergyTargetPolicy.eligibility(guidance: guidance,
                        target: review.energyTargetContext, at: now) == .reportedTargetComparison else { return false }
                let total = meals.filter { calendar.isDate($0.loggedAt, inSameDayAs: review.day) }
                    .reduce(0.0) { $0 + Double($1.calories) }
                // 80% of that day's reported target is a discrepancy, not a calculated
                // physiological requirement or an energy availability measure.
                return total < Double(goal) * 0.8
            }
            if lowFuelDays.count >= 2, let current,
               current.energy == .low || current.feelsUnusuallyHungry == true {
                var evidence: [WellbeingEvidenceKind] = [.completeFoodLogsBelowChosenGoal]
                if current.energy == .low { evidence.append(.reportedFatigue) }
                if current.feelsUnusuallyHungry == true { evidence.append(.reportedHunger) }
                recommendations.append(make(.fuelling, demand: .easeTraining, evidence: evidence, sources: ["FUEL-2023"]))
            }
        }
        let unqualifiedTrainingTargets = completeDays.filter {
            trainingDays.contains($0.day) && $0.reportedCalorieGoal != nil
                && NutritionEnergyTargetPolicy.eligibility(guidance: guidance,
                    target: $0.energyTargetContext, at: now) != .reportedTargetComparison
        }
        if !recommendations.contains(where: { $0.kind == .fuelling }), unqualifiedTrainingTargets.count >= 2,
           let current, current.energy == .low || current.feelsUnusuallyHungry == true {
            var evidence: [WellbeingEvidenceKind] = []
            if current.energy == .low { evidence.append(.reportedFatigue) }
            if current.feelsUnusuallyHungry == true { evidence.append(.reportedHunger) }
            switch targetReview.eligibility {
            case .tailoredReview: evidence.append(.tailoredNutritionNeeded)
            case .unknownPersonalContext: evidence.append(.nutritionContextUnknown)
            case .unknownTargetContext, .reportedTargetComparison: evidence.append(.energyTargetContextUnknown)
            }
            // Fatigue/hunger still deserve a check-in. An unqualified target
            // must not create a numerical deficiency or automatic demand hold.
            recommendations.append(make(.fuelling, demand: .checkIn, evidence: evidence, sources: ["FUEL-2023"]))
        }
        if !recommendations.contains(where: { $0.kind == .fuelling }), busyDays,
           let current, current.feelsUnusuallyHungry == true {
            recommendations.append(make(.fuelling, demand: .checkIn, evidence: [.reportedHunger, .consecutiveTrainingDays], sources: ["FUEL-2023"]))
        }

        let dietQuality = DietQualityEvidence.assess(reviews: context.recoverySourceAvailable ? context.nutritionReviews : [], meals: context.meals,
            guidance: guidance, at: now, calendar: calendar)
        var foodEvidence: [WellbeingEvidenceKind] = dietQuality.findings.map { finding in
            switch finding {
            case .limitedVariety: .limitedReportedFoodVariety
            case .lowFruitAndVegetables: .lowReportedFruitAndVegetables
            case .lowFoodFibre: .lowReportedFoodFibre
            case .highFreeSugar: .highReportedFreeSugar
            case .highSalt: .highReportedSalt
            }
        }
        if dietQuality.eligibility == .tailoredReview,
           !foodEvidence.isEmpty || dietQuality.completeAmountDayCount >= 3 {
            foodEvidence.append(.tailoredNutritionNeeded)
        } else if dietQuality.eligibility == .unknown, dietQuality.completeAmountDayCount >= 3 {
            foodEvidence.append(.nutritionContextUnknown)
        }
        if !foodEvidence.isEmpty {
            recommendations.append(make(.foodVariety, demand: .review, evidence: foodEvidence, sources: ["DIET-WHO"]))
        }

        // Thirst prompts a choice. A low water log never establishes dehydration
        // or justifies forcing a large catch-up drink, even on a training day.
        if let current, current.feelsThirsty == true {
            var evidence: [WellbeingEvidenceKind] = [.reportedThirst]
            if hasReportedFluidRestriction(guidance, at: now) { evidence.append(.prescribedFluidRestriction) }
            recommendations.append(make(.hydration, demand: .review, evidence: evidence, sources: ["WATER-2015"]))
        } else if let water = context.hydration,
                  water.day.timeIntervalSinceReferenceDate.isFinite,
                  water.day == today, water.loggedMilliliters >= 0,
                  (500 ... 20_000).contains(water.storedGoalMilliliters),
                  Double(water.loggedMilliliters) < Double(water.storedGoalMilliliters) * 0.4,
                  calendar.component(.hour, from: now) >= 15,
                  trainingDays.contains(today) || busyDays {
            var evidence: [WellbeingEvidenceKind] = [.waterLogBelowStoredGoal]
            if hasReportedFluidRestriction(guidance, at: now) { evidence.append(.prescribedFluidRestriction) }
            recommendations.append(make(.hydration, demand: .review, evidence: evidence, sources: ["WATER-2015"]))
        }
        if recommendations.isEmpty, current == nil {
            recommendations.append(make(.checkIn, demand: .review, evidence: [], sources: ["REC-2016"]))
        }
        recommendations.sort {
            if $0.demand != $1.demand { return $0.demand > $1.demand }
            return priority($0.kind) < priority($1.kind)
        }
        return WellbeingAssessment(recommendations: recommendations, recordedTrainingDays: trainingDays.count,
            reviewedNutritionDays: completeDays.count, hasCurrentRecoveryReport: current != nil,
            hasConflictingSleep: sleep.conflicting, evaluatedAt: now, timeZoneID: calendar.timeZone.identifier,
            workload: workload, dietQuality: dietQuality, energyTargetReview: targetReview,
            unavailableSources: unavailableSources)
    }

    private var empty: WellbeingAssessment {
        WellbeingAssessment(recommendations: [], recordedTrainingDays: 0, reviewedNutritionDays: 0,
            hasCurrentRecoveryReport: false, hasConflictingSleep: false)
    }

    private func make(_ kind: WellbeingRecommendationKind, demand: WellbeingDemand,
                      evidence: [WellbeingEvidenceKind], sources: [String]) -> WellbeingRecommendation {
        WellbeingRecommendation(kind: kind, demand: demand, evidence: evidence,
            policyVersion: Self.policyVersion, sourceReferences: sources)
    }

    private func priority(_ kind: WellbeingRecommendationKind) -> Int {
        switch kind {
        case .symptoms: 0
        case .fuelling: 1
        case .recovery: 2
        case .hydration: 3
        case .foodVariety: 4
        case .checkIn: 5
        }
    }

    private func hasReportedFluidRestriction(_ guidance: NutritionGuidanceContext?, at now: Date) -> Bool {
        guard let guidance else { return false }
        return guidance.isValid && guidance.reportedAt <= now && guidance.hasPrescribedFluidRestriction == true
    }

    private func validReports(_ reports: [RecoveryCheckIn], at now: Date, calendar: Calendar, since start: Date) -> [RecoveryCheckIn] {
        guard reports.count <= 3_650, Set(reports.map(\.id)).count == reports.count else { return [] }
        let valid = reports.filter {
            $0.isStructurallyValid && $0.reportedAt <= now && $0.day >= start && $0.day <= now
                && $0.timeZoneID == calendar.timeZone.identifier && calendar.startOfDay(for: $0.day) == $0.day
                && calendar.isDate($0.day, inSameDayAs: $0.reportedAt)
        }
        let byDay = Dictionary(grouping: valid, by: \.day)
        // Conflicting daily duplicates fail closed instead of picking whichever
        // happened to sort last. The repository normally prevents duplicates.
        return byDay.values.compactMap { $0.count == 1 ? $0.first : nil }.sorted { $0.day > $1.day }
    }

    private func validNutritionReviews(_ context: WellbeingContext, since start: Date) -> [NutritionDayReview] {
        guard let meals = context.meals, context.nutritionReviews.count <= 3_650,
              Set(context.nutritionReviews.map(\.id)).count == context.nutritionReviews.count else { return [] }
        let grouped = Dictionary(grouping: context.nutritionReviews, by: \.day)
        return grouped.values.compactMap { reviews -> NutritionDayReview? in
            guard reviews.count == 1, let review = reviews.first, review.day >= start,
                  review.isUsable(entries: meals, at: context.asOf, calendar: context.calendar) else { return nil }
            return review
        }.sorted { $0.day > $1.day }
    }

    private func resolvedSleep(current: RecoveryCheckIn?, health: RecoverySleepObservation?, at now: Date,
                               calendar: Calendar) -> (hours: Double?, conflicting: Bool) {
        let manual = current?.sleepHours
        let imported: Double?
        if let health, health.hours.isFinite, (0 ... 24).contains(health.hours),
           health.refreshedAt.timeIntervalSinceReferenceDate.isFinite, health.refreshedAt <= now,
           now.timeIntervalSince(health.refreshedAt) <= 6 * 3_600,
           calendar.isDate(health.day, inSameDayAs: now) {
            imported = health.hours
        } else { imported = nil }
        if let manual, let imported, abs(manual - imported) >= 2 { return (nil, true) }
        return (manual ?? imported, false)
    }
}
