import Foundation

enum PersonalSleepInput: String, Codable, CaseIterable, Identifiable {
    case directRing = "Oura · direct Bluetooth"
    case watch = "Apple Watch · Apple Health"
    case automatic = "Automatic fallback"
    var id: String { rawValue }
}

enum PersonalSleepSelection {
    static func choose(direct: PersonalNight?, health: [PersonalSource: PersonalNight], input: PersonalSleepInput, preferred: PersonalSource) -> PersonalNight? {
        switch input {
        case .directRing: return direct?.isDirectRing == true ? direct : nil
        case .watch: return health[.watch]
        case .automatic:
            let complete = direct.flatMap { $0.hours == nil ? nil : $0 }
            return preferred == .ring ? (complete ?? health[.ring] ?? health[.watch] ?? direct) : (health[.watch] ?? complete ?? health[.ring] ?? direct)
        }
    }
}

extension PersonalNight {
    var isDirectRing: Bool { source == .ring && identity.hasPrefix("direct-ring") }
    var sleepSourceTitle: String {
        if identity.hasPrefix("oura-account-export") { return "Oura export · Historical" }
        if isDirectRing { return "Oura · Bluetooth" }
        return source == .watch ? "Apple Watch · Apple Health" : "Oura · Apple Health"
    }
}

extension PersonalDay {
    var sleepSourceTitle: String {
        night?.sleepSourceTitle ?? ((sleepInput ?? .directRing) == .watch ? "Apple Watch requested" : ((sleepInput ?? .directRing) == .automatic ? "No sleep source available" : "Direct Oura requested"))
    }
    var sleepUnavailableMessage: String {
        switch sleepInput ?? .directRing {
        case .directRing: return "No direct Oura sleep synced for this day. Open Ring → Sync ring. Apple Health sleep is not used in this mode."
        case .watch: return "No Apple Watch sleep for this day. Check Apple Health access and Watch recordings."
        case .automatic: return "No sleep session for this day. Sync your ring or check Apple Health access."
        }
    }
    // Apply policy to old caches too: a pre-update fallback must not appear as
    // direct sleep while a fresh database/HealthKit refresh is in progress.
    func enforcingSleepInput(_ input: PersonalSleepInput) -> Self {
        var result = self
        result.sleepInput = input
        switch input {
        case .directRing: result.night = directRingNight?.isDirectRing == true ? directRingNight : (night?.isDirectRing == true ? night : nil)
        case .watch: result.night = night?.source == .watch ? night : nil
        case .automatic: break
        }
        let sleepMetrics = PersonalMetric.allCases.filter { $0.sleepMetric || $0 == .averageHR }
        for metric in sleepMetrics {
            result.values.removeValue(forKey: metric.rawValue)
            if let night = result.night, let value = night.value(metric) {
                result.values[metric.rawValue] = PersonalValue(value: value, source: night.source, identity: night.identity, method: "sleep timeline")
            }
        }
        return result
    }
}
