import Foundation

/// Synthetic screenshot fixture, only activated by the DEBUG launch argument.
/// Never reads hardware and never enters the persistent cache.
enum DashboardDemo {
    static func days(now: Date = Date()) -> [PersonalDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (-35...0).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            let start = date.addingTimeInterval(-3600)
            let labels = ["Awake", "Core", "Deep", "Core", "REM", "Core", "Awake", "Core", "Deep", "REM", "Core", "REM", "Awake"]
            let minutes: [Double] = [12, 50 + Double((offset + 35) % 7 - 3) * 5, 62, 40, 35, 45, 8, 40, 35, 45, 25, 28, 5]
            var cursor = start
            let stages = zip(labels, minutes).map { label, length -> PersonalStage in
                let end = cursor.addingTimeInterval(length * 60)
                defer { cursor = end }
                return PersonalStage(start: cursor, end: end, label: label)
            }
            let asleepHours = zip(labels, minutes).filter { $0.0 != "Awake" }.reduce(0) { $0 + $1.1 } / 60
            let hr = stride(from: 0, to: cursor.timeIntervalSince(start), by: 300).enumerated().map { index, seconds in
                PersonalPoint(time: start.addingTimeInterval(seconds), value: 55 + sin(Double(index) / 6) * 4 + cos(Double(index) / 2) * 2)
            }
            let hrv = hr.enumerated().map { index, point in PersonalPoint(time: point.time, value: 62 + sin(Double(index) / 5) * 9) }
            let night = PersonalNight(start: start, end: cursor, source: .ring, identity: "direct-ring:demo", hours: asleepHours, restorativeHours: 205.0 / 60, stages: stages, heartRate: hr, hrvSeries: hrv, hrvMethod: "RMSSD", bedStart: start, bedEnd: cursor, provenance: "Direct ring · Bluetooth · synthetic fixture")
            var day = PersonalDay(date: date, night: night)
            day.directRingNight = night
            for metric in PersonalMetric.allCases {
                if let value = night.value(metric) { day.values[metric.rawValue] = PersonalValue(value: value, source: .ring, identity: night.identity) }
            }
            let wobble = Double((offset + 35) % 5)
            day.values[PersonalMetric.restingHR.rawValue] = PersonalValue(value: 52 + wobble, source: .ring, identity: night.identity)
            day.values[PersonalMetric.hrv.rawValue] = PersonalValue(value: 58 + wobble * 2, source: .ring, identity: night.identity, method: "RMSSD")
            day.values[PersonalMetric.steps.rawValue] = PersonalValue(value: 8642 + wobble * 201, source: .watch, identity: "apple-health:demo")
            day.values[PersonalMetric.energy.rawValue] = PersonalValue(value: 468 + wobble * 18, source: .watch, identity: "apple-health:demo")
            day.values[PersonalMetric.oxygen.rawValue] = PersonalValue(value: 97, source: .ring, identity: night.identity)
            day.values[PersonalMetric.skinTemperature.rawValue] = PersonalValue(value: 33.2, source: .ring, identity: night.identity)
            day.values[PersonalMetric.temperatureDeviation.rawValue] = PersonalValue(value: 0.3, source: .ring, identity: night.identity)
            day.values[PersonalMetric.sleepScore.rawValue] = PersonalValue(value: 86, source: .ring, identity: "oura-account-export:demo")
            day.values[PersonalMetric.activityScore.rawValue] = PersonalValue(value: 91, source: .ring, identity: "oura-account-export:demo")
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--demo-missing-ring-sleep") || args.contains("--demo-watch-sleep") {
                // Model a pre-update cache with a valid Watch night, but no ring night.
                day.directRingNight = nil
                day.night?.source = .watch
                day.night?.identity = "apple-health:demo-watch"
                day.night?.provenance = "Apple Watch · Apple Health · synthetic fixture"
            } else if args.contains("--demo-partial-ring-sleep") {
                day.night?.hours = nil
                day.night?.stages = []
                day.directRingNight = day.night
            }
            #endif
            return day
        }
    }
}
