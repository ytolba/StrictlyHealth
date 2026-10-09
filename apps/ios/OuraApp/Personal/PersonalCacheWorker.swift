import Foundation
import SwiftData

// Created on a background executor. Its SwiftData context never crosses actors.
@ModelActor actor PersonalCacheWorker {
    func load() throws -> (days: [PersonalDay], refreshedAt: Date?, archiveCount: Int) {
        let rows = try modelContext.fetch(FetchDescriptor<PersonalCachedDay>())
        let days = rows.compactMap { try? JSONDecoder().decode(PersonalDay.self, from: $0.payload) }.sorted { $0.date < $1.date }
        return (days, rows.map(\.refreshedAt).max(), PersonalArchive.load().count)
    }

    // Stable encoding lets us avoid rewriting unchanged history and redrawing charts.
    static func payload(_ day: PersonalDay) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(day)
    }

    func persist(_ days: [PersonalDay]) throws -> Bool {
        do {
            let existing = try modelContext.fetch(FetchDescriptor<PersonalCachedDay>())
            let byKey = Dictionary(existing.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
            let keys = Set(days.map { PersonalAssembler.dayKey($0.date) })
            var changed = false
            for row in existing where !keys.contains(row.dayKey) { modelContext.delete(row); changed = true }
            for day in days {
                let key = PersonalAssembler.dayKey(day.date)
                let data = try Self.payload(day)
                if let row = byKey[key] {
                    if row.payload != data { row.payload = data; row.refreshedAt = Date(); changed = true }
                } else {
                    modelContext.insert(PersonalCachedDay(dayKey: key, payload: data)); changed = true
                }
            }
            if changed { try modelContext.save() }
            return changed
        } catch { modelContext.rollback(); throw error }
    }
}
