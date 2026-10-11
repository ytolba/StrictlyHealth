import Foundation

enum YouraHabit: String, Codable, CaseIterable, Identifiable {
    case caffeine, lateMeal, alcohol, stress, freeDay
    var id: String { rawValue }
    var title: String {
        switch self {
        case .caffeine: return "Caffeine"
        case .lateMeal: return "Late meal"
        case .alcohol: return "Alcohol"
        case .stress: return "Felt stressed"
        case .freeDay: return "Free day"
        }
    }
}
enum HabitAnswer: String, Codable, CaseIterable { case unknown = "Unknown", yes = "Yes", no = "No" }
struct HabitEntry: Codable, Identifiable {
    var id = UUID()
    var nightDate: Date
    var habit: YouraHabit
    var answer: HabitAnswer
    var time: Date? = nil
}
struct VoiceJournalDraft {
    var nightDate: Date
    var entries: [HabitEntry]
    var questions: [String] = []
    var mentioned: [YouraHabit] = []
    static func empty(date: Date) -> Self {
        Self(nightDate: date, entries: YouraHabit.allCases.map { HabitEntry(nightDate: date, habit: $0, answer: .unknown) })
    }
    /// Conservative English extraction: the review UI, not recognition, commits facts.
    static func parse(_ text: String, date: Date, calendar: Calendar = .current) -> Self {
        var draft = empty(date: date)
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let clauses = lower.components(separatedBy: CharacterSet(charactersIn: ",.;!?"))
            .flatMap { $0.components(separatedBy: " but ") }.flatMap { $0.components(separatedBy: " and ") }
        let patterns: [YouraHabit: String] = [
            .caffeine: "\\b(coffee|caffeine|espresso|energy drink|tea)\\b",
            .lateMeal: "\\b(late meal|late dinner|ate late|eating late)\\b",
            .alcohol: "\\b(alcohol|beer|wine|cocktail|drank alcohol)\\b",
            .stress: "\\b(stress|stressed|stressful|anxious)\\b",
            .freeDay: "\\b(free day|day off|workday|work day)\\b"
        ]
        for habit in YouraHabit.allCases {
            var answers: [HabitAnswer] = []
            for clause in clauses where clause.range(of: patterns[habit]!, options: .regularExpression) != nil {
                let mentioned = patterns.values.filter { clause.range(of: $0, options: .regularExpression) != nil }.count
                let uncertain = mentioned > 1 || clause.range(of: "\\b(maybe|unsure|uncertain|don't know|not sure|not much|less|little|hardly|decaf|herbal|if)\\b", options: .regularExpression) != nil
                let negative = clause.range(of: "\\b(no|not|never|without|didn't|did not|wasn't|was not|isn't|haven't|hadn't|none|skipped|avoided)\\b", options: .regularExpression) != nil
                let workday = habit == .freeDay && clause.range(of: "\\b(workday|work day)\\b", options: .regularExpression) != nil
                answers.append(uncertain ? .unknown : (workday ? (negative ? .yes : .no) : (negative ? .no : .yes)))
                if let match = clause.range(of: "\\b([0-9]{1,2})(:[0-9]{2})?\\s*(am|pm)\\b", options: .regularExpression) {
                    let raw = String(clause[match]).replacingOccurrences(of: " ", with: "")
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
                    f.dateFormat = raw.contains(":") ? "h:mma" : "ha"
                    if let time = f.date(from: raw), let i = draft.entries.firstIndex(where: { $0.habit == habit }) {
                        let c = calendar.dateComponents([.hour, .minute], from: time)
                        let evening = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) ?? date
                        draft.entries[i].time = calendar.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: evening)
                        draft.questions.append("Confirm the date and time for \(habit.title.lowercased()).")
                    }
                } else if clause.range(of: "\\b(at|around|about)\\s+([0-9]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\b", options: .regularExpression) != nil {
                    draft.questions.append("What time was \(habit.title.lowercased())? Include AM or PM, or leave the time unknown.")
                }
            }
            guard !answers.isEmpty, let i = draft.entries.firstIndex(where: { $0.habit == habit }) else { continue }
            draft.mentioned.append(habit)
            let unique = Set(answers.map(\.rawValue))
            draft.entries[i].answer = unique.count == 1 ? answers[0] : .unknown
            if unique.count > 1 || answers.contains(.unknown) {
                draft.questions.append("Was \(habit.title.lowercased()) yes or no for this night?")
            }
            if draft.entries[i].answer != .yes { draft.entries[i].time = nil }
        }
        if lower.range(of: "\\b(yesterday|tomorrow|last night|today)\\b", options: .regularExpression) != nil {
            draft.questions.append("Confirm which wake-up date these habits belong to.")
        }
        if draft.entries.allSatisfy({ $0.answer == .unknown }) { draft.questions.append("Tell me about caffeine, a late meal, alcohol, stress, or whether it was a free day.") }
        return draft
    }
    func applyingFollowup(_ text: String, habit: YouraHabit, calendar: Calendar = .current) -> Self {
        var result = self
        let simple = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: .punctuationCharacters)
        if let answer = ["yes": HabitAnswer.yes, "no": .no, "unknown": .unknown][simple], let i = result.entries.firstIndex(where: { $0.habit == habit }) {
            result.entries[i].answer = answer
            if answer != .yes { result.entries[i].time = nil }
        } else {
            let parsed = Self.parse(text, date: nightDate, calendar: calendar)
            for entry in parsed.entries where parsed.mentioned.contains(entry.habit) {
                if let i = result.entries.firstIndex(where: { $0.habit == entry.habit }) { result.entries[i] = entry }
            }
            result.questions = parsed.questions
        }
        return result
    }
}

actor YouraJournalStore {
    private let url: URL
    private struct Envelope: Codable { var version = 1; var entries: [HabitEntry] }
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouraJournal/entries.json")
    }
    func load() throws -> [HabitEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return envelope.entries
    }
    func save(_ entries: [HabitEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Envelope(entries: entries)).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

struct PatternEvidence: Identifiable {
    let date: Date
    let group: String
    let value: Double
    var id: Date { date }
}
struct PatternInsight: Identifiable {
    let id: String
    let title: String
    let metric: PersonalMetric
    let groupA: String
    let groupB: String
    let evidence: [PatternEvidence]
    let source: String
    var a: [Double] { evidence.filter { $0.group == groupA }.map(\.value) }
    var b: [Double] { evidence.filter { $0.group == groupB }.map(\.value) }
    var supported: Bool { a.count >= 5 && b.count >= 5 }
    var difference: Double? { supported ? YouraInsights.median(a)! - YouraInsights.median(b)! : nil }
    var explanation: String {
        guard let difference else { return "\(a.count)/5 \(groupA.lowercased()) nights · \(b.count)/5 \(groupB.lowercased()) nights" }
        let precision = metric == .sleep ? 1.0 / 120 : 0.5
        if abs(difference) < precision { return "Recorded medians are similar at this display precision." }
        if id.hasPrefix("schedule-") { return "\(groupA): median clock time \(Int(abs(difference).rounded())) min \(difference >= 0 ? "later" : "earlier") than \(groupB.lowercased())." }
        return "\(groupA): median \(metric.title.lowercased()) \(PersonalDisplay.value(abs(difference), metric: metric)) \(difference >= 0 ? "higher" : "lower") than \(groupB.lowercased())."
    }
}
struct OvernightHRShape {
    let firstMedian: Double?
    let lastMedian: Double?
    let lowestWindow: Date?
    let lowestMedian: Double?
}
struct InsightContext: Codable {
    struct Fact: Codable { let label: String; let value: String }
    let nightDate: String?
    let source: String
    let facts: [Fact]
    let patterns: [String]
    let limitations: String
    var preview: String {
        (["Night: \(nightDate ?? "unavailable")", "Source: \(source)"] + facts.map { "\($0.label): \($0.value)" } + patterns + [limitations]).joined(separator: "\n")
    }
}
struct YouraInsightSnapshot {
    var patterns: [PatternInsight] = []
    var brief: [String] = ["Sync a complete night to start your morning brief."]
    var context = InsightContext(nightDate: nil, source: "Unavailable", facts: [], patterns: [], limitations: "No valid night available. Associations are not causes or diagnoses.")
    var hr: OvernightHRShape? = nil
    var latestDate: Date? = nil
}
enum YouraInsights {
    static func median(_ values: [Double]) -> Double? {
        let x = values.filter(\.isFinite).sorted(); guard !x.isEmpty else { return nil }
        return x.count % 2 == 0 ? (x[x.count / 2 - 1] + x[x.count / 2]) / 2 : x[x.count / 2]
    }
    static func valid(_ night: PersonalNight) -> Bool {
        guard !night.identity.hasPrefix("oura-account-export"), night.start < night.end,
              night.end.timeIntervalSince(night.start) <= 24 * 3600,
              let hours = night.hours, hours.isFinite, hours > 0, hours <= 24,
              hours * 3600 <= night.end.timeIntervalSince(night.start) + 1,
              let onset = night.asleepStart, let wake = night.asleepEnd,
              onset >= night.start, wake <= night.end, wake > onset,
              night.coverage >= 0.95 else { return false }
        return !night.stages.isEmpty && night.stages.allSatisfy {
            ["Deep", "Core", "REM", "Asleep", "Awake"].contains($0.label) && $0.start >= night.start && $0.end <= night.end && $0.end > $0.start
        }
    }
    static func comparable(_ candidate: PersonalNight, _ latest: PersonalNight) -> Bool {
        valid(candidate) && candidate.source == latest.source && candidate.identity == latest.identity && candidate.hrvMethod == latest.hrvMethod
    }
    static func heartRate(_ night: PersonalNight) -> OvernightHRShape {
        let samples = night.heartRate.filter { $0.time >= night.start && $0.time < night.end && $0.value.isFinite && (25...240).contains($0.value) }.sorted { $0.time < $1.time }
        // Deduplicate timestamps so repeated records cannot manufacture coverage.
        let unique = Dictionary(samples.map { ($0.time, $0.value) }, uniquingKeysWith: { first, _ in first }).map { PersonalPoint(time: $0.key, value: $0.value) }.sorted { $0.time < $1.time }
        func sufficientlySampled(_ points: [PersonalPoint], span: TimeInterval) -> Bool {
            guard points.count >= 3, let first = points.first, let last = points.last,
                  last.time.timeIntervalSince(first.time) >= span * 0.65 else { return false }
            return zip(points, points.dropFirst()).allSatisfy { $1.time.timeIntervalSince($0.time) <= max(300, span / 3) }
        }
        let third = night.end.timeIntervalSince(night.start) / 3
        let first = unique.filter { $0.time < night.start.addingTimeInterval(third) }
        let last = unique.filter { $0.time >= night.end.addingTimeInterval(-third) }
        var lowest: (Date, Double)?
        for point in unique {
            let end = point.time.addingTimeInterval(900)
            guard end <= night.end else { continue }
            let window = unique.filter { $0.time >= point.time && $0.time < end }
            if sufficientlySampled(window, span: 900), let m = median(window.map(\.value)), lowest == nil || m < lowest!.1 { lowest = (point.time, m) }
        }
        return OvernightHRShape(firstMedian: sufficientlySampled(first, span: third) ? median(first.map(\.value)) : nil,
            lastMedian: sufficientlySampled(last, span: third) ? median(last.map(\.value)) : nil, lowestWindow: lowest?.0, lowestMedian: lowest?.1)
    }
    static func build(days: [PersonalDay], entries: [HabitEntry], now: Date = Date(), calendar: Calendar = .current) -> YouraInsightSnapshot {
        var result = YouraInsightSnapshot()
        guard let latest = days.filter({ $0.date <= now && $0.night.map(valid) == true }).max(by: { $0.date < $1.date }), let night = latest.night else { return result }
        result.latestDate = latest.date
        let cutoff = calendar.date(byAdding: .day, value: -59, to: latest.date)!
        let eligible = days.filter { $0.date >= cutoff && $0.date <= latest.date && $0.night.map { comparable($0, night) } == true }
        let candidates = Dictionary(eligible.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.date < $1.date }
        func answer(_ habit: YouraHabit, _ date: Date) -> HabitAnswer {
            entries.last { $0.habit == habit && calendar.isDate($0.nightDate, inSameDayAs: date) }?.answer ?? .unknown
        }
        let outcomes: [PersonalMetric] = [.sleep, .efficiency, .awakenings, .latency]
        func pattern(_ id: String, _ title: String, _ metric: PersonalMetric, _ a: String, _ b: String, classify: (PersonalDay) -> String?, value: (PersonalNight) -> Double?) {
            let evidence = candidates.compactMap { day -> PatternEvidence? in
                guard let group = classify(day), let n = day.night, let v = value(n), v.isFinite else { return nil }
                return PatternEvidence(date: day.date, group: group, value: v)
            }
            result.patterns.append(PatternInsight(id: id, title: title, metric: metric, groupA: a, groupB: b, evidence: evidence, source: night.sleepSourceTitle))
        }
        for habit in YouraHabit.allCases where habit != .freeDay {
            for metric in outcomes {
                pattern("\(habit.rawValue)-\(metric.rawValue)", habit.title, metric, "Yes", "No", classify: { day in
                    let x = answer(habit, day.date); return x == .unknown ? nil : x.rawValue
                }, value: { $0.value(metric) })
            }
        }
        let workouts = Dictionary(days.flatMap(\.workouts).map { ($0.id, $0) }, uniquingKeysWith: { old, _ in old }).values
        for metric in outcomes {
            pattern("workout-\(metric.rawValue)", "Workout timing", metric, "Within 2h", "Earlier", classify: { day in
                guard let onset = day.night?.asleepStart else { return nil }
                let previousDay = onset.addingTimeInterval(-24 * 3600)
                let ends = workouts.filter { $0.minutes.isFinite && $0.minutes > 0 }.map { $0.start.addingTimeInterval($0.minutes * 60) }.filter { $0 >= previousDay && $0 <= onset }
                guard let end = ends.max() else { return nil }
                return onset.timeIntervalSince(end) <= 7200 ? "Within 2h" : "Earlier"
            }, value: { $0.value(metric) })
        }
        // Unwrap clock times around the latest night, rather than averaging across midnight.
        func clock(_ date: Date, relativeTo reference: Date) -> Double {
            func minutes(_ x: Date) -> Double { let c = calendar.dateComponents([.hour, .minute], from: x); return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) }
            var difference = minutes(date) - minutes(reference)
            if difference > 720 { difference -= 1440 }; if difference < -720 { difference += 1440 }
            return difference
        }
        for (id, title, ref, get) in [
            ("onset", "Fell asleep", night.asleepStart!, { (n: PersonalNight) in n.asleepStart }),
            ("wake", "Woke up", night.asleepEnd!, { (n: PersonalNight) in n.asleepEnd }),
            ("midpoint", "Sleep midpoint", night.sleepWindowMidpoint!, { (n: PersonalNight) in n.sleepWindowMidpoint })
        ] {
            pattern("schedule-\(id)", "Schedule drift · \(title)", .latency, "Free day", "Work day", classify: { day in
                switch answer(.freeDay, day.date) { case .yes: return "Free day"; case .no: return "Work day"; case .unknown: return nil }
            }, value: { n in get(n).map { clock($0, relativeTo: ref) } })
        }
        result.hr = heartRate(night)
        result.brief = ["\(PersonalDisplay.value(night.hours, metric: .sleep)) recorded · \(night.sleepSourceTitle)."]
        let baselineStart = calendar.date(byAdding: .day, value: -28, to: latest.date)!
        let baseline = candidates.filter { $0.date >= baselineStart && $0.date < latest.date }.compactMap { $0.night?.hours }
        if baseline.count >= 14, let median = median(baseline), let hours = night.hours {
            if abs(hours - median) < 1.0 / 120 { result.brief.append("Close to your preceding \(baseline.count)-night median.") }
            else { result.brief.append("\(PersonalDisplay.value(abs(hours - median), metric: .sleep)) \(hours >= median ? "above" : "below") your preceding \(baseline.count)-night median.") }
        } else { result.brief.append("Building your baseline: \(baseline.count)/14 comparable nights in the preceding 28 days.") }
        if let pattern = result.patterns.first(where: \.supported) { result.brief.append(pattern.title + ": " + pattern.explanation) }
        else { result.brief.append("More confirmed check-ins are needed to compare your patterns.") }
        let facts = outcomes.compactMap { metric -> InsightContext.Fact? in
            guard let value = night.value(metric), value.isFinite else { return nil }
            return .init(label: metric.title, value: PersonalDisplay.value(value, metric: metric))
        } + [InsightContext.Fact(label: "Fell asleep", value: night.asleepStart!.formatted(date: .abbreviated, time: .shortened)), .init(label: "Woke up", value: night.asleepEnd!.formatted(date: .abbreviated, time: .shortened))]
        result.context = InsightContext(nightDate: latest.date.formatted(date: .abbreviated, time: .omitted), source: night.sleepSourceTitle,
            facts: facts, patterns: [], limitations: "Stage coverage \(Int(night.coverage * 100))%. Missing metrics are unknown. Baseline: \(baseline.count) comparable nights. Associations are not causes or diagnoses. No raw samples, identifiers, or journal history included.")
        return result
    }
}
