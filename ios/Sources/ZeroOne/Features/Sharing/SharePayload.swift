import Foundation

enum ZOShareSize: String, CaseIterable, Identifiable {
    case story, post, square, wide
    var id: Self { self }
    var label: String { switch self { case .story: "Story"; case .post: "Post"; case .square: "Square"; case .wide: "Wide" } }
    var pixels: (width: Double, height: Double) {
        switch self { case .story: (1080, 1920); case .post: (1080, 1350); case .square: (1080, 1080); case .wide: (1920, 1080) }
    }
    var aspectRatio: Double { pixels.width / pixels.height }
}

enum ZOShareLayout: String, CaseIterable, Identifiable {
    case stats, best, clean, route, noPhoto, sticker, recap
    var id: Self { self }
    var label: String {
        switch self { case .stats: "Stats"; case .best: "New best"; case .clean: "Just the photo"
        case .route: "Route"; case .noPhoto: "No photo"; case .sticker: "Sticker"; case .recap: "14 days" }
    }
}

struct ZOSharePrivacy: Equatable {
    var showLoads = true
    var showRoute = false
    var hideRouteEndpoints = true
    var showName = true
    var showBodyWeight = false
}

/// No account/trial state is inferred by this local image feature. The caller
/// supplies acknowledged saved records and, for a recap, its real window start.
enum ZOShareSource {
    case workout(WorkoutHistoryEntry, acknowledgedHistory: [WorkoutHistoryEntry])
    case outdoor(OutdoorActivityRecord)
    case first14Days(ZOShareRecapFacts)

    var layouts: [ZOShareLayout] {
        switch self { case .workout: [.stats, .best, .clean]
        case .outdoor: [.stats, .route, .noPhoto, .sticker]; case .first14Days: [.recap] }
    }
    var sizes: [ZOShareSize] { if case .first14Days = self { return [.story, .post, .square] }; return ZOShareSize.allCases }
    var isOutdoor: Bool { if case .outdoor = self { return true }; return false }
    var isRecap: Bool { if case .first14Days = self { return true }; return false }
    var hasRoute: Bool {
        if case let .outdoor(record) = self { return record.routeDeletedAt == nil && record.route?.segments.contains { $0.points.count > 1 } == true }
        return false
    }
}

struct ZOShareRecapFacts {
    let start: Date
    let trainingDays: [ZOShareTrainingDay]
    let workouts: Int
    let sets: Int
    let lifts: [ZOShareRecapLift]
    let nameAndNumber: String?
    /// Only an actual independently acknowledged measurement may be supplied.
    /// Missing Health permission/data is nil, never a zero change.
    let bodyWeightChange: Load?
    /// Nil when any exercise lacks conservative comparable prior evidence.
    /// Counts observed exercise improvements, never inferred strength PRs.
    let priorBestCount: Int?

    init?(start: Date, acknowledgedHistory: [WorkoutHistoryEntry], calendar: Calendar,
          nameAndNumber: String? = nil, bodyWeightChange: Load? = nil) {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              let end = calendar.date(byAdding: .day, value: 14, to: start),
              Set(acknowledgedHistory.map(\.id)).count == acknowledgedHistory.count,
              ZOShareBestEvidence.uniquePerformedSets(in: acknowledgedHistory),
              acknowledgedHistory.allSatisfy({ $0.completedAt.timeIntervalSinceReferenceDate.isFinite && $0.completedSetCount >= 0 && $0.executionCompleteness != .inconsistent }) else { return nil }
        let records = acknowledgedHistory.filter { $0.completedAt >= start && $0.completedAt < end && $0.completedSetCount > 0 }
        guard !records.isEmpty, records.allSatisfy(ZOShareBestEvidence.valid) else { return nil }
        var count = 0
        for record in records {
            guard record.completedSetCount <= Int.max - count else { return nil }
            count += record.completedSetCount
        }
        self.start = start
        workouts = records.count
        sets = count
        trainingDays = (0..<14).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return ZOShareTrainingDay(id: day, trained: records.contains { $0.completedAt >= day && $0.completedAt < next })
        }
        self.nameAndNumber = nameAndNumber
        self.bodyWeightChange = bodyWeightChange.flatMap { $0.value.isFinite ? $0 : nil }
        let evidence = records.map { ZOShareBestEvidence.evaluate(entry: $0, history: acknowledgedHistory) }
        priorBestCount = evidence.allSatisfy { $0 != nil } ? evidence.compactMap { $0 }.reduce(0) { $0 + $1.count } : nil
        // Exact saved-load changes at the same reps, unit and side convention.
        // These are observations, never inferred strength estimates or PR counts.
        let ordered = records.sorted(by: WorkoutHistoryEntry.newestFirst).reversed()
        var seen: Set<ExerciseID> = []
        let ids = ordered.flatMap { ($0.exercises ?? []).map(\.exerciseID) }.filter { seen.insert($0).inserted }
        lifts = ids.compactMap { id in
            guard Set(records.map(\.completedAt)).count == records.count else { return nil }
            let occurrences = ordered.compactMap { record -> [CompletedSet]? in
                guard let exercises = record.exercises else { return [] }
                let matches = exercises.filter { $0.exerciseID == id }
                return matches.isEmpty ? nil : matches.flatMap(\.completedSets)
            }
            guard occurrences.count > 1, let basis = occurrences.first?.first,
                  occurrences.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ZOShareBestEvidence.comparable($0, with: basis) } }),
                  let first = occurrences.first?.max(by: { $0.load.value < $1.load.value }),
                  let last = occurrences.last?.max(by: { $0.load.value < $1.load.value }), first.id != last.id else { return nil }
            let name = ExerciseLibrary.exercise(id: id)?.name ?? MoveKitExerciseCatalog.match(for: id)?.exercise.name ?? id.rawValue
            return ZOShareRecapLift(id: id, name: name, first: first.load, last: last.load)
        }
    }
}

struct ZOShareMetric: Identifiable, Equatable {
    let id: String
    let value: String
    let label: String
}

struct ZOSharePoint: Equatable { let x: Double; let y: Double }
struct ZOShareTrainingDay: Equatable, Identifiable { let id: Date; let trained: Bool }
struct ZOShareRecapLift: Equatable, Identifiable {
    let id: ExerciseID; let name: String; let first: Load; let last: Load
}
struct ZOShareLiftPayload: Equatable, Identifiable {
    let id: ExerciseID; let name: String; let values: String; let startFraction: Double; let currentFraction: Double
}

/// Deliberately excludes the original saved record, raw coordinates, Health
/// measurements and account identity. Renderers/AX/Club receive this projection.
struct ZOSharePayload: Equatable {
    let isOutdoor: Bool
    let title: String
    let date: String
    let metrics: [ZOShareMetric]
    let distance: String?
    let distanceUnit: String?
    let best: String?
    let railGroups: [Int]
    let route: [[ZOSharePoint]]
    let showsEndpoints: Bool
    let trainingDays: [ZOShareTrainingDay]
    let nameAndNumber: String?
    let bodyWeightChange: String?
    let lifts: [ZOShareLiftPayload]

    func accessibilityDescription(layout: ZOShareLayout, size: ZOShareSize = .story, localization: AppLocalization) -> String {
        var parts = [title, date]
        if let distance { parts.append(distance + " " + (distanceUnit ?? "")) }
        if layout == .best, let best { parts.append(localization.string("New best")); parts.append(best) }
        if layout != .clean && (layout != .best || best == nil) {
            let visible = layout == .route && distance != nil ? metrics.filter { $0.id == "time" || $0.id == "coverage" } : metrics
            parts += visible.map { $0.value + " " + localization.string($0.label) }
        }
        if !route.isEmpty { parts.append(localization.string(showsEndpoints ? "Route includes start and finish" : "Route with start and finish hidden")) }
        if let nameAndNumber { parts.append(nameAndNumber) }
        if let bodyWeightChange { parts.append(bodyWeightChange + " " + localization.string("body weight change")) }
        if layout == .recap && size != .square { parts += lifts.prefix(size == .post ? 1 : 3).map { $0.name + " " + $0.values } }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func make(source: ZOShareSource, privacy: ZOSharePrivacy, localization: AppLocalization) -> Self {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        switch source {
        case let .workout(entry, history):
            let exercises = entry.exercises ?? []
            let all = exercises.flatMap(\.completedSets)
            let qualified = ZOShareBestEvidence.valid(entry)
            var metrics: [ZOShareMetric] = []
            if qualified { metrics.append(.init(id: "sets", value: String(entry.completedSetCount), label: "sets")) }
            // No recorded duration exists here. The target is never presented as time trained.
            if qualified, privacy.showLoads, !all.isEmpty, let unit = all.first?.load.unit,
               all.count == entry.completedSetCount,
               all.allSatisfy({ !$0.isTimed && $0.isPerSide == false && $0.reps > 0 && $0.load.unit == unit && $0.load.value.isFinite && $0.load.value >= 0 }) {
                let volume = all.reduce(0) { $0 + $1.load.value * Double($1.reps) }
                if volume.isFinite && volume > 0 {
                    metrics.append(.init(id: "volume", value: number(volume, locale: localization.locale, decimals: 0), label: unit == .kilograms ? "kg moved" : "lb moved"))
                }
            }
            return Self(isOutdoor: false, title: entry.title, date: entry.completedAt.timeIntervalSinceReferenceDate.isFinite ? formatter.string(from: entry.completedAt) : "", metrics: metrics,
                distance: nil, distanceUnit: nil, best: privacy.showLoads ? newBest(entry: entry, history: history, localization: localization) : nil,
                railGroups: qualified ? exercises.map { $0.completedSets.count }.filter { $0 > 0 } : [], route: [], showsEndpoints: false,
                trainingDays: [], nameAndNumber: nil, bodyWeightChange: nil, lifts: [])
        case let .outdoor(record):
            var metrics: [ZOShareMetric] = []
            let distance = record.recordedDistanceMeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if let elapsed = clock(record.confirmedActiveSeconds) {
                if let distance, !record.hasMissingLocationCoverage,
                   let pace = clock(record.confirmedActiveSeconds / (distance / 1000)) {
                    metrics.append(.init(id: "pace", value: pace, label: "/km"))
                }
                metrics.append(.init(id: "time", value: elapsed, label: "time"))
            }
            if let steps = record.recordedSteps, steps > 0 {
                metrics.append(.init(id: "steps", value: number(Double(steps), locale: localization.locale, decimals: 0),
                    label: record.hasIncompleteStepCoverage ? "recorded steps" : "steps"))
            }
            if distance != nil && record.hasMissingLocationCoverage {
                metrics.append(.init(id: "coverage", value: localization.string("GPS gaps"), label: "recorded distance"))
            }
            let points = privacy.showRoute && record.routeDeletedAt == nil
                ? ZOShareRoute.project(record.route?.segments ?? [], trimEndpoints: privacy.hideRouteEndpoints) : []
            return Self(isOutdoor: true, title: localization.string(record.kind == .run ? "Run" : "Walk"), date: formatter.string(from: record.finishedAt), metrics: metrics,
                distance: distance.map { number($0 / 1000, locale: localization.locale, decimals: 2) }, distanceUnit: distance == nil ? nil : "km",
                best: nil, railGroups: [], route: points, showsEndpoints: !points.isEmpty && !privacy.hideRouteEndpoints,
                trainingDays: [], nameAndNumber: nil, bodyWeightChange: nil, lifts: [])
        case let .first14Days(facts):
            return Self(isOutdoor: false, title: localization.string("My first 14 days"), date: "", metrics: [
                .init(id: "workouts", value: String(facts.workouts), label: "recorded workouts"),
                .init(id: "sets", value: String(facts.sets), label: "recorded sets")]
                + (privacy.showLoads ? facts.priorBestCount.map { [.init(id: "bests", value: String($0), label: "new bests")] } ?? [] : []), distance: nil, distanceUnit: nil,
                best: nil, railGroups: [], route: [], showsEndpoints: false, trainingDays: facts.trainingDays,
                nameAndNumber: privacy.showName ? facts.nameAndNumber : nil,
                bodyWeightChange: privacy.showBodyWeight ? facts.bodyWeightChange.map { number($0.value, locale: localization.locale, decimals: 1) + " " + unitLabel($0.unit, localization: localization) } : nil,
                lifts: privacy.showLoads ? facts.lifts.prefix(3).map { lift in
                    let maximum = max(lift.first.value, lift.last.value)
                    return ZOShareLiftPayload(id: lift.id, name: lift.name,
                        values: exactNumber(lift.first.value, locale: localization.locale) + " → " + exactNumber(lift.last.value, locale: localization.locale) + " " + unitLabel(lift.last.unit, localization: localization),
                        startFraction: lift.first.value / maximum / 1.15, currentFraction: lift.last.value / maximum / 1.15)
                } : [])
        }
    }

    private static func newBest(entry: WorkoutHistoryEntry, history: [WorkoutHistoryEntry], localization: AppLocalization) -> String? {
        guard let best = ZOShareBestEvidence.evaluate(entry: entry, history: history)?.first else { return nil }
        let name = ExerciseLibrary.exercise(id: best.exerciseID)?.name
            ?? MoveKitExerciseCatalog.match(for: best.exerciseID)?.exercise.name ?? best.exerciseID.rawValue
        return name + " " + WorkoutLocalization(localization: localization).load(best.set.load) + " × " + String(best.set.reps)
            + (best.set.isPerSide == true ? " " + localization.string("per side") : "")
    }

    private static func unitLabel(_ unit: LoadUnit, localization: AppLocalization) -> String {
        localization.string(unit == .kilograms ? "kg" : "lb")
    }

    private static func number(_ value: Double, locale: Locale, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    private static func exactNumber(_ value: Double, locale: Locale) -> String {
        var text = String(value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
    static func clock(_ seconds: Double) -> String? {
        guard seconds.isFinite && seconds > 0,
              let value = Int(exactly: seconds.rounded()), value > 0 else { return nil }
        return value >= 3600 ? String(value / 3600) + String(format: ":%02d:%02d", value / 60 % 60, value % 60)
            : String(value / 60) + String(format: ":%02d", value % 60)
    }
}

/// Presentation evidence only. We compare the heaviest saved load at identical
/// reps, units and side convention. Changed or unknown occurrences are barriers,
/// including the newest occurrence; older matches never bridge those barriers.
enum ZOShareBestEvidence {
    struct Best { let exerciseID: ExerciseID; let set: CompletedSet }

    static func comparable(_ set: CompletedSet, with basis: CompletedSet) -> Bool {
        !set.isTimed && !basis.isTimed && set.isPerSide != nil && set.isPerSide == basis.isPerSide
            && set.reps > 0 && set.reps == basis.reps && set.load.unit == basis.load.unit
            && set.load.value.isFinite && set.load.value > 0 && basis.load.value.isFinite && basis.load.value > 0
    }

    static func evaluate(entry: WorkoutHistoryEntry, history: [WorkoutHistoryEntry]) -> [Best]? {
        guard valid(entry), Set(history.map(\.id)).count == history.count,
              uniquePerformedSets(in: history), history.contains(entry),
              history.allSatisfy({ $0.completedAt.timeIntervalSinceReferenceDate.isFinite }),
              history.filter({ $0.id == entry.id }).allSatisfy({ $0 == entry }),
              !history.contains(where: { $0.id != entry.id && $0.completedAt == entry.completedAt }) else { return nil }
        let prior = history.filter { $0.id != entry.id && $0.completedAt < entry.completedAt }
        guard !prior.isEmpty, prior.allSatisfy(valid) else { return nil }
        var result: [Best] = []
        var seen: Set<ExerciseID> = []
        for exercise in entry.exercises ?? [] where seen.insert(exercise.exerciseID).inserted {
            let current = (entry.exercises ?? []).filter { $0.exerciseID == exercise.exerciseID }.flatMap(\.completedSets)
            let old = prior.flatMap { ($0.exercises ?? []).filter { $0.exerciseID == exercise.exerciseID }.flatMap(\.completedSets) }
            guard let basis = current.first, !old.isEmpty,
                  current.allSatisfy({ comparable($0, with: basis) }),
                  old.allSatisfy({ comparable($0, with: basis) }),
                  !prior.contains(where: { ($0.exercises ?? []).contains { $0.exerciseID == exercise.exerciseID && $0.completedSets.isEmpty } }),
                  let strongest = current.max(by: { $0.load.value < $1.load.value }),
                  let previous = old.map(\.load.value).max() else { return nil }
            if strongest.load.value > previous { result.append(Best(exerciseID: exercise.exerciseID, set: strongest)) }
        }
        return result
    }

    static func valid(_ entry: WorkoutHistoryEntry) -> Bool {
        guard entry.completedAt.timeIntervalSinceReferenceDate.isFinite,
              entry.executionCompleteness != .inconsistent,
              let exercises = entry.exercises, !exercises.isEmpty else { return false }
        let sets = exercises.flatMap(\.completedSets)
        return entry.completedSetCount > 0 && sets.count == entry.completedSetCount
            && sets.allSatisfy({ $0.completedAt.timeIntervalSinceReferenceDate.isFinite && $0.completedAt <= entry.completedAt })
            && Set(exercises.map(\.id)).count == exercises.count && Set(sets.map(\.id)).count == sets.count
    }

    static func uniquePerformedSets(in history: [WorkoutHistoryEntry]) -> Bool {
        let ids = history.flatMap { ($0.exercises ?? []).flatMap(\.completedSets).map(\.id) }
        return Set(ids).count == ids.count
    }
}

enum ZOShareRoute {
    /// Trims real fixes before projecting. No GPS gaps are connected, no map
    /// coordinates or excluded endpoints survive in the renderer payload.
    static func project(_ segments: [OutdoorRouteSegment], trimEndpoints: Bool) -> [[ZOSharePoint]] {
        let all = segments.flatMap(\.points)
        guard all.count >= 2, all.count <= 10_000,
              all.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) <= 90 && abs($0.longitude) <= 180 }) else { return [] }
        var cumulative: [[Double]] = []
        var total = 0.0
        for segment in segments {
            var distances: [Double] = []
            for (index, point) in segment.points.enumerated() {
                if index > 0 { total += meters(segment.points[index - 1], point) }
                distances.append(total)
            }
            cumulative.append(distances)
        }
        let retained = zip(segments, cumulative).map { segment, distances in
            zip(segment.points, distances).compactMap { point, distance in
                !trimEndpoints || (distance >= 200 && total - distance >= 200) ? point : nil
            }
        }.filter { $0.count >= 2 }
        guard let origin = retained.first?.first else { return [] }
        let scale = max(0.001, cos(origin.latitude * .pi / 180))
        let projected = retained.map { points in points.map { point in
            ZOSharePoint(x: ((point.longitude - origin.longitude + 540).truncatingRemainder(dividingBy: 360) - 180) * scale,
                         y: -point.latitude)
        } }
        let points = projected.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return [] }
        let span = max(maxX - minX, maxY - minY)
        guard span.isFinite && span > 0 else { return [] }
        return projected.map { simplify($0, tolerance: span / 500).map { point in
            ZOSharePoint(x: (point.x - minX + (span - (maxX - minX)) / 2) / span,
                         y: (point.y - minY + (span - (maxY - minY)) / 2) / span)
        } }
    }

    private static func meters(_ a: OutdoorRouteFix, _ b: OutdoorRouteFix) -> Double {
        let lat = (b.latitude - a.latitude) * .pi / 180
        let lon = (b.longitude - a.longitude) * .pi / 180
        let term = pow(sin(lat / 2), 2) + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, term))))
    }

    private static func simplify(_ points: [ZOSharePoint], tolerance: Double) -> [ZOSharePoint] {
        guard points.count > 2 else { return points }
        var keep: Set<Int> = [0, points.count - 1]
        var ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last], dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            var farthest = first, maximum = tolerance * tolerance
            for index in (first + 1)..<last {
                let p = points[index]
                let fraction = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                let distance = pow(p.x - a.x - fraction * dx, 2) + pow(p.y - a.y - fraction * dy, 2)
                if distance > maximum { farthest = index; maximum = distance }
            }
            if farthest != first { keep.insert(farthest); ranges.append((first, farthest)); ranges.append((farthest, last)) }
        }
        return keep.sorted().map { points[$0] }
    }
}
