import Foundation

/// Display adapter for an already-decided local response. It neither parses a
/// request nor invokes policy. Unknown fields and metadata remain verbatim.
struct AssistantResponseCopy: Equatable {
    let eyebrow: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: AssistantActionID

    init(response: ContextualAssistantResponse, context: AssistantContext,
         localization: AppLocalization) {
        eyebrow = Self.eyebrow(response.eyebrow, localization: localization)
        let hasKnownCase = Self.hasKnownCase(response, context: context)
        title = hasKnownCase ? Self.title(response, context: context, localization: localization) : response.title
        detail = hasKnownCase ? Self.detail(response, context: context, localization: localization) : response.detail
        actionTitle = hasKnownCase
            ? Self.known(response.actionTitle, keys: Self.actionTitleKeys, localization: localization)
            : response.actionTitle
        action = response.action
    }

    /// Recognize the existing response family without choosing a new action.
    /// A key collision in an unknown/generated response is still ordinary text.
    private static func hasKnownCase(_ source: ContextualAssistantResponse, context: AssistantContext) -> Bool {
        switch (source.eyebrow, source.action) {
        case ("READY TO CONFIRM", .addWater): return source.title == "Add 250 ml"
        case ("NUTRITION", .openNutrition): return source.title == "Review today"
        case ("RECOVERY AND FUELLING", .reviewWellbeing):
            return source.title == "Check your records" || wellbeingTitleKeys.contains(source.title)
        case ("NEXT ACTION", .trainToday): return source.title == "Train today"
        case ("TODAY COMPLETE", .openNutrition): return source.title == "Training is done"
        case ("WORKOUT IN PROGRESS", .continueWorkout): return source.title == "Keep the current structure"
        case ("WORKOUT LIBRARY", .openWorkoutLibrary): return source.title == "Choose your next session"
        case ("LOCAL ASSISTANT", _): return source.title == "That is not supported yet"
        case ("IN PROGRESS", .continueWorkout):
            guard case let .inProgress(title, _) = context.workout else { return false }
            return source.title == "Continue \(title)"
        case ("LOCAL ADAPTATION", .shortenWorkout):
            guard case let .inProgress(title, true) = context.workout else { return false }
            return source.title == "Make \(title) 30 minutes"
        default: return false
        }
    }

    private static func known(_ source: String, keys: Set<String>,
                              localization: AppLocalization) -> String {
        keys.contains(source) ? localization.string(source) : source
    }

    private static func eyebrow(_ source: String, localization: AppLocalization) -> String {
        switch source {
        case "READY TO CONFIRM": localization.string("Ready to confirm")
        case "NUTRITION": localization.string("Nutrition")
        case "RECOVERY AND FUELLING": localization.string("Recovery and fuelling")
        case "NEXT ACTION": localization.string("Next action")
        case "TODAY COMPLETE": localization.string("Today complete")
        case "LOCAL ADAPTATION": localization.string("Local adaptation")
        case "WORKOUT IN PROGRESS": localization.string("Workout in progress")
        case "IN PROGRESS": localization.string("In progress")
        case "WORKOUT LIBRARY": localization.string("Workout library")
        case "LOCAL ASSISTANT": localization.string("Local assistant")
        default: source
        }
    }

    private static func title(_ response: ContextualAssistantResponse, context: AssistantContext,
                              localization: AppLocalization) -> String {
        if case let .inProgress(workoutTitle, canAdapt) = context.workout {
            if response.action == .continueWorkout, response.eyebrow == "IN PROGRESS",
               response.title == "Continue \(workoutTitle)" {
                return localization.format("Continue %1$@", .text(workoutTitle))
            }
            if canAdapt, response.action == .shortenWorkout, response.eyebrow == "LOCAL ADAPTATION",
               response.title == "Make \(workoutTitle) 30 minutes" {
                return localization.format("Make %1$@ 30 minutes", .text(workoutTitle))
            }
        }
        return known(response.title, keys: titleKeys, localization: localization)
    }

    private static func detail(_ response: ContextualAssistantResponse, context: AssistantContext,
                               localization: AppLocalization) -> String {
        switch response.action {
        case .addWater:
            if response.eyebrow == "READY TO CONFIRM", response.title == "Add 250 ml",
               context.hydration.isAvailable,
               response.detail == "Your current local total is \(context.hydration.consumedMilliliters) ml." {
                return localization.format("Your current local total is %1$lld ml.",
                                           .integer(context.hydration.consumedMilliliters))
            }
        case .openNutrition:
            if response.eyebrow == "NUTRITION", response.title == "Review today",
               context.nutrition.isAvailable,
               response.detail == "You have \(context.nutrition.entryCountToday) local entries today." {
                return localization.format("You have %1$lld local entries today.",
                                           .integer(context.nutrition.entryCountToday))
            }
            if response.eyebrow == "TODAY COMPLETE", response.title == "Training is done",
               case let .completed(workoutTitle) = context.today,
               response.detail == "\(workoutTitle) is recorded locally for today." {
                return localization.format("%1$@ is recorded locally for today.", .text(workoutTitle))
            }
        case .trainToday:
            if response.eyebrow == "NEXT ACTION", response.title == "Train today",
               case let .ready(workoutTitle) = context.today,
               response.detail == "\(workoutTitle) is ready from your local programme." {
                return localization.format("%1$@ is ready from your local programme.", .text(workoutTitle))
            }
        default: break
        }
        return known(response.detail, keys: detailKeys, localization: localization)
    }

    private static let wellbeingTitleKeys: Set<String> = [
        "A lighter day may help",
        "Feeling thirsty?",
        "How are you feeling?",
        "How is your recovery?",
        "Pause and check how you feel",
        "Review food amounts",
        "Review food variety",
        "Review nutrition context",
        "Review your dietary needs",
        "Review your fuelling",
        "Review your water log",
    ]

    private static let titleKeys: Set<String> = [
        "A lighter day may help",
        "Add 250 ml",
        "Check your records",
        "Choose your next session",
        "Feeling thirsty?",
        "How are you feeling?",
        "How is your recovery?",
        "Keep the current structure",
        "Pause and check how you feel",
        "Review food amounts",
        "Review food variety",
        "Review nutrition context",
        "Review today",
        "Review your dietary needs",
        "Review your fuelling",
        "Review your water log",
        "That is not supported yet",
        "Train today",
        "Training is done",
    ]

    private static let detailKeys: Set<String> = [
        "01 will create the existing deterministic proposal for your review.",
        "A short check-in helps 01 connect training, recovery and food without guessing from missing logs.",
        "Choose a workout first, then 01 can check whether it can be shortened.",
        "Choose from the three local Beta programmes.",
        "Food amounts are reported, but age and dietary limits are not confirmed for general adult guidance. Review the optional nutrition context before comparing amounts with reference values. Missing context does not mean a poor diet.",
        "I can guide your next action, shorten an eligible workout, add 250 ml water, open nutrition, choose a workout, or continue one.",
        "Local hydration is unavailable right now.",
        "Multiple complete day reviews suggest checking the food amounts you reported against general adult guidance. Review variety and portions without treating one nutrient as a verdict on your diet. These reports cannot establish a deficiency or personal calorie requirement.",
        "No workout is ready from local Today state.",
        "Nutrition storage is unavailable, but you can review the surface.",
        "On multiple recorded training days, complete food logs were below the goal you reported for each day, alongside low energy or unusual hunger. Review food intake and today's workload. These goals are not measured calorie requirements.",
        "Repeated comparable saved sets show fewer repetitions alongside your current recovery concerns. Consider lighter work or rest and review food, sleep and recovery. Actual rest and technique are not measured; this does not diagnose overtraining.",
        "Repetitions fell across three saved exposures with matching loads, prescribed work and reported effort. Check how you feel and whether conditions changed. This pattern alone does not establish poor recovery.",
        "Several completed day reviews show limited reported plant-food variety. Review vegetables, fruit, whole grains, beans, lentils, nuts and seeds as suitable for you. This cannot establish a nutrient deficiency.",
        "Some recovery, food or activity records could not be verified. Review them before using training advice.",
        "There is no interrupted workout to continue.",
        "This session cannot be shortened safely at its current point.",
        "You reported a prescribed fluid restriction. Follow that plan rather than catching up to the app's water goal. Review thirst or missing drink records with your care team if you are concerned.",
        "You reported low energy or unusual hunger alongside training. Review food, recovery and the source and purpose of your calorie target. Missing context prevents a qualified target comparison; it does not prove inadequate intake.",
        "You reported low energy or unusual hunger alongside training. Your dietary needs take priority; review food and workload with appropriate support. The app has not compared your target with a personal energy requirement.",
        "You reported new or worsening pain, or feeling unwell. Pause demanding training and get appropriate medical advice if symptoms persist, worsen or concern you.",
        "You reported thirst. Have a drink if appropriate for you; avoid forcing a large catch-up amount. Logged water does not measure hydration, and any prescribed fluid restriction takes priority.",
        "You reported unusual hunger alongside several recorded training days. Check whether food and recovery are keeping up with your workload.",
        "Your active workout state is stored locally.",
        "Your afternoon water log is below the stored goal alongside recorded training. Check for missing drinks before treating this as your actual intake. This does not establish dehydration or a personal fluid requirement.",
        "Your recent reports or recorded training days are worth checking together. Training frequency alone does not mean you are overtraining.",
        "Your recovery reports suggest easing today's demands. Consider lighter work or rest, then reassess how you feel. This is a check-in, not a diagnosis of overtraining.",
        "Your reported dietary needs take priority over general food targets. Review the recorded food pattern with appropriate support and choose options that fit your restrictions. These logs cannot verify ingredient safety or nutrient adequacy.",
    ]

    private static let actionTitleKeys: Set<String> = [
        "Add water",
        "Browse workouts",
        "Continue workout",
        "Open nutrition",
        "Prepare proposal",
        "Review check-in",
        "Review nutrition",
        "View workout",
    ]

}
