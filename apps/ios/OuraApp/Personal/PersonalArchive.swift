import Foundation

struct PersonalArchiveRecord: Codable, Identifiable {
    var table: String
    var day: String
    var fields: [String: String]
    var id: String { table + "|" + day + "|" + (fields["id"] ?? fields["timestamp"] ?? fields["bedtime_start"] ?? "daily") }
    func number(_ key: String) -> Double? {
        guard let raw = fields[key], let value = Double(raw), value.isFinite else { return nil }
        return value
    }
}

// Original importer: no account credentials, vendor SDK, or third-party executable code.
// The Oura account archive is normally semicolon-delimited CSV. JSON arrays and
// {"data": [...]} exports are also accepted; all dated fields remain inspectable.
enum PersonalArchive {
    struct ImportResult { var records: [PersonalArchiveRecord]; var skipped: Int }
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("oura-history.json")
    }
    static func load() -> [PersonalArchiveRecord] {
        (try? loadValidated()) ?? []
    }
    static func loadValidated() throws -> [PersonalArchiveRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PersonalArchiveRecord].self, from: Data(contentsOf: url))
    }
    static func save(_ records: [PersonalArchiveRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read(_ urls: [URL]) throws -> ImportResult {
        var files: [URL] = [], scopes: [URL] = []
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scopes.append(url) }
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { continue }
            if info.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in enumerator {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if info.isRegularFile == true && ["csv", "json"].contains(file.pathExtension.lowercased()) { files.append(file) }
                    if files.count > 300 { throw ImportError.invalid("Too many files. Select just your unzipped Oura data folder.") }
                }
            } else { files.append(url) }
        }
        var records: [PersonalArchiveRecord] = [], skipped = 0, totalBytes = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard ["csv", "json"].contains(file.pathExtension.lowercased()) else {
                throw ImportError.invalid("Unzip the Oura download in Files first, then choose its folder or CSV files.")
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            totalBytes += size
            guard size <= 50_000_000, totalBytes <= 200_000_000 else { throw ImportError.invalid("This selection is too large. Import smaller groups of CSV files.") }
            let result = try parse(Data(contentsOf: file), table: file.deletingPathExtension().lastPathComponent, json: file.pathExtension.lowercased() == "json")
            records += result.records; skipped += result.skipped
        }
        guard !records.isEmpty else { throw ImportError.invalid("No dated Oura records found. Select the unzipped account data export, not a settings file.") }
        return ImportResult(records: records, skipped: skipped)
    }
    static func parse(_ data: Data, table: String, json: Bool = false) throws -> ImportResult {
        var dictionaries: [[String: String]] = []
        if json {
            let object = try JSONSerialization.jsonObject(with: data)
            let rows = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            dictionaries = rows.map { row in row.mapValues { value in
                if value is NSNull { return "" }
                if let s = value as? String { return s }
                if JSONSerialization.isValidJSONObject(value), let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) { return s }
                return String(describing: value)
            } }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalid("Export must be UTF-8 text.") }
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let delimiter: Character = first.contains(";") ? ";" : ","
            let rows = try csv(text.replacingOccurrences(of: "\u{FEFF}", with: ""), delimiter: delimiter)
            guard let header = rows.first else { return ImportResult(records: [], skipped: 0) }
            guard Set(header).count == header.count else { throw ImportError.invalid("Duplicate CSV column names in \(table).") }
            for var row in rows.dropFirst() where row.contains(where: { !$0.isEmpty }) {
                // Some Oura exports omit the leading ID column, but never guess arbitrary alignment.
                if header.first == "id", row.count == header.count - 1 { row.insert("", at: 0) }
                guard row.count == header.count else { throw ImportError.invalid("Column mismatch in \(table). No records from this import were saved.") }
                dictionaries.append(Dictionary(uniqueKeysWithValues: zip(header, row)))
            }
        }
        let records = dictionaries.compactMap { fields -> PersonalArchiveRecord? in
            let raw = fields["day"] ?? fields["timestamp"] ?? fields["bedtime_end"] ?? fields["start_time"] ?? ""
            let day = String(raw.prefix(10))
            guard date(day) != nil else { return nil }
            return PersonalArchiveRecord(table: table.lowercased().replacingOccurrences(of: "_", with: ""), day: day, fields: fields.filter { !$0.value.isEmpty && !["null", "nan", "none"].contains($0.value.lowercased()) })
        }
        return ImportResult(records: records, skipped: dictionaries.count - records.count)
    }
    static func csv(_ text: String, delimiter: Character) throws -> [[String]] {
        // Swift treats CRLF as one Character; normalize before tokenizing.
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var i = 0, quoted = false, field = "", row: [String] = [], rows: [[String]] = []
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else if quoted || field.isEmpty { quoted.toggle() }
                else { field.append(c) } // JSON quotes in an unquoted semicolon field.
            } else if c == delimiter && !quoted { row.append(field); field = "" }
            else if (c == "\n" || c == "\r") && !quoted {
                row.append(field); rows.append(row); field = ""; row = []
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw ImportError.invalid("Unclosed quote in CSV. Re-export the file.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
    static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func sequence(_ raw: String?) -> [Double?] {
        guard let raw else { return [] }
        if let data = raw.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let values = (parsed as? [Any]) ?? ((parsed as? [String: Any])?["items"] as? [Any])
            if let values { return values.map { ($0 as? NSNumber)?.doubleValue } }
        }
        if raw.allSatisfy(\.isNumber) { return raw.map { Double(String($0)) } }
        return []
    }
    static func night(_ record: PersonalArchiveRecord) -> PersonalNight? {
        guard let start = timestamp(record.fields["bedtime_start"]), let end = timestamp(record.fields["bedtime_end"]), end > start else { return nil }
        let fine = sequence(record.fields["sleep_phase_30_sec"])
        let codes = fine.isEmpty ? sequence(record.fields["sleep_phase_5_min"]) : fine
        let epoch = fine.isEmpty ? 300.0 : 30.0
        let stages = codes.enumerated().compactMap { index, value -> PersonalStage? in
            guard let value, (1...4).contains(Int(value)), value.rounded() == value else { return nil }
            let a = start.addingTimeInterval(Double(index) * epoch), b = min(end, a.addingTimeInterval(epoch))
            guard b > a else { return nil }
            return PersonalStage(start: a, end: b, label: ["", "Deep", "Core", "REM", "Awake"][Int(value)])
        }
        var reported: [String: Double] = [:]
        for (metric, key, divisor) in [(PersonalMetric.deepSleep, "deep_sleep_duration", 3600.0), (.remSleep, "rem_sleep_duration", 3600), (.lightSleep, "light_sleep_duration", 3600), (.awake, "awake_time", 3600), (.latency, "latency", 60), (.efficiency, "efficiency", 1), (.averageHR, "average_heart_rate", 1), (.restlessPeriods, "restless_periods", 1), (.timeInBed, "time_in_bed", 3600)] {
            if let value = record.number(key), value >= 0 { reported[metric.rawValue] = value / divisor }
        }
        let hr = sequence(record.fields["heart_rate"]).enumerated().compactMap { index, value -> PersonalPoint? in
            guard let value, value.isFinite, value > 0 else { return nil }
            let time = start.addingTimeInterval(Double(index) * 300)
            guard time < end else { return nil }
            return PersonalPoint(time: time, value: value)
        }
        let duration = record.number("total_sleep_duration").flatMap { $0 >= 0 ? $0 / 3600 : nil }
        let restorative = reported[PersonalMetric.deepSleep.rawValue].flatMap { deep in reported[PersonalMetric.remSleep.rawValue].map { deep + $0 } }
        return PersonalNight(start: start, end: end, source: .ring, identity: "oura-account-export|sleep", hours: duration, restorativeHours: restorative, stages: stages, heartRate: hr, reported: reported, bedStart: start, bedEnd: end, provenance: "Oura account export · official reported values")
    }
    static func merge(_ live: [PersonalDay], records: [PersonalArchiveRecord]) -> [PersonalDay] {
        var days = Dictionary(uniqueKeysWithValues: live.map { (PersonalAssembler.dayKey($0.date), $0) })
        for (key, rows) in Dictionary(grouping: records, by: \.day) {
            guard let date = date(key) else { continue }
            var day = days[key] ?? PersonalDay(date: date)
            if let current = day.night, !current.identity.hasPrefix("oura-account-export") { day.liveNight = current }
            day.archiveRecords = rows.sorted { $0.id < $1.id }
            let nights = rows.filter { ["sleepmodel", "sleep", "sleepsession"].contains($0.table) }.compactMap(night)
            let imported = nights.max { ($0.hours ?? 0) < ($1.hours ?? 0) }
            if day.night?.hours == nil, let imported { day.night = imported }
            func set(_ metric: PersonalMetric, _ value: Double?, method: String = "Oura account export") {
                guard day.values[metric.rawValue] == nil, let value, value.isFinite else { return }
                day.values[metric.rawValue] = PersonalValue(value: value, source: .ring, identity: "oura-account-export", method: method)
            }
            if let n = day.night, n.identity.hasPrefix("oura-account-export") {
                for metric in PersonalMetric.allCases where metric.sleepMetric || metric == .averageHR { set(metric, n.value(metric)) }
            }
            for row in rows {
                switch row.table {
                case "dailysleep": set(.sleepScore, row.number("score"))
                case "dailyreadiness": set(.readinessScore, row.number("score")); set(.temperatureDeviation, row.number("temperature_deviation"))
                case "dailyactivity":
                    set(.activityScore, row.number("score")); set(.steps, row.number("steps")); set(.energy, row.number("active_calories"))
                    set(.totalEnergy, row.number("total_calories")); set(.distance, row.number("equivalent_walking_distance").map { $0 / 1000 })
                case "dailystress": set(.stress, row.number("stress_high").map { $0 / 3600 }); set(.restored, row.number("recovery_high").map { $0 / 3600 })
                case "dailycardiovascularage": set(.cardiovascularAge, row.number("vascular_age"))
                case "vo2max": set(.vo2Max, row.number("vo2_max"))
                case "dailyspo2":
                    set(.breathingDisturbances, row.number("breathing_disturbance_index"))
                    if let raw = row.fields["spo2_percentage"], let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { set(.oxygen, (obj["average"] as? NSNumber)?.doubleValue) }
                default: break
                }
            }
            // Only use the primary imported sleep session; naps are retained in the archive viewer.
            if let imported, let row = rows.first(where: { timestamp($0.fields["bedtime_start"]) == imported.start }) {
                set(.restingHR, row.number("lowest_heart_rate"), method: "Oura export lowest HR")
                set(.hrv, row.number("average_hrv"), method: "Oura export RMSSD")
                set(.respiratoryRate, row.number("average_breath"))
            }
            days[key] = day
        }
        return days.values.sorted { $0.date < $1.date }
    }
}
