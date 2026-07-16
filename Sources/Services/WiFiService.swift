import CoreWLAN
import CoreLocation
import Foundation

/// Holds a CLLocationManager so Wi‑Fi scanning can prompt for Location (required on modern macOS).
private final class WiFiLocationHelper: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiLocationHelper()
    private let manager = CLLocationManager()

    private override init() {
        super.init()
        manager.delegate = self
    }

    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }
}

struct WiFiNetworkInfo: Hashable {
    let ssid: String
    let rssi: Int
    let isSecure: Bool
    let isCurrent: Bool

    var signalBars: Int {
        // Rough map of dBm → 1…3 bars
        if rssi >= -55 { return 3 }
        if rssi >= -70 { return 2 }
        return 1
    }
}

/// Wi‑Fi status / scan / connect via CoreWLAN.
enum WiFiService {
    static var isPoweredOn: Bool {
        get { interface()?.powerOn() ?? false }
        set {
            do {
                try interface()?.setPower(newValue)
            } catch {
                AppLog.error("wifi setPower failed", ["error": "\(error)"])
            }
        }
    }

    static var currentSSID: String? {
        interface()?.ssid()
    }

    static func togglePower() {
        isPoweredOn.toggle()
    }

    static func scanNetworks() -> [WiFiNetworkInfo] {
        WiFiLocationHelper.shared.requestIfNeeded()
        guard let iface = interface(), iface.powerOn() else { return [] }
        let current = iface.ssid()
        do {
            let found = try iface.scanForNetworks(withName: nil)
            let mapped = found.compactMap { net -> WiFiNetworkInfo? in
                guard let ssid = net.ssid, !ssid.isEmpty else { return nil }
                return WiFiNetworkInfo(
                    ssid: ssid,
                    rssi: net.rssiValue,
                    isSecure: !net.supportsSecurity(.none),
                    isCurrent: ssid == current
                )
            }
            // Dedupe by SSID, keep strongest signal
            var best: [String: WiFiNetworkInfo] = [:]
            for info in mapped {
                if let existing = best[info.ssid] {
                    if info.rssi > existing.rssi { best[info.ssid] = info }
                } else {
                    best[info.ssid] = info
                }
            }
            return best.values.sorted { a, b in
                if a.isCurrent != b.isCurrent { return a.isCurrent }
                return a.rssi > b.rssi
            }
        } catch {
            AppLog.warn("wifi scan failed", ["error": "\(error)"])
            // Still surface the current network if known
            if let current, !current.isEmpty {
                return [WiFiNetworkInfo(ssid: current, rssi: -50, isSecure: true, isCurrent: true)]
            }
            return []
        }
    }

    static func disconnect() {
        interface()?.disassociate()
    }

    /// Associate to a network. Pass `nil` password for open networks.
    static func connect(ssid: String, password: String?) -> String? {
        guard let iface = interface() else { return "No Wi‑Fi interface" }
        do {
            let networks = try iface.scanForNetworks(withName: ssid)
            guard let network = networks.first else { return "Network not found" }
            try iface.associate(to: network, password: password)
            return nil
        } catch {
            AppLog.error("wifi connect failed", ["ssid": ssid, "error": "\(error)"])
            return error.localizedDescription
        }
    }

    private static func interface() -> CWInterface? {
        CWWiFiClient.shared().interface()
    }
}
