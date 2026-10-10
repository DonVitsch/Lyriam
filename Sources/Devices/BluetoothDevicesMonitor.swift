import Foundation
import Combine
import CoreAudio
import CoreBluetooth
import IOBluetooth
import IOKit
import ObjectiveC.runtime

struct HeadphoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isConnected: Bool
    let isAudioOutput: Bool
    let isAirPods: Bool
    let batteryLevel: Int?
    let leftBatteryLevel: Int?
    let rightBatteryLevel: Int?
    let caseBatteryLevel: Int?
    let modelSymbol: String?
    let productID: Int?

    init(
        id: String, name: String, isConnected: Bool, isAudioOutput: Bool,
        isAirPods: Bool, batteryLevel: Int?, leftBatteryLevel: Int?,
        rightBatteryLevel: Int?, caseBatteryLevel: Int?, modelSymbol: String? = nil, productID: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isAudioOutput = isAudioOutput
        self.isAirPods = isAirPods
        self.batteryLevel = batteryLevel
        self.leftBatteryLevel = leftBatteryLevel
        self.rightBatteryLevel = rightBatteryLevel
        self.caseBatteryLevel = caseBatteryLevel
        self.modelSymbol = modelSymbol
        self.productID = productID
    }

    var symbol: String {
        if let modelSymbol { return modelSymbol }
        guard isAirPods else { return "headphones" }
        let model = name.lowercased()
        if model.contains("max") { return "airpodsmax" }
        if model.contains("pro") { return "airpodspro" }
        return "airpods"
    }
}

/// Device names are editable. Only a known Apple Device ID determines the
/// artwork for renamed AirPods; another vendor's matching product ID does not.
enum HeadphoneModelIdentity {
    static func symbol(vendorIDSource: Int?, vendorID: Int?, productID: Int?) -> String? {
        // Device ID Profile: source 1 is the Bluetooth SIG Company Identifier.
        guard vendorIDSource == 1, vendorID == 0x004C, let productID else { return nil }
        // Factual model-family IDs verified against Apple's macOS resources:
        // CoreBluetoothUI.framework/Resources/AssetPaths.plist and
        // AssetPaths-B768/B788/B515c/B515d/B868.plist. No private framework is
        // loaded, and unknown or future IDs are deliberately not guessed.
        switch productID {
        case 0x2002, 0x200F, 0x2013, 0x2019, 0x201B, 0x2030, 0x2032, 0x2036, 0x2037:
            return "airpods"
        case 0x200E, 0x2014, 0x2024, 0x2027:
            return "airpodspro"
        case 0x200A, 0x201F, 0x202D:
            return "airpodsmax"
        default:
            return nil
        }
    }
}

/// Resolves the brief overlap between Bluetooth connection notifications and
/// CoreAudio output updates without inventing a second entry for the same device.
enum BluetoothConnectionState {
    static func bluetoothAvailable(
        controllerPoweredOn: Bool, controllerPoweredOff: Bool, hasActiveOutput: Bool
    ) -> Bool {
        !controllerPoweredOff && (controllerPoweredOn || hasActiveOutput)
    }

    static func isConnected(
        bluetoothAvailable: Bool, reportedConnection: Bool,
        isAudioOutput: Bool, latestConnectionHint: Bool?
    ) -> Bool {
        bluetoothAvailable && (latestConnectionHint ?? (reportedConnection || isAudioOutput))
    }

    static func shouldAddAudioFallback(
        id: String, existingIDs: Set<String>, bluetoothAvailable: Bool,
        latestConnectionHint: Bool?
    ) -> Bool {
        bluetoothAvailable && !existingIDs.contains(id) && latestConnectionHint != false
    }
}

/// Observes connections that macOS already manages. It does not scan, pair, or
/// open an additional connection to headphones.
@MainActor
final class BluetoothDevicesMonitor: NSObject, ObservableObject {
    @Published private(set) var devices: [HeadphoneDevice] = []
    @Published private(set) var bluetoothAvailable = false
    @Published private(set) var statusMessage: String?

    var onConnectionChange: ((HeadphoneDevice, Bool) -> Void)?

    private var isRunning = false
    private var hasSnapshot = false
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var observedDevices: [String: IOBluetoothDevice] = [:]
    private var connectionHints: [String: (connected: Bool, expires: Date)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var systemDevices: [String: SystemBluetoothDevice] = [:]
    private var systemRefreshRunning = false
    private var systemRefreshPending = false
    private var snapshotGeneration = 0
    private var pendingConnectionEvents: [String: Bool] = [:]
    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    override init() {
        super.init()
    }

    deinit {
        fallbackTimer?.invalidate()
        refreshTask?.cancel()
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let outputListener {
            var address = outputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener
            )
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hasSnapshot = false
        installObservers()
        refresh()
        refreshSystemSnapshot()

        // Notifications provide immediate changes. This low-frequency fallback
        // also catches Bluetooth power changes and system-reported battery updates.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemSnapshot() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func stop() {
        isRunning = false
        snapshotGeneration += 1
        systemRefreshPending = false
        pendingConnectionEvents.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main, outputListener
            )
        }
        outputListener = nil
        observedDevices.removeAll()
        connectionHints.removeAll()
        hasSnapshot = false
    }

    func refresh() {
        let authorization = CBManager.authorization
        guard authorization != .denied && authorization != .restricted else {
            bluetoothAvailable = false
            statusMessage = "允许 Lyriam 使用蓝牙后，即可显示耳机连接状态。"
            // Permission loss is not a headphone disconnection event.
            devices = []
            hasSnapshot = false
            return
        }

        let output = Self.currentBluetoothOutput()
        let controller = IOBluetoothHostController.default()
        bluetoothAvailable = BluetoothConnectionState.bluetoothAvailable(
            controllerPoweredOn: controller?.powerState == kBluetoothHCIPowerStateON,
            controllerPoweredOff: controller?.powerState == kBluetoothHCIPowerStateOFF,
            hasActiveOutput: output != nil
        )
        statusMessage = bluetoothAvailable ? nil : "蓝牙已关闭或暂不可用。"
        if isRunning && connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: self, selector: #selector(deviceConnected(_:device:))
            )
        }

        var candidates = observedDevices
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] {
            guard let id = Self.deviceID(device) else { continue }
            candidates[id] = device
        }
        if let outputID = output?.address,
           let device = IOBluetoothDevice(addressString: outputID) {
            candidates[outputID] = device
        }
        for (id, metadata) in systemDevices where metadata.headphone {
            if candidates[id] == nil, let device = IOBluetoothDevice(addressString: id) { candidates[id] = device }
        }

        // Match by name only when the active device is unambiguous; two paired
        // devices can have identical names.
        let outputNameMatches = candidates.filter {
            Self.displayName($0.value) == output?.name
        }
        let outputNameID = outputNameMatches.count == 1 ? outputNameMatches.first?.key : nil

        let registryBatteries = bluetoothAvailable ? Self.registryBatteryLevels() : [:]
        var next: [HeadphoneDevice] = []
        let now = Date()
        connectionHints = connectionHints.filter { $0.value.expires > now }

        for (id, device) in candidates {
            let metadata = systemDevices[id]
            let name = metadata?.name ?? Self.displayName(device)
            let isOutput = output.map {
                $0.address == id || ($0.address == nil && outputNameID == id)
            } ?? false
            guard metadata?.headphone == true || Self.isHeadphone(device, name: name) || isOutput else { continue }
            let reportedConnection = metadata?.connected ?? device.isConnected()
            let hintedConnection = connectionHints[id]?.connected
            if hintedConnection == reportedConnection { connectionHints.removeValue(forKey: id) }
            let connected = BluetoothConnectionState.isConnected(
                bluetoothAvailable: bluetoothAvailable,
                reportedConnection: reportedConnection, isAudioOutput: isOutput,
                latestConnectionHint: hintedConnection
            )

            if isRunning && connected && disconnectNotifications[id] == nil {
                disconnectNotifications[id] = device.register(
                    forDisconnectNotification: self,
                    selector: #selector(deviceDisconnected(_:device:))
                )
            } else if !connected {
                disconnectNotifications.removeValue(forKey: id)?.unregister()
            }

            let battery = connected ? Self.reportedBattery(device) : .unknown
            let modelSymbol = metadata.flatMap {
                HeadphoneModelIdentity.symbol(vendorIDSource: 1, vendorID: $0.vendorID, productID: $0.productID)
            } ?? Self.cachedModelSymbol(device)
            next.append(HeadphoneDevice(
                id: id, name: name, isConnected: connected,
                isAudioOutput: connected && isOutput,
                isAirPods: modelSymbol != nil || name.localizedCaseInsensitiveContains("airpods"),
                batteryLevel: connected ? (metadata?.single ?? registryBatteries[id] ?? battery.single) : nil,
                leftBatteryLevel: connected ? (metadata?.left ?? battery.left) : nil,
                rightBatteryLevel: connected ? (metadata?.right ?? battery.right) : nil,
                caseBatteryLevel: connected ? (metadata?.chargingCase ?? battery.chargingCase) : nil,
                modelSymbol: modelSymbol, productID: metadata?.productID
            ))
        }

        // Some LE audio devices do not appear in the classic paired list. Their
        // active CoreAudio output is still an actual, connected Bluetooth device.
        if let output, !next.contains(where: { $0.isAudioOutput }) {
            let id = output.address ?? outputNameID ?? "audio:\(output.uid)"
            if BluetoothConnectionState.shouldAddAudioFallback(
                id: id, existingIDs: Set(next.map(\.id)),
                bluetoothAvailable: bluetoothAvailable,
                latestConnectionHint: connectionHints[id]?.connected
            ) {
                next.append(HeadphoneDevice(
                    id: id, name: output.name,
                    isConnected: true, isAudioOutput: true,
                    isAirPods: output.name.localizedCaseInsensitiveContains("airpods"),
                    batteryLevel: output.address.flatMap { registryBatteries[$0] },
                    leftBatteryLevel: nil, rightBatteryLevel: nil, caseBatteryLevel: nil
                ))
            }
        }

        next.sort {
            if $0.isAudioOutput != $1.isAudioOutput { return $0.isAudioOutput }
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let shouldNotify = hasSnapshot
        if devices != next { devices = next }
        hasSnapshot = true

        guard shouldNotify else { return }
        var delivered = Set<String>()
        for device in next {
            if let old = previous[device.id] {
                if old.isConnected != device.isConnected {
                    onConnectionChange?(device, device.isConnected)
                    delivered.insert(device.id)
                }
            } else if device.isConnected {
                onConnectionChange?(device, true)
                delivered.insert(device.id)
            }
        }
        // A device removed from the paired list still gets a disconnection card.
        for old in previous.values where old.isConnected && !next.contains(where: { $0.id == old.id }) {
            let disconnected = HeadphoneDevice(
                id: old.id, name: old.name, isConnected: false, isAudioOutput: false,
                isAirPods: old.isAirPods, batteryLevel: nil,
                leftBatteryLevel: nil, rightBatteryLevel: nil, caseBatteryLevel: nil,
                modelSymbol: old.modelSymbol, productID: old.productID
            )
            onConnectionChange?(disconnected, false)
        }
        for (id, connected) in pendingConnectionEvents where !delivered.contains(id) {
            if let device = next.first(where: { $0.id == id && $0.isConnected == connected }) {
                onConnectionChange?(device, connected)
            }
        }
        pendingConnectionEvents.removeAll()
    }

    private func installObservers() {
        if CBManager.authorization != .denied && CBManager.authorization != .restricted {
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: self, selector: #selector(deviceConnected(_:device:))
            )
        }
        for name in [
            "IOBluetoothHostControllerPoweredOnNotification",
            "IOBluetoothHostControllerPoweredOffNotification",
            "IOBluetoothDeviceNameChanged",
            "IOBluetoothDeviceServicesChanged"
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshSystemSnapshot() }
            })
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main, listener
        ) == noErr {
            outputListener = listener
        }
    }

    private func scheduleRefresh() {
        guard isRunning else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    @objc nonisolated private func deviceConnected(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, let id = Self.deviceID(device) else { return }
            self.observedDevices[id] = device
            self.connectionHints[id] = (true, Date().addingTimeInterval(5))
            self.pendingConnectionEvents[id] = true
            self.refreshSystemSnapshot()
        }
    }

    @objc nonisolated private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, let id = Self.deviceID(device) else { return }
            self.observedDevices[id] = device
            self.connectionHints[id] = (false, Date().addingTimeInterval(5))
            self.pendingConnectionEvents[id] = false
            self.refresh()
            self.refreshSystemSnapshot()
        }
    }

    private static func displayName(_ device: IOBluetoothDevice) -> String {
        let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (device.nameOrAddress ?? "蓝牙耳机") : name
    }

    private func refreshSystemSnapshot() {
        guard isRunning else { return }
        guard !systemRefreshRunning else { systemRefreshPending = true; return }
        systemRefreshRunning = true
        let generation = snapshotGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = BluetoothSystemSnapshot.read()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemRefreshRunning = false
                guard self.isRunning, generation == self.snapshotGeneration else { return }
                if let result { self.systemDevices = result }
                self.refresh()
                if self.systemRefreshPending {
                    self.systemRefreshPending = false
                    self.refreshSystemSnapshot()
                }
            }
        }
    }

    private static func deviceID(_ device: IOBluetoothDevice) -> String? {
        device.addressString.flatMap(normalizedAddress)
    }

    private static func cachedModelSymbol(_ device: IOBluetoothDevice) -> String? {
        // Public getServiceRecord(for:) searches only previously queried
        // services; it does not start a scan, an SDP query, or a connection.
        guard let uuid = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(
            kBluetoothSDPUUID16ServiceClassPnPInformation.rawValue
        )), let record = device.getServiceRecord(for: uuid) else { return nil }

        func uint16(_ attribute: SDPAttributeDeviceIdentificationRecord) -> Int? {
            guard let element = record.getAttributeDataElement(
                BluetoothSDPServiceAttributeID(attribute.rawValue)
            ), element.getTypeDescriptor() == 1, element.getSize() == 2,
                  let value = element.getNumberValue() else { return nil }
            let number = value.intValue
            return (0...Int(UInt16.max)).contains(number) ? number : nil
        }
        return HeadphoneModelIdentity.symbol(
            vendorIDSource: uint16(kBluetoothSDPAttributeDeviceIdentifierVendorIDSource),
            vendorID: uint16(kBluetoothSDPAttributeDeviceIdentifierVendorID),
            productID: uint16(kBluetoothSDPAttributeDeviceIdentifierProductID)
        )
    }

    private static func normalizedAddress(_ value: String) -> String? {
        guard let range = value.range(
            of: "(?i)(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}", options: .regularExpression
        ) else { return nil }
        return String(value[range]).replacingOccurrences(of: "-", with: ":").uppercased()
    }

    private static func isHeadphone(_ device: IOBluetoothDevice, name: String) -> Bool {
        if name.localizedCaseInsensitiveContains("airpods") { return true }
        if device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) {
            let headphoneClasses: Set<BluetoothDeviceClassMinor> = [
                BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioHeadset),
                BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioHandsFree),
                BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioHeadphones),
                BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioPortable)
            ]
            if headphoneClasses.contains(device.deviceClassMinor) { return true }
        }
        // Cached service records help devices that report an unclassified class.
        // This accessor does not issue a new SDP query or connect to the device.
        for service in [kBluetoothSDPUUID16ServiceClassHeadset, kBluetoothSDPUUID16ServiceClassHandsFree] {
            if let uuid = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(service.rawValue)),
               device.getServiceRecord(for: uuid) != nil { return true }
        }
        // A2DP-only headphones may lack HFP and a specific headphone class.
        // Their cached AudioSink service is sufficient when the major/minor
        // class is unknown; known loudspeakers and other device classes keep
        // their existing classification.
        let unknownAudioClass = device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
            && device.deviceClassMinor == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioUnclassified)
        if unknownAudioClass || device.deviceClassMajor == 0,
           let uuid = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassAudioSink.rawValue)),
           device.getServiceRecord(for: uuid) != nil { return true }
        let lower = name.lowercased()
        return ["headphone", "headset", "earbud", "earphone", "耳机"].contains { lower.contains($0) }
    }

    private struct AudioOutput {
        let uid: String
        let name: String
        let address: String?
    }

    private static func currentBluetoothOutput() -> AudioOutput? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != 0 else { return nil }

        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              let uid = audioString(device, selector: kAudioDevicePropertyDeviceUID),
              let name = audioString(device, selector: kAudioObjectPropertyName) else { return nil }
        return AudioOutput(uid: uid, name: name, address: normalizedAddress(uid))
    }

    private static func audioString(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        // CoreAudio's CFString properties transfer a retained object to callers.
        return value.takeRetainedValue() as String
    }

    private struct BatteryReadings {
        let single: Int?
        let left: Int?
        let right: Int?
        let chargingCase: Int?
        static let unknown = BatteryReadings(single: nil, left: nil, right: nil, chargingCase: nil)
    }

    private static func reportedBattery(_ device: IOBluetoothDevice) -> BatteryReadings {
        // macOS has no public API for the separate AirPods batteries. These
        // optional read-only selectors mirror values already held by its
        // Bluetooth stack. Check the exact Objective-C ABI before calling; a
        // missing selector, unexpected signature, or zero sentinel stays unknown.
        let single = byteBattery(device, selectorName: "batteryPercentSingle")
            ?? longBattery(device, selectorName: "headsetBattery")
        return BatteryReadings(
            single: single,
            left: byteBattery(device, selectorName: "batteryPercentLeft"),
            right: byteBattery(device, selectorName: "batteryPercentRight"),
            chargingCase: byteBattery(device, selectorName: "batteryPercentCase")
        )
    }

    private static func byteBattery(_ device: IOBluetoothDevice, selectorName: String) -> Int? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(type(of: device), selector),
              method_getNumberOfArguments(method) == 2,
              methodReturns(method, encoding: "C") else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let result = Int(getter(device, selector))
        return (1...100).contains(result) ? result : nil
    }

    private static func longBattery(_ device: IOBluetoothDevice, selectorName: String) -> Int? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(type(of: device), selector),
              method_getNumberOfArguments(method) == 2,
              methodReturns(method, encoding: "q") else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let result = getter(device, selector)
        return (1...100).contains(result) ? Int(result) : nil
    }

    private static func methodReturns(_ method: Method, encoding: String) -> Bool {
        let type = method_copyReturnType(method)
        defer { free(type) }
        return String(cString: type) == encoding
    }

    private static func registryBatteryLevels() -> [String: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBluetoothDevice"), &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: Int] = [:]
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                entry, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let percent = dictionary["BatteryPercent"] as? NSNumber,
                  (0...100).contains(percent.intValue) else { continue }
            let addressValue = dictionary["DeviceAddress"] ?? dictionary["BTAddress"] ?? dictionary["BD_ADDR"]
            let id: String?
            if let address = addressValue as? String {
                id = normalizedAddress(address)
            } else if let data = addressValue as? Data, data.count == 6 {
                id = data.map { String(format: "%02X", $0) }.joined(separator: ":")
            } else {
                id = nil
            }
            if let id { result[id] = percent.intValue }
        }
        return result
    }
}
