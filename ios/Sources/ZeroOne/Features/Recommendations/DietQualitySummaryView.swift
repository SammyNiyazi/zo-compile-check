import SwiftUI

struct DietQualitySummaryView: View {
    let assessment: DietQualityAssessment
    @Environment(\.zeroOneLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Food quality context").zoText(.section)
            Text(localization.format("%1$lld complete food days and %2$lld qualified amount reviews in the last seven days.",
                .integer(assessment.completeFoodDayCount), .integer(assessment.completeAmountDayCount)))
                .zoText(.label).foregroundStyle(.secondary)
            switch assessment.eligibility {
            case .unknown:
                Text("General adult amount comparisons are waiting for current age and dietary-limit answers.").zoText(.caption)
            case .tailoredReview:
                Text("Your reported dietary needs take priority. General adult amount comparisons are withheld.").zoText(.caption)
            case .generalAdultReview:
                Text("General adult references: fruit and vegetables at least 400 g, food fibre at least 25 g, free sugar below 10% of recorded energy, salt below 5 g per day.")
                    .zoText(.caption)
                Text("These WHO references are for everyday dietary review, not personal calorie, training-fuel or electrolyte prescriptions.")
                    .zoText(.caption).foregroundStyle(.secondary)
            }
            Text(localization.format("Qualified days: fruit and vegetables %1$lld; food fibre %2$lld; free sugar %3$lld; salt %4$lld.",
                .integer(assessment.fruitAndVegetableDayCount), .integer(assessment.foodFibreDayCount),
                .integer(assessment.freeSugarDayCount), .integer(assessment.saltDayCount)))
                .zoText(.caption).foregroundStyle(.secondary)
            if assessment.unqualifiedAmountDayCount > 0 {
                Text("Partial, estimated or unsourced amounts remain recorded but are not compared with reference values.").zoText(.caption)
            }
            if assessment.hasConflictingSugarEnergy {
                Text("Some free-sugar totals conflict with the day's recorded calories. Those pairs were left out; review the amounts and units.").zoText(.caption)
            }
            Text("Absent amounts stay unknown. Food-group presence and these quantities cannot prove overall diet balance, micronutrient adequacy or ingredient safety.")
                .zoText(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
