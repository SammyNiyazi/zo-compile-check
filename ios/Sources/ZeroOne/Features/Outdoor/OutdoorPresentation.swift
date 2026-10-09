import Foundation

/// Display-only projection. It cannot mutate a route, journal or recorder.
enum OutdoorPresentation {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let total = Int(seconds)
        let secondsPart = String(format: "%02d", total % 60)
        if total < 3_600 { return "\(total / 60):\(secondsPart)" }
        return "\(total / 3_600):\(String(format: "%02d", total / 60 % 60)):\(secondsPart)"
    }

    static func distance(_ meters: Double?, locale: Locale) -> String {
        guard let meters, meters.isFinite, meters >= 0 else { return "—" }
        return (meters / 1_000).formatted(.number.locale(locale).precision(.fractionLength(2)))
    }

    static func steps(_ count: Int?, locale: Locale) -> String {
        guard let count, count >= 0 else { return "—" }
        return count.formatted(.number.locale(locale))
    }

    /// The same injected calendar/time zone formats the endpoints and decides
    /// whether the saved interval crossed a day. No source date is changed.
    static func date(_ date: Date, style: Date.FormatStyle, locale: Locale, calendar: Calendar) -> String {
        var resolved = style
        resolved.locale = locale
        resolved.calendar = calendar
        resolved.timeZone = calendar.timeZone
        return date.formatted(resolved)
    }

    static func crossesCalendarDay(start: Date, end: Date, calendar: Calendar) -> Bool {
        !calendar.isDate(start, inSameDayAs: end)
    }

    static func pace(seconds: TimeInterval, meters: Double?, hasGPSGap: Bool) -> String {
        guard !hasGPSGap, seconds.isFinite, seconds > 0,
              let meters, meters.isFinite, meters >= 100 else { return "—" }
        let pace = seconds / (meters / 1_000)
        guard pace.isFinite, pace > 0, pace < 3_600 else { return "—" }
        return String(format: "%d:%02d", Int(pace) / 60, Int(pace) % 60)
    }

    /// A requested finish must acknowledge the same checkpoint identity. This
    /// is once per presented view lifetime, not a persisted achievement latch.
    /// The model coalesces saved/alreadySaved, so this cannot prove a new write.
    /// Opening history, storage retry and an unmatched finish never trigger it.
    static func celebrates(finishedID: UUID?, requestedID: UUID?, alreadyCelebrated: Set<UUID>) -> Bool {
        guard let finishedID, finishedID == requestedID else { return false }
        return !alreadyCelebrated.contains(finishedID)
    }

    struct Point: Equatable { let x: Double; let y: Double }
    struct Segment: Identifiable, Equatable { let id: UUID; let points: [Point] }

    /// A local schematic thumbnail from retained real vertices. Each segment
    /// stays separate: there is no road snapping, GPS-gap connector or cropping.
    /// Sharing's private 200 m crop is a separate root-owned projection.
    static func thumbnail(_ route: OutdoorRouteAccumulator) -> [Segment] {
        let source = route.segments.map { ($0.id, $0.presentationPoints) }
        guard let origin = source.flatMap({ $0.1 }).first else { return [] }
        let longitudeScale = cos(origin.latitude * .pi / 180)
        let projected = source.map { id, fixes in
            Segment(id: id, points: fixes.map { fix in
                let longitude = (fix.longitude - origin.longitude + 540)
                    .truncatingRemainder(dividingBy: 360) - 180
                return Point(x: longitude * longitudeScale, y: -fix.latitude)
            })
        }
        let points = projected.flatMap(\.points)
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return [] }
        let span = max(maxX - minX, maxY - minY)
        return projected.map { segment in
            Segment(id: segment.id, points: segment.points.map { point in
                guard span > 0 else { return Point(x: 0.5, y: 0.5) }
                return Point(x: 0.5 + (point.x - (minX + maxX) / 2) / span * 0.8,
                             y: 0.5 + (point.y - (minY + maxY) / 2) / span * 0.8)
            })
        }
    }
}
