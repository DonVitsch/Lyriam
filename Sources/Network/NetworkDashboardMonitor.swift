import Foundation
import Combine
import Darwin
import Network
import SystemConfiguration

/// Reads this Mac's physical interface counters and the public exit observed by one HTTPS request.
/// The exit can differ between destinations when a router uses routing rules.
@MainActor
final class NetworkDashboardMonitor: ObservableObject {
    static let shared = NetworkDashboardMonitor()

    @Published private(set) var isConnected = false
    @Published private(set) var isActive = false
    @Published private(set) var interfaceName = ""
    @Published private(set) var uploadBytesPerSecond: Double?
    @Published private(set) var downloadBytesPerSecond: Double?
    @Published private(set) var publicIP = ""
    @Published private(set) var location = ""
    @Published private(set) var countryCode = ""
    @Published private(set) var isRefreshingLocation = false
    @Published private(set) var locationError: String?
    @Published private(set) var lastLocationRefresh: Date?

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.local.lyriam.network-path")
    private var preferredInterfaces: [String] = []
    private var timer: Timer?
    private var previous: NetworkCounterSample?
    private var locationTask: Task<Void, Never>?
    private var lastLocationAttempt: Date?
    private var retryAfter = Date.distantPast
    private var locationGeneration = UUID()

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            // Physical interfaces only. Adding utun counters here would count VPN packets twice.
            let names = path.availableInterfaces.filter {
                $0.type == .wifi || $0.type == .wiredEthernet || $0.type == .cellular
            }.map(\.name)
            Task { @MainActor [weak self] in
                self?.pathChanged(connected: connected, physicalInterfaces: names)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        previous = nil
        uploadBytesPerSecond = nil
        downloadBytesPerSecond = nil
        if active {
            sampleTraffic()
            refreshLocationIfNeeded()
            let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.sampleTraffic()
                    self.refreshLocationIfNeeded()
                }
            }
            RunLoop.main.add(tick, forMode: .common)
            timer = tick
        } else {
            cancelLocationRequest()
        }
    }

    func stop() {
        setActive(false)
        pathMonitor.cancel()
    }

    /// Explicit refresh still honors a brief debounce and an API rate-limit response.
    func refreshLocation() {
        guard isActive, isConnected, locationTask == nil, Date() >= retryAfter else { return }
        if let lastLocationAttempt, Date().timeIntervalSince(lastLocationAttempt) < 5 { return }
        requestLocation()
    }

    var status: String {
        if !isConnected { return "Offline" }
        if !location.isEmpty { return location }
        if isRefreshingLocation { return "Checking exit…" }
        return locationError == nil ? "Connected" : "Exit unavailable"
    }

    var flag: String {
        let scalars = countryCode.uppercased().unicodeScalars
        guard scalars.count == 2, scalars.allSatisfy({ (65...90).contains($0.value) }) else { return "🌐" }
        return String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar($0.value + 127397) }))
    }

    static func formatRate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB/s", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }

    private func pathChanged(connected: Bool, physicalInterfaces: [String]) {
        isConnected = connected
        preferredInterfaces = physicalInterfaces
        previous = nil
        uploadBytesPerSecond = nil
        downloadBytesPerSecond = nil
        cancelLocationRequest()
        publicIP = ""
        location = ""
        countryCode = ""
        lastLocationRefresh = nil
        locationError = nil
        // Keep failure/rate-limit throttles across network path updates.
        if isActive {
            sampleTraffic()
            refreshLocationIfNeeded()
        }
    }

    private func sampleTraffic() {
        guard isActive, isConnected else {
            previous = nil
            uploadBytesPerSecond = nil
            downloadBytesPerSecond = nil
            return
        }
        guard let sample = NetworkInterfaceCounters.read(preferred: preferredInterfaces) else {
            interfaceName = ""
            previous = nil
            uploadBytesPerSecond = nil
            downloadBytesPerSecond = nil
            return
        }
        interfaceName = sample.interfaceName
        if let previous, let rates = sample.rates(since: previous) {
            uploadBytesPerSecond = rates.up
            downloadBytesPerSecond = rates.down
        } else {
            uploadBytesPerSecond = nil
            downloadBytesPerSecond = nil
        }
        previous = sample
    }

    private func refreshLocationIfNeeded() {
        guard isActive, isConnected, locationTask == nil, Date() >= retryAfter else { return }
        if let lastLocationRefresh, Date().timeIntervalSince(lastLocationRefresh) < 300 { return }
        if let lastLocationAttempt, Date().timeIntervalSince(lastLocationAttempt) < 60 { return }
        requestLocation()
    }

    private func requestLocation() {
        let generation = UUID()
        locationGeneration = generation
        lastLocationAttempt = Date()
        isRefreshingLocation = true
        locationError = nil
        locationTask = Task { [weak self] in
            do {
                let result = try await NetworkExitLookup.fetch()
                guard let self, !Task.isCancelled, self.locationGeneration == generation else { return }
                self.publicIP = result.ip
                self.location = result.displayLocation
                self.countryCode = result.countryCode ?? ""
                self.lastLocationRefresh = Date()
                self.isRefreshingLocation = false
                self.locationTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.locationGeneration == generation else { return }
                if case NetworkExitLookupError.rateLimited(let seconds) = error {
                    self.retryAfter = Date().addingTimeInterval(seconds)
                }
                self.locationError = (error as? NetworkExitLookupError)?.message ?? "Unable to check the public exit. Try again later."
                self.isRefreshingLocation = false
                self.locationTask = nil
            }
        }
    }

    private func cancelLocationRequest() {
        locationGeneration = UUID()
        // A cancelled request isn't a failed lookup; reopening should get a fresh attempt.
        if locationTask != nil { lastLocationAttempt = nil }
        locationTask?.cancel()
        locationTask = nil
        isRefreshingLocation = false
    }
}

struct NetworkCounterSample {
    let interfaceName: String
    let upload: UInt64
    let download: UInt64
    let uptime: TimeInterval

    func rates(since previous: NetworkCounterSample) -> (up: Double, down: Double)? {
        let interval = uptime - previous.uptime
        guard interfaceName == previous.interfaceName, interval >= 0.2, interval <= 5,
              upload >= previous.upload, download >= previous.download else { return nil }
        return (Double(upload - previous.upload) / interval, Double(download - previous.download) / interval)
    }
}

enum NetworkInterfaceCounters {
    static func read(preferred: [String]) -> NetworkCounterSample? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return nil }
        defer { freeifaddrs(first) }
        var samples: [String: NetworkCounterSample] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let record = interface.pointee
            guard let address = record.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  record.ifa_flags & UInt32(IFF_UP) != 0,
                  record.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  record.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let pointer = record.ifa_data else { continue }
            let name = String(cString: record.ifa_name)
            // macOS physical Ethernet / Wi-Fi interfaces use en*. Include any physical interface
            // explicitly supplied by Network.framework; never select virtual utun / awdl links.
            guard name.hasPrefix("en") || preferred.contains(name),
                  !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            let data = pointer.assumingMemoryBound(to: if_data.self).pointee
            samples[name] = NetworkCounterSample(interfaceName: name, upload: UInt64(data.ifi_obytes),
                                                  download: UInt64(data.ifi_ibytes), uptime: ProcessInfo.processInfo.systemUptime)
        }
        // Prefer the physical default-route interface, then Network.framework's ordered candidates.
        // Exactly one interface is sampled, so a VPN and its underlying transport aren't added.
        let store = SCDynamicStoreCreate(nil, "Lyriam network counters" as CFString, nil, nil)
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String, let sample = samples[name] { return sample }
        }
        for name in preferred {
            if let sample = samples[name] { return sample }
        }
        // With no authoritative route, do not invent a total from unrelated interfaces.
        return nil
    }
}

struct NetworkExitResponse: Decodable {
    let success: Bool
    let ip: String
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?

    enum CodingKeys: String, CodingKey {
        case success, ip, country, region, city
        case countryCode = "country_code"
    }

    var displayLocation: String {
        var parts: [String] = []
        for value in [city, region, country].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !value.isEmpty && !parts.contains(value) {
            parts.append(value)
        }
        return parts.isEmpty ? "Unknown region" : parts.joined(separator: ", ")
    }
}

enum NetworkExitLookupError: Error {
    case unavailable, invalidResponse, rateLimited(TimeInterval)
    var message: String {
        switch self {
        case .rateLimited: return "Exit lookup limit reached. It will retry later."
        case .unavailable: return "Exit lookup is temporarily unavailable."
        case .invalidResponse: return "The exit lookup returned an unreadable response."
        }
    }
}

private final class NetworkExitSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "ipwho.is" ? request : nil)
    }
}

enum NetworkExitLookup {
    static func fetch() async throws -> NetworkExitResponse {
        // No account, API key, router access, or active speed test. The service sees the request's egress IP.
        let url = URL(string: "https://ipwho.is/?fields=success,ip,country,country_code,region,city")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NetworkExitSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await fetch(using: session, url: url)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private static func fetch(using session: URLSession, url: URL) async throws -> NetworkExitResponse {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkExitLookupError.invalidResponse }
        if http.statusCode == 429 {
            let delay = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 3600
            throw NetworkExitLookupError.rateLimited(max(60, min(delay, 86_400)))
        }
        guard http.statusCode == 200 else { throw NetworkExitLookupError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16_384 else { throw NetworkExitLookupError.invalidResponse }
            data.append(byte)
        }
        guard let result = try? JSONDecoder().decode(NetworkExitResponse.self, from: data),
              result.success, !result.ip.isEmpty, result.ip.count <= 45 else {
            throw NetworkExitLookupError.invalidResponse
        }
        return result
    }
}
