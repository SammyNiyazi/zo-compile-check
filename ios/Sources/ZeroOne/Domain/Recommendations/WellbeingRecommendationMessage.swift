import Foundation

struct WellbeingRecommendationMessage: Equatable, Sendable {
    let titleKey: String
    let detailKey: String
}

extension WellbeingRecommendation {
    var message: WellbeingRecommendationMessage { .init(titleKey: titleKey, detailKey: detailKey) }
    private var titleKey: String {
        switch kind {
        case .symptoms: "Pause and check how you feel"
        case .recovery: demand == .easeTraining ? "A lighter day may help" : "How is your recovery?"
        case .fuelling: "Review your fuelling"
        case .foodVariety:
            evidence.contains(.tailoredNutritionNeeded) ? "Review your dietary needs"
                : evidence.contains(.nutritionContextUnknown) ? "Review nutrition context"
                : evidence.contains(where: { [.lowReportedFruitAndVegetables, .lowReportedFoodFibre, .highReportedFreeSugar, .highReportedSalt].contains($0) })
                    ? "Review food amounts" : "Review food variety"
        case .hydration: evidence.contains(.reportedThirst) ? "Feeling thirsty?" : "Review your water log"
        case .checkIn: "How are you feeling?"
        }
    }

    private var detailKey: String {
        switch kind {
        case .symptoms:
            "You reported new or worsening pain, or feeling unwell. Pause demanding training and get appropriate medical advice if symptoms persist, worsen or concern you."
        case .recovery:
            evidence.contains(.repeatedComparablePerformanceDecline)
                ? (demand == .easeTraining
                    ? "Repeated comparable saved sets show fewer repetitions alongside your current recovery concerns. Consider lighter work or rest and review food, sleep and recovery. Actual rest and technique are not measured; this does not diagnose overtraining."
                    : "Repetitions fell across three saved exposures with matching loads, prescribed work and reported effort. Check how you feel and whether conditions changed. This pattern alone does not establish poor recovery.")
                : demand == .easeTraining
                ? "Your recovery reports suggest easing today's demands. Consider lighter work or rest, then reassess how you feel. This is a check-in, not a diagnosis of overtraining."
                : "Your recent reports or recorded training days are worth checking together. Training frequency alone does not mean you are overtraining."
        case .fuelling:
            evidence.contains(.tailoredNutritionNeeded)
                ? "You reported low energy or unusual hunger alongside training. Your dietary needs take priority; review food and workload with appropriate support. The app has not compared your target with a personal energy requirement."
                : evidence.contains(.nutritionContextUnknown) || evidence.contains(.energyTargetContextUnknown)
                ? "You reported low energy or unusual hunger alongside training. Review food, recovery and the source and purpose of your calorie target. Missing context prevents a qualified target comparison; it does not prove inadequate intake."
                : evidence.contains(.completeFoodLogsBelowChosenGoal)
                ? "On multiple recorded training days, complete food logs were below the goal you reported for each day, alongside low energy or unusual hunger. Review food intake and today's workload. These goals are not measured calorie requirements."
                : "You reported unusual hunger alongside several recorded training days. Check whether food and recovery are keeping up with your workload."
        case .foodVariety:
            evidence.contains(.tailoredNutritionNeeded)
                ? "Your reported dietary needs take priority over general food targets. Review the recorded food pattern with appropriate support and choose options that fit your restrictions. These logs cannot verify ingredient safety or nutrient adequacy."
                : evidence.contains(.nutritionContextUnknown)
                    ? "Food amounts are reported, but age and dietary limits are not confirmed for general adult guidance. Review the optional nutrition context before comparing amounts with reference values. Missing context does not mean a poor diet."
                    : evidence.contains(where: { [.lowReportedFruitAndVegetables, .lowReportedFoodFibre, .highReportedFreeSugar, .highReportedSalt].contains($0) })
                        ? "Multiple complete day reviews suggest checking the food amounts you reported against general adult guidance. Review variety and portions without treating one nutrient as a verdict on your diet. These reports cannot establish a deficiency or personal calorie requirement."
                        : "Several completed day reviews show limited reported plant-food variety. Review vegetables, fruit, whole grains, beans, lentils, nuts and seeds as suitable for you. This cannot establish a nutrient deficiency."
        case .hydration:
            evidence.contains(.prescribedFluidRestriction)
                ? "You reported a prescribed fluid restriction. Follow that plan rather than catching up to the app's water goal. Review thirst or missing drink records with your care team if you are concerned."
                : evidence.contains(.reportedThirst)
                ? "You reported thirst. Have a drink if appropriate for you; avoid forcing a large catch-up amount. Logged water does not measure hydration, and any prescribed fluid restriction takes priority."
                : "Your afternoon water log is below the stored goal alongside recorded training. Check for missing drinks before treating this as your actual intake. This does not establish dehydration or a personal fluid requirement."
        case .checkIn:
            "A short check-in helps 01 connect training, recovery and food without guessing from missing logs."
        }
    }
}
