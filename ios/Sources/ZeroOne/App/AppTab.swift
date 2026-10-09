import SwiftUI

enum AppTab: String, CaseIterable, Codable, Hashable {
    case today
    case workout
    case social
    case diets

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .workout:
            return "Workout"
        case .social:
            return "Social"
        case .diets:
            return "Diets"
        }
    }

    var systemImage: String {
        switch self {
        case .today:
            return "calendar"
        case .workout:
            return "dumbbell"
        case .social:
            return "person.2"
        case .diets:
            return "fork.knife"
        }
    }
}
