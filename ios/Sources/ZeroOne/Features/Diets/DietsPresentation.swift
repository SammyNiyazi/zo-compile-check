import Foundation

struct DietsWaterGlass: Identifiable, Equatable {
    let id: Int
    let capacityMilliliters: Int
    let filledMilliliters: Int
    var fraction: Double { Double(filledMilliliters) / Double(capacityMilliliters) }
}

enum DietsPresentation {
    /// Keep non-250 ml goals and partial glasses exact. A bounded display avoids
    /// allocating an unbounded collection for an unsupported saved goal.
    static func waterGlasses(current: Int, goal: Int) -> [DietsWaterGlass]? {
        guard current >= 0, goal > 0 else { return nil }
        let count = goal / 250 + (goal % 250 == 0 ? 0 : 1)
        guard count <= 64 else { return nil }
        return (0..<count).map { index in
            let start = index * 250
            let capacity = min(250, goal - start)
            return DietsWaterGlass(id: index, capacityMilliliters: capacity,
                filledMilliliters: min(max(0, current - start), capacity))
        }
    }

    /// Undo owns the exact newly confirmed row. A later edit invalidates it.
    static func canUndoAddition(_ saved: NutritionEntry, current: [NutritionEntry]) -> Bool {
        current.contains(saved)
    }
}
