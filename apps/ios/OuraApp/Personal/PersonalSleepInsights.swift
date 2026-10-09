import Foundation

/// Descriptive summaries of the recorded week, not an Oura or medical score.
struct PersonalSleepRhythm {
    let nights: Int
    let bedtimeVariationMinutes: Double
    let medianSleepHours: Double
    let goalNights: Int

    static func calculate(days: [PersonalDay], endingOn: Date, night: PersonalNight, goal: Double, calendar: Calendar = .current) -> Self? {
        let end = calendar.startOfDay(for: endingOn)
        guard let first = calendar.date(byAdding: .day, value: -6, to: end),
              let next = calendar.date(byAdding: .day, value: 1, to: end), goal.isFinite, goal > 0,
              !night.identity.hasPrefix("oura-account-export") else { return nil }
        // One day, source and device identity only; do not mix fallback sources.
        let grouped = Dictionary(grouping: days.filter { $0.date >= first && $0.date < next }, by: { calendar.startOfDay(for: $0.date) })
        let records = grouped.keys.sorted().compactMap { key -> (Double, Double)? in
            guard let n = grouped[key]?.first?.night, n.identity == night.identity, n.source == night.source,
                  n.coverage >= 0.95, let hours = n.hours, hours.isFinite, hours > 0,
                  let onset = n.asleepStart else { return nil }
            if n.source == .ring, n.value(.latency) == nil { return nil }
            let parts = calendar.dateComponents([.hour, .minute, .second], from: onset)
            let clock = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
            // 23:50 and 00:10 are twenty minutes apart, not 23 h 40 min.
            return (clock >= 720 ? clock - 1440 : clock, hours)
        }
        guard records.count >= 3 else { return nil }
        let typicalOnset = median(records.map(\.0))
        return Self(nights: records.count,
                    bedtimeVariationMinutes: median(records.map { abs($0.0 - typicalOnset) }),
                    medianSleepHours: median(records.map(\.1)),
                    goalNights: records.filter { $0.1 >= goal }.count)
    }
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), center = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[center - 1] + sorted[center]) / 2 : sorted[center]
    }
}
