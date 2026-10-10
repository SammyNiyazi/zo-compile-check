import Foundation

enum DietTrackerPresentation {
    static func kindTitle(_ kind: DietTrackerKind) -> String {
        switch kind {
        case .supplement: "Supplement"
        case .medicine: "Medicine"
        case .other: "Other"
        }
    }

    static func timeLabel(_ time: DietTrackerTime) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }

    static func detail(_ occurrence: DietTrackerOccurrence) -> String {
        let time = occurrence.time.map(timeLabel)
        let dose = occurrence.tracker.dose.trimmingCharacters(in: .whitespacesAndNewlines)
        return [time, dose.isEmpty ? nil : dose].compactMap { $0 }.joined(separator: " · ")
    }

    /// Adding a time never regenerates an existing scheduled occurrence's identity.
    static func addingTime(hour: Int, minute: Int, to times: [DietTrackerTime]) throws -> [DietTrackerTime] {
        let time = DietTrackerTime(hour: hour, minute: minute)
        guard time.isValid, times.count < 64 else { throw DietTrackerError.invalidEntry }
        guard !times.contains(where: { $0.minuteOfDay == time.minuteOfDay }) else {
            throw DietTrackerError.duplicateTime
        }
        return (times + [time]).sorted { $0.minuteOfDay < $1.minuteOfDay }
    }
}
