import Foundation
import HealthKit

enum PersonalAssembler {
    static func build(ring: Summary?, health: PersonalHealthSnapshot, preferences: PersonalPreferences, now: Date = Date()) -> [PersonalDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sleep = (health.samples[HKCategoryTypeIdentifier.sleepAnalysis.rawValue] ?? []).compactMap { $0 as? HKCategorySample }
        let quantities = health.samples.mapValues { $0.compactMap { $0 as? HKQuantitySample } }
        let workouts = (health.samples[HKObjectType.workoutType().identifier] ?? []).compactMap { $0 as? HKWorkout }
        let quantitiesByDay = quantities.mapValues { Dictionary(grouping: $0) { calendar.startOfDay(for: $0.startDate) } }
        let workoutsByDay = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.startDate) }
        return (0..<120).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: date)!
            var day = PersonalDay(date: date)
            let label = dayKey(date)
            let ringNight = ring?.nights.filter { night in
                guard let end = night.end_unix else { return false }
                return calendar.isDate(Date(timeIntervalSince1970: Double(end)), inSameDayAs: date)
            }.max { $0.durationS < $1.durationS }
            let directID = "direct-ring|\(ring?.device?.serial ?? "unverified")"
            let rn = ringNight.flatMap { makeRingNight($0, identity: directID) }
            let hn = healthNight(samples: sleep, wakeDate: date)
            let preferred = preferences.source(.sleep)
            day.directRingNight = rn
            day.sleepInput = preferences.resolvedSleepInput
            day.night = PersonalSleepSelection.choose(direct: rn, health: hn, input: preferences.resolvedSleepInput, preferred: preferred)
            if let night = day.night, let hours = night.hours {
                day.values[PersonalMetric.sleep.rawValue] = PersonalValue(value: hours, source: night.source, identity: night.identity, method: "sleep-duration")
            }
            for metric in [PersonalMetric.restingHR, .hrv] {
                let identifier = metric == .hrv ? HKQuantityTypeIdentifier.heartRateVariabilitySDNN : .restingHeartRate
                let unit: HKUnit = metric == .hrv ? .secondUnit(with: .milli) : HKUnit.count().unitDivided(by: .minute())
                let current = quantitiesByDay[identifier.rawValue]?[date] ?? []
                var candidates: [PersonalSource: PersonalValue] = [:]
                for source in PersonalSource.allCases {
                    let samples = current.filter { PersonalHealthReader.source($0) == source }
                    let groups = Dictionary(grouping: samples, by: PersonalHealthReader.identity)
                    let chosen = groups.keys.sorted { a, b in
                        groups[a]!.count == groups[b]!.count ? a < b : groups[a]!.count > groups[b]!.count
                    }.first
                    if let chosen {
                        let values = groups[chosen]!.map { $0.quantity.doubleValue(for: unit) }.filter { $0.isFinite && $0 > 0 }
                        if !values.isEmpty {
                            candidates[source] = PersonalValue(value: values.reduce(0, +) / Double(values.count), source: source,
                                identity: chosen, method: metric == .hrv ? "SDNN" : "HealthKit resting HR")
                        }
                    }
                }
                if let n = ringNight, let value = metric == .hrv ? n.hrv_ms : n.rhr, value.isFinite, value > 0,
                   ring?.device?.serial != nil {
                    candidates[.ring] = PersonalValue(value: value, source: .ring, identity: directID,
                        method: metric == .hrv ? "RMSSD" : "Overnight lowest HR")
                }
                let primary = preferences.source(metric)
                day.values[metric.rawValue] = candidates[primary] ?? candidates[primary.other]
            }
            for metric in [PersonalMetric.steps, .energy] {
                let identifier = metric == .steps ? HKQuantityTypeIdentifier.stepCount : .activeEnergyBurned
                let watchValue = health.totals[identifier.rawValue]?[date]
                let stat = ring?.activity_daily[label]
                let raw = metric == .steps ? stat?.steps : stat?.active_kcal
                let ringValue = raw.flatMap { value -> PersonalValue? in
                    guard value.isFinite, value >= 0, ring?.device?.serial != nil else { return nil }
                    return PersonalValue(value: value, source: .ring, identity: directID, method: "Activity-intensity estimate")
                }
                day.values[metric.rawValue] = preferences.source(metric) == .watch ? (watchValue ?? ringValue) : (ringValue ?? watchValue)
            }
            let watchWorkouts = (workoutsByDay[date] ?? []).filter { PersonalHealthReader.source($0) == .watch }.map {
                PersonalWorkout(id: $0.uuid.uuidString, start: $0.startDate, minutes: $0.duration / 60,
                    title: workoutTitle($0.workoutActivityType), source: .watch)
            }
            // Model-free ring builds have no trustworthy classified workouts. Do not invent them.
            day.workouts = watchWorkouts
            if !watchWorkouts.isEmpty {
                day.values[PersonalMetric.workouts.rawValue] = PersonalValue(value: Double(watchWorkouts.count), source: .watch, identity: "watch-workouts")
            }
            // Heart-rate chart is restricted to the chosen sleep source and interval.
            if var night = day.night, night.heartRate.isEmpty {
                let hr = (quantities[HKQuantityTypeIdentifier.heartRate.rawValue] ?? []).filter {
                    PersonalHealthReader.source($0) == night.source && $0.startDate >= night.start && $0.startDate < night.end
                }
                let groups = Dictionary(grouping: hr, by: PersonalHealthReader.identity)
                let chosen = groups[night.identity] != nil ? night.identity : nil
                if let chosen {
                    night.heartRate = groups[chosen]!.map { PersonalPoint(time: $0.startDate, value: $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) }
                }
                day.night = night
            }
            if let night = day.night {
                for metric in PersonalMetric.allCases where metric.sleepMetric || metric == .averageHR {
                    if let value = night.value(metric) {
                        day.values[metric.rawValue] = PersonalValue(value: value, source: night.source, identity: night.identity, method: "sleep timeline")
                    }
                }
            }
            if var night = day.night, (night.hrvSeries ?? []).isEmpty {
                let samples = (quantities[HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue] ?? []).filter {
                    $0.startDate >= night.start && $0.startDate < night.end && PersonalHealthReader.source($0) == night.source && PersonalHealthReader.identity($0) == night.identity
                }
                if !samples.isEmpty {
                    night.hrvSeries = samples.compactMap {
                        let value = $0.quantity.doubleValue(for: .secondUnit(with: .milli))
                        return value.isFinite && value > 0 ? PersonalPoint(time: $0.startDate, value: value) : nil
                    }
                    night.hrvMethod = "SDNN"
                    day.night = night
                }
            }
            if let n = ringNight, ring?.device?.serial != nil {
                for (metric, value) in [(PersonalMetric.respiratoryRate, n.breath_rate), (.oxygen, n.spo2_mean), (.skinTemperature, n.skin_temp)] {
                    if let value, value.isFinite {
                        day.values[metric.rawValue] = PersonalValue(value: value, source: .ring, identity: directID, method: "ring overnight measurement")
                    }
                }
            }
            for (metric, identifier, unit, scale) in [
                (PersonalMetric.respiratoryRate, HKQuantityTypeIdentifier.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), 1.0),
                (.oxygen, .oxygenSaturation, HKUnit.percent(), 100),
                (.skinTemperature, .appleSleepingWristTemperature, HKUnit.degreeCelsius(), 1)
            ] {
                let candidates = (quantities[identifier.rawValue] ?? []).filter {
                    let a = day.night?.start ?? date, b = day.night?.end ?? end
                    return $0.startDate >= a && $0.startDate < b && PersonalHealthReader.source($0) == .watch
                }
                let groups = Dictionary(grouping: candidates, by: PersonalHealthReader.identity)
                if let identity = groups.keys.sorted(by: { groups[$0]!.count == groups[$1]!.count ? $0 < $1 : groups[$0]!.count > groups[$1]!.count }).first {
                    let values = groups[identity]!.map { $0.quantity.doubleValue(for: unit) * scale }.filter { $0.isFinite && $0 > 0 }
                    if !values.isEmpty, preferences.source(metric) == .watch || day.values[metric.rawValue] == nil {
                        day.values[metric.rawValue] = PersonalValue(value: values.reduce(0, +) / Double(values.count), source: .watch, identity: identity,
                            method: day.night == nil ? "HealthKit daily sample mean" : "HealthKit sleep-window sample mean")
                    }
                }
            }
            if let stat = ring?.activity_daily[label], ring?.device?.serial != nil {
                for (metric, value) in [(PersonalMetric.totalEnergy, stat.total_kcal), (.distance, stat.distance_m.map { $0 / 1000 })] {
                    if let value, value.isFinite, value >= 0 { day.values[metric.rawValue] = PersonalValue(value: value, source: .ring, identity: directID) }
                }
            }
            return day
        }
    }
    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func unionHours(_ intervals: [(Date, Date)]) -> Double {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = sorted.first else { return 0 }
        var start = first.0, end = first.1, seconds = 0.0
        for interval in sorted.dropFirst() {
            if interval.0 <= end { end = max(end, interval.1) }
            else { seconds += end.timeIntervalSince(start); start = interval.0; end = interval.1 }
        }
        return (seconds + end.timeIntervalSince(start)) / 3600
    }
    private static func healthNight(samples: [HKCategorySample], wakeDate: Date) -> [PersonalSource: PersonalNight] {
        let cal = Calendar.current
        let noon = cal.date(byAdding: .hour, value: 12, to: wakeDate)!
        let previousNoon = cal.date(byAdding: .day, value: -1, to: noon)!
        let asleepCodes = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let within = samples.filter { $0.endDate > previousNoon && $0.startDate < noon && PersonalHealthReader.source($0) != nil }
        var result: [PersonalSource: PersonalNight] = [:]
        for source in PersonalSource.allCases {
            let groups = Dictionary(grouping: within.filter { PersonalHealthReader.source($0) == source }, by: PersonalHealthReader.identity)
            let chosen = groups.keys.sorted { a, b in
                func duration(_ key: String) -> Double {
                    unionHours(groups[key]!.filter { asleepCodes.contains($0.value) }.map { (max(previousNoon, $0.startDate), min(noon, $0.endDate)) })
                }
                return duration(a) == duration(b) ? a < b : duration(a) > duration(b)
            }.first
            guard let chosen else { continue }
            let asleep = groups[chosen]!.filter { asleepCodes.contains($0.value) }
            guard !asleep.isEmpty else { continue }
            // Select the longest contiguous sleep session, allowing <= 2 h awake gaps.
            let sorted = asleep.sorted { $0.startDate < $1.startDate }
            var sessions: [[HKCategorySample]] = []
            for sample in sorted {
                if let last = sessions.last, sample.startDate.timeIntervalSince(last.map(\.endDate).max()!) <= 7200 {
                    sessions[sessions.count - 1].append(sample)
                } else { sessions.append([sample]) }
            }
            let session = sessions.max { a, b in unionHours(a.map { ($0.startDate, $0.endDate) }) < unionHours(b.map { ($0.startDate, $0.endDate) }) }!
            let start = max(previousNoon, session.map(\.startDate).min()!)
            let end = min(noon, session.map(\.endDate).max()!)
            // Require the actual session's wake date to be this morning, not a clipped ongoing night.
            guard cal.isDate(session.map(\.endDate).max()!, inSameDayAs: wakeDate) else { continue }
            let stageRecords = groups[chosen]!.filter { $0.endDate > start && $0.startDate < end && $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
            let stages = stageRecords.map { record -> PersonalStage in
                let label: String
                switch record.value {
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: label = "Deep"
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue: label = "REM"
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue: label = "Core"
                case HKCategoryValueSleepAnalysis.awake.rawValue: label = "Awake"
                default: label = "Asleep"
                }
                return PersonalStage(start: max(start, record.startDate), end: min(end, record.endDate), label: label)
            }
            let restorative = stageRecords.filter { $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue || $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue }
            let bed = groups[chosen]!.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue && $0.endDate >= start && $0.startDate <= end }
            result[source] = PersonalNight(start: start, end: end, source: source, identity: chosen,
                hours: unionHours(session.map { (max(start, $0.startDate), min(end, $0.endDate)) }),
                restorativeHours: restorative.isEmpty ? nil : unionHours(restorative.map { (max(start, $0.startDate), min(end, $0.endDate)) }),
                stages: stages, heartRate: [], bedStart: bed.map(\.startDate).min(), bedEnd: bed.map(\.endDate).max(), provenance: source == .watch ? "Apple Watch · Apple Health · one device sleep session" : "Oura app · Apple Health · not direct Bluetooth")
        }
        return result
    }
    private static func makeRingNight(_ n: NightRow, identity: String) -> PersonalNight? {
        guard !identity.hasSuffix("unverified"), let startUnix = n.start_unix, let endUnix = n.end_unix, endUnix > startUnix else { return nil }
        let start = Date(timeIntervalSince1970: Double(startUnix)), end = Date(timeIntervalSince1970: Double(endUnix))
        // Only ring-emitted stages enter recovery; upstream also offers unvalidated signal estimates.
        let codes = n.staging_source == "ring" ? (n.hypnogram ?? []) : []
        let epoch = 30.0 // Ring epochs are measurements, never stretched to fit a bed window.
        let stages = codes.enumerated().compactMap { index, code -> PersonalStage? in
            let at = start.addingTimeInterval(Double(index) * epoch)
            guard (1...4).contains(code), at < end else { return nil }
            return PersonalStage(start: at, end: min(end, at.addingTimeInterval(epoch)), label: ["", "Deep", "Core", "REM", "Awake"][code])
        }
        // Time in bed is not sleep duration. Missing/incomplete staging remains unavailable.
        let complete = !codes.isEmpty && n.stagingComplete && codes.allSatisfy { (1...4).contains($0) } && abs(Double(codes.count) * epoch - end.timeIntervalSince(start)) < epoch && (n.staging_coverage_pct ?? 100) >= 95
        let hours = complete ? Double(codes.filter { (1...3).contains($0) }.count) * epoch / 3600 : nil
        let restorative = complete ? Double(codes.filter { $0 == 1 || $0 == 3 }.count) * epoch / 3600 : nil
        let hr = (n.series_t?.hr ?? []).compactMap { pair -> PersonalPoint? in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite, pair[1] > 0,
                  pair[0] >= Double(startUnix), pair[0] < Double(endUnix) else { return nil }
            return PersonalPoint(time: Date(timeIntervalSince1970: pair[0]), value: pair[1])
        }
        let hrv = (n.series_t?.hrv ?? []).compactMap { pair -> PersonalPoint? in
            guard pair.count >= 2, pair[0].isFinite, pair[1].isFinite, pair[1] > 0,
                  pair[0] >= Double(startUnix), pair[0] < Double(endUnix) else { return nil }
            return PersonalPoint(time: Date(timeIntervalSince1970: pair[0]), value: pair[1])
        }
        return PersonalNight(start: start, end: end, source: .ring,
            identity: identity + "|" + (n.staging_source ?? "ring"), hours: hours, restorativeHours: restorative, stages: stages, heartRate: hr, hrvSeries: hrv, hrvMethod: "RMSSD",
            bedStart: start, bedEnd: end, provenance: "Ring-emitted stages; missing epochs remain unknown")
    }
    private static func workoutTitle(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycling"
        case .swimming: return "Swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength training"
        case .yoga: return "Yoga"
        case .hiking: return "Hike"
        default: return "Workout"
        }
    }
}
