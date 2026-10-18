import Combine
import Foundation

struct PairedProfile: Codable, Equatable, Sendable {
    var version: Int = 1
    var name: String
    var host: String
    var tcpPort: UInt16 = 8889
    var udpPort: UInt16 = 8888
}

@MainActor
final class PairingProfileStore: ObservableObject {
    static let shared = PairingProfileStore()

    @Published private(set) var profile: PairedProfile?

    private static let key = "vpad.pairedProfile"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PairedProfile.self, from: data) {
            profile = decoded
        }
    }

    func save(_ profile: PairedProfile) {
        self.profile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func clear() {
        profile = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Accepts either the Mac's JSON payload or a vpad://pair URL with the same fields.
    func decode(_ string: String) -> PairedProfile? {
        let json: String
        if let url = URL(string: string), url.scheme == "vpad", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var dict: [String: Any] = [:]
            for item in components.queryItems ?? [] {
                if let value = item.value {
                    dict[item.name] = value
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let host = object["host"] as? String, let name = object["name"] as? String {
                let tcp = UInt16(object["tcp"] as? String ?? "") ?? 8889
                let udp = UInt16(object["udp"] as? String ?? "") ?? 8888
                return PairedProfile(name: name, host: host, tcpPort: tcp, udpPort: udp)
            }
            return nil
        }
        json = string
        guard let data = json.data(using: .utf8),
              let profile = try? JSONDecoder().decode(PairedProfile.self, from: data),
              !profile.host.isEmpty else {
            return nil
        }
        return profile
    }
}
