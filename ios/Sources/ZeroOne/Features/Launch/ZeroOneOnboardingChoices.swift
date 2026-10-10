import Foundation

enum ZeroOneTrainingSport: String, CaseIterable, Codable, Identifiable, Sendable {
    case volleyball, basketball, football, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .volleyball: "Volleyball"
        case .basketball: "Basketball"
        case .football: "Football"
        case .other: "Another sport"
        }
    }
}

enum ZeroOneEquipmentItem: String, CaseIterable, Codable, Identifiable, Sendable {
    case barbell, dumbbells, kettlebells, bench, pullUpBar, cables, machines, bands, none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .barbell: "Barbell and rack"
        case .dumbbells: "Dumbbells"
        case .kettlebells: "Kettlebells"
        case .bench: "Bench"
        case .pullUpBar: "Pull-up bar"
        case .cables: "Cable machine"
        case .machines: "Weight machines"
        case .bands: "Resistance bands"
        case .none: "No equipment"
        }
    }

    var symbol: String {
        switch self {
        case .barbell, .dumbbells: "dumbbell.fill"
        case .kettlebells: "figure.strengthtraining.functional"
        case .bench: "rectangle.portrait.on.rectangle.portrait"
        case .pullUpBar: "figure.pullups"
        case .cables, .machines: "figure.strengthtraining.traditional"
        case .bands: "circle.dashed"
        case .none: "figure.stand"
        }
    }

    static let fullGym: Set<Self> = Set(allCases.filter { $0 != .none })
    static let homeKit: Set<Self> = [.dumbbells, .bench, .bands, .pullUpBar]

    static func toggling(_ item: Self, in selection: Set<Self>) -> Set<Self> {
        if selection.contains(item) { return selection.subtracting([item]) }
        if item == .none { return [.none] }
        return selection.subtracting([.none]).union([item])
    }

    static func legacyAccess(for selection: Set<Self>) -> ZeroOneEquipmentAccess {
        if selection == [.none] { return .bodyweight }
        if selection == [.dumbbells] { return .dumbbells }
        if selection == fullGym { return .fullGym }
        return .notSure
    }
}

enum ZeroOneTrainingDay: Int, CaseIterable, Codable, Identifiable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }
    var shortTitle: String { String(title.prefix(3)) }

    static func legacyAvailability(for selection: Set<Self>) -> ZeroOneWeeklyAvailability {
        switch selection.count {
        case 0: .notSure
        case 1: .notSure
        case 2: .twoDays
        case 3: .threeDays
        case 4: .fourDays
        default: .fiveOrMoreDays
        }
    }
}

enum ZeroOneWeightPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case kilograms = "kg"
    case pounds = "lb"

    var id: String { rawValue }
    var title: String { self == .kilograms ? "Kilograms" : "Pounds" }
}

enum ZeroOneDistancePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case kilometers = "km"
    case miles = "mi"

    var id: String { rawValue }
    var title: String { self == .kilometers ? "Kilometres" : "Miles" }
}

enum ZeroOneOnboardingUnitDefaults {
    static func weight(for locale: Locale = .current) -> ZeroOneWeightPreference {
        locale.region?.identifier == "US" ? .pounds : .kilograms
    }

    static func distance(for locale: Locale = .current) -> ZeroOneDistancePreference {
        ["US", "GB"].contains(locale.region?.identifier ?? "") ? .miles : .kilometers
    }
}

extension ZeroOneUserProfile {
    var equipmentDescription: String? {
        guard let availableEquipment, !availableEquipment.isEmpty else { return equipmentAccess?.title }
        if availableEquipment.contains(.none) { return "No equipment" }
        if availableEquipment == ZeroOneEquipmentItem.fullGym { return "Full gym" }
        return availableEquipment.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", ")
    }

    var trainingDaysDescription: String? {
        guard let preferredTrainingDays, !preferredTrainingDays.isEmpty else { return weeklyAvailability?.title }
        return preferredTrainingDays.sorted { $0.rawValue < $1.rawValue }.map(\.shortTitle).joined(separator: ", ")
    }
}
