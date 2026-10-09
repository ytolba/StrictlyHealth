import Foundation

enum RingGeneration: String, Codable, CaseIterable, Identifiable {
    case unknown, gen1, gen2, gen3, ring4, ring5
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: return "Not sure / newer model"
        case .gen1: return "Oura first generation"
        case .gen2: return "Oura Gen 2"
        case .gen3: return "Oura Gen 3 · Heritage / Horizon"
        case .ring4: return "Oura Ring 4 · including Ceramic"
        case .ring5: return "Oura Ring 5"
        }
    }
    var permitsDirectSync: Bool { [.gen3, .ring4, .ring5, .unknown].contains(self) }
    var permitsPairing: Bool { [.gen3, .ring4, .ring5].contains(self) }
    var supportNote: String {
        switch self {
        case .gen3: return "Direct sync confirmed on one Gen 3 Horizon. This is not validation of every firmware or metric."
        case .ring4: return "Shared protocol implementation; live sync has not been tested on Ring 4 in this app. Treat as experimental."
        case .ring5: return "Upstream reports Ring 5 sync. This fork has not been hardware-tested on Ring 5; treat as experimental."
        case .gen1, .gen2: return "Legacy Bluetooth is not validated here. Use Oura account export import or available Apple Health records; direct sync and pairing are disabled."
        case .unknown: return "Identify your ring before pairing. Existing-key sync is experimental; matching Bluetooth services do not prove model compatibility."
        }
    }
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "ring.generation") ?? "") ?? .unknown
    }
}
