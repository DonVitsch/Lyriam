import Foundation

/// System Settings and IOBluetooth can hold different names after a rename.
/// The public system_profiler report supplies the current name for the exact address.
struct SystemBluetoothDevice: Equatable {
    let name: String
    let connected: Bool
    let headphone: Bool
    let vendorID: Int?
    let productID: Int?
    let left: Int?
    let right: Int?
    let chargingCase: Int?
    let single: Int?
}

enum BluetoothSystemSnapshot {
    static func read() -> [String: SystemBluetoothDevice]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, data.count <= 2_000_000 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String: SystemBluetoothDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["SPBluetoothDataType"] as? [[String: Any]],
              groups.contains(where: { $0["controller_properties"] != nil }) else { return nil }
        var result: [String: SystemBluetoothDevice] = [:]
        for group in groups {
            // Connected records win if the system briefly lists an address twice.
            for (key, connected) in [("device_not_connected", false), ("device_connected", true)] {
                for record in group[key] as? [[String: Any]] ?? [] {
                    for (name, value) in record {
                        guard let info = value as? [String: Any],
                              let address = info["device_address"] as? String,
                              let id = normalizedAddress(address) else { continue }
                        let kind = (info["device_minorType"] as? String ?? "").lowercased()
                        result[id] = SystemBluetoothDevice(name: name, connected: connected,
                            headphone: ["headphones", "headset", "handsfree"].contains(kind),
                            vendorID: hex(info["device_vendorID"]), productID: hex(info["device_productID"]),
                            left: battery(info["device_batteryLevelLeft"]), right: battery(info["device_batteryLevelRight"]),
                            chargingCase: battery(info["device_batteryLevelCase"]), single: battery(info["device_batteryLevelMain"]))
                    }
                }
            }
        }
        return result
    }

    private static func hex(_ value: Any?) -> Int? {
        guard let string = value as? String else { return nil }
        return Int(string.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    private static func battery(_ value: Any?) -> Int? {
        guard let string = value as? String, let value = Int(string.replacingOccurrences(of: "%", with: "")),
              (0...100).contains(value) else { return nil }
        return value
    }

    private static func normalizedAddress(_ value: String) -> String? {
        let address = value.replacingOccurrences(of: "-", with: ":").uppercased()
        guard address.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else { return nil }
        return address
    }
}
